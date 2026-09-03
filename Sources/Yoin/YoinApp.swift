import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import WebKit

/// Forces the SPM executable to behave like a normal foreground app (window + Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The Dock/Finder icon comes from AppIcon.icns via Info.plist's CFBundleIconFile.
        // Don't touch Bundle.module here: in a hand-packaged .app the SPM resource bundle
        // isn't reliably resolvable, and its accessor fatal-errors on launch if it isn't.
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // While the mini player is up we hide the main window on purpose — don't quit.
        !MainActor.assumeIsolated { MiniPlayerController.shared.isOpen }
    }
}

@main
struct YoinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var player = PlayerEngine()
    @StateObject private var updater = UpdaterModel()
    @StateObject private var ipod = IPodWatcher()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(player)
                .environmentObject(updater)
                .environmentObject(ipod)
                .preferredColorScheme(state.scheme)
                .frame(minWidth: 720, idealWidth: 1180, minHeight: 540, idealHeight: 760)
                .onAppear {
                    // Expose the live engine/state to AppleScript (see Scripting.swift),
                    // so external players like NotchGlass can read now-playing state.
                    ScriptingBridge.shared.player = player
                    ScriptingBridge.shared.state = state
                    // Wire up the floating mini-player panel.
                    MiniPlayerController.shared.configure(player: player, state: state)
                    // Wire the system Now Playing panel + media keys (F7–F9 / Control Center).
                    NowPlayingCenter.shared.configure(player: player, state: state)
                    // Log every finished track to listening history for the recap.
                    player.trackFinished = { [weak state] track, elapsed, duration in
                        state?.recordPlay(track, elapsed: elapsed, duration: duration)
                        state?.radioFeedback(track, elapsed: elapsed, duration: duration)
                    }
                    // Keep the radio station topped up as the queue plays down.
                    player.queueAdvanced = { [weak state, weak player] in
                        guard let state, let player else { return }
                        state.radioTopUpIfNeeded(on: player)
                    }
                    // Surface a dead/stalled stream instead of hanging silently.
                    player.onError = { [weak state] msg in state?.showNotice(msg) }
                    // Show the "What's New" card once on the first launch after an update.
                    if WhatsNew.shouldAutoShow() { state.showWhatsNew = true }
                    // Fill missing genres on imported/local albums from their file tags so mood
                    // radio works without a Bandcamp sync.
                    Task { await state.backfillLocalGenres() }
                    // Also scrape Bandcamp tags for genre-less Bandcamp albums at launch (not just
                    // after a sync), so existing libraries unlock moods without a manual re-sync.
                    Task { await state.backfillGenresFromBandcamp() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Standard "Check for Updates…" item in the app menu, next to About.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .toolbar) {
                Button("Mini Player") { MiniPlayerController.shared.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }
    }
}

/// App-wide UI state.
@MainActor
final class AppState: ObservableObject {
    enum Screen: Hashable { case crate, grid, playlists, wishlist, ipod, recap, settings }
    enum Filter: Hashable { case all, favourites, downloaded, bandcamp, imported }
    /// Grid ordering. `.artist` also switches the grid to grouped, sticky-header sections —
    /// it replaces the old standalone Artists tab.
    enum Sort: String, CaseIterable, Hashable {
        case added, artist, title, year
        var label: String {
            switch self {
            case .added:  return "Added"
            case .artist: return "Artist"
            case .title:  return "Title"
            case .year:   return "Year"
            }
        }
        var icon: String {
            switch self {
            case .added:  return "clock"
            case .artist: return "person"
            case .title:  return "textformat"
            case .year:   return "calendar"
            }
        }
    }

    @Published var screen: Screen = .crate
    @Published var filter: Filter = .all { didSet { front = 0 } }
    @Published var sort: Sort = .added
    @Published var nowPlayingAlbumID: UUID? { didSet { if nowPlayingAlbumID != oldValue { refreshAmbient() } } }
    /// A muted colour pulled from the now-playing cover, tinting the background glow.
    /// `nil` when nothing is playing. Gated for display by the "ambientTheming" setting.
    @Published var ambient: Color?
    /// A few representative colours from the now-playing cover, for the bespoke grain-gradient bg.
    @Published var ambientPalette: [Color] = []
    /// Whether an endless radio station is currently driving the queue.
    @Published var radioActive = false
    /// Human name of the station currently playing (e.g. "Chill", "Radio: Aphex Twin"), for
    /// the player bar / Up Next indicator. `nil` when no radio is playing.
    @Published var currentRadioLabel: String?
    /// The recipe behind the current station, so it can be saved.
    private var currentRadioSeed: RadioSeed?
    /// The station currently being built (Last.fm boost + resolving opening tracks can take a
    /// moment). Drives the loading spinner on the tapped mood chip / saved-radio row. `nil` when
    /// nothing is starting.
    @Published var radioStarting: RadioSeed?
    /// Saved radio stations (recipes; regenerated on play).
    @Published var savedRadios: [SavedRadio] = SavedRadioStore.load()
    /// Guards against overlapping top-ups while one is in flight.
    private var radioRefilling = false
    /// Bumped whenever a station starts or stops, so a slow async start/top-up computed
    /// for an old station is discarded instead of leaking into the current one.
    private var radioGeneration = 0
    /// The radio recommendation engine (seeded queue over the user's own library).
    lazy var radio = RadioStation(
        library: { [weak self] in self?.albums ?? [] },
        resolve: { [weak self] album in await self?.resolveTracks(for: album) ?? [] },
        history: { HistoryStore.load() }
    )
    @Published var openedAlbumID: UUID?
    @Published var searchOpen = false
    @Published var front = 0

    // Liked songs (individual tracks, distinct from whole-album favourites)
    /// Sentinel id for the virtual "Liked Songs" playlist shown in the Playlists rail.
    static let likedSongsID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    @Published var likedTracks: [PlaylistTrack] = LikedSongsStore.load()

    /// The liked songs presented as a (virtual, non-persisted) playlist so the Playlists
    /// screen can render/play them with the existing UI.
    var likedSongsPlaylist: Playlist {
        var pl = Playlist(name: "Liked Songs", tracks: likedTracks)
        pl.id = Self.likedSongsID
        return pl
    }

    func isLiked(_ track: Track) -> Bool {
        guard let id = track.albumID, let idx = track.trackIndex else { return false }
        return likedTracks.contains { $0.albumID == id && $0.trackIndex == idx }
    }

    /// Like / unlike the given song, persisting immediately.
    func toggleLikedSong(_ track: Track) {
        guard let id = track.albumID, let idx = track.trackIndex else {
            showNotice("Can't favourite this song."); return
        }
        if let existing = likedTracks.firstIndex(where: { $0.albumID == id && $0.trackIndex == idx }) {
            likedTracks.remove(at: existing)
            showNotice("Removed from Liked Songs")
        } else if let entry = playlistEntry(for: track) {
            likedTracks.insert(entry, at: 0)   // newest first
            showNotice("Added to Liked Songs")
        }
        LikedSongsStore.save(likedTracks)
    }

    func unlikeSongs(at offsets: IndexSet) {
        likedTracks.remove(atOffsets: offsets)
        LikedSongsStore.save(likedTracks)
    }

    // Playlists
    @Published var playlists: [Playlist] = PlaylistStore.load()
    /// Which playlist the Playlists screen is showing in its detail pane.
    @Published var selectedPlaylistID: UUID?
    /// A freshly-created playlist whose name should open in inline-rename mode.
    @Published var renamingPlaylistID: UUID?
    /// Smart playlists currently being recomputed — drives the header spinner and
    /// coalesces overlapping rebuilds (launch + sync + a manual refresh).
    @Published var rebuildingSmart: Set<UUID> = []
    /// Smart playlists asked to rebuild again while a rebuild was already running — the
    /// in-flight pass re-runs once for each, so no refresh is lost.
    private var smartRebuildPending: Set<UUID> = []
    /// When the last full smart-playlist rebuild ran, for throttling on-visit refreshes.
    private var lastSmartRebuild: Date = .distantPast
    /// Whether the "Up Next" queue panel is open.
    @Published var queueOpen = false
    @Published var scheme: ColorScheme = .dark
    @Published var albums: [Album] = Album.sample

    /// Which cover carousel to show on the Crate screen. Persisted.
    @Published var crateStyle: CrateStyle =
        CrateStyle(rawValue: UserDefaults.standard.string(forKey: "yoin.crateStyle") ?? "") ?? .coverflow {
        didSet { UserDefaults.standard.set(crateStyle.rawValue, forKey: "yoin.crateStyle") }
    }

    /// Which floating mini-player look to use. Persisted.
    @Published var miniPlayerStyle: MiniPlayerStyle =
        MiniPlayerStyle(rawValue: UserDefaults.standard.string(forKey: "yoin.miniStyle") ?? "") ?? .cover {
        didSet {
            UserDefaults.standard.set(miniPlayerStyle.rawValue, forKey: "yoin.miniStyle")
            MiniPlayerController.shared.restyle()
        }
    }

    /// The user's display identity (name + avatar) for recaps and shares.
    @Published var profile: Profile = ProfileStore.load()
    func saveProfile() { ProfileStore.save(profile) }

    /// Transient, user-facing error/status message (auto-clears). Rendered as a banner in RootView.
    /// Mirror of the connected iPod (from IPodWatcher) so context menus can offer "Add to iPod".
    @Published var connectedIPod: IPodDevice?

