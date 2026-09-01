import Foundation

/// Persists the user's library (imported files + Bandcamp albums & download state) to disk.
enum Library {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    static func save(_ albums: [Album]) {
        // Only real content — skip the built-in sample placeholders.
        let real = albums.filter { $0.source == .bandcamp || $0.url != nil || $0.localTracks != nil }
        guard let data = try? JSONEncoder().encode(real) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> [Album] {
        guard let data = try? Data(contentsOf: fileURL),
              var albums = try? JSONDecoder().decode([Album].self, from: data) else { return [] }
        // Drop download links to files that no longer exist on disk.
        for i in albums.indices {
            if let tracks = albums[i].localTracks {
                let present = tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
                albums[i].localTracks = present.isEmpty ? nil : present
            }
        }
        // Drop imported entries whose source file is gone.
        albums.removeAll { $0.source == .local && $0.url != nil && !FileManager.default.fileExists(atPath: $0.url!.path) }
        // Collapse any duplicates left by earlier re-syncs (keep the first occurrence).
        var seen = Set<String>()
        albums = albums.filter { seen.insert($0.dedupeKey).inserted }
        return albums
    }
}
