import Foundation

/// One logged listen: a track that was played, and for how long. The append-only
/// stream of these feeds the year-end "recap" (top albums, covers, share link).
struct PlayEvent: Codable, Sendable {
    /// The album this track belonged to, when known — used to join back to live
    /// artwork and Bandcamp links at recap time.
    var albumID: UUID?
    /// Denormalised so the log stays human-readable even if the album is later removed.
    var albumTitle: String
    var artist: String
    var trackTitle: String
    var date: Date
    /// Seconds actually elapsed on this track before moving on / stopping.
    var seconds: Double
    /// Track length when known (0 if the stream never reported one).
    var duration: Double

    /// A play counts as a real listen (not a skip) once it ran ≥30s or ≥half the track.
    var isRealListen: Bool {
        seconds >= 30 || (duration > 0 && seconds / duration >= 0.5)
    }
}

/// Append-only listening history, persisted next to the library. Feeds the recap, stats,
/// smart playlists and radio — all of which read it often, so it's backed by an in-memory
/// cache (decoded from disk once) with writes pushed to a background queue. That keeps the
/// hot read paths off the disk and, crucially, the whole-file rewrite off the main thread,
/// where it used to run on every finished track and could stall the UI as history grew.
enum HistoryStore {
    private static let lock = NSLock()
    private static let writeQueue = DispatchQueue(label: "app.yoin.history-write", qos: .utility)
    /// Authoritative once loaded; guarded by `lock`. `nonisolated(unsafe)` because the lock,
    /// not the actor system, provides the synchronisation.
    nonisolated(unsafe) private static var cache: [PlayEvent]?

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private static func readDisk() -> [PlayEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([PlayEvent].self, from: data) else { return [] }
        return events
    }

    /// Cached events, seeding the cache from disk on first access. Assumes `lock` is held.
    private static func cachedLocked() -> [PlayEvent] {
        if let c = cache { return c }
        let loaded = readDisk()
        cache = loaded
        return loaded
    }

    static func load() -> [PlayEvent] {
        lock.lock(); defer { lock.unlock() }
        return cachedLocked()
    }

    /// Append one event: update the cache immediately, then persist off the main thread.
    static func append(_ event: PlayEvent) {
        lock.lock()
        var all = cachedLocked()
        all.append(event)
        cache = all
        lock.unlock()
        persist(all)
    }

    private static func persist(_ events: [PlayEvent]) {
        writeQueue.async {
            guard let data = try? JSONEncoder().encode(events) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
