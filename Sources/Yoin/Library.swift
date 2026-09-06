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

    // Encoding the whole library (each album carries its embedded cover bytes) is expensive, so
    // it runs off the calling thread. Callers hit `save` on the main actor — often several times
    // in a tight loop (enrichment, iPod import) — so a generation token coalesces a burst into a
    // single encode+write of the latest snapshot and never blocks the UI.
    private static let ioQueue = DispatchQueue(label: "com.yoin.library.io", qos: .utility)
    private static let genLock = NSLock()
    private nonisolated(unsafe) static var generation = 0

    static func save(_ albums: [Album]) {
        // Only real content — skip the built-in sample placeholders. Cheap; stays on the caller.
        let real = albums.filter { $0.source == .bandcamp || $0.url != nil || $0.localTracks != nil }
        genLock.lock(); generation += 1; let myGen = generation; genLock.unlock()
        ioQueue.async {
            // Skip entirely if a newer save has already superseded this one.
            genLock.lock(); let current = generation; genLock.unlock()
            guard myGen == current else { return }
            guard let data = try? JSONEncoder().encode(real) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
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
