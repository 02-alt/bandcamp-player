import Foundation
import AppKit
import ImageIO

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

/// Writes cover art for newly-added tracks into the iPod's `ArtworkDB` + `.ithmb` thumbnail blobs.
///
/// Rather than synthesise the (model-specific) database structures from scratch, it CLONES an
/// existing image entry (`mhii`) from the device's own ArtworkDB — so the byte layout, thumbnail
/// formats and sizes match exactly whatever iTunes wrote — and only repoints the clone at freshly
/// appended RGB565 pixels (and stamps the new track's persistent id). Best-effort: any failure
/// leaves the already-playable tracks untouched (they just show no cover).
enum IPodArtworkWriter {
    /// One thumbnail format the device keeps (learned from the template `mhii`).
    struct Format { let id: Int; let width: Int; let height: Int; let size: Int; let mhniRel: Int }
    /// A clonable image entry + the formats it carries.
    struct Template { let mhii: [UInt8]; let songIDRel: Int; let formats: [Format] }

    private static func u32(_ d: [UInt8], _ o: Int) -> Int { guard o>=0, o+4<=d.count else { return 0 }; return Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16 | Int(d[o+3])<<24 }
    private static func u16(_ d: [UInt8], _ o: Int) -> Int { guard o>=0, o+2<=d.count else { return 0 }; return Int(d[o]) | Int(d[o+1])<<8 }
    private static func u64(_ d: [UInt8], _ o: Int) -> UInt64 { guard o>=0, o+8<=d.count else { return 0 }; var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(d[o+k]) << (8*k) }; return v }
    private static func tag(_ d: [UInt8], _ o: Int) -> String? { guard o>=0, o+4<=d.count else { return nil }; return String(bytes: d[o..<o+4], encoding: .ascii) }
    private static func setU32(_ d: inout [UInt8], _ o: Int, _ v: Int) { guard o>=0, o+4<=d.count else { return }; d[o]=UInt8(v&0xFF); d[o+1]=UInt8((v>>8)&0xFF); d[o+2]=UInt8((v>>16)&0xFF); d[o+3]=UInt8((v>>24)&0xFF) }
    private static func setU64(_ d: inout [UInt8], _ o: Int, _ v: UInt64) { guard o>=0, o+8<=d.count else { return }; for k in 0..<8 { d[o+k]=UInt8((v >> (8*k)) & 0xFF) } }

    /// Locate the image list, returning (imageMhsd, mhli, endOfImages) offsets, or nil.
    private static func imageList(_ d: [UInt8]) -> (mhsd: Int, mhli: Int, count: Int, start: Int)? {
        guard tag(d, 0) == "mhfd" else { return nil }
        var p = u32(d, 4)
        let children = u32(d, 0x14)
        var mhsd = -1
        for _ in 0..<children {
            guard tag(d, p) == "mhsd" else { break }
            if u16(d, p+12) == 1 { mhsd = p; break }     // ArtworkDB mhsd index is 16-bit
            p += max(u32(d, p+8), 4)
        }
        guard mhsd >= 0 else { return nil }
        let mhli = mhsd + u32(d, mhsd+4)
        guard tag(d, mhli) == "mhli" else { return nil }
        return (mhsd, mhli, u32(d, mhli+8), mhli + u32(d, mhli+4))
    }

    /// Parse ArtworkDB → a clone template (the first image entry with ≥1 thumbnail) + every song_id
    /// already carrying art. A nil template means there's nothing to clone (skip artwork).
    static func readTemplate(volume: URL) -> (template: Template?, dbids: Set<UInt64>) {
        let dir = volume.appendingPathComponent("iPod_Control/Artwork", isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("ArtworkDB")), data.count > 16 else { return (nil, []) }
        let d = [UInt8](data)
        guard let (_, _, count, start) = imageList(d) else { return (nil, []) }
        var dbids = Set<UInt64>()
        var template: Template? = nil
        var q = start
        for _ in 0..<count {
            guard tag(d, q) == "mhii" else { break }
            let total = max(u32(d, q+8), 4)
            let songID = u64(d, q+20)
            if songID != 0 { dbids.insert(songID) }
            if template == nil {
                let numChildren = u32(d, q+12)
                var c = q + u32(d, q+4)
                var formats: [Format] = []
                for _ in 0..<numChildren {
                    guard tag(d, c) == "mhod" else { break }
                    let mhodTotal = max(u32(d, c+8), 4)
                    if u16(d, c+12) == 2 {                      // thumbnail container
                        let mhni = c + u32(d, c+4)
                        if tag(d, mhni) == "mhni" {
                            let fid = u32(d, mhni+16), size = u32(d, mhni+24)
                            let h = u16(d, mhni+32), w = u16(d, mhni+34)
                            if w > 0, h > 0, size >= w*h*2 { formats.append(Format(id: fid, width: w, height: h, size: size, mhniRel: mhni - q)) }
                        }
                    }
                    c += mhodTotal
                }
                if !formats.isEmpty, let bytes = slice(d, q, total) { template = Template(mhii: bytes, songIDRel: 20, formats: formats) }
            }
            q += total
        }
        return (template, dbids)
    }

    /// Clone the template once per entry, repoint each thumbnail at freshly appended pixels, and
    /// splice the new `mhii` block into ArtworkDB. Returns true if anything was written.
    @discardableResult
    static func append(volume: URL, entries: [(dbid: UInt64, artwork: Data)], template: Template) -> Bool {
        let dir = volume.appendingPathComponent("iPod_Control/Artwork", isDirectory: true)
        let dbURL = dir.appendingPathComponent("ArtworkDB")
        guard var d = (try? Data(contentsOf: dbURL)).map({ [UInt8]($0) }),
              let (mhsd, mhli, _, start) = imageList(d) else { return false }
        // Walk to the end of the current image list = insertion point.
        var appendAt = start
        var walked = start
        let count = u32(d, mhli+8)
        for _ in 0..<count { guard tag(d, walked) == "mhii" else { break }; walked += max(u32(d, walked+8), 4); appendAt = walked }
        try? Data(d).write(to: dbURL.appendingPathExtension("cabinbak"))

        var newBlock: [UInt8] = []
        var added = 0
        for e in entries {
            guard let cg = decodeImage(e.artwork) else { continue }
            var mhii = template.mhii
            setU64(&mhii, template.songIDRel, e.dbid)
            var wroteAny = false
            for f in template.formats {
                let px = rgb565(cg, width: f.width, height: f.height, targetSize: f.size)
                guard px.count == f.size, let offset = appendThumbnail(px, to: dir.appendingPathComponent("F\(f.id)_1.ithmb")) else { continue }
                setU32(&mhii, f.mhniRel + 20, offset)   // ithmb_offset (size @ +24 stays the template's)
                wroteAny = true
            }
            if wroteAny { newBlock += mhii; added += 1 }
        }
        guard added > 0 else { return false }
        d.insert(contentsOf: newBlock, at: appendAt)
        setU32(&d, mhli+8, u32(d, mhli+8) + added)              // image count
        setU32(&d, mhsd+8, u32(d, mhsd+8) + newBlock.count)     // mhsd total_len
        setU32(&d, 8, u32(d, 8) + newBlock.count)               // mhfd total_len
        do { try Data(d).write(to: dbURL) } catch { return false }
        return true
    }

    private static func slice(_ d: [UInt8], _ o: Int, _ len: Int) -> [UInt8]? {
        guard o >= 0, len > 0, o+len <= d.count else { return nil }
        return Array(d[o..<o+len])
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Render `cg` to a `width×height` RGB565 (little-endian) thumbnail padded to `targetSize` bytes
    /// (the device's declared image size — rows may carry padding).
    private static func rgb565(_ cg: CGImage, width w: Int, height h: Int, targetSize: Int) -> [UInt8] {
        guard w > 0, h > 0 else { return [] }
        let bpr = w * 4
        var rgba = [UInt8](repeating: 0, count: bpr * h)
        rgba.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let stride = max(w * 2, targetSize / max(h, 1))
        var out = [UInt8](repeating: 0, count: stride * h)
        for y in 0..<h {
            let srcY = h - 1 - y                 // CGContext origin is bottom-left; iPod rows go top→bottom
            for x in 0..<w {
                let o = srcY * bpr + x * 4
                let v = (UInt16(rgba[o] >> 3) << 11) | (UInt16(rgba[o+1] >> 2) << 5) | UInt16(rgba[o+2] >> 3)
                let po = y * stride + x * 2
                out[po] = UInt8(v & 0xFF); out[po+1] = UInt8(v >> 8)
            }
        }
        if out.count < targetSize { out += [UInt8](repeating: 0, count: targetSize - out.count) }
        else if out.count > targetSize { out = Array(out.prefix(targetSize)) }
        return out
    }

    /// Append RGB565 bytes to a `.ithmb`, returning the byte offset they were written at.
    private static func appendThumbnail(_ px: [UInt8], to file: URL) -> Int? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        guard let fh = try? FileHandle(forWritingTo: file) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        do { try fh.write(contentsOf: Data(px)) } catch { return nil }
        return Int(end)
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