    @Published var notice: String?
    func showNotice(_ message: String) {
        notice = message
        let token = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.notice == token { self.notice = nil }
        }
    }

    // Bandcamp connection
    enum SyncState: Equatable { case idle, syncing, done(Int), failed(String) }
    @Published var showLogin = false
    @Published var showWhatsNew = false
    @Published var identity: String? = Keychain.get(account: "identity")
    @Published var sync: SyncState = .idle
    /// Items fetched / total owned during a sync — drives the launch progress bar.
    /// `syncTotal == 0` means the total is unknown (fall back to an indeterminate bar).
    @Published var syncLoaded = 0
    @Published var syncTotal = 0
    var isConnected: Bool { identity != nil }

    /// True only when there's nothing to show yet and we're still fetching — i.e. first launch
    /// / empty library. A returning user's cached crate stays visible during a background sync.
    var isInitialLoading: Bool {
        sync == .syncing && !albums.contains { $0.source == .bandcamp || $0.url != nil || $0.hasLocalFiles }
    }
    /// Sync progress 0…1 when the total is known, else nil (indeterminate).
    var syncFraction: Double? {
        guard syncTotal > 0 else { return nil }
        return min(1, Double(syncLoaded) / Double(syncTotal))
    }

    // Downloads
    enum DownloadState: Equatable { case downloading, done, failed(String) }
    @Published var downloads: [UUID: DownloadState] = [:]

    // Multi-select (for bulk delete from the grid)
    @Published var selecting = false
    @Published var selection: Set<UUID> = []

    /// Set to an album id to auto-open its "Edit details" sheet (e.g. after combining).
    @Published var editRequestID: UUID?

    // Custom right-click menu currently on screen (see ContextMenu.swift).
    @Published var activeMenu: AppMenuState?
    func showMenu(_ items: [AppMenuItem], at point: CGPoint) {
        // Require at least one real row — a divider-only menu would show an empty,
        // input-blocking scrim with nothing to click.
        guard items.contains(where: { !$0.isDivider }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { activeMenu = AppMenuState(location: point, items: items) }
    }
    func dismissMenu() {
        withAnimation(.easeOut(duration: 0.12)) { activeMenu = nil }
    }

    /// Bandcamp album URLs the user removed — filtered out on re-sync so they stay gone.
    private static let hiddenKey = "yoin.hiddenBandcamp"
    static var hiddenBandcamp: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: hiddenKey) }
    }

    /// Where downloaded music lives.
    nonisolated static let libraryFolder: URL = {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Vinyl", isDirectory: true)
    }()

    init() {
        // Restore the saved library (imported files + downloaded Bandcamp albums).
        let saved = Library.load()
        if !saved.isEmpty { albums = saved }
        // If we already have a saved session, refresh the collection on launch.
        if identity != nil { Task { await syncBandcamp() } }
        // Refresh any smart playlists against the freshly-loaded library / history.
        Task { await rebuildSmartPlaylists() }
        // Genre backfill runs after a sync (see syncBandcamp) — not here — because sync
        // rebuilds the Bandcamp albums with fresh ids, which would race this.
    }

    /// Write the current library to disk.
    func persist() { Library.save(albums) }

    /// Log a finished track to listening history (feeds the year-end recap).
    /// Called by PlayerEngine whenever a track stops being active.
    func recordPlay(_ track: Track, elapsed: Double, duration: Double) {
        guard elapsed >= 5 else { return }   // ignore instant skips / accidental taps
        // Prefer the track's own album (correct even in playlist playback), else the album screen.
        let album = track.albumID.flatMap { id in albums.first { $0.id == id } } ?? nowPlayingAlbum
        let event = PlayEvent(
            albumID: album?.id,
            albumTitle: album?.title ?? track.title,
            // Album artist (stable) rather than the track's — featured tracks vary, which
            // would otherwise split one album across several recap groups.
            artist: album?.artist ?? track.artist,
            trackTitle: track.title,
            date: Date(),
            seconds: elapsed,
            duration: duration
        )
        HistoryStore.append(event)
    }

    func flip(_ delta: Int) {
        let n = visibleAlbums.count
        guard n > 0 else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            front = (front + delta + n) % n
        }
    }

    /// Albums shown by the active filter, in the active sort order.
    var visibleAlbums: [Album] {
        let filtered: [Album]
        switch filter {
        case .all:        filtered = albums
        case .favourites: filtered = albums.filter { $0.isFavourite }
        case .downloaded: filtered = albums.filter { $0.isDownloaded }
        case .bandcamp:   filtered = albums.filter { $0.source == .bandcamp }
        case .imported:   filtered = albums.filter { $0.source == .local }
        }
        return sortedForDisplay(filtered)
    }

    private func sortedForDisplay(_ list: [Album]) -> [Album] {
        switch sort {
        case .added:
            return list   // natural (insertion) order
        case .artist:
            return list.sorted {
                let byArtist = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                if $0.year != $1.year { return $0.year < $1.year }   // oldest first within an artist
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .title:
            return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .year:
            return list.sorted { $0.year > $1.year }   // newest first
        }
    }

    func count(for f: Filter) -> Int {
        switch f {
        case .all:        return albums.count
        case .favourites: return albums.filter { $0.isFavourite }.count
        case .downloaded: return albums.filter { $0.isDownloaded }.count
        case .bandcamp:   return albums.filter { $0.source == .bandcamp }.count
        case .imported:   return albums.filter { $0.source == .local }.count
        }
    }

    // Also resolves wishlist items (they aren't in `albums`) so Now Playing shows the right
    // cover/artist and can offer a buy nudge while previewing an unowned wishlist track.
    var nowPlayingAlbum: Album? {
        albums.first { $0.id == nowPlayingAlbumID } ?? wishlist.first { $0.id == nowPlayingAlbumID }
    }

    /// Recompute the ambient background tint from the now-playing cover. Uses embedded
    /// artwork when present, otherwise the remote cover (cached, else fetched once).
    private func refreshAmbient() {
        guard let album = nowPlayingAlbum else {
            withAnimation(.easeInOut(duration: 0.6)) { ambient = nil; ambientPalette = [] }
            return
        }
        if let img = album.artwork {
            setAmbient(from: img)
        } else if let url = album.artworkURL {
            if let hit = ArtworkCache.remote(url) {
                setAmbient(from: hit)
            } else {
                // Cover must be downloaded — clear now so we don't show the PREVIOUS track's
                // colours while it loads (that was the "old colours for a second" flash).
                ambient = nil; ambientPalette = []
                let forID = album.id
                Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let img = NSImage(data: data) else { return }
                    ArtworkCache.store(img, for: url)
                    // The user may have skipped tracks while this cover downloaded — only apply
                    // the tint if this is still the now-playing album, else we'd flash a stale colour.
                    guard let self, self.nowPlayingAlbumID == forID else { return }
                    self.setAmbient(from: img)
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.6)) { ambient = nil; ambientPalette = [] }
        }
    }

    private func setAmbient(from img: NSImage) {
        let colour = AmbientColor.extract(from: img)
        let pal = AmbientColor.palette(from: img)
        withAnimation(.easeInOut(duration: 0.6)) { ambient = colour; ambientPalette = pal }
    }
    var openedAlbum: Album? { albums.first { $0.id == openedAlbumID } }

    func toggleFavourite(_ id: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[i].isFavourite.toggle()
        persist()
    }

    // MARK: - Multi-select & delete

    func enterSelection(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            selecting = on
            if !on { selection.removeAll() }
        }
    }

    func toggleSelect(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Select every album currently shown by the active filter.
    func selectAllVisible() { selection = Set(visibleAlbums.map { $0.id }) }

    /// Remove the selected albums from the library. Bandcamp albums are also remembered
    /// as hidden so a re-sync won't bring them back. Local audio files are left on disk.
    func deleteSelected() {
        deleteAlbums(selection)
        enterSelection(false)
    }

    func deleteAlbums(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = albums.filter { ids.contains($0.id) }
        var hidden = Self.hiddenBandcamp
        for a in removed where a.source == .bandcamp {
            if let url = a.bandcampItemURL { hidden.insert(url) }
        }
        Self.hiddenBandcamp = hidden
        albums.removeAll { ids.contains($0.id) }
        if let opened = openedAlbumID, ids.contains(opened) { openedAlbumID = nil }
        persist()
    }

    // MARK: - Library health (broken / unstreamable checker)

    enum HealthState: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case done([LibraryIssue])
    }
    @Published var health: HealthState = .idle
    private var healthScanToken = UUID()

    private func issue(_ a: Album, _ reason: String) -> LibraryIssue {
        LibraryIssue(id: a.id, title: a.title, artist: a.artist, reason: reason,
                     canRedownload: a.source == .bandcamp && a.bandcampDownloadURL != nil)
    }

    /// Check every album for a playable source: local files present on disk, or a Bandcamp
    /// page that still resolves a stream. Instant for local/metadata problems; network-probes
    /// Bandcamp albums that have no offline copy.
    func scanLibraryHealth() {
        let fm = FileManager.default
        let snapshot = albums
        var issues: [LibraryIssue] = []
        var probeTargets: [(id: UUID, url: String)] = []

        for a in snapshot {
            let localMissing: Bool = {
                if let u = a.url, !fm.fileExists(atPath: u.path) { return true }
                if let ts = a.localTracks, ts.contains(where: { !fm.fileExists(atPath: $0.path) }) { return true }
                return false
            }()
            if a.source == .local {
                if a.url == nil && !a.hasLocalFiles { issues.append(issue(a, "No audio file")) }
                else if localMissing { issues.append(issue(a, "Audio file missing on disk")) }
            } else {   // bandcamp
                if a.hasLocalFiles && !localMissing {
                    continue   // has an offline copy — fine
                } else if let url = a.bandcampItemURL {
                    probeTargets.append((a.id, url))
                } else {
                    issues.append(issue(a, "No streamable source"))
                }
            }
        }

        guard let identity, !probeTargets.isEmpty else {
            health = .done(issues)
            return
        }

        let token = UUID(); healthScanToken = token
        health = .scanning(done: 0, total: probeTargets.count)
        let total = probeTargets.count
        let baseIssues = issues
        Task { [weak self] in
            let bad = await LibraryHealth.unreachable(probeTargets, identity: identity) { done in
                Task { @MainActor in
                    guard let self, self.healthScanToken == token else { return }
                    self.health = .scanning(done: done, total: total)
                }
            }
            await MainActor.run {
                guard let self, self.healthScanToken == token else { return }
                var all = baseIssues
                for a in snapshot where bad.contains(a.id) {
                    all.append(self.issue(a, "Won't stream from Bandcamp"))
                }
                self.health = .done(all)
            }
        }
    }

    /// Re-fetch a Bandcamp album's files after it was flagged with missing downloads.
    func redownloadIssue(_ id: UUID) {
        guard let a = albums.first(where: { $0.id == id }), a.bandcampDownloadURL != nil else { return }
        if let i = albums.firstIndex(where: { $0.id == id }) { albums[i].localTracks = nil }   // force a fresh pull
        download(albums.first(where: { $0.id == id }) ?? a)
    }

    /// Merge several single-file local imports into one multi-track album.
    /// Files stay on disk; the separate entries are replaced by a single album.
    func combineIntoAlbum(_ ids: Set<UUID>) {
        let members = albums.filter { ids.contains($0.id) && $0.isSingleLocalFile }
        guard members.count >= 2 else { return }
        // Track order follows the filenames (natural/numeric sort).
        let ordered = members.sorted {
            ($0.url?.lastPathComponent ?? $0.title).localizedStandardCompare($1.url?.lastPathComponent ?? $1.title) == .orderedAscending
        }
        let urls = ordered.compactMap { $0.url }
        let artists = Set(ordered.map { $0.artist })
        let artist = artists.count == 1 ? (artists.first ?? "Unknown Artist") : "Various Artists"

        // Name from a shared parent folder, unless it's a generic download location.
        let generic: Set<String> = ["Downloads", "Desktop", "Music", "Documents"]
        let parents = Set(ordered.compactMap { $0.url?.deletingLastPathComponent().lastPathComponent })
        let folder = parents.count == 1 ? parents.first : nil
        let title = (folder.map { generic.contains($0) ? nil : $0 } ?? nil) ?? "Untitled Album"

        var merged = Album(
            title: title,
            artist: artist,
            year: ordered.first(where: { !$0.year.isEmpty })?.year ?? "",
            format: "\(urls.count) tracks",
            lossless: ordered.allSatisfy { $0.lossless },
            g0: ordered.first?.g0 ?? 0.28, g1: ordered.first?.g1 ?? 0.08
        )
        merged.localTracks = urls
        merged.source = .local
        merged.artworkData = ordered.first(where: { $0.artworkData != nil })?.artworkData
        merged.artworkURL = ordered.first(where: { $0.artworkURL != nil })?.artworkURL
        merged.isFavourite = ordered.contains { $0.isFavourite }

        // Replace the first member in place (keeps grid position); drop the rest.
        guard let firstID = ordered.first?.id, let idx = albums.firstIndex(where: { $0.id == firstID }) else { return }
        albums[idx] = merged
        let remove = Set(ordered.dropFirst().map { $0.id })
        albums.removeAll { remove.contains($0.id) }

        enterSelection(false)
        openedAlbumID = merged.id
        editRequestID = merged.id   // open Edit so the user can name it right away
        persist()
    }

    /// Un-hide previously removed Bandcamp albums and re-sync to bring them back.
    func restoreRemovedBandcamp() {
        Self.hiddenBandcamp = []
        Task { await syncBandcamp() }
    }

    /// Start playing an album (resolves its tracks), remembering which album it is.
    func play(_ album: Album, on player: PlayerEngine) {
        stopRadio()
        nowPlayingAlbumID = album.id
        autoCacheIfNeeded(album)
        Task {
            let tracks = await resolveTracks(for: album)
            player.play(tracks)
        }
    }

    // MARK: - Offline mode (auto-cache played albums)

    static let offlineModeKey = "offlineMode"
    var offlineMode: Bool { UserDefaults.standard.bool(forKey: Self.offlineModeKey) }

    /// When offline mode is on, download a just-played Bandcamp album in the background so it
    /// plays without a connection next time. No-op if it's already downloaded/downloading.
    func autoCacheIfNeeded(_ album: Album) {
        guard offlineMode, album.canDownload, downloads[album.id] == nil else { return }
        download(album)
    }

    // MARK: - Liner notes (Bandcamp album description + credits)

    private var notesFetching = Set<UUID>()

    /// Fetch the album's Bandcamp "about" + "credits" text once, caching it on the album.
    func loadNotes(for albumID: UUID) {
        guard let identity,
              let i = albums.firstIndex(where: { $0.id == albumID }),
              albums[i].source == .bandcamp,
              !albums[i].notesLoaded,
              let itemURL = albums[i].bandcampItemURL,
              !notesFetching.contains(albumID) else { return }
        notesFetching.insert(albumID)
        Task { [weak self] in
            let notes = try? await BandcampClient(identity: identity).notes(forItemURL: itemURL)
            await MainActor.run {
                guard let self else { return }
                self.notesFetching.remove(albumID)
                guard let j = self.albums.firstIndex(where: { $0.id == albumID }) else { return }
                self.albums[j].about = notes?.about
                self.albums[j].bcCredits = notes?.credits
                self.albums[j].notesLoaded = true
                self.persist()
            }
        }
    }

    /// Forget an album's cached liner notes so the next `loadNotes` re-fetches them from Bandcamp.
    func invalidateNotes(for albumID: UUID) {
        notesFetching.remove(albumID)
        guard let i = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[i].notesLoaded = false
    }

    // MARK: - Radio (endless station over the user's own library)

    /// Start an endless station seeded from an album (optionally a specific track within it).
    func startRadio(album: Album, track: Track? = nil, on player: PlayerEngine) {
        startRadio(seeds: [album], seedTrack: track,
                   nowPlayingID: track == nil ? album.id : nil,
                   seed: .album(title: album.title, artist: album.artist),
                   label: album.artist.isEmpty ? album.title : album.artist, on: player)
    }

    /// Cached result of `dailyMixArtists`, so it's computed once per day rather than on every
    /// view render (the Radio pane re-renders ~5×/sec while a track plays). Keyed by day + seed +
    /// album count so it stays rock-steady across renders but refreshes when any of those change.
    private var dailyMixCache: (day: Int, seed: Int, albumCount: Int, count: Int, artists: [String])?
    /// Manual reshuffle offset — "New mixes" advances this to slide to a fresh page immediately,
    /// without waiting for the daily rotation. @Published so the Radio pane re-renders on change.
    @Published private var mixSeed = 0

    /// Reshuffle the "Made for you" mixes to a fresh set right now.
    func refreshDailyMixes() { mixSeed += 1; dailyMixCache = nil }

    /// Up to `count` artists to feature as personalised mixes today — your most-played artists,
    /// rotated one page per day so the picks change daily (never the same set several days running)
    /// rather than showing the same mixes forever. Falls back to your biggest artists by album
    /// count when listening history is still thin. Deterministic (ties broken by name) and cached
    /// per day so the cards don't reshuffle on every render.
    func dailyMixArtists(count: Int = 4) -> [String] {
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        if let c = dailyMixCache, c.day == day, c.seed == mixSeed, c.albumCount == albums.count, c.count == count {
            return c.artists
        }
        // Only artists you actually have playable music from, so every mix can be built.
        let playable = Dictionary(grouping: albums.filter { $0.isPlayable }, by: { $0.artist.lowercased() })
        var counts: [String: Int] = [:]        // lowercased key -> real listens
        var display: [String: String] = [:]    // lowercased key -> canonical display name
        for e in HistoryStore.load() where e.isRealListen && !e.artist.isEmpty {
            let key = e.artist.lowercased()
            guard playable[key] != nil else { continue }
            counts[key, default: 0] += 1
            display[key] = e.artist
        }
        // Deterministic order: plays desc, then name asc (so ties never reshuffle between calls).
        var pool = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { display[$0.key] ?? $0.key }
        // Thin history: top up with the artists you own the most albums by (also deterministic).
        if pool.count < count {
            let byAlbums = playable.filter { !$0.key.isEmpty }
                .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
                .compactMap { $0.value.first?.artist }
            for name in byAlbums where !pool.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                pool.append(name)
            }
        }
        let artists: [String]
        if pool.count > count {
            // Slide a `count`-wide window one page per day (and per manual reshuffle) so the mixes
            // differ from yesterday's — and from the last "New mixes" tap.
            let start = ((day + mixSeed) * count) % pool.count
            artists = (0..<count).map { pool[(start + $0) % pool.count] }
        } else {
            artists = pool
        }
        dailyMixCache = (day, mixSeed, albums.count, count, artists)
        return artists
    }

    /// Start a station seeded from a whole artist's catalogue.
    func startRadioForArtist(_ name: String, on player: PlayerEngine) {
        let seeds = albums.filter { $0.isPlayable && $0.artist.caseInsensitiveCompare(name) == .orderedSame }
        guard !seeds.isEmpty else { showNotice("No playable music by \(name)."); return }
        startRadio(seeds: seeds, seed: .artist(name), label: name, on: player)
    }

    /// Runs at most once per launch.
    private var genreBackfillDone = false
    /// Album URLs we've successfully scraped tags from (across launches), so they aren't
    /// re-fetched every launch. Persisted in UserDefaults. Only *successful* scrapes are
    /// recorded — a page that yielded no tags (transient failure, changed markup, or genuinely
    /// untagged) is retried on a later launch rather than being permanently locked out of moods.
    private static let scrapedKey = "yoin.genreScrapedURLs.v2"

    /// Bandcamp albums arrive with no genre, so moods have nothing to match. Backfill genres
    /// in the background from each album's public Bandcamp tags — throttled to stay polite,
    /// remembering which pages were already scraped so successful pages aren't re-fetched every
    /// launch, and updating live so moods light up as it goes.
    func backfillGenresFromBandcamp() async {
        guard let identity, !genreBackfillDone else { return }
        var scraped = Set(UserDefaults.standard.stringArray(forKey: Self.scrapedKey) ?? [])
        let client = BandcampClient(identity: identity)
        let targets = albums.filter {
            $0.source == .bandcamp && ($0.genre?.isEmpty ?? true)
            && ($0.bandcampItemURL.map { !scraped.contains($0) } ?? false)
        }
        // Nothing to do yet (e.g. before the first sync populates the collection) — leave the
        // flag unset so a later sync can kick this off.
        guard !targets.isEmpty else { return }
        genreBackfillDone = true
        let urls = targets.compactMap { $0.bandcampItemURL }
        var processed = 0
        for url in urls {
            let tags = (try? await client.tags(forItemURL: url)) ?? []
            // Only remember pages we actually got tags from — a tagless/failed fetch stays
            // eligible for a future retry instead of being cached as "done" forever.
            if !tags.isEmpty {
                scraped.insert(url)
                // Re-find by URL (stable across a re-sync, unlike the album id).
                if let i = albums.firstIndex(where: { $0.bandcampItemURL == url }) {
                    // Keep a handful of tags; they double as the genre string moods match on.
                    albums[i].genre = tags.prefix(8).joined(separator: ", ")
                }
            }
            processed += 1
            if processed % 15 == 0 {
                persist()
                UserDefaults.standard.set(Array(scraped), forKey: Self.scrapedKey)
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        persist()
        UserDefaults.standard.set(Array(scraped), forKey: Self.scrapedKey)
    }

    private var localGenreBackfillDone = false

    /// Imported/local albums used to arrive without a genre (import only read title/artist/art),
    /// so mood radio stayed locked for libraries that never sync from Bandcamp. Backfill genres
    /// in the background from each album's own embedded file tags — the moods light up as it goes.
    /// Runs at most once per launch; only touches albums that have local files and no genre yet.
    func backfillLocalGenres() async {
        guard !localGenreBackfillDone else { return }
        let targets: [(id: UUID, file: URL)] = albums.compactMap { a in
            guard a.genre?.isEmpty ?? true else { return nil }
            guard let file = a.localTracks?.first ?? a.url else { return nil }
            return (a.id, file)
        }
        guard !targets.isEmpty else { return }
        localGenreBackfillDone = true
        var processed = 0
        for (id, file) in targets {
            guard let g = await Self.loadMetadata(url: file).genre else { continue }
            // Re-find by id and only fill if still empty (enrichment may have set one meanwhile).
            if let i = albums.firstIndex(where: { $0.id == id }), albums[i].genre?.isEmpty ?? true {
                albums[i].genre = g
            }
            processed += 1
            if processed % 15 == 0 { persist() }
        }
        persist()
    }

    /// Start a station for a mood — seeded from the albums whose genre tags match it.
    func startRadioForMood(_ mood: Mood, on player: PlayerEngine) {
        let matches = albums.filter { $0.isPlayable && mood.matches($0.genre) }
        guard !matches.isEmpty else {
            showNotice("No \(mood.label.lowercased()) music found — enrich albums to add genres."); return
        }
        let seeds = Array(matches.shuffled().prefix(4))
        // Mood radio stays *inside* the mood (no drifting across the library).
        let restrict: (Album) -> Bool = { mood.matches($0.genre) }
        radioStarting = .mood(mood)   // show the spinner immediately (covers the Last.fm fetch too)
        // Online mode: rank picks by the wider world's top artists for this mood (needs a key).
        if RadioPrefs.moodOnline, let key = RadioPrefs.lastfmKey {
            radioGeneration &+= 1; radioRefilling = false
            let generation = radioGeneration
            Task {
                let boost = await LastFMClient.topArtists(forTag: mood.lastfmTag, key: key)
                startRadio(seeds: seeds, restrictTo: restrict, artistBoost: boost,
                           generation: generation, seed: .mood(mood), label: mood.label, on: player)
            }
        } else {
            startRadio(seeds: seeds, restrictTo: restrict, seed: .mood(mood), label: mood.label, on: player)
        }
    }

    /// Shared radio launcher: reset any current station, build the opening tracks, play.
    /// Pass an explicit `generation` when the caller already bumped it (online mood path).
    private func startRadio(seeds: [Album], seedTrack: Track? = nil, nowPlayingID: UUID? = nil,
                            restrictTo: ((Album) -> Bool)? = nil, artistBoost: [String: Double] = [:],
                            generation: Int? = nil, seed: RadioSeed, label: String, on player: PlayerEngine) {
        // Invalidate any station already running (and its in-flight top-up).
        if generation == nil { radioGeneration &+= 1; radioRefilling = false }
        let generation = generation ?? radioGeneration
        // Spinner on the tapped station (album/artist starts land here too). Only if we're still
        // the current generation — a stale online-mood task must not clobber a newer tap's spinner.
        if generation == radioGeneration { radioStarting = seed }
        Task {
            let opening = await radio.start(seeds: seeds, seedTrack: seedTrack,
                                            restrictTo: restrictTo, artistBoost: artistBoost)
            // A newer startRadio/stopRadio superseded us while we were resolving — it now owns
            // `radioStarting`, so don't touch it.
            guard generation == radioGeneration else { return }
            radioStarting = nil   // this station finished loading (success or empty)
            guard !opening.isEmpty else { showNotice("Couldn't start radio."); return }
            nowPlayingAlbumID = nowPlayingID
            radioActive = true
            currentRadioSeed = seed
            currentRadioLabel = label
            player.play(opening)
            showNotice("Radio: \(label)")
        }
    }

    func stopRadio() {
        radioStarting = nil     // cancel any pending "starting…" spinner
        guard radioActive else { return }
        radioGeneration &+= 1   // discard any in-flight top-up
        radioRefilling = false
        radioActive = false
        currentRadioSeed = nil
        currentRadioLabel = nil
        radio.stop()
    }

    // MARK: Saved radio stations

    func persistRadios() { SavedRadioStore.save(savedRadios) }

    /// True when the currently-playing station is already saved.
    var isCurrentRadioSaved: Bool {
        guard let seed = currentRadioSeed else { return false }
        return savedRadios.contains { $0.seed == seed }
    }

    /// Save the station that's playing now.
    func saveCurrentRadio() {
        guard let seed = currentRadioSeed, let name = currentRadioLabel else { return }
        guard !savedRadios.contains(where: { $0.seed == seed }) else { showNotice("Already saved"); return }
        savedRadios.insert(SavedRadio(name: name, seed: seed), at: 0)
        persistRadios()
        showNotice("Saved “\(name)” to Radio")
    }

    func deleteSavedRadio(_ id: UUID) {
        savedRadios.removeAll { $0.id == id }
        persistRadios()
    }

    /// Play a saved station (regenerates fresh from the current library).
    func playSavedRadio(_ radio: SavedRadio, on player: PlayerEngine) {
        switch radio.seed {
        case .mood(let m):
            startRadioForMood(m, on: player)
        case .artist(let a):
            startRadioForArtist(a, on: player)
        case .album(let title, let artist):
            if let album = albums.first(where: {
                $0.title.caseInsensitiveCompare(title) == .orderedSame &&
                $0.artist.caseInsensitiveCompare(artist) == .orderedSame
            }) {
                startRadio(album: album, on: player)
            } else {
                showNotice("“\(title)” isn't in your library anymore.")
            }
        }
    }

    /// Called as the playhead advances — refills the station before the queue runs dry.
    func radioTopUpIfNeeded(on player: PlayerEngine) {
        guard radioActive, !radioRefilling else { return }
        guard player.queue.count - player.index <= 5 else { return }
        radioRefilling = true
        let generation = radioGeneration
        Task {
            let more = await radio.topUp()
            // Drop the result if the station was stopped/replaced while we generated.
            guard generation == radioGeneration else { return }
            radioRefilling = false
            if radioActive, !more.isEmpty { player.addToQueue(more) }
        }
    }

    /// Feed a finished track's outcome back into the station (skip vs. real listen).
    func radioFeedback(_ track: Track, elapsed: Double, duration: Double) {
        guard radioActive else { return }
        // A track that never loaded (duration 0, barely any elapsed) is a failure, not a
        // dislike — don't penalize the artist for it.
        if duration <= 0 && elapsed < 5 { return }
        let liked = elapsed >= 30 || (duration > 0 && elapsed / duration >= 0.5)
        radio.recordFeedback(artist: track.artist, liked: liked)
    }

    // MARK: - Queue (play next / add to queue)

    func playNextAlbum(_ album: Album, on player: PlayerEngine) {
        Task {
            let tracks = await resolveTracks(for: album)
            guard !tracks.isEmpty else { return }
            if player.queue.isEmpty { nowPlayingAlbumID = album.id }
            player.playNext(tracks)
            showNotice("Playing next: \(album.title)")
        }
    }

    func addAlbumToQueue(_ album: Album, on player: PlayerEngine) {
        Task {
            let tracks = await resolveTracks(for: album)
            guard !tracks.isEmpty else { return }
            if player.queue.isEmpty { nowPlayingAlbumID = album.id }
            player.addToQueue(tracks)
            showNotice("Added to queue: \(album.title)")
        }
    }

    // MARK: - Playlists

    func persistPlaylists() { PlaylistStore.save(playlists) }

    @discardableResult
    func createPlaylist(named name: String = "New Playlist") -> Playlist {
        // Keep the default name unique so several fresh playlists don't collide.
        var candidate = name
        var n = 2
        while playlists.contains(where: { $0.name == candidate }) { candidate = "\(name) \(n)"; n += 1 }
        let pl = Playlist(name: candidate)
        playlists.insert(pl, at: 0)
        persistPlaylists()
        return pl
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        playlists[i].name = trimmed.isEmpty ? "Untitled Playlist" : trimmed
        persistPlaylists()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        if selectedPlaylistID == id { selectedPlaylistID = playlists.first?.id }
        persistPlaylists()
    }

    func setPlaylistCover(_ id: UUID, data: Data?) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].coverImageData = data
        persistPlaylists()
    }

    // MARK: Smart playlists

    /// Create (or re-select, if it already exists) an auto-generated playlist for a rule,
    /// jump to it, and kick off its first build.
    func createSmartPlaylist(_ rule: SmartRule) {
        if let existing = playlists.first(where: { $0.smart == rule }) {
            selectedPlaylistID = existing.id
            withAnimation(Motion.glide) { screen = .playlists }
            Task { await rebuildSmartPlaylist(existing.id) }
            return
        }
        let pl = createPlaylist(named: rule.defaultName)   // inserts at 0, persists, keeps name unique
        if let i = playlists.firstIndex(where: { $0.id == pl.id }) {
            playlists[i].smart = rule
            persistPlaylists()
        }
        selectedPlaylistID = pl.id
        withAnimation(Motion.glide) { screen = .playlists }
        Task { await rebuildSmartPlaylist(pl.id) }
    }

    /// Recompute one smart playlist's tracks from current history + library.
    func rebuildSmartPlaylist(_ id: UUID) async {
        guard playlists.first(where: { $0.id == id })?.smart != nil else { return }
        // Already building this one — mark it dirty so the running pass re-runs once with
        // the newer data (e.g. a post-sync rebuild landing during the slow launch rebuild),
        // rather than being silently dropped.
        if rebuildingSmart.contains(id) { smartRebuildPending.insert(id); return }
        rebuildingSmart.insert(id)
        defer { rebuildingSmart.remove(id) }
        repeat {
            smartRebuildPending.remove(id)
            guard let rule = playlists.first(where: { $0.id == id })?.smart else { return }
            let snapshot = albums
            let history = HistoryStore.load()
            let tracks = await SmartPlaylistBuilder.build(rule, albums: snapshot, history: history) { album in
                await self.resolveTracks(for: album)
            }
            // Re-find: the list may have changed while we awaited resolution.
            guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
            playlists[i].tracks = tracks
            persistPlaylists()
        } while smartRebuildPending.contains(id)
    }

    /// Refresh every smart playlist (called on launch, after a Bandcamp sync, and on demand).
    func rebuildSmartPlaylists() async {
        lastSmartRebuild = Date()
        for id in playlists.filter({ $0.isSmart }).map(\.id) {
            await rebuildSmartPlaylist(id)
        }
    }

    /// Throttled variant for the Playlists tab's `.task`, which re-fires on every visit —
    /// resolving tracks is network-bound, so skip if we rebuilt recently (launch/sync/refresh
    /// already keep them fresh).
    func rebuildSmartPlaylistsIfStale(minInterval: TimeInterval = 90) async {
        guard playlists.contains(where: { $0.isSmart }),
              Date().timeIntervalSince(lastSmartRebuild) >= minInterval else { return }
        await rebuildSmartPlaylists()
    }

    /// Add every track of an album to a playlist (resolving titles/order).
    func addAlbum(_ album: Album, toPlaylist id: UUID) {
        Task {
            let tracks = await resolveTracks(for: album)
            guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
            guard !tracks.isEmpty else { showNotice("Couldn't load “\(album.title)”."); return }
            let entries = tracks.enumerated().map { idx, t in
                PlaylistTrack(albumID: album.id, albumTitle: album.title, artist: album.artist,
                              title: t.title, trackIndex: idx,
                              artworkURL: album.artworkURL, artworkData: album.artworkData,
                              g0: album.g0, g1: album.g1)
            }
            playlists[i].tracks.append(contentsOf: entries)
            persistPlaylists()
            showNotice("Added \(entries.count) track\(entries.count == 1 ? "" : "s") to \(playlists[i].name)")
        }
    }

    /// Create a new playlist, drop this album in, and jump to it in rename mode.
    func createPlaylistAndAdd(_ album: Album) {
        let pl = createPlaylist()
        addAlbum(album, toPlaylist: pl.id)
        selectedPlaylistID = pl.id
        renamingPlaylistID = pl.id
        withAnimation(Motion.glide) { screen = .playlists }
    }

    func removeFromPlaylist(_ id: UUID, at offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.remove(atOffsets: offsets)
        persistPlaylists()
    }

    func moveInPlaylist(_ id: UUID, from offsets: IndexSet, to dest: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.move(fromOffsets: offsets, toOffset: dest)
        persistPlaylists()
    }

    /// Build a playlist entry for a single (usually now-playing) track.
    private func playlistEntry(for track: Track) -> PlaylistTrack? {
        guard let albumID = track.albumID, let index = track.trackIndex else { return nil }
        let album = albums.first { $0.id == albumID }
        return PlaylistTrack(albumID: albumID,
                             albumTitle: album?.title ?? track.title,
                             artist: track.artist,
                             title: track.title,
                             trackIndex: index,
                             artworkURL: track.artworkURL ?? album?.artworkURL,
                             artworkData: track.artworkData ?? album?.artworkData,
                             g0: track.g0, g1: track.g1)
    }

    /// Add a single track (e.g. the now-playing one) to a playlist.
    func addTrack(_ track: Track, toPlaylist id: UUID) {
        guard let entry = playlistEntry(for: track) else {
            showNotice("Couldn't add this track to a playlist."); return
        }
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.append(entry)
        persistPlaylists()
        showNotice("Added “\(track.title)” to \(playlists[i].name)")
    }

    /// New playlist seeded with a single track, then jump to it in rename mode.
    func createPlaylistAndAdd(track: Track) {
        let pl = createPlaylist()
        addTrack(track, toPlaylist: pl.id)
        selectedPlaylistID = pl.id
        renamingPlaylistID = pl.id
        withAnimation(Motion.glide) { screen = .playlists }
    }

    /// Resolve a playlist into a playable queue — each member album resolved once, then
    /// its stored track picked by index (so cross-album reordering plays in the right order).
    func resolvePlaylistTracks(_ playlist: Playlist) async -> [Track] {
        var byAlbum: [UUID: [Track]] = [:]
        var result: [Track] = []
        for entry in playlist.tracks {
            let resolved: [Track]
            if let cached = byAlbum[entry.albumID] {
                resolved = cached
            } else if let album = albums.first(where: { $0.id == entry.albumID }) {
                resolved = await resolveTracks(for: album)
                byAlbum[entry.albumID] = resolved
            } else {
                byAlbum[entry.albumID] = []
                resolved = []
            }
            if resolved.indices.contains(entry.trackIndex) { result.append(resolved[entry.trackIndex]) }
        }
        return result
    }

    func playPlaylist(_ playlist: Playlist, on player: PlayerEngine, startAt index: Int = 0) {
        stopRadio()
        Task {
            let tracks = await resolvePlaylistTracks(playlist)
            guard !tracks.isEmpty else { showNotice("Couldn't load “\(playlist.name)”."); return }
            nowPlayingAlbumID = nil    // playlist context — per-track album lives on each Track
            player.play(tracks, startAt: min(max(0, index), tracks.count - 1))
        }
    }

    func toggleScheme() {
        withAnimation(.easeInOut(duration: 0.25)) {
            scheme = (scheme == .dark) ? .light : .dark
        }
    }

    var current: Album {
        let v = visibleAlbums
        guard !v.isEmpty else { return albums.first ?? Album.placeholder }
        return v[max(0, min(front, v.count - 1))]
    }

    // MARK: - Bandcamp

    func connect() { showLogin = true }

    /// Called by the login sheet once it captures the session cookie.
    func finishConnect(identity: String) {
        Keychain.set(identity, account: "identity")
        self.identity = identity
        showLogin = false
        Task { await syncBandcamp() }
    }

    func disconnect() {
        Keychain.delete(account: "identity")
        identity = nil
        sync = .idle
        albums.removeAll { $0.source == .bandcamp }
        Self.clearBandcampWebData()   // actually log out — drop any residual WebKit session cookies
        persist()
    }

    /// Remove any Bandcamp cookies/data left in WebKit's shared store (older builds used a
    /// persistent login store). Without this, "Disconnect" wouldn't truly log the user out.
    private static func clearBandcampWebData() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let bc = records.filter { $0.displayName.contains("bandcamp") }
            guard !bc.isEmpty else { return }
            store.removeData(ofTypes: types, for: bc) {}
        }
    }

    func syncBandcamp(announce: Bool = false) async {
        guard let identity else { return }
        sync = .syncing
        syncLoaded = 0
        syncTotal = 0
        do {
            let client = BandcampClient(identity: identity)
            let summary = try await client.collectionSummary()
            syncTotal = summary.total ?? 0
            let items = try await client.collection(fanID: summary.fanID) { loaded in
                Task { @MainActor [weak self] in self?.syncLoaded = loaded }
            }

            // Keep any already-downloaded files across a re-sync (matched by album page URL).
            let downloadedByURL = Dictionary(
                albums.filter { $0.source == .bandcamp && $0.localTracks != nil }
                    .compactMap { a in a.bandcampItemURL.map { ($0, a.localTracks!) } },
                uniquingKeysWith: { a, _ in a }
            )

            // Preserve any local metadata edits (title/artist/cover/credits/history) across
            // a re-sync, matched by album page URL — a sync shouldn't wipe the user's work.
            let existingByURL = Dictionary(
                albums.filter { $0.source == .bandcamp }
                    .compactMap { a in a.bandcampItemURL.map { ($0, a) } },
                uniquingKeysWith: { a, _ in a }
            )

            let hidden = Self.hiddenBandcamp
            let bandcampAlbums = items.filter { item in
                // Skip albums the user has deleted from the library.
                item.itemURL.map { !hidden.contains($0) } ?? true
            }.map { item -> Album in
                var a = Album(title: item.title, artist: item.artist, year: "",
                      format: "Bandcamp", lossless: true, g0: 0.30, g1: 0.09,
                      artworkURL: item.artworkURL, source: .bandcamp,
                      bandcampItemURL: item.itemURL,
                      bandcampDownloadURL: item.downloadPageURL)
                // Remember the pristine Bandcamp values so "Reset to original" always works.
                a.origTitle = item.title
                a.origArtist = item.artist
                a.origArtworkURL = item.artworkURL
                // Carry over the user's edits/enrichment if we already had this album.
                if let url = item.itemURL, let prev = existingByURL[url] {
                    a.title = prev.title
                    a.artist = prev.artist
                    a.year = prev.year
                    a.artworkURL = prev.artworkURL
                    a.artworkData = prev.artworkData
                    a.label = prev.label
                    a.genre = prev.genre
                    a.credits = prev.credits
                    a.trackCredits = prev.trackCredits
                    a.discogsReleaseID = prev.discogsReleaseID
                    a.musicbrainzID = prev.musicbrainzID
                    a.history = prev.history
                    a.isFavourite = prev.isFavourite
                }
                if let url = item.itemURL, let local = downloadedByURL[url] {
                    a.localTracks = local
                    a.format = "FLAC (offline)"
                }
                return a
            }
            albums.removeAll { $0.source == .bandcamp }
            albums.insert(contentsOf: bandcampAlbums, at: 0)
            front = 0
            sync = .done(bandcampAlbums.count)
            persist()
            Task { await rebuildSmartPlaylists() }   // new plays / albums may shift the rankings
            Task { await backfillGenresFromBandcamp() }   // fill genres for mood radio
            if announce {
                showNotice("Synced \(bandcampAlbums.count) album\(bandcampAlbums.count == 1 ? "" : "s") from Bandcamp")
            }
        } catch {
            let msg = (error as? BandcampError)?.errorDescription ?? error.localizedDescription
            sync = .failed(msg)
            showNotice(msg)
            // A stale cookie means we're effectively logged out.
            if case BandcampError.notAuthenticated = error { disconnect() }
        }
    }

    // MARK: - Wishlist (saved-but-not-bought items)

    /// Wishlist items, modelled as Bandcamp albums (streamable + buyable) but kept OUT of
    /// `albums` so they never count toward the owned library, stats, radio, or health checks.
    @Published var wishlist: [Album] = []

    enum WishlistLoad: Equatable { case idle, loading, loaded, failed(String) }
    @Published var wishlistLoad: WishlistLoad = .idle

    /// Fetch the account's Bandcamp wishlist. Cheap enough to call whenever the tab opens; it
    /// replaces the in-memory list (not persisted — always fresh from Bandcamp).
    func syncWishlist(force: Bool = false) async {
        guard let identity else { wishlistLoad = .failed("Connect your Bandcamp account to see your wishlist."); return }
        if case .loading = wishlistLoad { return }
        if !force, case .loaded = wishlistLoad, !wishlist.isEmpty { return }
        wishlistLoad = .loading
        do {
            let client = BandcampClient(identity: identity)
            let fanID = try await client.fanID()
            let items = try await client.wishlist(fanID: fanID)
            // Reuse the id of any item that's still on the wishlist (matched by page URL) so a
            // refresh doesn't orphan the currently-playing wishlist track (which is tracked by id).
            let prevIDByURL = Dictionary(
                wishlist.compactMap { a in a.bandcampItemURL.map { ($0, a.id) } },
                uniquingKeysWith: { a, _ in a }
            )
            wishlist = items.map { item in
                var a = Album(title: item.title, artist: item.artist, year: "",
                              format: "Wishlist", lossless: true, g0: 0.30, g1: 0.09,
                              artworkURL: item.artworkURL, source: .bandcamp,
                              bandcampItemURL: item.itemURL,
                              bandcampDownloadURL: nil)
                if let url = item.itemURL, let id = prevIDByURL[url] { a.id = id }
                return a
            }
            wishlistLoad = .loaded
        } catch {
            let msg = (error as? BandcampError)?.errorDescription ?? error.localizedDescription
            wishlistLoad = .failed(msg)
            if case BandcampError.notAuthenticated = error { disconnect() }
        }
    }

    // MARK: - Friends (Bandcamp fans this account follows)

    /// Whether the friends browser overlay is showing.
    @Published var friendsOpen = false
    /// The friend whose collection is currently open (nil = show the friends list).
    @Published var openedFriend: Friend? = nil

    @Published var friends: [Friend] = []
    enum FriendsLoad: Equatable { case idle, loading, loaded, failed(String) }
    @Published var friendsLoad: FriendsLoad = .idle

    /// One friend's collection or wishlist, revealed a page (20) at a time rather than pulling
    /// their whole library up front — a friend can own hundreds of albums.
    struct FriendItems {
        var albums: [Album] = []
        var next: String? = nil        // `older_than_token` for the next page
        var started = false
        var loading = false
        var reachedEnd = false
        var failed: String? = nil
        var seen: Set<String> = []     // dedupe across page boundaries
    }
    /// Per-friend caches, keyed by fan_id, so reopening a friend keeps what was already loaded.
    @Published var friendColl: [Int: FriendItems] = [:]
    @Published var friendWish: [Int: FriendItems] = [:]

    func friendItems(_ id: Int, wishlist: Bool) -> FriendItems {
        (wishlist ? friendWish[id] : friendColl[id]) ?? FriendItems()
    }
    private func store(_ s: FriendItems, _ id: Int, _ wishlist: Bool) {
        if wishlist { friendWish[id] = s } else { friendColl[id] = s }
    }

    /// Open the friends browser (and load the list on first open).
    func openFriends() {
        friendsOpen = true
        openedFriend = nil
        Task { await syncFriends() }
    }

    /// Fetch the list of fans this account follows.
    func syncFriends(force: Bool = false) async {
        guard let identity else { friendsLoad = .failed("Connect your Bandcamp account to see your friends."); return }
        if case .loading = friendsLoad { return }
        if !force, case .loaded = friendsLoad, !friends.isEmpty { return }
        friendsLoad = .loading
        do {
            friends = try await BandcampClient(identity: identity).followingFans()
            friendsLoad = .loaded
        } catch {
            friendsLoad = .failed((error as? BandcampError)?.errorDescription ?? error.localizedDescription)
            if case BandcampError.notAuthenticated = error { disconnect() }
        }
    }

    /// Open a friend and load the first page of their collection.
    func openFriend(_ friend: Friend) {
        openedFriend = friend
        if !friendItems(friend.id, wishlist: false).started {
            Task { await loadMoreFriend(friend, wishlist: false) }
        }
    }

    /// First page of a friend's list (no-op once it's been started).
    func startFriendList(_ friend: Friend, wishlist: Bool) async {
        if friendItems(friend.id, wishlist: wishlist).started { return }
        await loadMoreFriend(friend, wishlist: wishlist)
    }

    /// Fetch the next 20 items of a friend's collection (or wishlist), appending to what's shown.
    func loadMoreFriend(_ friend: Friend, wishlist: Bool) async {
        guard let identity else { return }
        var s = friendItems(friend.id, wishlist: wishlist)
        if s.loading || s.reachedEnd { return }
        s.loading = true; s.started = true; s.failed = nil
        store(s, friend.id, wishlist)
        do {
            let client = BandcampClient(identity: identity)
            let page = wishlist
                ? try await client.wishlistPage(fanID: friend.id, olderThan: s.next, count: 20)
                : try await client.collectionPage(fanID: friend.id, olderThan: s.next, count: 20)
            var t = friendItems(friend.id, wishlist: wishlist)
            for item in page.items {
                let key = item.itemURL ?? "id:\(item.id)"
                if t.seen.insert(key).inserted { t.albums.append(Self.friendAlbum(from: item)) }
            }
            t.next = page.next
            t.reachedEnd = (page.next == nil)
            t.loading = false
            store(t, friend.id, wishlist)
        } catch {
            var t = friendItems(friend.id, wishlist: wishlist)
            t.loading = false
            t.failed = (error as? BandcampError)?.errorDescription ?? error.localizedDescription
            store(t, friend.id, wishlist)
            if case BandcampError.notAuthenticated = error { disconnect() }
        }
    }

    // MARK: - "People you follow own this" (the macaron)

    /// Which followed friends own each album, keyed by normalized Bandcamp item URL.
    @Published var friendOwners: [String: [Friend]] = [:]
    enum OwnershipLoad: Equatable { case idle, loading, loaded }
    @Published var ownershipLoad: OwnershipLoad = .idle

    /// The user's own library album matching a Bandcamp item URL, if they own it — used to show
    /// an "owned" badge and a "Go to album" jump when browsing a friend's collection.
    func libraryAlbum(forBandcampURL url: String?) -> Album? {
        guard let key = Self.normalizeBCURL(url) else { return nil }
        return albums.first { $0.source == .bandcamp && Self.normalizeBCURL($0.bandcampItemURL) == key }
    }

    /// Close the friends drawer and open an owned album's detail page.
    func goToLibraryAlbum(_ id: UUID) {
        friendsOpen = false
        openedFriend = nil
        openedAlbumID = id
    }

    /// Followed friends who own this album (empty when unknown / not built yet).
    func owners(of album: Album) -> [Friend] {
        guard let key = Self.normalizeBCURL(album.bandcampItemURL) else { return [] }
        return friendOwners[key] ?? []
    }

    /// Build the ownership index: for each followed friend, fetch their collection and record
    /// which of *your* albums they also own. Runs once per session (in the background) — it's
    /// the one friends feature with real cost (one collection fetch per friend), so it's throttled
    /// to a few concurrent requests and only matches URLs already in your library.
    func buildFriendOwnership(force: Bool = false) async {
        guard let identity else { return }
        if case .loading = ownershipLoad { return }
        if !force, case .loaded = ownershipLoad { return }
        // Claim the slot *before* the first await, else two concurrent view .task callers both
        // pass the guard above and each run the full per-friend collection scan (the heaviest
        // network op in the friends feature).
        ownershipLoad = .loading
        await syncFriends()
        guard !friends.isEmpty else { ownershipLoad = .loaded; return }

        let mine = Set(albums.compactMap { Self.normalizeBCURL($0.bandcampItemURL) })
        guard !mine.isEmpty else { ownershipLoad = .loaded; return }

        let friends = self.friends
        var hits: [(String, Friend)] = []
        let batchSize = 4
        for start in stride(from: 0, to: friends.count, by: batchSize) {
            let batch = Array(friends[start..<min(start + batchSize, friends.count)])
            let part = await withTaskGroup(of: [(String, Friend)].self) { group in
                for f in batch {
                    group.addTask {
                        let client = BandcampClient(identity: identity)
                        guard let items = try? await client.collection(fanID: f.id) else { return [] }
                        return items.compactMap { item in
                            Self.normalizeBCURL(item.itemURL).flatMap { mine.contains($0) ? ($0, f) : nil }
                        }
                    }
                }
                var acc: [(String, Friend)] = []
                for await r in group { acc.append(contentsOf: r) }
                return acc
            }
            hits.append(contentsOf: part)
        }

        var index: [String: [Friend]] = [:]
        for (url, f) in hits { index[url, default: []].append(f) }
        for k in index.keys {
            var seen = Set<Int>()
            index[k] = index[k]!.filter { seen.insert($0.id).inserted }
        }
        friendOwners = index
        ownershipLoad = .loaded
    }

    /// Canonical form of a Bandcamp item URL for matching (lowercased, no query/fragment/trailing slash).
    nonisolated static func normalizeBCURL(_ s: String?) -> String? {
        guard var u = s?.lowercased() else { return nil }
        if let q = u.firstIndex(of: "?") { u = String(u[..<q]) }
        if let h = u.firstIndex(of: "#") { u = String(u[..<h]) }
        while u.hasSuffix("/") { u.removeLast() }
        return u.isEmpty ? nil : u
    }

    /// A streamable, non-persisted Album for a friend's item, carrying their review note.
    private static func friendAlbum(from item: BCItem) -> Album {
        var a = Album(title: item.title, artist: item.artist, year: "",
                      format: "Bandcamp", lossless: true, g0: 0.30, g1: 0.09,
                      artworkURL: item.artworkURL, source: .bandcamp,
                      bandcampItemURL: item.itemURL, bandcampDownloadURL: nil)
        a.friendReview = item.review
        return a
    }

    /// Resolves an album into a playable track queue (downloaded files, local file, or Bandcamp streams).
    func resolveTracks(for album: Album) async -> [Track] {
        if let locals = album.localTracks, !locals.isEmpty {
            return locals.enumerated().map { i, fileURL in
                Track(title: FilenameCleaner.trackTitle(fileURL.deletingPathExtension().lastPathComponent),
                      artist: album.artist, streamURL: fileURL,
                      artworkURL: album.artworkURL, albumID: album.id, trackIndex: i, g0: album.g0, g1: album.g1)
            }
        }
        if let url = album.url {
            return [Track(title: album.title, artist: album.artist, streamURL: url,
                          artworkData: album.artworkData, albumID: album.id, trackIndex: 0, g0: album.g0, g1: album.g1)]
        }
        if album.source == .bandcamp, let identity, let itemURL = album.bandcampItemURL {
            do {
                var tracks = try await BandcampClient(identity: identity).tracks(forItemURL: itemURL)
                for i in tracks.indices { tracks[i].albumID = album.id; tracks[i].trackIndex = i }
                return tracks
            } catch {
                NSLog("Bandcamp track resolve failed: \(error)")
                if case BandcampError.notAuthenticated = error {
                    showNotice("Your Bandcamp session expired — reconnect to keep playing.")
                    disconnect()
                } else {
                    showNotice("Couldn't load “\(album.title)” from Bandcamp.")
                }
                return []
            }
        }
        return []
    }

    // MARK: - Bandcamp download (lossless, offline)

    func download(_ album: Album) {
        Task { await downloadOne(album) }
    }

    /// Download every not-yet-downloaded Bandcamp album, one at a time.
    func downloadAll() {
        Task {
            for album in albums where album.canDownload {
                await downloadOne(album)
            }
        }
    }

    private func downloadOne(_ album: Album) async {
        guard let identity, let page = album.bandcampDownloadURL,
              downloads[album.id] != .downloading else { return }
        downloads[album.id] = .downloading
        do {
            let files = try await Self.performDownload(identity: identity, pageURL: page,
                                                       artist: album.artist, title: album.title)
            guard !files.isEmpty else { throw BandcampError.decode }
            if let idx = albums.firstIndex(where: { $0.id == album.id }) {
                albums[idx].localTracks = files
                albums[idx].format = "FLAC (offline)"
            }
            downloads[album.id] = .done
            persist()
        } catch {
            NSLog("Bandcamp download failed: \(error)")
            downloads[album.id] = .failed(error.localizedDescription)
            if case BandcampError.notAuthenticated = error {
                showNotice("Your Bandcamp session expired — reconnect to download.")
                disconnect()
            } else {
                showNotice("Couldn't download “\(album.title)”.")
            }
        }
    }

    private static func performDownload(identity: String, pageURL: String,
                                        artist: String, title: String) async throws -> [URL] {
        let client = BandcampClient(identity: identity)
        let (fileURL, _) = try await client.resolveDownloadURL(pageURL: pageURL)

        let (tmp, resp) = try await URLSession.shared.download(for: client.authorizedRequest(fileURL))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BandcampError.badResponse(http.statusCode)
        }

        let fm = FileManager.default
        let safe = { (s: String) in s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces) }
        let dest = libraryFolder.appendingPathComponent("\(safe(artist)) - \(safe(title))", isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        // Detect a zip (album) by its magic bytes; otherwise it's a single track file.
        let handle = try FileHandle(forReadingFrom: tmp)
        let magic = try handle.read(upToCount: 8) ?? Data()
        try? handle.close()
        let isZip = (magic.prefix(2) == Data([0x50, 0x4B]))   // "PK"

        if isZip {
            try unzip(tmp, to: dest)
        } else {
            // Guard against Bandcamp answering with a 200 HTML/JSON error page (e.g. an
            // expired session) — don't save that verbatim as a ".flac" that won't play.
            let mime = (resp as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let looksLikeText = magic.first == 0x3C          // '<' → HTML/XML
                || magic.first == 0x7B                       // '{' → JSON
                || mime.contains("text/") || mime.contains("json")
            if looksLikeText { try? fm.removeItem(at: dest); throw BandcampError.decode }
            let file = dest.appendingPathComponent("\(safe(title)).flac")
            try fm.moveItem(at: tmp, to: file)
        }

        // Collect audio files, sorted (track order).
        let audio = (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil))?
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []
        return audio
    }

    private static func unzip(_ zip: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw BandcampError.decode }
    }

    // MARK: - Drag & drop import

    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "alac", "caf", "aifc"]

    private static func lossless(_ ext: String) -> Bool {
        ["FLAC", "ALAC", "WAV", "AIF", "AIFF", "AIFC"].contains(ext.uppercased())
    }

    /// Handle files/folders dropped anywhere on the window. Audio files import as singles;
    /// folders import as one album (their audio files become the tracks).
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let items = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !items.isEmpty else { return false }
        Task { @MainActor in
            for provider in items {
                guard let url = await Self.loadURL(from: provider) else { continue }
                self.importAny(url)
            }
        }
        return true
    }

    /// Import a picked/dropped URL: a folder becomes an album, an audio file a single.
    @MainActor
    func importAny(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            importFolder(url)
        } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
            importFile(url)
        }
    }

    /// Show an open panel and import whatever the user picks (files or album folders).
    @MainActor
    func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = "Import"
        panel.message = "Choose audio files, or a folder to import as an album."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importAny(url) }
    }

    // MARK: Apple Music

    /// The Apple Music / iTunes "Music" media folder, if present (modern first, legacy last).
    nonisolated static var appleMusicMusicFolder: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "Music/Music/Media.localized/Music",
            "Music/Music/Media/Music",
            "Music/iTunes/iTunes Media/Music",
        ].map { home.appendingPathComponent($0) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Import albums you own in the Apple Music app. Opens a panel at the Music
    /// media folder so the user grants access; whole-library, per-artist, or
    /// per-album selections all work (each album folder becomes one album).
    @MainActor
    func importFromAppleMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder]
        panel.prompt = "Import"
        panel.message = "Choose your Apple Music library, an artist, or an album folder."
        panel.directoryURL = Self.appleMusicMusicFolder
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importTree(url) }
    }

    /// Import a directory tree: a folder with audio files becomes one album,
    /// otherwise recurse into subfolders (Artist/Album/tracks, whole libraries).
    @MainActor
    func importTree(_ url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        guard isDir.boolValue else {
            if Self.audioExtensions.contains(url.pathExtension.lowercased()) { importFile(url) }
            return
        }
        let contents = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if contents.contains(where: { Self.audioExtensions.contains($0.pathExtension.lowercased()) }) {
            importFolder(url)
        } else {
            for sub in contents {
                var subIsDir: ObjCBool = false
                if fm.fileExists(atPath: sub.path, isDirectory: &subIsDir), subIsDir.boolValue {
                    importTree(sub)
                }
            }
        }
    }

    /// Bridge NSItemProvider's callback API to async, capturing only the continuation.
    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }

    // MARK: Managed-library copies

    /// The app's own music folder for imported singles.
    nonisolated private static var importsFolder: URL { libraryFolder.appendingPathComponent("Imports", isDirectory: true) }

    nonisolated private static func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A library subfolder that doesn't collide with an existing one.
    nonisolated private static func uniqueDir(_ parent: URL, named name: String) -> URL {
        let fm = FileManager.default
        let base = safeName(name).isEmpty ? "Album" : safeName(name)
        var dir = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = parent.appendingPathComponent("\(base) (\(n))", isDirectory: true); n += 1
        }
        return dir
    }

    /// Copy a single audio file into the app's Imports folder; returns the managed URL.
    private static func copyFileIntoLibrary(_ url: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: importsFolder, withIntermediateDirectories: true)
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent
            var dest = importsFolder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = importsFolder.appendingPathComponent("\(base) (\(n)).\(ext)"); n += 1
            }
            do { try fm.copyItem(at: url, to: dest); return dest } catch { return nil }
        }.value
    }

    /// Copy a folder's audio files into a new managed album folder; returns them in track order.
    private static func copyFolderIntoLibrary(_ folder: URL) async -> [URL]? {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let audio = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard !audio.isEmpty else { return nil }
            let dest = uniqueDir(libraryFolder, named: folder.lastPathComponent)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            var copied: [URL] = []
            for src in audio {
                let d = dest.appendingPathComponent(src.lastPathComponent)
                if (try? fm.copyItem(at: src, to: d)) != nil { copied.append(d) }
            }
            return copied.isEmpty ? nil : copied
        }.value
    }

    @MainActor
    private func importFile(_ url: URL) {
        Task { @MainActor in
            // Copy into the app's library so the entry doesn't depend on the source file.
            guard let local = await Self.copyFileIntoLibrary(url) else { return }
            let ext = local.pathExtension.uppercased()
            // Clean up messy download filenames (track numbers, underscores, junk).
            let parsed = FilenameCleaner.parse(local.deletingPathExtension().lastPathComponent)
            let album = Album(
                title: parsed.title,
                artist: parsed.artist ?? "Unknown Artist",
                year: "",
                format: ext,
                lossless: Self.lossless(ext),
                g0: 0.28, g1: 0.08,
                url: local
            )
            self.albums.insert(album, at: 0)
            self.front = 0
            self.screen = .grid
            self.persist()

            // Enrich from embedded metadata, then from the web (cover + name + credits).
            let meta = await Self.loadMetadata(url: local)
            if let idx = self.albums.firstIndex(where: { $0.id == album.id }) {
                if let t = meta.title  { self.albums[idx].title = t }
                if let a = meta.artist { self.albums[idx].artist = a }
                if let art = meta.artwork { self.albums[idx].artworkData = art }
                if let g = meta.genre { self.albums[idx].genre = g }
                self.persist()
            }
            await self.enrich(albumID: album.id)
        }
    }

    /// Import a folder as a single multi-track album (its audio files, copied into the library).
    @MainActor
    private func importFolder(_ folder: URL) {
        Task { @MainActor in
            guard let tracks = await Self.copyFolderIntoLibrary(folder) else { return }
            let exts = tracks.map { $0.pathExtension.uppercased() }
            var album = Album(
                title: folder.lastPathComponent,
                artist: "Unknown Artist",
                year: "",
                format: "\(tracks.count) track\(tracks.count == 1 ? "" : "s")",
                lossless: exts.allSatisfy { Self.lossless($0) },
                g0: 0.28, g1: 0.08
            )
            album.source = .local
            album.localTracks = tracks
            self.albums.insert(album, at: 0)
            self.front = 0
            self.screen = .grid
            self.persist()

            // Pull artist/cover from the tracks, then enrich from the web. Apple Music's
            // first file often lacks embedded art, so if track 1 has none, scan a few more
            // before falling back to the web match rather than sampling only the first.
            if let first = tracks.first {
                var meta = await Self.loadMetadata(url: first)
                if meta.artwork == nil {
                    for t in tracks.dropFirst().prefix(6) {
                        let m = await Self.loadMetadata(url: t)
                        if let art = m.artwork { meta.artwork = art; break }
                    }
                }
                if let idx = self.albums.firstIndex(where: { $0.id == album.id }) {
                    if let a = meta.artist { self.albums[idx].artist = a }
                    if let art = meta.artwork { self.albums[idx].artworkData = art }
                    if let g = meta.genre { self.albums[idx].genre = g }
                    self.persist()
                }
            }
            await self.enrich(albumID: album.id)
        }
    }

    /// Re-read embedded cover art from already-imported local albums. Because import now has
    /// an iTunes-keyspace fallback, files that showed no cover on an earlier import can be
    /// fixed in place — no need to delete and re-import. Only sets a cover when one is found
    /// (never clears an existing one), scanning several tracks per album.
    func rescanArtwork(_ ids: Set<UUID>) {
        let targets: [(id: UUID, files: [URL])] = ids.compactMap { id in
            guard let a = albums.first(where: { $0.id == id }) else { return nil }
            let files = a.localTracks ?? a.url.map { [$0] } ?? []
            return files.isEmpty ? nil : (id, files)
        }
        guard !targets.isEmpty else { showNotice("No local files to re-scan."); return }
        let total = targets.count
        showNotice("Re-scanning artwork for \(total) album\(total == 1 ? "" : "s")…")
        Task { @MainActor in
            var found = 0
            for t in targets {
                var art: Data? = nil
                for f in t.files.prefix(8) {
                    if let a = await Self.loadMetadata(url: f).artwork { art = a; break }
                }
                if let art, let idx = self.albums.firstIndex(where: { $0.id == t.id }) {
                    self.albums[idx].artworkData = art
                    found += 1
                }
            }
            self.persist()
            showNotice("Recovered artwork for \(found) of \(total) album\(total == 1 ? "" : "s").")
        }
    }

    private struct TrackMeta { var title: String?; var artist: String?; var artwork: Data?; var genre: String? }

    private static func loadMetadata(url: URL) async -> TrackMeta {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        func str(_ key: AVMetadataKey) -> String? {
            AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first?.stringValue
        }
        var artwork = AVMetadataItem.metadataItems(from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first?.dataValue
        // Apple Music / iTunes `.m4a` files keep cover art in the iTunes keyspace (the `covr`
        // atom), which frequently isn't promoted into `.commonMetadata` — so the common lookup
        // above comes back empty even though the file has embedded art. Fall back to reading
        // the iTunes-format metadata directly before giving up on a cover.
        if artwork == nil, let iTunes = try? await asset.loadMetadata(for: .iTunesMetadata) {
            artwork = AVMetadataItem.metadataItems(from: iTunes, filteredByIdentifier: .iTunesMetadataCoverArt).first?.dataValue
        }
        // Genre lives in the format-specific keyspace, not `.commonMetadata` — read it from the
        // iTunes (`.m4a`), ID3 (`.mp3`) and QuickTime atoms so imported albums carry a genre for
        // mood radio. The first non-empty wins.
        var genre: String?
        if let iTunes = try? await asset.loadMetadata(for: .iTunesMetadata) {
            genre = AVMetadataItem.metadataItems(from: iTunes, filteredByIdentifier: .iTunesMetadataUserGenre).first?.stringValue
                ?? AVMetadataItem.metadataItems(from: iTunes, filteredByIdentifier: .iTunesMetadataPredefinedGenre).first?.stringValue
        }
        if genre == nil, let id3 = try? await asset.loadMetadata(for: .id3Metadata) {
            genre = AVMetadataItem.metadataItems(from: id3, filteredByIdentifier: .id3MetadataContentType).first?.stringValue
        }
        if genre == nil, let qt = try? await asset.loadMetadata(for: .quickTimeMetadata) {
            genre = AVMetadataItem.metadataItems(from: qt, filteredByIdentifier: .quickTimeMetadataGenre).first?.stringValue
        }
        genre = genre.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return TrackMeta(title: str(.commonKeyTitle), artist: str(.commonKeyArtist), artwork: artwork, genre: genre)
    }
}
