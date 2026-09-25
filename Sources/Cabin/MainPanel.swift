import SwiftUI
import AppKit

struct MainPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ipod: IPodWatcher
    @Environment(\.palette) private var p

    // Narrow window: drop the whole top bar and let the Crate show a single big focused cover with
    // slivers of its neighbours — just covers + a minimal player bar. Uses the real NSWindow width
    // (state.windowWidth), not a GeometryReader — see WindowAccessor.
    private var solo: Bool { state.screen == .crate && state.windowWidth < 520 }
    // Too narrow for the full header (centred tabs + trailing cluster overlap): swap to a compact
    // header — a screen-picker menu + Search + a "•••" overflow — so nothing collides or clips.
    private var compactHeader: Bool { !solo && state.windowWidth < 620 }

    private var detailOpen: Bool {
        state.openedAlbum != nil || state.openedArtist != nil || state.openedExternalAlbum != nil
    }
    private var firstRun: Bool { !state.isConnected && state.albums.isEmpty }

    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        VStack(spacing: 0) {
            // Music-style header in the page, just below the title bar: the draggable glass tab
            // switch centred, the library buttons + Search on the right, at 44pt.
            if !solo && state.showsLibraryHeader(player) {
                headerBar
                    .padding(.horizontal, Space.s5)
                    .padding(.top, Space.s1)
                    .zIndex(1)
            }
            pages
        }
    }

    /// Tabs truly centred when there's room (a hidden copy of the right-hand cluster balances the
    /// row); otherwise they slide left of the cluster instead of running into it.
    private var headerBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                HeaderTrailing().hidden().accessibilityHidden(true)
                Spacer(minLength: Space.s3)
                ScreenSwitch()
                Spacer(minLength: Space.s3)
                HeaderTrailing()
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ScreenSwitch()
                Spacer(minLength: Space.s3)
                HeaderTrailing()
            }
        }
        .frame(height: HeaderMetrics.height)
    }

    private var pages: some View {
        ZStack {
                // Hidden while a full-screen overlay (album / artist / search) is up, so those can be
                // transparent and let RootView's ambient show through instead of covering it in black.
                if state.openedAlbum == nil && state.openedArtist == nil && state.openedExternalAlbum == nil && !state.searchOpen {
                    Group {
                        if state.screen == .settings {
                            SettingsView().environmentObject(state.bpmProgress)
                        } else if state.screen == .recap {
                            RecapView()
                        } else {
                            VStack(spacing: Space.s5) {
                                // First run (not connected, empty library): drop the tabs + toolbar so
                                // the welcome stands alone — nothing to browse or search yet.
                                content(solo: solo)
                            }
                            // Flat layout: pull the header up to reclaim the old card's top margin,
                            // keeping just enough clearance for the window's traffic-light buttons.
                            .padding(.horizontal, (solo || compactHeader) ? Space.s4 : Space.s7)
                            .padding(.top, solo ? Space.s4 : Space.s5)
                            .padding(.bottom, solo ? Space.s4 : Space.s5)
                        }
                    }
                }

                if let artist = state.openedArtist {
                    ArtistView(name: artist).transition(.opacity)
                }

                if let album = state.openedAlbum {
                    // Keyed by album so stepping ˄ ˅ rebuilds the page (and its toolbar items, whose
                    // actions would otherwise keep pointing at the previous album) — a crossfade.
                    AlbumDetailView(album: album).id(album.id).transition(.opacity)
                }

                // An unowned album (wishlist / friend's pick): read-only detail, hidden once an
                // artist or owned-album page opens over it.
                if let ext = state.openedExternalAlbum, state.openedArtist == nil, state.openedAlbum == nil {
                    ExternalAlbumDetailView(album: ext, note: state.openedExternalNote).transition(.opacity)
                }

                if state.searchOpen {
                    SearchOverlay().transition(.opacity)
                }
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clip at the panel's bottom so nothing (e.g. the crate's filter list in a short window)
        // bleeds down over the transparent player bar below — but not the top, so detail pages can
        // run up under the (bar-less) title bar.
        .clipShape(OpenTopRect())
    }

    // MARK: Header (replaces the sidebar)

    /// Narrow header: a screen-picker menu on the left, Search + a "•••" overflow on the right.
    private var compactHeaderBar: some View {
        HStack(spacing: Space.s3) {
            ScreenPickerButton()
            Spacer(minLength: Space.s2)
            if !state.isConnected {
                Button { state.connect() } label: {
                    Text("Connect").font(.system(size: 12, weight: .bold))
                }
                .modifier(GlassButton(prominent: true)).controlSize(.large)
            }
            IconButton(system: "magnifyingglass", label: "Search", tip: "Search") {
                withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = true }
            }
            HeaderOverflowButton()
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: ipod.device != nil)
    }


    @ViewBuilder
    private func content(solo: Bool) -> some View {
        switch state.screen {
        case .crate:     CrateView(solo: solo)
        case .grid:      GridView()
        case .playlists: PlaylistsView()
        case .wishlist:  WishlistView()
        case .ipod:      IPodView()
        case .recap, .settings: EmptyView()
        }
    }
}

