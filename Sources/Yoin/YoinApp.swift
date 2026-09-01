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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(player)
                .environmentObject(updater)
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
                    }
                    // Show the "What's New" card once on the first launch after an update.
                    if WhatsNew.shouldAutoShow() { state.showWhatsNew = true }
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
    enum Screen: Hashable { case crate, grid, artists, playlists, recap, settings }
    enum Filter: Hashable { case all, favourites, downloaded, bandcamp, imported }

    @Published var screen: Screen = .crate
    @Published var filter: Filter = .all { didSet { front = 0 } }
    @Published var nowPlayingAlbumID: UUID?
    @Published var openedAlbumID: UUID?
    @Published var searchOpen = false
    @Published var front = 0

    // Playlists
    @Published var playlists: [Playlist] = PlaylistStore.load()
    /// Which playlist the Playlists screen is showing in its detail pane.
    @Published var selectedPlaylistID: UUID?
    /// A freshly-created playlist whose name should open in inline-rename mode.
    @Published var renamingPlaylistID: UUID?
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
    var isConnected: Bool { identity != nil }

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
    /// Anchor of the most recent menu — reused to re-anchor a follow-up menu (e.g. the
    /// "Add to playlist…" submenu) after the first one is dismissed on selection.
    var lastMenuLocation: CGPoint = .zero
    func showMenu(_ items: [AppMenuItem], at point: CGPoint) {
        guard !items.isEmpty else { return }
        lastMenuLocation = point
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

    /// Albums shown by the active filter.
    var visibleAlbums: [Album] {
        switch filter {
        case .all:        return albums
        case .favourites: return albums.filter { $0.isFavourite }
        case .downloaded: return albums.filter { $0.isDownloaded }
        case .bandcamp:   return albums.filter { $0.source == .bandcamp }
        case .imported:   return albums.filter { $0.source == .local }
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

    var nowPlayingAlbum: Album? { albums.first { $0.id == nowPlayingAlbumID } }
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
        nowPlayingAlbumID = album.id
        Task {
            let tracks = await resolveTracks(for: album)
            player.play(tracks)
        }
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

    /// Present the "Add to playlist…" chooser (a follow-up menu re-anchored at the last spot).
    func showAddToPlaylistMenu(for album: Album) {
        var items: [AppMenuItem] = [
            AppMenuItem(title: "New playlist…", systemImage: "plus") { self.createPlaylistAndAdd(album) }
        ]
        if !playlists.isEmpty {
            items.append(.divider())
            for pl in playlists {
                items.append(AppMenuItem(title: pl.name, systemImage: "music.note.list") {
                    self.addAlbum(album, toPlaylist: pl.id)
                })
            }
        }
        showMenu(items, at: lastMenuLocation)
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
        do {
            let client = BandcampClient(identity: identity)
            let fanID = try await client.fanID()
            let items = try await client.collection(fanID: fanID)

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

    /// Resolves an album into a playable track queue (downloaded files, local file, or Bandcamp streams).
    func resolveTracks(for album: Album) async -> [Track] {
        if let locals = album.localTracks, !locals.isEmpty {
            return locals.map { fileURL in
                Track(title: FilenameCleaner.trackTitle(fileURL.deletingPathExtension().lastPathComponent),
                      artist: album.artist, streamURL: fileURL,
                      artworkURL: album.artworkURL, albumID: album.id, g0: album.g0, g1: album.g1)
            }
        }
        if let url = album.url {
            return [Track(title: album.title, artist: album.artist, streamURL: url,
                          artworkData: album.artworkData, albumID: album.id, g0: album.g0, g1: album.g1)]
        }
        if album.source == .bandcamp, let identity, let itemURL = album.bandcampItemURL {
            do {
                var tracks = try await BandcampClient(identity: identity).tracks(forItemURL: itemURL)
                for i in tracks.indices { tracks[i].albumID = album.id }
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

            // Pull artist/cover from the first track, then enrich from the web.
            if let first = tracks.first {
                let meta = await Self.loadMetadata(url: first)
                if let idx = self.albums.firstIndex(where: { $0.id == album.id }) {
                    if let a = meta.artist { self.albums[idx].artist = a }
                    if let art = meta.artwork { self.albums[idx].artworkData = art }
                    self.persist()
                }
            }
            await self.enrich(albumID: album.id)
        }
    }

    private struct TrackMeta { var title: String?; var artist: String?; var artwork: Data? }

    private static func loadMetadata(url: URL) async -> TrackMeta {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        func str(_ key: AVMetadataKey) -> String? {
            AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first?.stringValue
        }
        let artwork = AVMetadataItem.metadataItems(from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first?.dataValue
        return TrackMeta(title: str(.commonKeyTitle), artist: str(.commonKeyArtist), artwork: artwork)
    }
}
