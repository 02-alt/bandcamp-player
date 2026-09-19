import Foundation

/// Persistent BPM cache. Keyed by a *stable* per-track key ("<album dedupeKey>#<index>") rather
/// than the stream URL, so detected tempos survive relaunches and Bandcamp stream-URL churn.
/// Populated by the "Analyze library" batch (see `AppState.analyzeLibraryBPM`) and read by the
/// tempo smart-shelf. Writes are debounced off the main thread.
@MainActor
final class BPMStore {
    static let shared = BPMStore()

    private var map: [String: Double]
    private init() { map = Self.load() }

    static func key(album: Album, index: Int) -> String { "\(album.dedupeKey)#\(index)" }

    /// Stored BPM for a track, if analysed.
    func bpm(album: Album, index: Int) -> Double? { map[Self.key(album: album, index: index)] }
    /// Whether *any* track of the album has a stored BPM (cheap "is this album analysed?" probe).
    func hasAny(album: Album) -> Bool { map[Self.key(album: album, index: 0)] != nil }
    /// Total tracks with a known BPM across the whole library.
    var total: Int { map.count }

    func set(_ bpm: Double, album: Album, index: Int) { map[Self.key(album: album, index: index)] = bpm }

    // MARK: Persistence

    private static let ioQueue = DispatchQueue(label: "com.cabin.bpm.io", qos: .utility)

    /// Write the current map to disk off the main thread.
    func save() {
        let snapshot = map
        Self.ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private nonisolated static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bpm.json")
    }

    private nonisolated static func load() -> [String: Double] {
        guard let data = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return m
    }
}
