import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import WebKit

/// Forces the SPM executable to behave like a normal foreground app (window + Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var spaceMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installSpacebarToggle()
        // The Dock/Finder icon comes from AppIcon.icns via Info.plist's CFBundleIconFile.
        // Don't touch Bundle.module here: in a hand-packaged .app the SPM resource bundle
        // isn't reliably resolvable, and its accessor fatal-errors on launch if it isn't.
    }

    /// Space toggles play/pause — except while typing in a text field (search, ⌘K palette,
    /// rename boxes), where the space must fall through as a real keystroke.
    private func installSpacebarToggle() {
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,   // 49 = spacebar
                  // Ignore ⌘/⌥/⌃-space (Spotlight, input switchers, etc.).
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            // Let Space through when a text field is editing OR a control (button/toggle/slider)
            // is keyboard-focused, so it activates that control instead of toggling playback.
            let editing = event.window?.firstResponder.map { $0 is NSText || $0 is NSTextView || $0 is NSControl } ?? false
            // Let the space type when a text field / editor is first responder.
            guard !editing else { return event }
            MainActor.assumeIsolated { ScriptingBridge.shared.player?.toggle() }
            return nil   // swallow so it doesn't also "click" a focused control
        }
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
    @AppStorage("menuBarPlayer") private var menuBarPlayer = true

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(player)
                .environmentObject(player.clock)
                .environmentObject(updater)
                .environmentObject(ipod)
                .preferredColorScheme(state.scheme)
                // The height floor is low so the Crate can shrink to its essentials — the cover
                // carousel + player bar — shedding the feature panel progressively (see
                // CrateView.featureDetail). The width floor is low too, so a short + narrow window
                // collapses into the single-cover "solo" layout (see MainPanel).
                .frame(minWidth: 220, idealWidth: 1180, minHeight: 180, idealHeight: 900)
                .onAppear {
                    // Expose the live engine/state to AppleScript (see Scripting.swift),
                    // so external players like NotchGlass can read now-playing state.
                    ScriptingBridge.shared.player = player
                    ScriptingBridge.shared.state = state
                    // Wire up the floating mini-player panel.
                    MiniPlayerController.shared.configure(player: player, state: state)
                    // Wire up the menu-bar now-playing dropdown and show it if enabled.
                    MenuBarController.shared.configure(player: player, state: state)
                    MenuBarController.shared.setInstalled(menuBarPlayer)
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
                    // Feed the "Auto" EQ preset the current album's genre.
                    player.currentGenre = { [weak state] in state?.nowPlayingAlbum?.genre }
                    // Show the "What's New" card once on the first launch after an update.
                    if WhatsNew.shouldAutoShow() { state.showWhatsNew = true }
                    // Show last month's listening receipt once, at the start of a new month.
                    else if let m = MonthlyReceipt.shouldAutoShow() { state.receiptMonth = m }
                    // Fill missing genres on imported/local albums from their file tags so mood
                    // radio works without a Bandcamp sync.
                    Task { await state.backfillLocalGenres() }
                    // Also scrape Bandcamp tags for genre-less Bandcamp albums at launch (not just
                    // after a sync), so existing libraries unlock moods without a manual re-sync.
                    Task { await state.backfillGenresFromBandcamp() }
                    // Fill in artist locations for the collection map (MusicBrainz, throttled).
                    Task { await state.backfillArtistLocations() }
                    // Build the "owned by friends" index at launch (not tied to a view's lifecycle,
                    // so quick navigation can't cancel it and leave the badges empty all session).
                    if state.isConnected { Task { await state.buildFriendOwnership() } }
                }
                // Add/remove the menu-bar dropdown as the Settings toggle changes.
                .onChange(of: menuBarPlayer) { _, on in MenuBarController.shared.setInstalled(on) }
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
                Button("Unbox Prototype…") { state.unboxAlbums = []; withAnimation(.easeInOut(duration: 0.35)) { state.showNewAlbumReveal = true } }
                    .keyboardShortcut("u", modifiers: [.command, .option])
            }
            CommandMenu("Playback") {
                Button("Command Palette…") { state.paletteOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Search…") { withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = true } }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Next Track") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Track") { player.prev() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button(player.shuffle ? "Turn Shuffle Off" : "Shuffle") { player.shuffle.toggle() }
                Button(player.repeatOne ? "Turn Repeat Off" : "Repeat One") { player.repeatOne.toggle() }
            }
        }
        // The menu-bar now-playing dropdown is managed in AppKit (see MenuBarController) so we
        // can centre it precisely under its icon — SwiftUI's MenuBarExtra(.window) drifts right.
    }
}

/// Bandcamp-sync progress, split out of `AppState` so the per-item tick during a sync only
/// invalidates the launch/progress UI (`LaunchLoadingView`) — not every view observing `AppState`.
@MainActor
final class SyncProgress: ObservableObject {
    /// Items fetched / total owned during a sync. `total == 0` means unknown (indeterminate bar).
    @Published var loaded = 0
    @Published var total = 0
    /// Sync progress 0…1 when the total is known, else nil (indeterminate).
    var fraction: Double? { total > 0 ? min(1, Double(loaded) / Double(total)) : nil }
}

/// Progress of the "Analyze library" tempo pass, in its own observable so per-album ticks only
/// invalidate the Settings row that shows them — not every view observing `AppState`.
@MainActor
final class BPMProgress: ObservableObject {
    @Published var running = false
    @Published var done = 0       // albums processed
    @Published var total = 0      // albums to process
    @Published var analyzed = 0   // tracks with a known BPM (store total)
}

/// App-wide UI state.
@MainActor
final class AppState: ObservableObject {
    enum Screen: Hashable { case crate, grid, playlists, wishlist, ipod, recap, settings }
    enum Filter: Hashable { case all, new, favourites, downloaded, bandcamp, imported }
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
    /// The live window size in points, published from the NSWindow (see WindowAccessor). Drives the
    /// narrow "solo" Crate layout + minimal player bar, and — at the very smallest size — hiding the
    /// player bar entirely (just the cover). A SwiftUI GeometryReader can't be trusted here because
    /// wide content overflows and clips inside a smaller window, over-reporting the size.
    @Published var windowWidth: CGFloat = 1180
    @Published var windowHeight: CGFloat = 900
    /// Usable height (points) of the display the window is on — see WindowAccessor. Drives the
    /// global UI zoom so the interface reads at a comfortable density on small laptop screens
    /// instead of feeling oversized (its absolute point sizes are tuned for a big display).
    @Published var screenHeight: CGFloat = 1080
    @Published var filter: Filter = .all { didSet { front = 0; rebuildVisible() } }
    @Published var sort: Sort = .added { didSet { rebuildVisible() } }
    @Published var nowPlayingAlbumID: UUID? { didSet { if nowPlayingAlbumID != oldValue { refreshAmbient() } } }
    /// The played album when it lives outside `albums`/`wishlist` (e.g. a friend's collection
    /// item you don't own). Retained so Now Playing can show the right cover and a buy link.
    @Published var nowPlayingExternalAlbum: Album? = nil
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
    /// The artist whose (zero-scrape) page is open, by display name. `nil` when closed.
    @Published var openedArtist: String?
    @Published var searchOpen = false
    /// The ⌘K command palette (actions + album search).
    @Published var paletteOpen = false
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
    /// A pending "quick create playlist" prompt (from the right-click menu): the item to seed the
    /// new playlist with, plus a suggested name. Non-nil drives the QuickPlaylistCreator overlay.
    @Published var playlistDraft: PlaylistDraft?
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
    /// Full-window collection map overlay (opened from the listening-stats card).
    @Published var mapOpen = false
    /// A location string the map should fly to + select once it opens (set when the user taps an
    /// album's origin on the album page). Cleared by the map once applied.
    @Published var mapFocusLocation: String? = nil
    /// Measured height of the docked player bar, so screens that scroll behind it (the album
    /// tracklist) know how much bottom clearance to add. 0 while the bar is hidden.
    @Published var playerBarHeight: CGFloat = 0
    @Published var scheme: ColorScheme = .dark
    @Published var albums: [Album] = [] { didSet { rebuildVisible() } }

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

