import Foundation

/// Individually "liked" songs — as opposed to whole-album favourites (`Album.isFavourite`).
/// Stored denormalised as `PlaylistTrack`s (like playlists) so they survive album removal
/// and can re-resolve fresh stream URLs, and so the "Liked Songs" list reuses playlist UI.
enum LikedSongsStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("liked.json")
    }

    static func load() -> [PlaylistTrack] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([PlaylistTrack].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [PlaylistTrack]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
