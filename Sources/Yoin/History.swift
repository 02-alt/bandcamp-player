import Foundation

/// One logged listen: a track that was played, and for how long. The append-only
/// stream of these feeds the year-end "recap" (top albums, covers, share link).
struct PlayEvent: Codable {
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

/// Append-only listening history, persisted next to the library. Feeds the recap.
enum HistoryStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [PlayEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([PlayEvent].self, from: data) else { return [] }
        return events
    }

    /// Append one event. Rewrites the file (fine at this scale — a year of plays is
    /// a few thousand small rows) so history survives a crash/quit immediately.
    static func append(_ event: PlayEvent) {
        var all = load()
        all.append(event)
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
