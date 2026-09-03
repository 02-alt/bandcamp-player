import Foundation
import AppKit
import Combine

/// A click-wheel iPod (Classic / Video / Nano / Mini / Shuffle) mounted as a USB disk.
/// Detected by the tell-tale `iPod_Control` folder at a volume's root. (iPod Touch syncs over
/// Apple's proprietary protocol and never mounts as a disk, so it can't appear here.)
struct IPodDevice: Equatable, Identifiable {
    var id: URL { volumeURL }
    let volumeURL: URL
    let name: String
    let totalBytes: Int64
    let freeBytes: Int64
    /// The iPod's USB serial = its FireWire GUID, needed to sign the database (hash58). Nil if
    /// it couldn't be read — in which case adding songs is disabled (we won't write an unsigned DB).
    var serial: String?

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var iTunesDBURL: URL { volumeURL.appendingPathComponent("iPod_Control/iTunes/iTunesDB") }
}

/// One track read from the iPod's `iTunesDB` (read-only browse — Phase 2).
struct IPodTrack: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var artist: String
    var album: String
    var durationMs: Int
    /// The track's persistent id (mhit song_id @0x70) — links to artwork in the ArtworkDB.
    var dbid: UInt64 = 0
    /// The mhit track id (@0x10) — used to remove the track (and its playlist entries).
    var trackID: Int = 0
    /// iPod-style file path (mhod type 2), e.g. ":iPod_Control:Music:F09:DVSI.mp3".
    var location: String = ""
}

/// Watches for a click-wheel iPod mounting/unmounting and publishes the current device.
/// The iPod tab only appears while `device != nil`.
@MainActor
final class IPodWatcher: ObservableObject {
    @Published private(set) var device: IPodDevice?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            // Block-based observers are retained by the center for the app's lifetime (this watcher
            // is an app-lifetime @StateObject); the weak self means they never fire into a dead one.
            _ = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scan()
            }
        }
        scan()
    }

    /// Re-scan for an iPod, doing the blocking I/O (volume enumeration + `ioreg`) OFF the main
    /// thread, then publishing the result on the main actor.
    func scan() {
        Task { [weak self] in
            let dev = await IPodWatcher.findDevice()
            guard let self else { return }
            if self.device != dev { self.device = dev }
        }
    }

    /// Read the connected iPod's USB serial (its FireWire GUID) via `ioreg`. Used to sign the DB.
    nonisolated static func readSerial() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        proc.arguments = ["-r", "-n", "iPod", "-l"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        // Line looks like:  "USB Serial Number" = "000A2700215EBB72"
        for line in out.split(separator: "\n") where line.contains("Serial Number") {
            if let r = line.range(of: "\"[0-9A-Fa-f]{8,}\"", options: .regularExpression) {
                return String(line[r]).replacingOccurrences(of: "\"", with: "")
            }
        }
        return nil
    }

    /// Find a connected click-wheel iPod (nonisolated async → runs off the main actor).
    nonisolated static func findDevice() async -> IPodDevice? {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        for url in vols {
            let control = url.appendingPathComponent("iPod_Control")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: control.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            return IPodDevice(
                volumeURL: url,
                name: vals?.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(vals?.volumeTotalCapacity ?? 0),
                freeBytes: Int64(vals?.volumeAvailableCapacity ?? 0),
                serial: readSerial()
            )
        }
        return nil
    }
}

/// Read-only parser for the iPod's `iTunesDB` (little-endian chunked format). We scan for `mhit`
/// (track) records and pull their `mhod` string children — robust across DB versions because it
/// keys off each chunk's own header/total-length fields rather than hard-coded sizes.
///
/// Layout used (offsets relative to a chunk's 4-byte tag):
///   any chunk:  +4 header length, +8 total length (header + children)
///   mhit:       +12 mhod count, +40 duration(ms), +44 track number
///   mhod:       +12 type (1 title, 2 location, 3 album, 4 artist, 5 genre)
///               then at +headerLen: +4 byte-length, +16 UTF-16LE string
/// Looks up real album art from iTunes for an iPod album (its own artwork is a proprietary
/// thumbnail DB we don't read). Memoized — including misses — so each album is fetched once.
@MainActor
final class IPodArt {
    static let shared = IPodArt()
    private var cache: [String: URL?] = [:]

