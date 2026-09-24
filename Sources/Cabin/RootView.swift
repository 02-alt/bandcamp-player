import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Publishes the real NSWindow width (points) and lowers the window's minimum size so it can shrink
/// into the narrow "solo" layout. A SwiftUI GeometryReader can't do this: wide content overflows and
/// clips inside a smaller window, so it reports the content's intrinsic width, not the window's.
private struct WindowAccessor: NSViewRepresentable {
    let onSize: (CGSize) -> Void
    let onScreen: (CGFloat) -> Void

    final class Coordinator { var observed = false; var tokens: [NSObjectProtocol] = [] }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { attach(v, context.coordinator) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { attach(v, context.coordinator) }
    }

    private func attach(_ v: NSView, _ coord: Coordinator) {
        guard let w = v.window else { return }
        w.minSize = WindowSize.minimum
        // Give the window Safari's title-bar treatment: a transparent *unified* toolbar (SwiftUI's —
        // see `titlebarToolbar` in RootView; views like the small Now Playing add real items to it).
        // Without a toolbar, `.hiddenTitleBar` leaves the short 28pt title strip, and the traffic
        // lights read as cramped/small; the toolbar raises the strip to the standard ~52pt Safari
        // height, while the transparent bar + full-size content keeps the full-bleed look.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.toolbar?.showsBaselineSeparator = false
        w.toolbarStyle = .unified
        // Screenshot/QA hook: CABIN_WINDOW=980x600 launches at an exact window size.
        if !coord.observed, let spec = ProcessInfo.processInfo.environment["CABIN_WINDOW"] {
            let wh = spec.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2 { w.setFrame(NSRect(origin: w.frame.origin, size: NSSize(width: wh[0], height: wh[1])), display: true) }
        }
        onSize(w.frame.size)
        reportScreen(w)
        guard !coord.observed else { return }
        coord.observed = true
        coord.tokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: w, queue: .main
        ) { _ in onSize(w.frame.size) })
        // The display can change when the window is dragged to another monitor — re-read then.
        coord.tokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: w, queue: .main
        ) { _ in reportScreen(w) })
    }

    private func reportScreen(_ w: NSWindow) {
        // visibleFrame excludes the menu bar / Dock — the height the window can actually use.
        if let h = (w.screen ?? NSScreen.main)?.visibleFrame.height { onScreen(h) }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var ipod: IPodWatcher
    @AppStorage("ambientTheming") private var ambientTheming = true
    @State private var dropTargeted = false

    /// Keeps a SwiftUI-managed window toolbar present at all times (for the tall ~52pt title strip —
    /// see WindowAccessor) with an invisible item; other views add their own real items to it.
    @ToolbarContentBuilder private var titlebarToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .automatic) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
        }
        // Like Music: the view switcher lives in the title bar (the native segmented control gets its
        // toolbar glass there). Detail pages hide it and show a floating Back instead (see body).
        if !fullScreenOverlay {
            if state.searchOpen && (detailOpen || !showsScreenSwitch) {
                // Search opened from a page without the usual toolbar (⌘S / palette on a detail
                // page or first run): still give it its field (and so a way to close it).
                ToolbarItem(placement: .primaryAction) { searchToolbarItem }
            } else if !detailOpen && showsScreenSwitch {
                // Stays up during search (so the buttons don't jump left); picking a tab ends the search.
                ToolbarItem(placement: .principal) { ScreenSwitch().modifier(LinkCursor()) }
                ToolbarItemGroup(placement: .primaryAction) { libraryToolbarButtons }
                // Search on its own glass, at the far right (like Music).
                if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
                ToolbarItem(placement: .primaryAction) { searchToolbarItem }
            }
        }
    }

    /// Add music / iPod / Friends / Settings — native toolbar items, like Music's top right.
    @ViewBuilder private var libraryToolbarButtons: some View {
        // Small window: the Crate's filters (the side list has no room there).
        if state.screen == .crate && state.sizeBand == .small {
            CrateFilterMenu()
        }
        Menu {
            Button("Import Files or Folder…", systemImage: "folder") { state.pickAndImport() }
            Button("Import from Apple Music…", systemImage: "music.note") { state.importFromAppleMusic() }
            Divider()
            Button("Discover on Bandcamp…", systemImage: "safari") {
                NSWorkspace.shared.open(URL(string: "https://bandcamp.com/discover")!)
            }
            Divider()
            if state.isConnected {
                Button(state.sync == .syncing ? "Syncing Bandcamp…" : "Sync Bandcamp",
                       systemImage: "arrow.triangle.2.circlepath") {
                    Task { await state.syncBandcamp(announce: true) }
                }
            } else {
                Button("Connect Bandcamp…", systemImage: "link") { state.connect() }
            }
        } label: { Label("Add Music", systemImage: "plus") }
        .menuIndicator(.hidden)
        .help("Add music")
        .modifier(LinkCursor())
        // Only while a click-wheel iPod is connected; opens the full-window iPod mode.
        if ipod.device != nil {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    state.searchOpen = false
                    state.screen = state.screen == .ipod ? .crate : .ipod
                }
            } label: { Label("iPod", systemImage: "ipod") }
            .help("iPod")
            .modifier(LinkCursor())
        }
        if state.isConnected {
            Button { state.openFriends() } label: { Label("Friends", systemImage: "person.2") }
                .help("Friends")
                .modifier(LinkCursor())
        }
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { state.searchOpen = false; state.screen = .settings }
        } label: { Label("Settings", systemImage: "gearshape") }
        .help("Settings")
        .modifier(LinkCursor())
    }

    /// Search: the button turns into a search field in place (like Music / Finder).
    @ViewBuilder private var searchToolbarItem: some View {
        if state.searchOpen {
            ToolbarSearchField(text: $state.searchQuery) {
                withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = false }
            }
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = true }
            } label: { Label("Search", systemImage: "magnifyingglass") }
            .help("Search")
            .modifier(LinkCursor())
        }
    }

    /// Now Playing, Art mode, First Listen, the unbox reveal or the map covers the whole window.
    private var fullScreenOverlay: Bool {
        player.expanded || player.artMode || state.firstListenAlbum != nil
            || state.showNewAlbumReveal || state.mapOpen || state.isInitialLoading
    }
    /// Something sits over the detail page (search, palette, receipt, a drawer) — Back and ⌘[
    /// would close the page hidden underneath, so they step aside.
    private var detailCovered: Bool {
        state.searchOpen || state.paletteOpen || state.receiptMonth != nil
            || state.friendsOpen || state.queueOpen
    }
    private var detailOpen: Bool {
        state.openedAlbum != nil || state.openedArtist != nil || state.openedExternalAlbum != nil
    }
    /// The four collection tabs — hidden on first run (nothing to browse yet) and during search.
    private var showsScreenSwitch: Bool {
        state.isConnected || !state.albums.isEmpty
    }
    /// Back closes the page on top: an album over an artist over an unowned album.
    private func closeTopDetail() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if state.openedAlbum != nil { state.openedAlbumID = nil }
            else if state.openedArtist != nil { state.openedArtist = nil }
            else { state.openedExternalAlbum = nil }
        }
    }

    var body: some View {
        let p = Palette(scheme: state.scheme)
        // The recap is its own full-screen moment — suppress the cover-derived tint so it can't
        // bleed through the uncovered titlebar strip behind the traffic lights.
        let onRecap = state.screen == .recap
        // Cover-derived glow, when enabled and something is playing.
        let ambient = (ambientTheming && !onRecap) ? state.ambient : nil
        // Bespoke per-album skin (e.g. "Forever Alone" → animated black ocean).
        let special = ambientTheming && !onRecap && AlbumTheme.hasBackground(state.nowPlayingAlbum)
        // Tiniest window: a very short Crate → show only the cover, no player bar. (The player bar
        // reduces to a single row first — see PlayerBar — then disappears here.)
        let tinyWindow = state.screen == .crate && state.windowHeight < 380
        ZStack {
            if special {
                AlbumTheme.background(for: state.nowPlayingAlbum, colors: state.ambientPalette).ignoresSafeArea()
            } else {
                // Page + soft blobs so the glass reads. The blobs pick up the now-playing
                // cover's colour when ambient theming is on, else stay monochrome.
                p.page.ignoresSafeArea()
                // A full-bleed wash so the tint reads. Kept low (0.08) because content now sits
                // directly on this ambient (the glass panels are gone): a heavier wash lifts the
                // background luminance and pulls muted text under the WCAG AA contrast floor,
                // especially for bright covers (measured: a teal cover ran the right edge to ~0.08
                // luminance, dropping muted2 to ~2.8:1 — well under 4.5:1).
                if let ambient {
                    ambient.opacity(0.08).blendMode(.plusLighter).ignoresSafeArea()
                }
                // The blobs are drawn as overlays on a flexible Color.clear so their fixed 640/560
                // sizes don't force the root ZStack's minimum height (which would center-clip the
                // header + player bar once the window is shorter than the blob — see the low height
                // floor in CabinApp). Color.clear takes the proposed size; overlays don't drive it.
                // Skipped on the recap so the background is one flat, continuous surface right up
                // to the top edge — no shade seam where the titlebar strip meets the recap page.
                if !onRecap {
                    Color.clear
                        .overlay {
                            Circle().fill(ambient?.opacity(0.38) ?? p.blob1).frame(width: 640, height: 640)
                                .blur(radius: 110).offset(x: -200, y: -360)
                        }
                        .overlay {
                            Circle().fill(ambient?.opacity(0.18) ?? p.blob2).frame(width: 560, height: 560)
                                .blur(radius: 110).offset(x: 420, y: 380)
                        }
                        .ignoresSafeArea()
                }
            }

            ZStack {
                MainPanel()
                // Full-page collection map — covers the content area but keeps the player bar.
                if state.mapOpen {
                    CollectionMapView()
                        .environment(\.palette, p)
                        .transition(.opacity)
                }
            }
            // Docked translucent player bar as a bottom safe-area inset (not a VStack sibling), so
            // the content fills the window and can scroll *behind* it — screens that opt in (the
            // album tracklist) show through the material instead of stopping at its top edge.
            // The covers + player bar are the two non-negotiable elements; the inset keeps the bar
            // pinned to the bottom edge no matter how short the window gets.
            // Hidden while the full-window Now Playing screen is up.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // At the very smallest size (narrow Crate + short) drop the player bar too — just the
                // cover. Covers are tap-to-play and the transport keys/media keys still work.
                // Hide the bar entirely on first run (empty library, nothing playing) so the
                // welcome screen doesn't sit above a dead "Nothing here" player.
                let idleEmpty = state.albums.isEmpty && player.current == nil
                if !player.expanded && !tinyWindow && !idleEmpty { PlayerBar() }
            }
            .sheet(isPresented: $state.showWhatsNew) {
                WhatsNewView { state.showWhatsNew = false }
                    .environment(\.palette, p)
            }
            // Mirror the connected iPod for context menus. `onChange(initial:)` runs after the
            // view is instantiated — mutating state here (unlike in onReceive, which replays during
            // graph instantiation and aborts) is safe.
            .onChange(of: ipod.device, initial: true) { _, dev in state.connectedIPod = dev }

            // Drag & drop hint
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(p.text.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(p.text.opacity(0.04))
                    .overlay(
                        Text("Drop music or a folder to import")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.text)
                    )
                    .padding(Space.s4)
                    .allowsHitTesting(false)
            }

            // Up Next queue panel (slides in over the collection).
            if state.queueOpen {
                QueueView()
                    .environment(\.palette, p)
                    .zIndex(150)
            }

            // Friends drawer (slides in from the right like Up Next).
            if state.friendsOpen {
                FriendsView()
                    .environment(\.palette, p)
                    .zIndex(150)
            }

            // Full-window Now Playing screen. First Listen is an alternate style that
            // borrows the focused reading-room layout, bound to the live player.
            if player.expanded {
                // The same subject the turntable shows: the playing album if any, else the album
                // resolved from the current track, else the browsed album (state.current). This
                // last fallback matters at rest — before play is pressed — so First Listen always
                // renders when it's the chosen style, instead of dropping back to the turntable.
                let firstListenAlbum = state.nowPlayingAlbum
                    ?? player.current?.albumID.flatMap { state.album(id: $0) }
                    ?? state.current
                Group {
                    if state.nowPlayingStyle == .firstListen {
                        FirstListenNowPlaying(album: firstListenAlbum, track: player.current,
                                              onClose: { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { player.expanded = false } })
                            .id(firstListenAlbum.id)   // rebuild + re-sync on album change
                    } else {
                        NowPlayingView()
                    }
                }
                .environment(\.palette, p)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
            }

            // Fullscreen art mode — a full takeover, so it sits above everything, including the
            // standalone First Listen (zIndex 510) and the unbox reveal, both of which can open it.
            if player.artMode {
                ArtModeView()
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(520)
            }


            // Transient error/status banner.
            if let notice = state.notice {
                VStack {
                    Text(notice)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text)
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(p.text.opacity(0.12)))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                        .padding(.top, Space.s5)
                        .onTapGesture { withAnimation { state.notice = nil } }
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(300)
            }

            // Monthly listening receipt (full-window reveal).
            if let month = state.receiptMonth {
                ReceiptView(month: month)
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(280)
            }

            // ⌘K command palette.
            if state.paletteOpen {
                CommandPalette()
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(275)
            }

            // Quick "New playlist…" prompt from a right-click menu.
            if let draft = state.playlistDraft {
                QuickPlaylistCreator(draft: draft)
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(276)
            }

            // Detail pages (album / artist / unowned album): a floating native Back just below the
            // traffic lights. It sits over the page, so it stays put while the page scrolls.
            if detailOpen && !fullScreenOverlay && !detailCovered {
                Button { closeTopDetail() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .glassIconButton(side: 40)
                .help("Back")
                .keyboardShortcut("[", modifiers: .command)
                .padding(.leading, 14).padding(.top, Space.s1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
                .zIndex(90)
            }

            // Custom right-click menus render above everything.
            ContextMenuLayer().zIndex(200)

            // Full-window "new album" reveal — auto-fired on a just-bought record (unboxes exactly
            // those), or opened manually (⌥⌘U / palette) to browse the whole library. Frosts the app.
            if state.showNewAlbumReveal {
                UnboxPrototypeView(realAlbums: state.unboxAlbums.isEmpty ? state.albums : state.unboxAlbums,
                                   onClose: { withAnimation(.easeInOut(duration: 0.3)) { state.showNewAlbumReveal = false; state.unboxAlbums = [] } })
                    .environment(\.colorScheme, .dark)   // keep the reveal dark even in a light app
                    .transition(.opacity)
                    .zIndex(500)
            }

            // Standalone First Listen screen (from the Crate button / context menu).
            if let a = state.firstListenAlbum {
                FirstListenPresenter(album: a,
                                     onClose: { withAnimation(.easeInOut(duration: 0.3)) { state.firstListenAlbum = nil } })
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
                    .zIndex(510)
            }

            // First-launch loading screen while the collection is still being fetched.
            if state.isInitialLoading {
                LaunchLoadingView()
                    .environment(\.palette, p)
                    .environmentObject(state.syncProgress)
                    .transition(.opacity)
                    .zIndex(400)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state.isInitialLoading)
        .animation(.easeInOut(duration: 0.35), value: state.showNewAlbumReveal)
        .animation(.easeInOut(duration: 0.35), value: state.firstListenAlbum?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.notice)
        .environment(\.palette, p)
        .tint(p.text)
        .background(WindowAccessor(onSize: { size in
            if abs(state.windowWidth - size.width) > 0.5 { state.windowWidth = size.width }
            if abs(state.windowHeight - size.height) > 0.5 { state.windowHeight = size.height }
        }, onScreen: { h in
            if abs(state.screenHeight - h) > 0.5 { state.screenHeight = h }
        }))
        .toolbar { titlebarToolbar }
        // If the iPod is unplugged while its screen is open, fall back to the Crate.
        .onChange(of: ipod.device) { _, dev in
            if dev == nil && state.screen == .ipod { state.screen = .crate }
        }
        .uiZoom(scale: state.uiScale, size: CGSize(width: state.windowWidth, height: state.windowHeight))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            state.handleDrop(providers)
        }
        .sheet(isPresented: $state.showLogin) {
            BandcampLoginSheet()
                .environment(\.palette, p)
        }
    }
}

