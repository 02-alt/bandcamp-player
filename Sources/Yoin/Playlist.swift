import Foundation

/// One track inside a playlist. Denormalised (title/artist/cover) so a playlist stays
/// readable even if the album is later removed, but keyed by `albumID` + `trackIndex`
/// so playback can re-resolve fresh stream URLs (Bandcamp links expire).
struct PlaylistTrack: Identifiable, Codable, Equatable {
    var id = UUID()
    var albumID: UUID
    var albumTitle: String
    var artist: String
    var title: String
    /// Position of this track within its album's resolved track list.
    var trackIndex: Int
    var artworkURL: URL?
    var artworkData: Data?
    var g0: Double = 0.28
    var g1: Double = 0.08
}

/// A user-built, ordered collection of tracks.
struct Playlist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var tracks: [PlaylistTrack] = []
    var createdAt: Date = Date()
    /// A user-chosen cover image (PNG), overriding the auto-generated cover mosaic.
    var coverImageData: Data?

    var isEmpty: Bool { tracks.isEmpty }
    /// Distinct album covers (front of the list first) for the stacked mosaic thumbnail.
    var coverTracks: [PlaylistTrack] {
        var seen = Set<UUID>()
        return tracks.filter { seen.insert($0.albumID).inserted }
    }
}

/// Persists playlists next to the library / history, in the app-support "Vinyl" folder.
enum PlaylistStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlists.json")
    }

    static func load() -> [Playlist] {
        guard let data = try? Data(contentsOf: fileURL),
              let lists = try? JSONDecoder().decode([Playlist].self, from: data) else { return [] }
        return lists
    }

    static func save(_ lists: [Playlist]) {
        guard let data = try? JSONEncoder().encode(lists) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
