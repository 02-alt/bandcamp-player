import Foundation
import AppKit

/// Decoded cover pixels handed back from the artwork actor (Sendable so it can cross to the main
/// actor, where the NSImage is built).
struct IPodCoverPixels: Sendable {
    let rgba: [UInt8]; let width: Int; let height: Int
}

/// Reads album art straight from the iPod's own `ArtworkDB` + `.ithmb` thumbnail blobs.
/// The iPod stores art as raw RGB565 pixels (not image files), indexed by each track's persistent
/// id (dbid). An `actor` so the DB parse + file reads + pixel conversion run OFF the main thread;
/// the caller builds the NSImage on the main actor. Low-res (largest the device keeps, ~140px on a
/// Classic) but exact and fully offline.
actor IPodArtworkDB {
    private let artworkDir: URL
    private var refs: [UInt64: Ref] = [:]        // dbid → largest thumbnail reference
    private var cache: [UInt64: IPodCoverPixels?] = [:]
    private var parsed = false

    private struct Ref { let formatID: Int; let offset: Int; let size: Int; let width: Int; let height: Int }
    private static let maxDimension = 1024        // sanity cap on untrusted 16-bit dimensions

    init(volume: URL) {
        artworkDir = volume.appendingPathComponent("iPod_Control/Artwork", isDirectory: true)
    }

    /// Decoded cover pixels for a track's dbid, or nil if the iPod has no art for it.
    func cover(forDBID dbid: UInt64) -> IPodCoverPixels? {
        guard dbid != 0 else { return nil }
        if !parsed { parse(); parsed = true }
        if let hit = cache[dbid] { return hit }
        let px = refs[dbid].flatMap(decode)
        cache[dbid] = px
        return px
    }

    // MARK: ArtworkDB parsing

    private func parse() {
        guard let data = try? Data(contentsOf: artworkDir.appendingPathComponent("ArtworkDB")),
              data.count > 16 else { return }
        let d = [UInt8](data); let n = d.count
        func u32(_ o: Int) -> Int { o>=0 && o+4<=n ? Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16 | Int(d[o+3])<<24 : 0 }
        func u16(_ o: Int) -> Int { o>=0 && o+2<=n ? Int(d[o]) | Int(d[o+1])<<8 : 0 }
        func u64(_ o: Int) -> UInt64 {
            guard o>=0, o+8<=n else { return 0 }
            var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(d[o+k]) << (8*k) }; return v
        }
        func tag(_ o: Int) -> String? { o>=0 && o+4<=n ? String(bytes: d[o..<o+4], encoding: .ascii) : nil }
        guard tag(0) == "mhfd" else { return }

        var p = u32(4)
        let mhfdChildren = u32(0x14)
        var imageListMhsd = -1
        for _ in 0..<mhfdChildren {
            guard tag(p) == "mhsd" else { break }
            if u16(p+12) == 1 { imageListMhsd = p; break }   // ArtworkDB mhsd index is 16-bit
            p += max(u32(p+8), 4)
        }
        guard imageListMhsd >= 0 else { return }
        let mhli = imageListMhsd + u32(imageListMhsd+4)
        guard tag(mhli) == "mhli" else { return }
        let imageCount = u32(mhli+8)

        var q = mhli + u32(mhli+4)
        for _ in 0..<imageCount {
            guard tag(q) == "mhii" else { break }
            let mhiiTotal = u32(q+8)
            let numChildren = u32(q+12)
            let dbid = u64(q+20)                       // song_id / persistent id
            var c = q + u32(q+4)
            for _ in 0..<numChildren {
                guard tag(c) == "mhod" else { break }
                let mhodTotal = u32(c+8)
                if u16(c+12) == 2 {                    // thumbnail container
                    let mhni = c + u32(c+4)
                    if tag(mhni) == "mhni" {
                        let w = u16(mhni+34), h = u16(mhni+32)
                        let ref = Ref(formatID: u32(mhni+16), offset: u32(mhni+20),
                                      size: u32(mhni+24), width: w, height: h)
                        if w > 0, h > 0, w <= Self.maxDimension, h <= Self.maxDimension, ref.size > 0 {
                            if let cur = refs[dbid], cur.width >= w {} else { refs[dbid] = ref }
                        }
                    }
                }
                c += max(mhodTotal, 4)
            }
            q += max(mhiiTotal, 4)
        }
    }

    // MARK: ithmb decode (RGB565 LE)

    private func decode(_ ref: Ref) -> IPodCoverPixels? {
        let file = artworkDir.appendingPathComponent("F\(ref.formatID)_1.ithmb")
        guard let fh = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(ref.offset))
        guard let raw = try? fh.read(upToCount: ref.size), raw.count >= ref.width*ref.height*2, ref.height > 0
        else { return nil }

        let w = ref.width, h = ref.height
        let stride = raw.count / h
        var rgba = [UInt8](repeating: 0, count: w*h*4)
        raw.withUnsafeBytes { buf in
            let px = buf.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y*stride + x*2
                    guard i+1 < raw.count else { continue }
                    let v = UInt16(px[i]) | (UInt16(px[i+1]) << 8)
                    let o = (y*w + x)*4
                    rgba[o]   = UInt8((Int((v >> 11) & 0x1F) * 255) / 31)   // R
                    rgba[o+1] = UInt8((Int((v >> 5)  & 0x3F) * 255) / 63)   // G
                    rgba[o+2] = UInt8((Int(v & 0x1F)        * 255) / 31)    // B
                    rgba[o+3] = 255
                }
            }
        }
        return IPodCoverPixels(rgba: rgba, width: w, height: h)
    }
}

/// Build an NSImage from decoded cover pixels (call on the main actor from the view).
func iPodCoverImage(_ px: IPodCoverPixels) -> NSImage? {
    guard let provider = CGDataProvider(data: Data(px.rgba) as CFData) else { return nil }
    guard let cg = CGImage(width: px.width, height: px.height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: px.width*4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true,
                           intent: .defaultIntent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: px.width, height: px.height))
}