    func coverURL(artist: String, album: String) async -> URL? {
        let key = "\(artist)|\(album)".lowercased()
        if let cached = cache[key] { return cached }
        let term = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { cache[key] = URL?.none; return nil }
        let url = await Self.fetch(term)
        cache[key] = url
        return url
    }

    private static func fetch(_ term: String) async -> URL? {
        guard var c = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        c.queryItems = [.init(name: "term", value: term),
                        .init(name: "entity", value: "album"),
                        .init(name: "limit", value: "1")]
        guard let u = c.url,
              let (data, _) = try? await URLSession.shared.data(from: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let art = (results.first?["artworkUrl100"]) as? String else { return nil }
        return URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }
}

enum IPodDB {
    static func tracks(atVolume volumeURL: URL, limit: Int = 100_000) -> [IPodTrack] {
        let dbURL = volumeURL.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        guard let data = try? Data(contentsOf: dbURL), data.count > 16 else { return [] }
        return parse(data, limit: limit)
    }

    static func parse(_ data: Data, limit: Int) -> [IPodTrack] {
        var tracks: [IPodTrack] = []
        let n = data.count

        func u32(_ off: Int) -> Int {
            guard off >= 0, off + 4 <= n else { return 0 }
            return Int(data[off]) | Int(data[off + 1]) << 8 | Int(data[off + 2]) << 16 | Int(data[off + 3]) << 24
        }
        func u64(_ off: Int) -> UInt64 {
            guard off >= 0, off + 8 <= n else { return 0 }
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(data[off + k]) << (8 * k) }
            return v
        }
        func tag(_ off: Int) -> String? {
            guard off + 4 <= n else { return nil }
            return String(bytes: data[off..<off + 4], encoding: .ascii)
        }
        func string(at off: Int, byteLen: Int) -> String? {
            guard byteLen > 0, off >= 0, off + byteLen <= n else { return nil }
            return String(bytes: data[off..<off + byteLen], encoding: .utf16LittleEndian)
        }

        var p = 0
        while p + 16 <= n && tracks.count < limit {
            guard tag(p) == "mhit" else { p += 1; continue }
            let headerLen = u32(p + 4)
            let totalLen = u32(p + 8)
            let mhodCount = u32(p + 12)
            let durationMs = u32(p + 40)
            let dbid = u64(p + 112)      // mhit song_id (persistent id) → ArtworkDB link
            let trackID = u32(p + 16)

            var title = "", artist = "", album = "", location = ""
            var q = p + max(headerLen, 16)
            var parsed = 0
            while parsed < mhodCount, q + 16 <= n, tag(q) == "mhod" {
                let mhodHeader = u32(q + 4)
                let mhodTotal = u32(q + 8)
                let type = u32(q + 12)
                if (1...5).contains(type) {
                    let byteLen = u32(q + mhodHeader + 4)
                    if let s = string(at: q + mhodHeader + 16, byteLen: byteLen) {
                        switch type {
                        case 1: title = s
                        case 2: location = s
                        case 3: album = s
                        case 4: artist = s
                        default: break
                        }
                    }
                }
                guard mhodTotal > 0 else { break }
                q += mhodTotal
                parsed += 1
            }

            // Skip phantom/placeholder records: the iPod stores some non-song entries whose
            // "title" is just a long numeric persistent-ID (no real song is a 10+ digit number).
            let isPlaceholder = title.count > 10 && title.allSatisfy(\.isNumber)
            if !isPlaceholder && !(title.isEmpty && artist.isEmpty && album.isEmpty) {
                tracks.append(IPodTrack(title: title.isEmpty ? "Unknown track" : title,
                                        artist: artist, album: album, durationMs: durationMs,
                                        dbid: dbid, trackID: trackID, location: location))
            }
            // Skip past this record's children when the total length is sane; otherwise inch forward.
            p += (totalLen > headerLen && totalLen < n) ? totalLen : 4
        }
        return tracks
    }
}
