import AppKit
import Foundation
import Network

/// Watches real network reachability (Wi-Fi / ethernet up or down), so the UI can show an
/// "Offline" indicator on a plane or train rather than only reflecting Bandcamp-login state.
/// The path handler fires on a background queue; we hop to the main actor to update `AppState`.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.cabin.network-monitor")
    private var started = false

    /// Called on the main queue with the latest reachability whenever it changes.
    var onChange: ((Bool) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.onChange?(online) }
        }
        monitor.start(queue: queue)
    }
}

/// Tiny deterministic PRNG (xorshift64) so a trip's "discovery" picks are stable when the
/// estimate is recomputed, yet still vary day to day.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

extension AppState {
    // MARK: Network monitoring

    func startNetworkMonitoring() {
        networkMonitor.onChange = { [weak self] online in
            guard let self else { return }
            if self.isOnline != online { self.isOnline = online }
            // While we have a connection, top up locally-stored cover art for downloaded
            // albums so they don't render blank the next time we're offline.
            if online { self.backfillOfflineArtwork() }
        }
        networkMonitor.start()
    }

    // MARK: Offline artwork

    /// Fetch a downloaded album's remote cover into `artworkData` (persisted in the library),
    /// so it still shows when there's no network. No-op if it already has bytes / no URL / fails.
    func cacheArtworkData(for albumID: UUID) async {
        guard let i = albums.firstIndex(where: { $0.id == albumID }),
              albums[i].artworkData == nil,
              let url = albums[i].artworkURL else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              NSImage(data: data) != nil else { return }
        guard let j = albums.firstIndex(where: { $0.id == albumID }), albums[j].artworkData == nil else { return }
        albums[j].artworkData = data
        persist()
    }

    /// Backfill cover art for every downloaded album that only has a remote URL — so the crate
    /// isn't blank offline. Runs while online; fetches sequentially and persists once at the end.
    func backfillOfflineArtwork() {
        guard isOnline else { return }
        let targets = albums.filter { $0.isDownloaded && $0.artworkData == nil && $0.artworkURL != nil }
        guard !targets.isEmpty else { return }
        Task {
            var changed = false
            for a in targets {
                guard let url = a.artworkURL,
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      NSImage(data: data) != nil else { continue }
                if let j = albums.firstIndex(where: { $0.id == a.id }), albums[j].artworkData == nil {
                    albums[j].artworkData = data
                    changed = true
                }
            }
            if changed { persist() }
        }
    }

    // MARK: Trip prep (offline download selection)

    /// A rough FLAC track size, for estimating a download's footprint before we fetch it.
    static let avgFlacTrackBytes: Int64 = 35 * 1024 * 1024

    /// Best-effort track count: the real files if downloaded, else a number parsed from the
    /// `format` string (often "12 tracks"), else a typical-album fallback.
    func estimatedTrackCount(_ album: Album) -> Int {
        if let n = album.localTracks?.count, n > 0 { return n }
        let digits = album.format.prefix { $0.isNumber }
        if let n = Int(digits), n > 0 { return n }
        return 10
    }

    /// Estimated on-disk size of an album as FLAC.
    func estimatedSizeBytes(_ album: Album) -> Int64 {
        Int64(estimatedTrackCount(album)) * Self.avgFlacTrackBytes
    }

    /// The albums "Prep for trip" would download: a blend of the user's most-listened,
    /// recently-played and a few never-heard records, drawn only from not-yet-downloaded
    /// Bandcamp albums and capped at `count`. Interleaved ~5 : 3 : 2 so the mix favours
    /// familiar music while still slipping in some discovery.
    func tripPrepCandidates(count: Int) -> [Album] {
        let pool = albums.filter { $0.canDownload }
        guard count > 0, !pool.isEmpty else { return [] }

        // Most-recent listen per album, from history.
        var lastPlayed: [UUID: Date] = [:]
        for e in HistoryStore.load() {
            guard let id = e.albumID else { continue }
            if let cur = lastPlayed[id] { if e.date > cur { lastPlayed[id] = e.date } }
            else { lastPlayed[id] = e.date }
        }

        let played = pool.filter { playCount(for: $0) > 0 }
        let never  = pool.filter { playCount(for: $0) == 0 }

        let mostListened = played.sorted { playCount(for: $0) > playCount(for: $1) }
        let recent = played.sorted {
            (lastPlayed[$0.id] ?? .distantPast) > (lastPlayed[$1.id] ?? .distantPast)
        }
        var rng = SeededRNG(seed: UInt64(max(0, Int(Date().timeIntervalSince1970) / 86_400)))
        let discovery = never.shuffled(using: &rng)

        var chosen: [Album] = []
        var seen = Set<UUID>()
        var i = 0, j = 0, k = 0
        func take(_ list: [Album], _ idx: inout Int) {
            while idx < list.count {
                let a = list[idx]; idx += 1
                if seen.insert(a.id).inserted { chosen.append(a); return }
            }
        }
        while chosen.count < count {
            let before = chosen.count
            for _ in 0..<5 where chosen.count < count { take(mostListened, &i) }
            for _ in 0..<3 where chosen.count < count { take(recent, &j) }
            for _ in 0..<2 where chosen.count < count { take(discovery, &k) }
            if chosen.count == before { break }   // every list exhausted
        }
        return chosen
    }
}
