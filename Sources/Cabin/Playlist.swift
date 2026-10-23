import Foundation
import CabinCore

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

/// One album inside a Set — a "vinyl box" of whole albums you flip through and reorder.
/// Denormalised (title/artist/cover) so the box still renders if the album is later removed,
/// but `id` matches the album's id so clicking a cover can open the real album page.
struct SetAlbum: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var artist: String
    var artworkURL: URL?
    var artworkData: Data?
    var g0: Double = 0.28
    var g1: Double = 0.08
}

/// What a `Playlist` record actually is: a track list (playlist) or a box of whole albums (set).
enum PlaylistKind: String, Codable { case playlist, set }

/// A user-built, ordered collection — either of tracks (`.playlist`) or whole albums (`.set`).
struct Playlist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var kind: PlaylistKind = .playlist
    var tracks: [PlaylistTrack] = []
    /// Ordered whole-album members; only used when `kind == .set`.
    var albumRefs: [SetAlbum] = []
    var createdAt: Date = Date()
    /// A user-chosen cover image (PNG), overriding the auto-generated cover mosaic.
    var coverImageData: Data?
    /// When set, this is an auto-generated ("smart") playlist: its `tracks` are recomputed
    /// from listening history and are not hand-editable. `nil` = an ordinary playlist.
    var smart: SmartRule?

    init(id: UUID = UUID(), name: String, kind: PlaylistKind = .playlist, tracks: [PlaylistTrack] = [],
         albumRefs: [SetAlbum] = [], createdAt: Date = Date(), coverImageData: Data? = nil, smart: SmartRule? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.tracks = tracks; self.albumRefs = albumRefs
        self.createdAt = createdAt; self.coverImageData = coverImageData; self.smart = smart
    }

    /// Hand-written so records saved before Sets existed (no `kind` / `albumRefs`) still load —
    /// synthesized decoding ignores default values and would fail the whole playlists file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(PlaylistKind.self, forKey: .kind) ?? .playlist
        tracks = try c.decodeIfPresent([PlaylistTrack].self, forKey: .tracks) ?? []
        albumRefs = try c.decodeIfPresent([SetAlbum].self, forKey: .albumRefs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        coverImageData = try c.decodeIfPresent(Data.self, forKey: .coverImageData)
        smart = try c.decodeIfPresent(SmartRule.self, forKey: .smart)
    }

    var isSmart: Bool { smart != nil }
    var isEmpty: Bool { kind == .set ? albumRefs.isEmpty : tracks.isEmpty }

    /// Number of members, kind-aware (albums for a set, tracks for a playlist).
    var itemCount: Int { kind == .set ? albumRefs.count : tracks.count }
    var itemCountLabel: String {
        let noun = kind == .set ? "album" : "track"
        return "\(itemCount) \(noun)\(itemCount == 1 ? "" : "s")"
    }

    /// Distinct album covers (front of the list first) for the stacked mosaic thumbnail. Sets map
    /// their album members through the same `PlaylistTrack` shape so the mosaics work unchanged.
    var coverTracks: [PlaylistTrack] {
        if kind == .set {
            return albumRefs.map {
                PlaylistTrack(albumID: $0.id, albumTitle: $0.title, artist: $0.artist,
                              title: $0.title, trackIndex: 0,
                              artworkURL: $0.artworkURL, artworkData: $0.artworkData,
                              g0: $0.g0, g1: $0.g1)
            }
        }
        var seen = Set<UUID>()
        return tracks.filter { seen.insert($0.albumID).inserted }
    }
}

/// A pending "quick create" from the right-click menu: what to seed the new playlist with and a
/// suggested name. Held transiently in `AppState.playlistDraft` while the overlay is open.
struct PlaylistDraft: Identifiable {
    let id = UUID()
    enum Source { case album(Album); case track(Track) }
    let source: Source
    let suggestedName: String

    /// A one-line "what am I adding" hint for the overlay.
    var subtitle: String {
        switch source {
        case .album(let a): return "Album · \(a.artist)"
        case .track(let t): return "Song · \(t.artist)"
        }
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

    private static let writer = CoalescedJSONWriter(label: "com.cabin.playlists.io")

    static func save(_ lists: [Playlist]) { writer.write(lists, to: fileURL) }
    static func flush() { writer.flush() }
}

/// Encodes + writes a JSON snapshot off the main thread, coalescing bursts (e.g. one save per row
/// crossed while drag-reordering) into a single write of the latest value — the same pattern as
/// `LocalLibraryStore`. Playlists carry cover bytes, so a synchronous encode stalled the UI.
final class CoalescedJSONWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0   // guarded by `lock`

    init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }

    func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        queue.async { [self] in
            lock.lock(); let latest = generation; lock.unlock()
            guard mine == latest, let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Block until any queued write has finished (app termination).
    func flush() { queue.sync {} }
}