/// The grid's sort control: a circular icon button that opens the app-styled menu
/// with the ordering options (Added / Artist / Title / Year), a checkmark on the active one.
/// The Crate's filters (all / new / favourites / …) as a native title-bar filter button, used in a
/// small window, where the Crate shows only the cover pile. The icon fills while a filter is on.
struct CrateFilterMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let rows = FilterList.visibleRows(state)
        Menu {
            Picker("Show", selection: Binding(get: { state.filter },
                                              set: { f in withAnimation(Motion.glide) { state.filter = f } })) {
                ForEach(rows, id: \.0) { f, label in
                    Text("\(label.capitalized)  \(state.count(for: f))").tag(f)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HeaderIcon(system: state.filter == .all
                       ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
                       on: state.filter != .all)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(state.filter == .all ? "Filter" : "Showing \(rows.first { $0.0 == state.filter }?.1 ?? "")")
        .modifier(LinkCursor())
    }
}

private struct SortMenuButton: View {
    @EnvironmentObject var state: AppState
    @State private var frame: CGRect = .zero

    var body: some View {
        IconButton(system: "arrow.up.arrow.down", label: "Sort", tip: "Sort") { open() }
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { frame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in frame = f }
                }
            )
    }

    private func open() {
        let items = AppState.Sort.allCases.map { s in
            AppMenuItem(title: s.label, systemImage: state.sort == s ? "checkmark" : s.icon) {
                withAnimation(Motion.glide) { state.sort = s }
            }
        }
        state.showMenu(items, at: CGPoint(x: frame.minX, y: frame.maxY + 6))
    }
}

/// Compact-header screen switcher: a labelled popup ("Grid ▾") that opens the view list, used in
/// place of the full segmented bar when the window is too narrow for it.
private struct ScreenPickerButton: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ipod: IPodWatcher
    @Environment(\.palette) private var p
    @State private var frame: CGRect = .zero

    private var currentLabel: String {
        switch state.screen {
        case .crate: return "Crate"; case .grid: return "Grid"
        case .playlists: return "Playlists"; case .wishlist: return "Wishlist"
        case .ipod: return "iPod"; default: return "Library"
        }
    }

    var body: some View {
        Button { open() } label: {
            HStack(spacing: 5) {
                Text(currentLabel).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(p.muted)
            }
        }
        .modifier(GlassButton()).controlSize(.large)
        .accessibilityLabel("Switch view, \(currentLabel)")
        .background(GeometryReader { g in
            Color.clear.onAppear { frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in frame = f }
        })
    }

    private func open() {
        var opts: [(String, String, AppState.Screen)] = [
            ("Crate", "square.stack", .crate), ("Grid", "square.grid.2x2", .grid),
            ("Playlists", "music.note.list", .playlists), ("Wishlist", "heart", .wishlist)
        ]
        if ipod.device != nil { opts.append(("iPod", "ipod", .ipod)) }
        let items = opts.map { o in
            AppMenuItem(title: o.0, systemImage: state.screen == o.2 ? "checkmark" : o.1) {
                withAnimation(Motion.glide) { state.screen = o.2 }
            }
        }
        state.showMenu(items, at: CGPoint(x: frame.minX, y: frame.maxY + 6))
    }
}

/// Compact-header overflow ("•••"): the secondary actions (sort, select, add music, sync/connect,
/// friends, settings) that don't fit as their own buttons on a narrow window.
private struct HeaderOverflowButton: View {
    @EnvironmentObject var state: AppState
    @State private var frame: CGRect = .zero

    var body: some View {
        IconButton(system: "ellipsis", label: "More", tip: "More") { open() }
            .background(GeometryReader { g in
                Color.clear.onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            })
    }

