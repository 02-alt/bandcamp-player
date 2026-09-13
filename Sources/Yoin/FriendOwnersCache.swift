import Foundation

/// Persists the "owned by friends" index (normalized album URL → friends who own it) so the badges
/// show instantly on launch instead of waiting on a full per-friend collection scan. Refreshed in
/// the background once the snapshot is older than `ttl`.
enum FriendOwnersCache {
    static let ttl: TimeInterval = 24 * 3600

    struct Snapshot: Codable {
        let date: Date
        let index: [String: [Friend]]
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("friend-owners.json")
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ index: [String: [Friend]]) {
        let snapshot = Snapshot(date: Date(), index: index)
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