private extension View {
    /// Lay this view out on a `1/scale` larger canvas, then scale it down to `size` — a non-blurry
    /// "zoom out" that makes the whole UI read smaller while still filling the window. A no-op at
    /// scale 1 (desktop displays) or before the real window size is known.
    @ViewBuilder func uiZoom(scale: CGFloat, size: CGSize) -> some View {
        if scale >= 0.999 || size.width < 1 || size.height < 1 {
            self
        } else {
            frame(width: size.width / scale, height: size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                // `size` is the full window frame (titlebar included). Without this, the zoom
                // container is inset below the hidden titlebar's top safe area while still sized to
                // the full height — leaving the titlebar region uncovered (a grey bar) and pushing
                // the bottom off-screen, where `.clipped()` cuts the player bar. Fill edge-to-edge.
                .ignoresSafeArea()
        }
    }
}

/// The title-bar search field: focused as soon as it appears; Escape (or the clear button on an
/// empty field) closes search.
private struct ToolbarSearchField: View {
    @Binding var text: String
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your library", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand(perform: onClose)
            Button {
                if text.isEmpty { onClose() } else { text = "" }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .modifier(LinkCursor())
            .help(text.isEmpty ? "Close search" : "Clear")
        }
        .padding(.horizontal, 10)
        .frame(width: 260)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