    private func open() {
        var items: [AppMenuItem] = []
        if state.screen == .grid {
            var sort = AppMenuItem(title: "Sort", systemImage: "arrow.up.arrow.down") {}
            sort.submenu = AppState.Sort.allCases.map { s in
                AppMenuItem(title: s.label, systemImage: state.sort == s ? "checkmark" : s.icon) {
                    withAnimation(Motion.glide) { state.sort = s }
                }
            }
            items.append(sort)
            items.append(AppMenuItem(title: state.selecting ? "Done selecting" : "Select albums",
                                     systemImage: "checkmark.circle") { state.enterSelection(!state.selecting) })
            items.append(.divider())
        }
        items.append(AppMenuItem(title: "Import files or folder…", systemImage: "folder") { state.pickAndImport() })
        items.append(AppMenuItem(title: "Import from Apple Music…", systemImage: "music.note") { state.importFromAppleMusic() })
        if state.isConnected {
            items.append(AppMenuItem(title: state.sync == .syncing ? "Syncing Bandcamp…" : "Sync Bandcamp",
                                     systemImage: "arrow.triangle.2.circlepath") {
                Task { await state.syncBandcamp(announce: true) }
            })
        } else {
            items.append(AppMenuItem(title: "Connect Bandcamp…", systemImage: "link") { state.connect() })
        }
        items.append(.divider())
        if state.isConnected {
            items.append(AppMenuItem(title: "Friends", systemImage: "person.2") { state.openFriends() })
        }
        items.append(AppMenuItem(title: "Settings", systemImage: "gearshape") {
            withAnimation(.easeInOut(duration: 0.15)) { state.screen = .settings }
        })
        state.showMenu(items, at: CGPoint(x: frame.minX, y: frame.maxY + 6))
    }
}

/// Switch for the collection views — the native segmented control, like Music's
/// Library / Apple Music / iTunes Store switch.
/// Frame of each segment, reported up in the switcher's own coordinate space so the draggable
/// pill can be positioned over any tab.
private struct SegFrameKey: PreferenceKey {
    static let defaultValue: [AppState.Screen: CGRect] = [:]
    static func reduce(value: inout [AppState.Screen: CGRect], nextValue: () -> [AppState.Screen: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct ScreenSwitch: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    private let items: [(String, AppState.Screen)] = [
        ("Crate", .crate), ("Grid", .grid), ("Playlists", .playlists), ("Wishlist", .wishlist)
    ]

    // The bar itself never moves. Only the glass selection pill is draggable: while `dragX`
    // is set it follows the pointer along the bar (clamped between the first and last tab),
    // the tab under it lights up, and on release the nearest tab is committed — exactly like
    // the Apple Music tab bar.
    @State private var frames: [AppState.Screen: CGRect] = [:]
    @State private var dragX: CGFloat? = nil
    @State private var hovering = false
    @State private var lastDragX: CGFloat? = nil
    // Liquid side-stretch: grows while the pill is moving, springs back to 0 at rest.
    @State private var stretch: CGFloat = 0
    private var dragging: Bool { dragX != nil }
    private var active: Bool { dragging || hovering }

    // Tab shown as selected: the one under the pill while dragging, else the real screen.
    private var previewScreen: AppState.Screen? {
        if let x = dragX { return nearest(toX: x) }
        return state.searchOpen ? nil : state.screen   // no tab lit while searching
    }

    var body: some View {
        // A native GlassEffectContainer so the bar glass and the selection-pill glass are ONE
        // system — the pill lenses and merges into the bar (like the native Messenger tab bar),
        // instead of a flat coloured capsule sitting on top.
        glassContainer {
            HStack(spacing: 3) {
                ForEach(items, id: \.1) { segment($0.0, $0.1) }
                // The iPod is no longer a tab — it's entered from the trailing iPod button (see
                // MainPanel.trailingButtons), which only appears while a click-wheel iPod is connected.
            }
            .padding(4)
            .background(alignment: .topLeading) { pill }
            .coordinateSpace(name: "screenSwitch")
            // Pure system Liquid Glass bar (no dark scrim) so it refracts clean like the native
            // tab-bar pill, instead of reading as a smoked-black capsule.
            .glass(in: Capsule(), pure: true)
            // The pill is draggable, but as a *simultaneous* gesture so a plain tap still reaches the
            // segment buttons underneath (a clear overlay handle swallowed taps under the macOS 26 SDK).
            .simultaneousGesture(barDrag)
            .onHover { h in hovering = h; (h ? NSCursor.openHand : NSCursor.arrow).set() }
        }
        .onPreferenceChange(SegFrameKey.self) { frames = $0 }
    }

    /// Wraps the switcher in Apple's `GlassEffectContainer` on macOS 26 (so the bar + pill glass
    /// blend as one fluid shape); plain pass-through on older systems (material fallback).
    @ViewBuilder private func glassContainer<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { content() }
        } else {
            content()
        }
    }

