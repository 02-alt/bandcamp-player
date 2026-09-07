import Foundation

/// One timestamped line of synced lyrics.
struct LrcLine: Equatable {
    let time: Double     // seconds from track start
    let text: String     // may be empty (an instrumental gap between sung lines)
}

/// Time-synced lyrics for a track: lines sorted ascending by timestamp. Only ever built from
/// LRCLIB's `syncedLyrics` (we don't surface plain/unsynced lyrics — see the Settings copy).
struct SyncedLyrics: Equatable {
    let lines: [LrcLine]

    /// Index of the line that should be highlighted at `t` seconds — the last line whose
    /// timestamp is at or before `t`, or nil before the first line begins.
    func activeIndex(at t: Double) -> Int? {
        guard let first = lines.first, t >= first.time else { return nil }
        // Lines are sorted; walk from the end for the last one that has started.
        var idx = 0
        for (i, line) in lines.enumerated() where line.time <= t { idx = i }
        return idx
    }
}

/// Parses LRCLIB `syncedLyrics` (standard `.lrc`) into ordered `LrcLine`s.
/// Handles multiple timestamps on one line (`[00:12.00][00:47.00] chorus`) and ignores
/// `[ar:]`/`[ti:]`/`[length:]` metadata tags. Returns nil if no timestamped lines are found.
enum LRC {
    static func parse(_ raw: String) -> SyncedLyrics? {
        var lines: [LrcLine] = []
        // [mm:ss] or [mm:ss.xx] / [mm:ss.xxx]
        let stampPattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let re = try? NSRegularExpression(pattern: stampPattern) else { return nil }

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let ns = line as NSString
            let stamps = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !stamps.isEmpty else { continue }   // metadata tag or plain text — skip

            // Text is everything after the final timestamp on the line.
            let textStart = stamps.map { $0.range.location + $0.range.length }.max() ?? 0
            let text = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)

            for m in stamps {
                let mins = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let secs = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                lines.append(LrcLine(time: mins * 60 + secs + frac, text: text))
            }
        }
        guard !lines.isEmpty else { return nil }
        lines.sort { $0.time < $1.time }
        return SyncedLyrics(lines: lines)
    }
}

/// Fetches time-synced lyrics from LRCLIB (https://lrclib.net) and caches results — including
/// misses — on disk so each track hits the network at most once.
enum LyricsService {
    private static let session = URLSession(configuration: .default)
    private static let userAgent = "Yoin (+https://github.com/02-alt/bandcamp-player)"

    /// Synced lyrics for a track, or nil if LRCLIB has none. `durationSec` sharpens the exact-match
    /// endpoint; a fuzzy search is used as a fallback. Results are memoised on disk via `LyricsStore`.
    @MainActor
    static func synced(artist: String, title: String, album: String, durationSec: Double) async -> SyncedLyrics? {
        let key = LyricsStore.key(artist: artist, title: title)
        if let cached = LyricsStore.shared.cached(key) {          // hit or known-miss
            return cached.isEmpty ? nil : LRC.parse(cached)
        }
        let raw = await fetch(artist: artist, title: title, album: album, durationSec: durationSec)
        LyricsStore.shared.store(raw ?? "", for: key)             // "" marks a miss
        LyricsStore.shared.save()
        return raw.flatMap(LRC.parse)
    }

    /// Returns the raw `syncedLyrics` string from LRCLIB, or nil.
    private static func fetch(artist: String, title: String, album: String, durationSec: Double) async -> String? {
        // 1) Exact-match endpoint (fast, precise) when we have a plausible duration.
        if durationSec > 0,
           var c = URLComponents(string: "https://lrclib.net/api/get") {
            c.queryItems = [.init(name: "artist_name", value: artist),
                            .init(name: "track_name", value: title),
                            .init(name: "album_name", value: album),
                            .init(name: "duration", value: String(Int(durationSec.rounded())))]
            if let u = c.url, let hit: LRCLIBTrack = try? await get(u), let s = hit.syncedLyrics, !s.isEmpty {
                return s
            }
        }
        // 2) Fuzzy search fallback — first result that actually carries synced lyrics.
        guard var c = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        c.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        guard let u = c.url, let results: [LRCLIBTrack] = try? await get(u) else { return nil }
        return results.first(where: { !($0.syncedLyrics ?? "").isEmpty })?.syncedLyrics
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct LRCLIBTrack: Decodable {
        let syncedLyrics: String?
    }
}

/// Persistent cache of LRCLIB `syncedLyrics` strings, keyed by "<artist>|<title>" (lowercased).
/// Mirrors `BPMStore`: synchronous load on init, debounced off-main writes. An empty string is a
/// deliberate "known miss" so we don't re-hit the network for tracks LRCLIB doesn't have.
@MainActor
final class LyricsStore {
    static let shared = LyricsStore()

    private var map: [String: String]
    private init() { map = Self.load() }

    static func key(artist: String, title: String) -> String {
        "\(artist)|\(title)".lowercased()
    }

    /// Cached raw LRC ("" = known miss), or nil if never fetched.
    func cached(_ key: String) -> String? { map[key] }
    func store(_ raw: String, for key: String) { map[key] = raw }

    // MARK: Persistence

    private static let ioQueue = DispatchQueue(label: "com.yoin.lyrics.io", qos: .utility)

    func save() {
        let snapshot = map
        Self.ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private nonisolated static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lyrics.json")
    }

    private nonisolated static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }
}
