import Foundation

/// Persistent cache of resolved Bandcamp tracklists, keyed by the album's public page URL
/// (stable across re-syncs, like `ArtistLocationStore`). Two jobs:
///
///  1. **Instant display** — an album page can render its tracklist immediately from cache
///     instead of waiting on a network scrape, even after a relaunch.
///  2. **Skip re-scraping** — Bandcamp stream URLs are signed and time-limited, so we only
///     *reuse* cached URLs for playback while they're still fresh (`streamTTL`); past that we
///     re-resolve. The stored metadata (titles/order/art) stays useful regardless of age.
@MainActor
final class TracklistCache {
    static let shared = TracklistCache()

    /// How long a cached stream URL is presumed playable. Bandcamp tokens outlive this, but we
    /// stay conservative so a reused URL never 403s mid-play; display is instant either way.
    static let streamTTL: TimeInterval = 30 * 60

    struct CachedTrack: Codable {
        var title: String
        var artist: String
        var streamURL: String
        var artworkURL: String?
        var duration: TimeInterval?   // optional: legacy entries decode as nil and re-resolve
    }
    struct Entry: Codable {
        var tracks: [CachedTrack]
        var fetchedAt: Date
    }

    private var map: [String: Entry]   // itemURL -> entry
    private init() { map = Self.load() }

    // MARK: Read

    /// Tracklist for display — cached metadata regardless of age. Stream URLs may be stale;
    /// callers that need to *play* should still go through `resolveTracks`.
    func displayTracks(for album: Album) -> [Track]? {
        guard let key = album.bandcampItemURL, let entry = map[key] else { return nil }
        return build(entry, album: album)
    }

    /// Tracklist safe to play *now* — only returned while the stream URLs are still fresh.
    func freshTracks(for album: Album) -> [Track]? {
        guard let key = album.bandcampItemURL, let entry = map[key],
              Date().timeIntervalSince(entry.fetchedAt) < Self.streamTTL else { return nil }
        return build(entry, album: album)
    }

    private func build(_ entry: Entry, album: Album) -> [Track]? {
        let tracks = entry.tracks.enumerated().compactMap { i, c -> Track? in
            guard let url = URL(string: c.streamURL) else { return nil }
            return Track(title: c.title, artist: c.artist, streamURL: url,
                         artworkURL: c.artworkURL.flatMap(URL.init(string:)),
                         albumID: album.id, trackIndex: i,
                         duration: c.duration, g0: album.g0, g1: album.g1)
        }
        return tracks.isEmpty ? nil : tracks
    }

    // MARK: Write

    func store(_ tracks: [Track], forItemURL itemURL: String) {
        guard !tracks.isEmpty else { return }
        map[itemURL] = Entry(tracks: tracks.map {
            CachedTrack(title: $0.title, artist: $0.artist,
                        streamURL: $0.streamURL.absoluteString, artworkURL: $0.artworkURL?.absoluteString,
                        duration: $0.duration)
        }, fetchedAt: Date())
        save()
    }

    /// Drop a cached entry so the next resolve re-scrapes (e.g. user hits "Reload from Bandcamp").
    func invalidate(forItemURL itemURL: String?) {
        guard let itemURL, map[itemURL] != nil else { return }
        map[itemURL] = nil
        save()
    }

    // MARK: Persistence

    private static let ioQueue = DispatchQueue(label: "com.cabin.tracklistcache.io", qos: .utility)

    private func save() {
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
        return dir.appendingPathComponent("tracklists.json")
    }

    private nonisolated static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return m
    }
}