    private func clampedCenter(_ rect: CGRect) -> CGFloat {
        let mids = frames.values.map(\.midX)
        let lo = mids.min() ?? rect.midX
        let hi = mids.max() ?? rect.midX
        return dragging ? min(max(dragX ?? rect.midX, lo), hi) : rect.midX
    }

    // Base uniform scale — the pill grows on hover and grows more while dragging.
    private var pillScale: CGFloat { dragging ? 1.12 : hovering ? 1.05 : 1 }

    // The single glass pill, positioned over the previewed tab (or under the pointer).
    @ViewBuilder private var pill: some View {
        if let screen = previewScreen, let rect = frames[screen] {
            pillGlass
                // Brighter, thicker light-catching rim when the pill is live.
                .overlay(Capsule().strokeBorder(active ? p.text.opacity(0.4) : p.edge,
                                                lineWidth: active ? 1.5 : 1))
                .frame(width: rect.width, height: rect.height)
                // Uniform grow + a liquid horizontal stretch (wider, a touch shorter) that
                // pulses on the sides as the pill is dragged.
                .scaleEffect(CGSize(width: pillScale * (1 + stretch),
                                    height: pillScale * (1 - stretch * 0.55)))
                .shadow(color: .black.opacity(active ? 0.3 : 0),
                        radius: active ? 14 : 0, y: active ? 6 : 0)
                .position(x: clampedCenter(rect), y: rect.midY)
                .animation(.spring(response: 0.32, dampingFraction: 0.7), value: hovering)
        }
    }

    // Real Liquid Glass (interactive → live edge lensing/refraction) on macOS 26, tinted
    // brighter than the bar; material fallback on older systems.
    @ViewBuilder private var pillGlass: some View {
        if #available(macOS 26.0, *) {
            // Pure Liquid Glass (no colour fill on top, which would mute it) → the pill reads as
            // real glass that lenses and merges with the bar inside the GlassEffectContainer.
            Color.clear.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(p.glassFill).background(.ultraThinMaterial, in: Capsule())
        }
    }

    // Invisible, sits exactly over the pill and captures the drag + hover.
    /// Drag-to-move-the-pill, attached to the whole bar as a simultaneous gesture. `minimumDistance`
    /// keeps a tap from ever starting a drag, and `onEnded` no-ops unless a drag actually began — so
    /// tapping a tab is handled by its button, not misread as a zero-length drag to the same spot.
    private var barDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("screenSwitch"))
            .onChanged { v in
                let dx = v.location.x - (lastDragX ?? v.location.x)
                lastDragX = v.location.x
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.8)) {
                    dragX = v.location.x
                    stretch = min(0.16, abs(dx) * 0.018)
                }
            }
            .onEnded { v in
                guard dragX != nil else { lastDragX = nil; return }   // a tap, not a drag
                let target = nearest(toX: v.location.x)
                lastDragX = nil
                withAnimation(Motion.glide) {
                    state.searchOpen = false
                    state.screen = target
                    dragX = nil
                    stretch = 0
                }
            }
    }

    private func nearest(toX x: CGFloat) -> AppState.Screen {
        frames.min { abs($0.value.midX - x) < abs($1.value.midX - x) }?.key ?? state.screen
    }

    private func segment(_ label: String, _ screen: AppState.Screen) -> some View {
        let on = previewScreen == screen
        return Button {
            withAnimation(Motion.glide) { state.searchOpen = false; state.screen = screen }
        } label: {
            // HIG large-control size: the bar is 44pt tall (see HeaderMetrics).
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).fixedSize()
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.horizontal, 18)
                .frame(height: HeaderMetrics.height - 8)
                .background {
                    // Report this segment's frame so the draggable pill can find it.
                    GeometryReader { g in
                        Color.clear.preference(
                            key: SegFrameKey.self,
                            value: [screen: g.frame(in: .named("screenSwitch"))])
                    }
                }
                .contentShape(Capsule())
                .hoverHighlight(active: on)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}