    /// How the full-window Now Playing screen renders the hero disc — a flat cover disc, or a
    /// full turntable (record on a platter with a tracking tonearm). Persisted.
    @Published var nowPlayingStyle: NowPlayingStyle =
        NowPlayingStyle(rawValue: UserDefaults.standard.string(forKey: "yoin.nowPlayingStyle") ?? "") ?? .flat {
        didSet { UserDefaults.standard.set(nowPlayingStyle.rawValue, forKey: "yoin.nowPlayingStyle") }
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
    /// The full-window "new album" reveal overlay.
    @Published var showNewAlbumReveal = false
    /// When non-empty, the reveal unboxes exactly these albums (auto-triggered after a sync detects a
    /// just-bought record); empty means the manual, browse-the-whole-library prototype.
    @Published var unboxAlbums: [Album] = []
    /// Present the standalone First Listen screen for this album (from the Crate button / context menu).
    @Published var firstListenAlbum: Album?
    /// The month whose listening receipt is being shown (nil = hidden).
    @Published var receiptMonth: ReceiptMonth?
    @Published var identity: String? = Keychain.get(account: "identity")
    @Published var sync: SyncState = .idle
    /// Items fetched / total owned during a sync — drives the launch progress bar. Backed by a
    /// separate observable (`SyncProgress`) so the frequent updates don't invalidate the whole app;
    /// these proxies keep existing call sites working. Read the live value via `syncProgress`.
    let syncProgress = SyncProgress()
    var syncLoaded: Int { get { syncProgress.loaded } set { syncProgress.loaded = newValue } }
    var syncTotal: Int { get { syncProgress.total } set { syncProgress.total = newValue } }
    var isConnected: Bool { identity != nil }

    /// True only when there's nothing to show yet and we're still fetching — i.e. first launch
    /// / empty library. A returning user's cached crate stays visible during a background sync.
    var isInitialLoading: Bool {
        sync == .syncing && !albums.contains { $0.source == .bandcamp || $0.url != nil || $0.hasLocalFiles }
    }
    /// Sync progress 0…1 when the total is known, else nil (indeterminate).
    var syncFraction: Double? { syncProgress.fraction }

    // Downloads
    enum DownloadState: Equatable { case downloading, done, failed(String) }
    @Published var downloads: [UUID: DownloadState] = [:]

    /// Live network reachability (real Wi-Fi/ethernet state, not just login). Drives the
    /// "Offline" indicator — see `startNetworkMonitoring()`. Optimistically true until the
    /// first path update arrives.
    @Published var isOnline = true
    let networkMonitor = NetworkMonitor()

    /// Progress of a running "Prep for trip" bulk download, nil when idle.
    struct TripPrepState: Equatable { var done: Int; var total: Int }
    @Published var tripPrep: TripPrepState? = nil

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
        withAnimation(.easeOut(duration: 0.1)) { activeMenu = AppMenuState(location: point, items: items) }
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

    /// Albums (by `dedupeKey`) whose "new arrival" unboxing we've already run — so the ceremony
    /// fires once per just-bought record and never again.
    private static let celebratedKey = "yoin.celebratedAlbums"
    static var celebratedAlbums: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: celebratedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: celebratedKey) }
    }
    /// Set once we've seeded `celebratedAlbums` from the first sync, so updating the app doesn't
    /// unbox a backlog of already-owned recent purchases.
    private static let unboxInitKey = "yoin.unboxInitialized"

    /// A removed Bandcamp album, with a human-readable title/artist derived from its URL
    /// (we only stored the URL when hiding it) — used by the "Restore removed" picker.
    struct HiddenAlbum: Identifiable, Hashable {
        let url: String
        var id: String { url }
        let title: String
        let artist: String

        init(url: String) {
            self.url = url
            // e.g. https://artist.bandcamp.com/album/some-album-name
            let comps = URLComponents(string: url)
            let host = comps?.host ?? ""
            let sub = host.hasSuffix(".bandcamp.com") ? String(host.dropLast(".bandcamp.com".count)) : host
            let slug = comps?.path.split(separator: "/").last.map(String.init) ?? ""
            func prettify(_ s: String) -> String {
                s.replacingOccurrences(of: "-", with: " ")
                 .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                 .joined(separator: " ")
            }
            self.title = slug.isEmpty ? url : prettify(slug)
            self.artist = sub.isEmpty ? "" : prettify(sub)
        }
    }

    /// Removed Bandcamp albums, sorted for display in the restore picker.
    static var hiddenBandcampAlbums: [HiddenAlbum] {
        hiddenBandcamp.map(HiddenAlbum.init(url:))
            .sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
    }

    /// Where downloaded music lives.
    nonisolated static let libraryFolder: URL = {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Vinyl", isDirectory: true)
    }()

    init() {
        // Demo: force the fresh-install state (no library, not connected) without touching real data.
        if ProcessInfo.processInfo.environment["YOIN_DEMO_EMPTY"] == "1" {
            identity = nil
            rebuildVisible()
            startNetworkMonitoring()
            return
        }
        // Restore the saved library (imported files + downloaded Bandcamp albums).
        let saved = Library.load()
        if !saved.isEmpty { albums = saved }
        rebuildVisible()   // seed the cache (didSet doesn't fire for the property initialiser)
        refreshCloudUploadedState()   // seed which imported albums are already on iCloud
        // If we already have a saved session, refresh the collection on launch.
        if identity != nil { Task { await syncBandcamp() } }
        // Refresh any smart playlists against the freshly-loaded library / history.
        Task { await rebuildSmartPlaylists() }
        startNetworkMonitoring()
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
        if event.isRealListen {
            if playCountMemo != nil, let id = album?.id { playCountMemo?[id, default: 0] += 1 }
            if playCountByKeyMemo != nil {
                let key = Self.albumKey(album?.title ?? event.albumTitle, album?.artist ?? event.artist)
                playCountByKeyMemo?[key, default: 0] += 1
            }
        }
    }

    // MARK: Real waveform for the now-playing track (local files only)

    /// Amplitude peaks (0…1) for the playing track when it's a local file we could analyse;
    /// nil while loading or for remote streams (the UI falls back to the placeholder bars).
    @Published var nowPlayingWaveform: [CGFloat]? = nil
    private var waveformTrackID: UUID?

    /// Compute (once) and publish the real waveform for `track`. Cheap to call repeatedly.
    func ensureWaveform(for track: Track?) {
        guard let track else { nowPlayingWaveform = nil; waveformTrackID = nil; return }
        guard waveformTrackID != track.id else { return }
        waveformTrackID = track.id
        nowPlayingWaveform = nil   // clear → placeholder bars until (and unless) real peaks arrive
        let url = track.streamURL
        guard url.isFileURL else { return }
        let forID = track.id
        Task {
            let peaks = await WaveformAnalyzer.peaks(url: url, bins: 100)
            guard self.waveformTrackID == forID else { return }   // track changed while analysing
            self.nowPlayingWaveform = peaks
        }
    }

    // MARK: Play counts (drive the vinyl "patina" / wear)

    private var playCountMemo: [UUID: Int]?
    private var playCountByKeyMemo: [String: Int]?

    static func albumKey(_ title: String, _ artist: String) -> String {
        "\(title.lowercased())\u{1}\(artist.lowercased())"
    }

    /// How many real listens an album has, memoised over the history log (rebuilt lazily).
    /// O(1) after the first call, so it's safe to read from the per-frame disc render.
    func playCount(forAlbum id: UUID) -> Int {
        if playCountMemo == nil { rebuildPlayCountMemo() }
        return playCountMemo?[id] ?? 0
    }

    /// Real listens for an album counted by title+artist, so duplicate album instances (e.g. the
    /// Bandcamp copy and an iPod-imported copy of the same record) all show the same total.
    func playCount(for album: Album) -> Int {
        if playCountByKeyMemo == nil { rebuildPlayCountMemo() }
        return playCountByKeyMemo?[Self.albumKey(album.title, album.artist)] ?? 0
    }

    private func rebuildPlayCountMemo() {
        // title+artist → albumID, so history events that lack an albumID (e.g. imported iPod plays
        // whose album wasn't matched at import time) still count toward the right album.
        var byKey: [String: UUID] = [:]
        for a in albums { byKey[Self.albumKey(a.title, a.artist)] = a.id }
        var m: [UUID: Int] = [:]
        var k: [String: Int] = [:]
        for e in HistoryStore.load() where e.isRealListen {
            let key = Self.albumKey(e.albumTitle, e.artist)
            k[key, default: 0] += 1
            let id = e.albumID ?? byKey[key]
            if let id { m[id, default: 0] += 1 }
        }
        playCountMemo = m
        playCountByKeyMemo = k
    }

    /// Drop the memos so the next read rebuilds them — used after a bulk history change (e.g.
    /// importing an iPod's play counts) that doesn't go through the incremental `recordPlay` path.
    func invalidatePlayCounts() { playCountMemo = nil; playCountByKeyMemo = nil; objectWillChange.send() }

    func flip(_ delta: Int) {
        let n = visibleAlbums.count
        guard n > 0 else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            front = (front + delta + n) % n
        }
    }

    /// Albums shown by the active filter, in the active sort order. Cached: recomputed only when
    /// `albums`/`filter`/`sort` change (via `rebuildVisible`), not on every read — it's read from
    /// view bodies, drag/scroll handlers and the ~5 Hz player bar, where re-filtering + re-sorting
    /// the whole library each time was a hot path.
    @Published private(set) var visibleAlbums: [Album] = []
    /// Per-filter album counts, cached alongside `visibleAlbums` for the filter chips/rows.
    @Published private(set) var filterCounts: [Filter: Int] = [:]
    /// O(1) album lookup by id, rebuilt with `visibleAlbums`. Replaces per-render/per-row
    /// `albums.first { $0.id == … }` scans in detail/list views.
    private(set) var albumIndex: [UUID: Album] = [:]
    /// The live album for `id` from the current library (nil if not owned).
    func album(id: UUID) -> Album? { albumIndex[id] }

    /// Recompute the cached `visibleAlbums` + `filterCounts`. Call after any change to
    /// `albums`, `filter`, or `sort`.
    func rebuildVisible() {
        let filtered: [Album]
        switch filter {
        case .all:        filtered = albums
        case .new:        filtered = albums.filter { isNewArrival($0) }
        case .favourites: filtered = albums.filter { $0.isFavourite }
        case .downloaded: filtered = albums.filter { $0.isDownloaded }
        case .bandcamp:   filtered = albums.filter { $0.source == .bandcamp }
        case .imported:   filtered = albums.filter { $0.source == .local }
        }
        visibleAlbums = sortedForDisplay(filtered)
        albumIndex = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var bc: [String: Album] = [:]
        for a in albums where a.source == .bandcamp {
            if let k = Self.normalizeBCURL(a.bandcampItemURL) { bc[k] = a }
        }
        bandcampURLIndex = bc
        rebuildOwners()   // depends on bandcampURLIndex above
        filterCounts = [
            .all: albums.count,
            .new: albums.lazy.filter { self.isNewArrival($0) }.count,
            .favourites: albums.lazy.filter { $0.isFavourite }.count,
            .downloaded: albums.lazy.filter { $0.isDownloaded }.count,
            .bandcamp: albums.lazy.filter { $0.source == .bandcamp }.count,
            .imported: albums.lazy.filter { $0.source == .local }.count,
        ]
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

    /// "New arrivals": bought within the last month and not yet listened to. Albums with no known
    /// purchase date (pre-tracking / old back-catalogue) are never new, so connecting an account
    /// with a big library doesn't flood the shelf.
    static let newArrivalWindow: TimeInterval = 30 * 24 * 3600
    func isNewArrival(_ a: Album) -> Bool {
        guard a.isPlayable, let d = a.dateAdded,
              Date().timeIntervalSince(d) <= Self.newArrivalWindow else { return false }
        return playCount(for: a) == 0
    }

    func count(for f: Filter) -> Int {
        if let c = filterCounts[f] { return c }
        switch f {
        case .all:        return albums.count
        case .new:        return albums.filter { isNewArrival($0) }.count
        case .favourites: return albums.filter { $0.isFavourite }.count
        case .downloaded: return albums.filter { $0.isDownloaded }.count
        case .bandcamp:   return albums.filter { $0.source == .bandcamp }.count
        case .imported:   return albums.filter { $0.source == .local }.count
        }
    }

    // Also resolves wishlist items (they aren't in `albums`) so Now Playing shows the right
    // cover/artist and can offer a buy nudge while previewing an unowned wishlist track.
    var nowPlayingAlbum: Album? {
        nowPlayingAlbumID.flatMap { albumIndex[$0] }
            ?? wishlist.first { $0.id == nowPlayingAlbumID }
            ?? (nowPlayingExternalAlbum?.id == nowPlayingAlbumID ? nowPlayingExternalAlbum : nil)
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
        // Convert on the main actor (the image is already decoded — cheap), then run the
        // per-pixel CIAreaAverage + palette analysis off-main so track changes don't stall the UI.
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            withAnimation(.easeInOut(duration: 0.6)) { ambient = nil; ambientPalette = [] }
            return
        }
        let box = CGImageBox(cg)
        let forID = nowPlayingAlbumID
        Task.detached(priority: .userInitiated) {
            let colour = AmbientColor.extract(from: box.image)
            let pal = AmbientColor.palette(from: box.image)
            await MainActor.run { [weak self] in
                guard let self, self.nowPlayingAlbumID == forID else { return }   // track changed meanwhile
                withAnimation(.easeInOut(duration: 0.6)) { self.ambient = colour; self.ambientPalette = pal }
            }
        }
    }
    var openedAlbum: Album? { albums.first { $0.id == openedAlbumID } }

    /// An album you don't own (a wishlist item / friend's pick), shown in a read-only detail page.
    @Published var openedExternalAlbum: Album?
    /// The pill under the title on that page, e.g. "In your wishlist" or "In Alice's library".
    @Published var openedExternalNote: String = "In your wishlist"

    /// Open the read-only detail page for an unowned album (wishlist / friend's pick).
    func openExternalAlbum(_ album: Album, note: String = "In your wishlist") {
        searchOpen = false
        openedArtist = nil
        openedAlbumID = nil
        friendsOpen = false
        openedFriend = nil
        openedExternalNote = note
        openedExternalAlbum = album
    }

    // MARK: Artist page (zero-scrape — everything is derived from albums you already have)

    /// Open the artist page for a display name, replacing any open album detail / friends drawer.
    func openArtist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        openedAlbumID = nil
        openedExternalAlbum = nil
        friendsOpen = false
        openedFriend = nil
        openedArtist = trimmed
    }

    /// Albums by an artist already in your library (case-insensitive name match).
    func libraryAlbums(byArtist name: String) -> [Album] {
        let key = Self.artistKey(name)
        return albums.filter { Self.artistKey($0.artist) == key }
    }

    /// Albums by an artist on your wishlist (case-insensitive name match).
    func wishlistAlbums(byArtist name: String) -> [Album] {
        let key = Self.artistKey(name)
        return wishlist.filter { Self.artistKey($0.artist) == key }
    }

    private static func artistKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

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

    private func issue(_ a: Album, _ reason: String, _ kind: LibraryIssue.Kind) -> LibraryIssue {
        LibraryIssue(id: a.id, title: a.title, artist: a.artist, reason: reason,
                     canRedownload: a.source == .bandcamp && a.bandcampDownloadURL != nil, kind: kind)
    }

    /// Check every album for a playable source and, for Bandcamp albums, whether their page still
    /// exists. Local/metadata problems are instant; every Bandcamp album with a public URL is
    /// probed so we can tell a *lost* album (removed and never downloaded) from an *archived* one
    /// (removed but saved offline) — the "dead album" detector.
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
                if a.url == nil && !a.hasLocalFiles { issues.append(issue(a, "No audio file", .noSource)) }
                else if localMissing { issues.append(issue(a, "Audio file missing on disk", .missingFile)) }
            } else {   // bandcamp
                if let url = a.bandcampItemURL {
                    probeTargets.append((a.id, url))   // probe every Bandcamp album for availability
                } else if !a.hasLocalFiles {
                    issues.append(issue(a, "No streamable source", .noSource))
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
            let results = await LibraryHealth.availability(probeTargets, identity: identity) { done in
                Task { @MainActor in
                    guard let self, self.healthScanToken == token else { return }
                    self.health = .scanning(done: done, total: total)
                }
            }
            await MainActor.run {
                guard let self, self.healthScanToken == token else { return }
                self.applyAvailability(results, snapshot: snapshot, baseIssues: baseIssues)
            }
        }
    }

    /// Fold the per-album availability probes into persisted state + the health-issue list.
    /// Only a confirmed `.removed` flags an album; `.unavailable`/`.needsAuth` leave it untouched
    /// so a network blip or expired session never wrongly reports an album as gone.
    private func applyAvailability(_ results: [UUID: BandcampClient.AlbumProbe],
                                   snapshot: [Album], baseIssues: [LibraryIssue]) {
        var all = baseIssues
        let now = Date()
        for a in snapshot {
            guard let probe = results[a.id],
                  let idx = albums.firstIndex(where: { $0.id == a.id }) else { continue }
            switch probe {
            case .alive:
                albums[idx].availability = .ok
                albums[idx].availabilityCheckedAt = now
            case .removed:
                albums[idx].availability = .removed
                albums[idx].availabilityCheckedAt = now
                if albums[idx].isDownloaded {
                    all.append(issue(a, "Removed from Bandcamp — saved offline, you're safe", .archived))
                } else if a.bandcampDownloadURL != nil {
                    all.append(issue(a, "Removed from Bandcamp — rescue it before the file link expires", .lost))
                } else {
                    all.append(issue(a, "Removed from Bandcamp — the stream is gone", .lost))
                }
            case .unavailable, .needsAuth:
                break   // couldn't verify — don't change availability, don't flag
            }
        }
        // Order the list so the urgent cases (lost, then archived) sit above disk problems.
        func rank(_ k: LibraryIssue.Kind) -> Int {
            switch k { case .lost: return 0; case .archived: return 1; case .missingFile: return 2; case .noSource: return 3 }
        }
        all.sort { rank($0.kind) < rank($1.kind) }
        health = .done(all)
        persist()
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

    /// Un-hide the chosen removed albums (by URL) and re-sync to bring just those back.
    func restoreRemovedBandcamp(urls: Set<String>) {
        guard !urls.isEmpty else { return }
        var hidden = Self.hiddenBandcamp
        hidden.subtract(urls)
        Self.hiddenBandcamp = hidden
        Task { await syncBandcamp() }
    }

    /// Start playing an album (resolves its tracks), remembering which album it is.
    func play(_ album: Album, on player: PlayerEngine) {
        stopRadio(on: player)
        nowPlayingAlbumID = album.id
        // Remember albums that live outside the owned library / wishlist (a friend's item),
        // so Now Playing keeps the right cover and can offer a buy link.
        let known = albums.contains { $0.id == album.id } || wishlist.contains { $0.id == album.id }
        nowPlayingExternalAlbum = known ? nil : album
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

    /// Start a station seeded from the music of one spot on the collection map. Only what you can
    /// actually play seeds it — owned albums directly, plus any wishlist/friend items whose Bandcamp
    /// page you *do* own — so the map's Wishlist/Friends layers can start a station too when there's
    /// overlap with your library.
    func startRadioForPlace(_ name: String, albums placeAlbums: [Album], on player: PlayerEngine) {
        var seen = Set<UUID>()
        let seeds = placeAlbums.compactMap { a -> Album? in
            let owned = a.isPlayable ? a : libraryAlbum(forBandcampURL: a.bandcampItemURL)
            guard let owned, owned.isPlayable, seen.insert(owned.id).inserted else { return nil }
            return owned
        }
        guard !seeds.isEmpty else { showNotice("No playable music from \(name)."); return }
        startRadio(seeds: Array(seeds.shuffled().prefix(6)), seed: .place(name), label: name, on: player)
    }

    /// Start a place station by name alone — looks up its located albums itself (used by the Radio
    /// pane's "by place" suggestions, which only carry the place string).
    func startRadioForPlace(named name: String, on player: PlayerEngine) {
        startRadioForPlace(name, albums: albumsLocated(at: name), on: player)
    }

    /// Cached result of `topRadioPlaces` — the Radio pane re-renders several times a second while a
    /// track plays, and grouping every album by origin each time is wasteful. Keyed by album count,
    /// the location cache's size, and the shuffle offset so it refreshes when any change and is
    /// steady otherwise.
    private var topPlacesCache: (albumCount: Int, locCount: Int, count: Int, shuffle: Int, places: [String])?
    /// "New places" advances this to slide the suggestions to a fresh window of your located places.
    @Published private var placeShuffle = 0

    /// Reshuffle the "By place" suggestions to a fresh set right now.
    func refreshPlaceMixes() { placeShuffle += 1; topPlacesCache = nil }

    /// Up to `count` places you own playable music from — the "by place" radio suggestions. Ranked by
    /// album count (ties broken by name for a stable order), then a `count`-wide window is slid by
    /// `placeShuffle` so "New places" rotates through everywhere you have music, not just the top few.
    /// Empty until artist origins have resolved (the map/backfill fills the location cache).
    func topRadioPlaces(count: Int = 4) -> [String] {
        let store = ArtistLocationStore.shared
        let locCount = store.map.count
        if let c = topPlacesCache, c.albumCount == albums.count, c.locCount == locCount,
           c.count == count, c.shuffle == placeShuffle {
            return c.places
        }
        var counts: [String: Int] = [:]
        for a in albums where a.isPlayable {
            guard let loc = store.location(forArtist: a.artist) else { continue }
            counts[loc, default: 0] += 1
        }
        let pool = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        let places: [String]
        if pool.count > count {
            let start = (placeShuffle * count) % pool.count
            places = (0..<count).map { pool[(start + $0) % pool.count] }
        } else {
            places = pool
        }
        topPlacesCache = (albums.count, locCount, count, placeShuffle, places)
        return places
    }

    /// True when there are more located places than the suggestion grid shows — i.e. "New places"
    /// has something fresh to rotate to (so the button can hide when it wouldn't do anything).
    func hasMorePlacesToShuffle(beyond count: Int = 4) -> Bool {
        let store = ArtistLocationStore.shared
        var seen = Set<String>()
        for a in albums where a.isPlayable {
            if let loc = store.location(forArtist: a.artist) { seen.insert(loc) }
            if seen.count > count { return true }
        }
        return false
    }

    /// Runs at most once per launch.
    private var genreBackfillDone = false
    /// Album URLs we've successfully scraped tags from (across launches), so they aren't
    /// re-fetched every launch. Persisted in UserDefaults. Only *successful* scrapes are
    /// recorded — a page that yielded no tags (transient failure, changed markup, or genuinely
    /// untagged) is retried on a later launch rather than being permanently locked out of moods.
    // v3: the pass now also scrapes artist locations for the map, so existing installs re-run it
    // once to backfill locations for pages that were previously visited for genres alone.
    private static let scrapedKey = "yoin.genreScrapedURLs.v3"

    /// Bandcamp albums arrive with no genre (so moods have nothing to match) and no artist
    /// location (so the collection map is empty). Both live on the album's public Bandcamp page,
    /// so one throttled pass fetches each page once and fills *both* — the genre from its tags and
    /// the artist's origin from its location line. Grabbing the location here means the map fills
    /// almost instantly instead of waiting on MusicBrainz's 1-request/second lookups. Remembers
    /// scraped pages so successful ones aren't re-fetched every launch, and updates live.
    func backfillGenresFromBandcamp() async {
        guard let identity, !genreBackfillDone else { return }
        var scraped = Set(UserDefaults.standard.stringArray(forKey: Self.scrapedKey) ?? [])
        let client = BandcampClient(identity: identity)
        let locStore = ArtistLocationStore.shared
        // Visit a page if it can still give us something we don't have — a genre or a location.
        let targets = albums.filter { a in
            guard a.source == .bandcamp, let u = a.bandcampItemURL, !scraped.contains(u) else { return false }
            let needsGenre = a.genre?.isEmpty ?? true
            let needsLocation = !locStore.resolved(a.artist)
            return needsGenre || needsLocation
        }
        // Nothing to do yet (e.g. before the first sync populates the collection) — leave the
        // flag unset so a later sync can kick this off.
        guard !targets.isEmpty else { return }
        genreBackfillDone = true
        let urls = targets.compactMap { $0.bandcampItemURL }
        var processed = 0
        for url in urls {
            let (tags, location) = (try? await client.tagsAndLocation(forItemURL: url)) ?? ([], nil)
            // A page that gave us neither tags nor a location was a failed/empty fetch — leave it
            // un-scraped so it's retried later rather than cached as "done" forever.
            if !tags.isEmpty || location != nil {
                scraped.insert(url)
                // Re-find by URL (stable across a re-sync, unlike the album id).
                if let i = albums.firstIndex(where: { $0.bandcampItemURL == url }) {
                    if !tags.isEmpty {
                        // Keep a handful of tags; they double as the genre string moods match on.
                        albums[i].genre = tags.prefix(8).joined(separator: ", ")
                    }
                    // Seed the artist's map location straight from Bandcamp (skips MusicBrainz).
                    if let location, !locStore.resolved(albums[i].artist) {
                        locStore.store(location, for: albums[i].artist)
                    }
                }
            }
            processed += 1
            if processed % 15 == 0 {
                persist()
                locStore.save()
                UserDefaults.standard.set(Array(scraped), forKey: Self.scrapedKey)
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        persist()
        locStore.save()
        UserDefaults.standard.set(Array(scraped), forKey: Self.scrapedKey)
    }

    private var locationBackfillDone = false

    /// Fills in each artist's place of origin (for the collection map) from MusicBrainz — a
    /// structured, documented API, no page scraping. Results are cached per artist in the
    /// persistent `ArtistLocationStore` (survives re-syncs and relaunches), so each artist is
    /// looked up at most once — ever — and the map never resets. Deduped per artist, rate-limited
    /// by `MBThrottle`. Runs at most once per launch.
    func backfillArtistLocations() async {
        guard !locationBackfillDone else { return }
        let store = ArtistLocationStore.shared
        // One lookup per distinct artist we haven't already resolved (hit or miss) in the cache.
        let artists = Set(albums.map { $0.artist.trimmingCharacters(in: .whitespaces) })
            .filter { !$0.isEmpty && !store.resolved($0) }
        guard !artists.isEmpty else { return }
        locationBackfillDone = true
        var processed = 0
        for artist in artists {
            let area = await MetadataService.artistArea(artist)
            store.store(area ?? "", for: artist)   // "" = looked up, none found
            processed += 1
            if processed % 10 == 0 { store.save() }
        }
        store.save()
    }

    /// Resolve artist origins for an arbitrary album list (a wishlist, a friend's collection) so
    /// the collection map can plot sources beyond the owned library. Skips artists already looked
    /// up (hit or miss) in the persistent cache, so it costs nothing for artists you already own.
    /// Rate-limited by `MBThrottle`; cancellation-safe so switching map source doesn't strand it.
    /// `onResolved` is called with each artist's non-empty location as soon as it's found, so a
    /// caller can geocode it right away and let map pins appear progressively instead of all at
    /// once after the whole (rate-limited) batch finishes.
    func resolveArtistLocations(for source: [Album], onResolved: (String) async -> Void = { _ in }) async {
        let store = ArtistLocationStore.shared
        let artists = Set(source.map { $0.artist.trimmingCharacters(in: .whitespaces) })
            .filter { !$0.isEmpty && !store.resolved($0) }
        guard !artists.isEmpty else { return }
        var processed = 0
        for artist in artists {
            if Task.isCancelled { break }
            let area = await MetadataService.artistArea(artist)
            store.store(area ?? "", for: artist)
            if let area, !area.isEmpty { await onResolved(area) }
            processed += 1
            if processed % 10 == 0 { store.save() }
        }
        store.save()
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
            // Auto-DJ: blend the station with beat-matched crossfades (unless DJ mode owns playback).
            player.autoDJ = RadioPrefs.autoDJ
            player.play(opening)
            showNotice("Radio: \(label)")
        }
    }

    func stopRadio(on player: PlayerEngine? = nil) {
        radioStarting = nil     // cancel any pending "starting…" spinner
        player?.autoDJ = false
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

    /// A representative library album for a saved-station seed, so its row/tile can show a cover.
    /// Prefers an album that actually has artwork. Nil for mood stations (not tied to one album).
    func radioCoverAlbum(for seed: RadioSeed) -> Album? {
        func withArt(_ list: [Album]) -> Album? { list.first { $0.artwork != nil || $0.artworkURL != nil } ?? list.first }
        switch seed {
        case .mood:
            return nil
        case .artist(let name):
            return withArt(libraryAlbums(byArtist: name))
        case .album(let title, let artist):
            let ak = Self.artistKey(artist), t = title.lowercased()
            return albums.first { Self.artistKey($0.artist) == ak && $0.title.lowercased() == t }
                ?? withArt(libraryAlbums(byArtist: artist))
        case .place(let name):
            return withArt(albumsLocated(at: name))
        }
    }

    /// Playable owned albums whose artist origin resolves to `name` — the seed pool behind a place
    /// station, rebuilt live so a saved station regenerates from the current library + geocache.
    private func albumsLocated(at name: String) -> [Album] {
        let store = ArtistLocationStore.shared
        return albums.filter { $0.isPlayable && store.location(forArtist: $0.artist) == name }
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
        case .place(let name):
            let here = albumsLocated(at: name)
            if here.isEmpty { showNotice("No music from \(name) in your library anymore.") }
            else { startRadioForPlace(name, albums: here, on: player) }
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

    /// Reorder by index — used by the manual drag-gesture reorder (remove-then-insert).
    func reorderPlaylistTrack(_ id: UUID, from: Int, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let count = playlists[i].tracks.count
        guard from >= 0, from < count, to >= 0, to < count, from != to else { return }
        let item = playlists[i].tracks.remove(at: from)
        playlists[i].tracks.insert(item, at: to)
        persistPlaylists()
    }

    /// Remove a single track (by id) from a playlist — used by the row's hover delete button.
    func removeTrackFromPlaylist(_ id: UUID, trackID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }),
              let t = playlists[i].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        playlists[i].tracks.remove(at: t)
        persistPlaylists()
    }

    // MARK: Quick-create playlist (right-click → New playlist…)

    /// Open the quick-create overlay seeded with an album's tracks. Presented on the NEXT runloop
    /// tick so the click that chose "New playlist…" fully drains first — otherwise that same click
    /// falls through onto the just-mounted overlay and fires its default (Create) action.
    func beginPlaylistDraft(album: Album) {
        let draft = PlaylistDraft(source: .album(album), suggestedName: album.title)
        DispatchQueue.main.async { self.playlistDraft = draft }
    }
    /// Open the quick-create overlay seeded with a single track. Deferred for the same reason.
    func beginPlaylistDraft(track: Track) {
        let draft = PlaylistDraft(source: .track(track), suggestedName: track.title)
        DispatchQueue.main.async { self.playlistDraft = draft }
    }
    func cancelPlaylistDraft() { playlistDraft = nil }

    /// Create the playlist with the typed name and add the seeded item — without leaving the
    /// current screen (the quick, in-place path). Falls back to "New Playlist" for a blank name.
    func commitPlaylistDraft(name: String) {
        guard let draft = playlistDraft else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let pl = createPlaylist(named: trimmed.isEmpty ? "New Playlist" : trimmed)
        switch draft.source {
        case .album(let album): addAlbum(album, toPlaylist: pl.id)
        case .track(let track): addTrack(track, toPlaylist: pl.id)
        }
        playlistDraft = nil
        showNotice("Created “\(pl.name)”")
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
        stopRadio(on: player)
        Task {
            let tracks = await resolvePlaylistTracks(playlist)
            guard !tracks.isEmpty else { showNotice("Couldn't load “\(playlist.name)”."); return }
            nowPlayingAlbumID = nil    // playlist context — per-track album lives on each Track
            player.play(tracks, startAt: min(max(0, index), tracks.count - 1))
        }
    }

    // MARK: - Recap mix (soundtrack the year-in-review) + save-as-playlist

    /// One representative track per top album of the year — the track you played most on it,
    /// falling back to the opener. Ranked by the album's plays. `limit` caps how many albums
    /// we resolve (each may be a network fetch).
    private func recapTopTracks(_ recap: Recap, limit: Int) async -> [(album: Album, track: Track, index: Int)] {
        func nt(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        // Most-played track title per album, for this year.
        let hist = HistoryStore.load().filter {
            Calendar.current.component(.year, from: $0.date) == recap.year && $0.isRealListen
        }
        var perAlbum: [String: [String: Int]] = [:]
        for e in hist { perAlbum[nt(e.albumTitle), default: [:]][e.trackTitle, default: 0] += 1 }

        var out: [(Album, Track, Int)] = []
        for item in recap.items.prefix(limit) {
            guard let id = item.albumID, let album = albums.first(where: { $0.id == id }) else { continue }
            let tracks = await resolveTracks(for: album)
            guard !tracks.isEmpty else { continue }
            let wanted = perAlbum[nt(item.title)]?.max { $0.value < $1.value }?.key
            let idx = wanted.flatMap { w in tracks.firstIndex { nt($0.title) == nt(w) } } ?? 0
            out.append((album, tracks[idx], idx))
        }
        return out
    }

    /// Play a mix of the year's most-listened tracks — the recap's soundtrack.
    func playRecapMix(_ recap: Recap, on player: PlayerEngine, completion: @escaping () -> Void = {}) {
        Task {
            let picks = await recapTopTracks(recap, limit: 20)
            let queue = picks.map(\.track)
            guard !queue.isEmpty else { completion(); return }
            stopRadio(on: player)
            nowPlayingAlbumID = nil          // mix context — album lives on each Track
            player.play(queue)
            completion()
        }
    }

    /// Save the year's most-listened tracks as an ordinary, editable playlist.
    func saveRecapPlaylist(_ recap: Recap) {
        Task {
            let picks = await recapTopTracks(recap, limit: 30)
            guard !picks.isEmpty else { showNotice("Couldn't build the \(String(recap.year)) playlist."); return }
            let tracks = picks.map { p in
                PlaylistTrack(albumID: p.album.id, albumTitle: p.album.title, artist: p.album.artist,
                              title: p.track.title, trackIndex: p.index,
                              artworkURL: p.album.artworkURL, artworkData: p.album.artworkData,
                              g0: p.album.g0, g1: p.album.g1)
            }
            var name = "\(String(recap.year)) Recap", n = 2
            while playlists.contains(where: { $0.name == name }) { name = "\(String(recap.year)) Recap \(n)"; n += 1 }
            playlists.insert(Playlist(name: name, tracks: tracks), at: 0)
            persistPlaylists()
            showNotice("Saved “\(name)” · \(tracks.count) track\(tracks.count == 1 ? "" : "s")")
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
            // The library's Bandcamp URLs *before* this sync — anything not in here is new this round.
            let previousURLs = Set(existingByURL.keys)

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
                    // Keep the SAME id across a re-sync — anything tracking an album by id (the open
                    // album page, now-playing, selection) would otherwise be dropped when a launch
                    // sync swaps in fresh objects (that's the "open an album → it rolls back" bug).
                    a.id = prev.id
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
                    // Prefer the real Bandcamp purchase date (self-heals older entries that only had
                    // a first-seen date); else keep whatever we had.
                    a.dateAdded = item.purchased ?? prev.dateAdded
                } else {
                    a.dateAdded = item.purchased ?? Date()   // real purchase date, else first-seen now
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
            celebrateNewArrivals(in: bandcampAlbums, previousURLs: previousURLs)
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

    /// After a sync, auto-open the new-album unboxing for any just-bought, unheard records that
    /// appeared for the first time this round and haven't been celebrated yet. The very first time
    /// this runs it seeds the "seen" set silently, so installing/updating the app doesn't unbox a
    /// backlog of already-owned recent purchases.
    private func celebrateNewArrivals(in synced: [Album], previousURLs: Set<String>) {
        var celebrated = Self.celebratedAlbums

        // First sync ever: seed *every* current new-arrival as already-seen, so a fresh install with a
        // backlog of recent purchases (or an existing library updating to this feature) doesn't unbox
        // everything at once. From here on, only genuinely-new future buys fire.
        if !UserDefaults.standard.bool(forKey: Self.unboxInitKey) {
            for a in synced where isNewArrival(a) { celebrated.insert(a.dedupeKey) }
            Self.celebratedAlbums = celebrated
            UserDefaults.standard.set(true, forKey: Self.unboxInitKey)
            return
        }

        // New to the library this sync AND reading as a fresh, unheard purchase we haven't celebrated.
        let fresh = synced.filter { a in
            guard let url = a.bandcampItemURL, !previousURLs.contains(url) else { return false }
            return isNewArrival(a) && !celebrated.contains(a.dedupeKey)
        }
        guard !fresh.isEmpty else { return }
        fresh.forEach { celebrated.insert($0.dedupeKey) }
        Self.celebratedAlbums = celebrated

        unboxAlbums = fresh
        withAnimation(.easeInOut(duration: 0.35)) { showNewAlbumReveal = true }
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
            // A cancelled request (view torn down, or this load superseded by a newer one) isn't a
            // real error — don't show it. Drop back to idle so the next appearance reloads.
            if Self.isCancellation(error) { if case .loading = wishlistLoad { wishlistLoad = .idle }; return }
            let msg = (error as? BandcampError)?.errorDescription ?? error.localizedDescription
            wishlistLoad = .failed(msg)
            if case BandcampError.notAuthenticated = error { disconnect() }
        }
    }

    /// True for a cancelled network request or a cancelled Task — i.e. the work was torn down or
    /// superseded, not a genuine failure the user should see.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - Friends (Bandcamp fans this account follows)

    /// Whether the friends browser overlay is showing.
    @Published var friendsOpen = false
    /// The friend whose collection is currently open (nil = show the friends list).
    @Published var openedFriend: Friend? = nil

    @Published var friends: [Friend] = []
    enum FriendsLoad: Equatable { case idle, loading, loaded, failed(String) }
    @Published var friendsLoad: FriendsLoad = .idle

    // MARK: "What's new since you last looked"
    /// Newest collection item keys per friend (Bandcamp item URLs), from the ownership scan + opens.
    @Published var friendRecent: [Int: Set<String>] = [:]
    /// Keys already looked at per friend — never expires. Drives the "new" dot and per-album tag.
    @Published var friendSeen: [Int: Set<String>] = [:]
    private var friendsCacheLoaded = false
    private var friendsCacheDate: Date?
    private var friendCollRefreshed: Set<Int> = []   // page-1 re-fetched this session (collection)
    private var friendWishRefreshed: Set<Int> = []   // page-1 re-fetched this session (wishlist)

    /// The key a friend-collection album is tracked by (its Bandcamp URL). URL-less items opt out.
    static func friendItemKey(_ album: Album) -> String? { album.bandcampItemURL }

    /// New (unseen) collection keys for a friend — empty until we have a prior baseline for them.
    func friendNewKeys(_ id: Int) -> Set<String> {
        guard let seen = friendSeen[id] else { return [] }   // no baseline yet → nothing is "new"
        return (friendRecent[id] ?? []).subtracting(seen)
    }
    func friendHasNew(_ id: Int) -> Bool { !friendNewKeys(id).isEmpty }
    func albumIsNew(_ album: Album, friendID: Int) -> Bool {
        guard let key = Self.friendItemKey(album) else { return false }
        return friendNewKeys(friendID).contains(key)
    }

    /// Record a friend's newest keys, establishing a silent baseline the first time we see them.
    private func noteFriendRecent(_ id: Int, _ keys: Set<String>, persist: Bool = true) {
        guard !keys.isEmpty else { return }
        friendRecent[id] = keys
        if friendSeen[id] == nil { friendSeen[id] = keys }   // baseline — nothing flagged new first time
        if persist { saveFriendsCache() }
    }

    /// Mark everything currently known for a friend as seen (called when you leave their page).
    func markFriendSeen(_ id: Int) {
        guard let recent = friendRecent[id], friendSeen[id] != recent else { return }
        friendSeen[id] = recent
        saveFriendsCache()
    }

    /// Populate the drawer from disk once, so it opens instantly. Kicks a background refresh if stale.
    func loadFriendsCacheIfNeeded() {
        guard !friendsCacheLoaded else { return }
        friendsCacheLoaded = true
        guard let snap = FriendsCache.load() else { return }
        friendsCacheDate = snap.date
        if !snap.friends.isEmpty, friends.isEmpty { friends = snap.friends; friendsLoad = .loaded }
        func hydrate(_ albums: [Album]) -> FriendItems {
            var s = FriendItems()
            s.albums = albums; s.started = true
            s.seen = Set(albums.compactMap { $0.bandcampItemURL })
            return s
        }
        for (id, albums) in snap.coll where friendColl[id] == nil { friendColl[id] = hydrate(albums) }
        for (id, albums) in snap.wish where friendWish[id] == nil { friendWish[id] = hydrate(albums) }
        friendRecent = snap.recent.mapValues(Set.init)
        friendSeen = snap.seen.mapValues(Set.init)
    }

    private func saveFriendsCache() {
        let cap = 40
        let coll = friendColl.compactMapValues { $0.albums.isEmpty ? nil : Array($0.albums.prefix(cap)) }
        let wish = friendWish.compactMapValues { $0.albums.isEmpty ? nil : Array($0.albums.prefix(cap)) }
        FriendsCache.save(.init(date: friendsCacheDate ?? Date(), friends: friends,
                                coll: coll, wish: wish,
                                recent: friendRecent.mapValues(Array.init),
                                seen: friendSeen.mapValues(Array.init)))
    }

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

    /// Open the friends browser (showing the cached list instantly, then refreshing).
    func openFriends() {
        friendsOpen = true
        openedFriend = nil
        loadFriendsCacheIfNeeded()
        Task { await syncFriends() }
    }

    /// Fetch the list of fans this account follows. Shows the disk cache first; only hits the
    /// network when the cache is missing, empty, or older than the TTL (or forced).
    func syncFriends(force: Bool = false) async {
        guard let identity else { friendsLoad = .failed("Connect your Bandcamp account to see your friends."); return }
        loadFriendsCacheIfNeeded()
        if case .loading = friendsLoad { return }
        let stale = friendsCacheDate.map { Date().timeIntervalSince($0) > FriendsCache.ttl } ?? true
        if !force, !stale, case .loaded = friendsLoad, !friends.isEmpty { return }
        friendsLoad = .loading
        do {
            friends = try await BandcampClient(identity: identity).followingFans()
            friendsLoad = .loaded
            friendsCacheDate = Date()
            saveFriendsCache()
        } catch {
            if Self.isCancellation(error) { if case .loading = friendsLoad { friendsLoad = .idle }; return }
            // A cached list is better than an error — keep showing it if we have one.
            if !friends.isEmpty { friendsLoad = .loaded; return }
            friendsLoad = .failed((error as? BandcampError)?.errorDescription ?? error.localizedDescription)
            if case BandcampError.notAuthenticated = error { disconnect() }
        }
    }

    /// Open a friend and load the first page of their collection.
    func openFriend(_ friend: Friend) {
        if let prev = openedFriend, prev.id != friend.id { markFriendSeen(prev.id) }
        openedFriend = friend
        Task { await startFriendList(friend, wishlist: false) }
    }

    /// First page of a friend's list. Shows the cache instantly, then refreshes page 1 once per
    /// session so the newest additions (and the "new" tags) are current.
    func startFriendList(_ friend: Friend, wishlist: Bool) async {
        if friendItems(friend.id, wishlist: wishlist).started {
            let refreshed = wishlist ? friendWishRefreshed.contains(friend.id) : friendCollRefreshed.contains(friend.id)
            if !refreshed { await refreshFriendFirstPage(friend, wishlist: wishlist) }
            return
        }
        await loadMoreFriend(friend, wishlist: wishlist)
    }

    /// Re-fetch a friend's first (newest) page and replace it, fixing the paging cursor and
    /// surfacing anything added since the cache was written.
    private func refreshFriendFirstPage(_ friend: Friend, wishlist: Bool) async {
        guard let identity else { return }
        if wishlist { friendWishRefreshed.insert(friend.id) } else { friendCollRefreshed.insert(friend.id) }
        do {
            let client = BandcampClient(identity: identity)
            let page = wishlist
                ? try await client.wishlistPage(fanID: friend.id, olderThan: nil, count: 20)
                : try await client.collectionPage(fanID: friend.id, olderThan: nil, count: 20)
            var t = friendItems(friend.id, wishlist: wishlist)
            var albums: [Album] = []
            var seen: Set<String> = []
            for item in page.items {
                let key = item.itemURL ?? "id:\(item.id)"
                if seen.insert(key).inserted { albums.append(Self.friendAlbum(from: item)) }
            }
            // Keep any older pages the user had already loaded beyond this first page.
            let extra = t.albums.filter { a in !seen.contains(a.bandcampItemURL ?? "") }
            t.albums = albums + extra
            t.next = page.next
            t.reachedEnd = (page.next == nil) && extra.isEmpty
            t.started = true
            store(t, friend.id, wishlist)
            if !wishlist { noteFriendRecent(friend.id, Set(page.items.compactMap { $0.itemURL })) }
        } catch { /* keep the cached page on a failed refresh */ }
    }

    /// Fetch the next 20 items of a friend's collection (or wishlist), appending to what's shown.
    func loadMoreFriend(_ friend: Friend, wishlist: Bool) async {
        guard let identity else { return }
        var s = friendItems(friend.id, wishlist: wishlist)
        if s.loading || s.reachedEnd { return }
        let isFirstPage = s.next == nil && s.albums.isEmpty
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
            if isFirstPage, !wishlist { noteFriendRecent(friend.id, Set(page.items.compactMap { $0.itemURL })) }
            else { saveFriendsCache() }
        } catch {
            var t = friendItems(friend.id, wishlist: wishlist)
            t.loading = false
            // Cancellation (superseded page load / view torn down) isn't a failure to surface —
            // reopen `started` so the next appearance refetches this page instead of showing a
            // spurious error or a false "nothing here".
            if Self.isCancellation(error) {
                if t.albums.isEmpty { t.started = false }
            } else {
                t.failed = (error as? BandcampError)?.errorDescription ?? error.localizedDescription
            }
            store(t, friend.id, wishlist)
            if case BandcampError.notAuthenticated = error { disconnect() }
        }
    }

    // MARK: - "People you follow own this" (the macaron)

    /// Which followed friends own each album, keyed by normalized Bandcamp item URL.
    @Published var friendOwners: [String: [Friend]] = [:] { didSet { rebuildOwners() } }
    /// Per-album owner list keyed by album id — precomputed from `friendOwners` so the grid's
    /// `owners(of:)` is an O(1) dictionary hit instead of normalizing a URL string per visible cell
    /// on every AppState publish. Rebuilt when `friendOwners` or the library changes.
    @Published private(set) var ownersByAlbumID: [UUID: [Friend]] = [:]
    /// Loaded the on-disk ownership snapshot yet this session? (loads once, for instant badges)
    private var ownershipCacheLoaded = false
    /// Your Bandcamp albums keyed by normalized item URL, for O(1) "do I own this?" lookups when
    /// browsing a friend's collection. Rebuilt with the library (see `rebuildVisible`).
    private(set) var bandcampURLIndex: [String: Album] = [:]
    enum OwnershipLoad: Equatable { case idle, loading, loaded }
    @Published var ownershipLoad: OwnershipLoad = .idle

    /// The user's own library album matching a Bandcamp item URL, if they own it — used to show
    /// an "owned" badge and a "Go to album" jump when browsing a friend's collection.
    func libraryAlbum(forBandcampURL url: String?) -> Album? {
        guard let key = Self.normalizeBCURL(url) else { return nil }
        return bandcampURLIndex[key]   // O(1); was an O(n) scan + per-element normalize, per row
    }

    /// Close the friends drawer and open an owned album's detail page.
    func goToLibraryAlbum(_ id: UUID) {
        friendsOpen = false
        openedFriend = nil
        openedAlbumID = id
    }

    /// Followed friends who own this album (empty when unknown / not built yet). O(1) — reads the
    /// precomputed `ownersByAlbumID` rather than normalizing the URL per call (this runs per grid cell).
    func owners(of album: Album) -> [Friend] {
        ownersByAlbumID[album.id] ?? []
    }

    /// Followed friends who own the album at this Bandcamp URL — for items outside your library
    /// (wishlist / a friend's pick), where the id-keyed `owners(of:)` has nothing to match.
    func owners(forBandcampURL url: String?) -> [Friend] {
        guard let key = Self.normalizeBCURL(url) else { return [] }
        return friendOwners[key] ?? []
    }

    /// Rebuild the id-keyed owner map from `friendOwners` (reusing the normalized-URL → album index).
    func rebuildOwners() {
        guard !friendOwners.isEmpty else {
            if !ownersByAlbumID.isEmpty { ownersByAlbumID = [:] }
            return
        }
        var map: [UUID: [Friend]] = [:]
        for (key, album) in bandcampURLIndex {
            if let owners = friendOwners[key], !owners.isEmpty { map[album.id] = owners }
        }
        ownersByAlbumID = map
    }

    /// Build the ownership index: for each followed friend, fetch their collection and record
    /// which of *your* albums they also own. Runs once per session (in the background) — it's
    /// the one friends feature with real cost (one collection fetch per friend), so it's throttled
    /// to a few concurrent requests and only matches URLs already in your library.
    func buildFriendOwnership(force: Bool = false) async {
        guard let identity else { return }
        loadFriendsCacheIfNeeded()   // populate the list, recency & seen-marks from disk at launch
        // Show cached badges instantly (once per session), and skip the network rebuild while the
        // snapshot is still fresh — the scan is the friends feature's one heavy op. An EMPTY cache
        // never blocks a rebuild (a failed earlier scan shouldn't stick for the whole TTL).
        if !ownershipCacheLoaded {
            ownershipCacheLoaded = true
            if let cached = FriendOwnersCache.load() {
                friendOwners = cached.index
                if !force, !cached.index.isEmpty, Date().timeIntervalSince(cached.date) < FriendOwnersCache.ttl {
                    ownershipLoad = .loaded; return
                }
            }
        }
        if case .loading = ownershipLoad { return }
        if !force, case .loaded = ownershipLoad { return }
        // Claim the slot *before* the first await, else two concurrent view .task callers both
        // pass the guard above and each run the full per-friend collection scan (the heaviest
        // network op in the friends feature).
        ownershipLoad = .loading
        await syncFriends()
        // If the caller's view went away mid-build (quick navigation on launch cancels the .task),
        // don't cache this partial/empty result as "loaded" — reset so a later visit rebuilds it.
        guard !Task.isCancelled else { ownershipLoad = .idle; return }
        guard !friends.isEmpty else { ownershipLoad = .loaded; return }

        // Match a friend's collection item to one of your albums by its Bandcamp URL, else by
        // title+artist (Bandcamp URLs often differ — subdomain vs custom domain, editions — so a
        // URL-only match misses records a friend clearly owns). Both map to the SAME key the
        // `owners(of:)` lookup uses: your album's normalized URL.
        let bc = albums.filter { $0.source == .bandcamp }
        let mineByURL = Set(bc.compactMap { Self.normalizeBCURL($0.bandcampItemURL) })
        let mineByTA = Dictionary(
            bc.compactMap { a in Self.normalizeBCURL(a.bandcampItemURL).map { (Self.taKey(a.title, a.artist), $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard !mineByURL.isEmpty else { ownershipLoad = .loaded; return }

        // Page every friend BREADTH-FIRST (page 1 of each, then page 2 of those with more, …) with
        // gentle pacing. Friends with small collections finish in the first round, so their badges
        // reveal first; big collectors (hundreds of albums) fill in over later rounds without
        // hanging the whole scan or getting rate-limited (which killed the old concurrent version).
        let client = BandcampClient(identity: identity)
        var index: [String: [Friend]] = [:]
        var tokens: [Int: String?] = [:]           // per-friend paging cursor (nil = first page)
        var done: Set<Int> = []
        func match(_ item: BCItem, _ f: Friend) {
            let key: String? = {
                if let u = Self.normalizeBCURL(item.itemURL), mineByURL.contains(u) { return u }
                return mineByTA[Self.taKey(item.title, item.artist)]
            }()
            if let key, !(index[key]?.contains { $0.id == f.id } ?? false) { index[key, default: []].append(f) }
        }

        for _ in 0..<15 {                          // up to 15 rounds → ≤ ~750 items per friend
            var progressed = false
            for f in friends where !done.contains(f.id) {
                progressed = true
                var page = try? await client.collectionPage(fanID: f.id, olderThan: tokens[f.id] ?? nil, count: 50)
                if page == nil {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    page = try? await client.collectionPage(fanID: f.id, olderThan: tokens[f.id] ?? nil, count: 50)
                }
                let firstPage = (tokens[f.id] ?? nil) == nil
                guard let page else { done.insert(f.id); continue }
                for item in page.items { match(item, f) }
                friendOwners = index               // progressive reveal after each page
                // Their newest page drives the "new since you last looked" dot in the list.
                if firstPage { noteFriendRecent(f.id, Set(page.items.compactMap { $0.itemURL }), persist: false) }
                if page.next == nil { done.insert(f.id) } else { tokens[f.id] = page.next }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            if !progressed { break }               // everyone reached the end
        }

        friendOwners = index
        ownershipLoad = .loaded
        FriendOwnersCache.save(index)              // persist for instant badges next launch
        saveFriendsCache()                         // persist refreshed recency/list in one write
    }

    /// A title+artist key for matching an album across sources when URLs differ.
    nonisolated static func taKey(_ title: String, _ artist: String) -> String {
        "\(title.lowercased())\u{1}\(artist.lowercased())"
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
                Track(title: FilenameCleaner.trackTitle(fileURL.deletingPathExtension().lastPathComponent,
                                                        artist: album.artist, album: album.title),
                      artist: album.artist, streamURL: fileURL,
                      artworkURL: album.artworkURL, albumID: album.id, trackIndex: i, g0: album.g0, g1: album.g1)
            }
        }
        if let url = album.url {
            return [Track(title: album.title, artist: album.artist, streamURL: url,
                          artworkData: album.artworkData, albumID: album.id, trackIndex: 0, g0: album.g0, g1: album.g1)]
        }
        if album.source == .bandcamp, let identity, let itemURL = album.bandcampItemURL {
            // Reuse recently-cached stream URLs while they're still valid — no re-scrape.
            if let cached = TracklistCache.shared.freshTracks(for: album) { return cached }
            do {
                var tracks = try await BandcampClient(identity: identity).tracks(forItemURL: itemURL)
                for i in tracks.indices { tracks[i].albumID = album.id; tracks[i].trackIndex = i }
                TracklistCache.shared.store(tracks, forItemURL: itemURL)
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

    // MARK: - Tempo (BPM) analysis

    let bpmProgress = BPMProgress()
    private var bpmCancel = false

    /// Tracks in the library with a known (stored) BPM.
    var bpmKnownCount: Int { BPMStore.shared.total }

    /// Analyse tempo for every track — local files *and* Bandcamp streams (each stream is
    /// downloaded to a temp file, analysed, then discarded, so this uses real bandwidth and can
    /// take a while). Skips already-analysed tracks; safe to re-run. Persists incrementally.
    func analyzeLibraryBPM() {
        guard !bpmProgress.running else { return }
        bpmCancel = false
        let targets = albums
        bpmProgress.running = true
        bpmProgress.done = 0
        bpmProgress.total = targets.count
        bpmProgress.analyzed = BPMStore.shared.total
        Task { await runBPMAnalysis(targets) }
    }

    func stopBPMAnalysis() { bpmCancel = true }

    private func runBPMAnalysis(_ targets: [Album]) async {
        let batchSize = 3   // bound the download/analysis fan-out
        for start in stride(from: 0, to: targets.count, by: batchSize) {
            if bpmCancel { break }
            let batch = Array(targets[start..<min(start + batchSize, targets.count)])
            await withTaskGroup(of: Void.self) { group in
                for album in batch { group.addTask { await self.analyzeAlbumBPM(album) } }
            }
            bpmProgress.done = min(start + batch.count, targets.count)
            bpmProgress.analyzed = BPMStore.shared.total
            BPMStore.shared.save()
        }
        BPMStore.shared.save()
        bpmProgress.analyzed = BPMStore.shared.total
        bpmProgress.running = false
        if !bpmCancel { showNotice("Tempo analysis complete — \(BPMStore.shared.total) tracks.") }
        // Refresh any tempo smart-shelves now that more BPMs are known.
        Task { await rebuildSmartPlaylists() }
    }

    private func analyzeAlbumBPM(_ album: Album) async {
        let tracks = await resolveTracks(for: album)
        for (i, t) in tracks.enumerated() {
            if bpmCancel { return }
            if BPMStore.shared.bpm(album: album, index: i) != nil { continue }
            if let bpm = await TempoAnalyzer.detectBPM(localOrRemote: t.streamURL) {
                BPMStore.shared.set(bpm, album: album, index: i)
            }
        }
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

    /// Download a trip-sized selection of albums (most-listened + recently-played + a few
    /// never-heard picks, see `tripPrepCandidates`), one at a time, reporting progress via
    /// `tripPrep`. Call from the "Prep for trip" button.
    func prepForTrip(count: Int) {
        guard tripPrep == nil else { return }
        let picks = tripPrepCandidates(count: count)
        guard !picks.isEmpty else {
            showNotice("Everything's already downloaded — you're trip-ready.")
            return
        }
        tripPrep = TripPrepState(done: 0, total: picks.count)
        Task {
            for a in picks {
                await downloadOne(a)
                if var st = tripPrep { st.done += 1; tripPrep = st }
            }
            let n = picks.count
            tripPrep = nil
            showNotice("Trip-ready — \(n) album\(n == 1 ? "" : "s") saved offline.")
        }
    }

    // MARK: Trip prep — manage the offline batch

    /// Bandcamp albums currently saved offline — the "trip" library.
    var offlineAlbums: [Album] { albums.filter { $0.isDownloaded } }

    /// Estimated on-disk size of everything downloaded offline.
    func offlineBytes() -> Int64 { offlineAlbums.reduce(0) { $0 + estimatedSizeBytes($1) } }

    /// Re-download the albums already saved offline — refreshes their FLAC files (e.g. after a
    /// re-master) and repairs any partial downloads. Reports progress via `tripPrep`.
    func refreshOfflineAlbums() {
        guard tripPrep == nil else { return }
        let targets = offlineAlbums.filter { $0.bandcampDownloadURL != nil }
        guard !targets.isEmpty else { return }
        tripPrep = TripPrepState(done: 0, total: targets.count)
        Task {
            for a in targets {
                await downloadOne(a)
                if var st = tripPrep { st.done += 1; tripPrep = st }
            }
            let n = targets.count
            tripPrep = nil
            showNotice("Refreshed \(n) offline album\(n == 1 ? "" : "s").")
        }
    }

    /// Delete every offline download — removes the local FLAC files and frees the space. Each
    /// Bandcamp download lives in its own folder under the library, so the folder goes wholesale.
    func deleteOfflineAlbums() {
        let targets = offlineAlbums
        guard !targets.isEmpty else { return }
        let fm = FileManager.default
        for a in targets {
            if let first = a.localTracks?.first {
                try? fm.removeItem(at: first.deletingLastPathComponent())
            }
            if let i = albums.firstIndex(where: { $0.id == a.id }) {
                albums[i].localTracks = nil
                albums[i].format = "FLAC"
            }
            downloads[a.id] = nil
        }
        persist()
        let n = targets.count
        showNotice("Deleted \(n) offline download\(n == 1 ? "" : "s") — space reclaimed.")
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
            await cacheArtworkData(for: album.id)   // so the cover shows offline too
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
            throw http.statusCode == 429 ? BandcampError.rateLimited : BandcampError.badResponse(http.statusCode)
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

    // MARK: - Cloud sync (imported → iOS)

    /// Backfill every eligible imported album — used by "Send all".
    @MainActor
    func cloudBackfill() {
        let snapshot = albums
        Task.detached { await CloudUploader.shared.uploadAll(snapshot) }
    }

    // MARK: Per-album send picker

    /// Whether the "Send to iPhone" picker sheet is open.
    @Published var cloudSendOpen = false
    /// Imported albums that have been sent to iCloud (drives per-album state in the picker).
    @Published var cloudUploadedIDs: Set<UUID> = []
    /// Imported albums currently uploading (drives per-row progress).
    @Published var cloudUploadingIDs: Set<UUID> = []

    /// Seed `cloudUploadedIDs` from what's already on record. Call at launch.
    @MainActor
    func refreshCloudUploadedState() {
        cloudUploadedIDs = Set(albums.filter { CloudUploader.isUploaded($0.id) }.map { $0.id })
    }

    /// Imported (local) albums eligible to send.
    var sendableAlbums: [Album] { albums.filter { CloudSync.isSyncable($0) } }

    /// Send one imported album to iCloud (user-chosen). Progress + notice.
    @MainActor
    func cloudSend(_ album: Album) {
        guard CloudUploader.isEnabled, !cloudUploadingIDs.contains(album.id) else { return }
        cloudUploadingIDs.insert(album.id)
        Task { @MainActor in
            await CloudUploader.shared.upload(album)
            self.cloudUploadingIDs.remove(album.id)
            if CloudUploader.isUploaded(album.id) {
                self.cloudUploadedIDs.insert(album.id)
                self.showNotice("Sent “\(album.title)” to iPhone")
            } else {
                self.showNotice("Couldn't send “\(album.title)”.")
            }
        }
    }

    /// Remove one album from iCloud (un-send).
    @MainActor
    func cloudUnsend(_ id: UUID) {
        Task { @MainActor in
            await CloudUploader.shared.delete(id: id)
            self.cloudUploadedIDs.remove(id)
        }
    }

    /// Send every imported album not yet on iCloud.
    @MainActor
    func cloudSendAll() { for a in sendableAlbums where !cloudUploadedIDs.contains(a.id) { cloudSend(a) } }

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
