import Foundation

/// Persists the friends drawer so it opens instantly on launch instead of showing the loader:
/// the followed-fans list, the first page of each opened friend's collection/wishlist, and the
/// "what's new since you last looked" bookkeeping.
///
/// - `recent` — the newest collection item keys per friend (Bandcamp item URLs), refreshed by the
///   background ownership scan and when you open a friend. Compared against `seen` to surface new
///   additions.
/// - `seen` — the keys you've already looked at per friend. Never expires with the TTL (the list
///   cache can go stale and refresh, but what you've seen is permanent). Updated when you leave a
///   friend's page. A friend with no `seen` entry yet gets a silent baseline (nothing flagged new
///   the very first time you ever see them).
///
/// The TTL only decides whether to refresh in the background — the cached data is always shown.
enum FriendsCache {
    static let ttl: TimeInterval = 24 * 3600

    struct Snapshot: Codable {
        var date: Date
        var friends: [Friend]
        var coll: [Int: [Album]]        // fan_id → first page of their collection
        var wish: [Int: [Album]]        // fan_id → first page of their wishlist
        var recent: [Int: [String]]     // fan_id → newest collection item keys
        var seen: [Int: [String]]       // fan_id → keys already looked at (no TTL)
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("friends.json")
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