/// The title bar's right-hand cluster: Offline / Connect / Grid sort + Select, the glass group of
/// Filter (small Crate) / Add / iPod / Friends / Settings, and Search (which opens a field in place).
struct HeaderTrailing: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ipod: IPodWatcher
    @Environment(\.palette) private var p

    var body: some View { headerTrailing }

    private var headerTrailing: some View {
        HStack(spacing: Space.s3) {
            trailingButtons
            libraryButtons
            searchButton
        }
        .fixedSize()
    }

    /// Filter (small Crate) / Add / iPod / Friends / Settings, grouped on one glass capsule.
    private var libraryButtons: some View {
        HStack(spacing: 0) {
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
            } label: { HeaderIcon(system: "plus") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("Add music").modifier(LinkCursor())
            // Only while a click-wheel iPod is connected; opens the full-window iPod mode.
            if ipod.device != nil {
                headerIconButton("ipod", help: "iPod", on: state.screen == .ipod) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        state.searchOpen = false
                        state.goTo(state.screen == .ipod ? .crate : .ipod)
                    }
                }
            }
            if state.isConnected {
                headerIconButton("person.2", help: "Friends") { state.openFriends() }
            }
            headerIconButton("gearshape", help: "Settings") {
                withAnimation(.easeInOut(duration: 0.15)) { state.goTo(.settings) }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: HeaderMetrics.height)
        .modifier(HeaderGlass(shape: Capsule()))
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: ipod.device != nil)
    }

    /// Search: a round glass button that turns into a search field in place.
    @ViewBuilder private var searchButton: some View {
        if state.searchOpen {
            ToolbarSearchField(text: $state.searchQuery) {
                withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = false }
            }
            .font(.system(size: 14))
            .frame(height: HeaderMetrics.height)
            .modifier(HeaderGlass(shape: Capsule()))
            .transition(.opacity)
        } else {
            Button { withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = true } } label: {
                HeaderIcon(system: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .frame(width: HeaderMetrics.height, height: HeaderMetrics.height)
            .modifier(HeaderGlass(shape: Circle()))
            .help("Search").modifier(LinkCursor())
        }
    }

    private func headerIconButton(_ system: String, help: String, on: Bool = false,
                                  _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HeaderIcon(system: system, on: on) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
            .modifier(LinkCursor())
    }

    private var trailingButtons: some View {
        HStack(spacing: Space.s4) {
            if !state.isOnline {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        state.screen = .grid
                        state.filter = .downloaded
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "wifi.slash").font(.system(size: 11, weight: .semibold))
                        Text("Offline").font(.system(size: 12, weight: .semibold))
                    }
                }
                .modifier(GlassButton()).controlSize(.large)
                .help("You're offline — tap to see your downloaded albums")
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
            if !state.isConnected {
                Button { state.connect() } label: {
                    Text("Connect Bandcamp").font(.system(size: 12, weight: .bold))
                }
                .modifier(GlassButton(prominent: true)).controlSize(.large)
            }
            if state.screen == .grid {
                SortMenuButton()
                Button { state.enterSelection(!state.selecting) } label: {
                    Text(state.selecting ? "Done" : "Select").font(.system(size: 12, weight: .semibold))
                }
                .modifier(GlassButton(prominent: state.selecting)).controlSize(.large)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: ipod.device != nil)
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: state.isOnline)
    }
}

/// The view tabs as the native segmented control — in the title bar it gets the system's
/// Liquid Glass toolbar look, exactly like Music's Library / Apple Music / iTunes Store switch.
struct NativeScreenSwitch: View {
    @EnvironmentObject var state: AppState

    private let items: [(String, AppState.Screen)] = [
        ("Crate", .crate), ("Grid", .grid), ("Playlists", .playlists), ("Wishlist", .wishlist)
    ]

    var body: some View {
        // Screens outside the four tabs (settings, recap, iPod) — and search — leave none selected.
        Picker("View", selection: Binding(
            get: { !state.searchOpen && items.contains { $0.1 == state.screen } ? state.screen : nil },
            set: { s in
                guard let s else { return }
                withAnimation(.easeInOut(duration: 0.2)) { state.goTo(s) }
            }
        )) {
            ForEach(items, id: \.1) { Text($0.0).tag(Optional($0.1)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .modifier(LinkCursor())
    }
}

/// Size of the page header's controls — HIG large controls (44pt tall).
enum HeaderMetrics {
    static let height: CGFloat = 44
}

/// One icon in the header's glass button group.
struct HeaderIcon: View {
    let system: String
    var on: Bool = false
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Image(systemName: system)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(on ? p.accent : p.text)
            .frame(width: 40, height: 36)
            .background(Capsule().fill(p.text.opacity(hovering ? 0.10 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Native Liquid Glass behind the header controls (material on macOS 14–15).
struct HeaderGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(p.edgeSoft, lineWidth: 1))
        }
    }
}


/// A clip rectangle with no top edge: clips the sides and bottom, lets content run up past the top.
private struct OpenTopRect: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 10_000, width: rect.width, height: rect.height + 10_000))
    }
}
