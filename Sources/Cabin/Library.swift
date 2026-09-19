import Foundation

/// The persistence seam for the user's library (imported files + Bandcamp albums &
/// download state). Kept as a protocol so a cloud-backed or platform-specific store
/// (e.g. the iOS app) can stand in for the local file store without touching call sites.
protocol LibraryStore {
    func load() -> [Album]
    func save(_ albums: [Album])
}

/// File-backed store: `<Application Support>/Vinyl/library.json`. The macOS default.
struct LocalLibraryStore: LibraryStore {
    static let shared = LocalLibraryStore()

    private var fileURL: URL {
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
    private static let ioQueue = DispatchQueue(label: "com.cabin.library.io", qos: .utility)
    private static let genLock = NSLock()
    private nonisolated(unsafe) static var generation = 0

    func save(_ albums: [Album]) {
        // Only real content — skip the built-in sample placeholders. Cheap; stays on the caller.
        let real = albums.filter { $0.source == .bandcamp || $0.url != nil || $0.localTracks != nil }
        Self.genLock.lock(); Self.generation += 1; let myGen = Self.generation; Self.genLock.unlock()
        let target = fileURL
        Self.ioQueue.async {
            // Skip entirely if a newer save has already superseded this one.
            Self.genLock.lock(); let current = Self.generation; Self.genLock.unlock()
            guard myGen == current else { return }
            guard let data = try? JSONEncoder().encode(real) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    func load() -> [Album] {
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

/// Thin facade over the active `LibraryStore`. Call sites use `Library.load()/save(_:)`;
/// swap `store` to change where the library lives (e.g. a cloud-syncing wrapper).
enum Library {
    /// The active store. Swappable so a cloud-backed or iOS store can stand in.
    /// Set once at startup before any load/save, so unguarded mutation is safe.
    nonisolated(unsafe) static var store: LibraryStore = LocalLibraryStore.shared

    static func save(_ albums: [Album]) { store.save(albums) }
    static func load() -> [Album] { store.load() }
}
