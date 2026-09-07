import Foundation

/// Persistent artist → place-of-origin cache (from MusicBrainz), keyed by lowercased artist name
/// so it's **independent of the album list**: a Bandcamp re-sync rebuilds `Album`s from scratch
/// (with no location), but this cache survives, so the map doesn't reset and nothing is re-fetched.
/// An empty string is a deliberate "known miss" — the artist was looked up and MusicBrainz had no
/// area — so we don't keep re-querying them. Mirrors `BPMStore`'s persistence.
@MainActor
final class ArtistLocationStore: ObservableObject {
    static let shared = ArtistLocationStore()

    @Published private(set) var map: [String: String]   // artist(lowercased) -> location ("" = miss)
    private init() { map = Self.load() }

    static func key(_ artist: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The resolved location for an artist, or nil if unknown/miss.
    func location(forArtist artist: String) -> String? {
        guard let v = map[Self.key(artist)], !v.isEmpty else { return nil }
        return v
    }

    /// Whether we've already looked this artist up (hit or miss) — so we skip re-querying.
    func resolved(_ artist: String) -> Bool { map[Self.key(artist)] != nil }

    func store(_ location: String, for artist: String) { map[Self.key(artist)] = location }

    // MARK: Persistence

    private static let ioQueue = DispatchQueue(label: "com.yoin.artistloc.io", qos: .utility)

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
        return dir.appendingPathComponent("artistLocations.json")
    }

    private nonisolated static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }
}
