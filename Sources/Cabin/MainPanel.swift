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

    var body: some View {
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
                                let firstRun = !state.isConnected && state.albums.isEmpty
                                if !solo && !firstRun { compactHeader ? AnyView(compactHeaderBar) : AnyView(header) }
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
                    AlbumDetailView(album: album).transition(.opacity)
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
        // Clip at the panel's real bounds so nothing (e.g. the crate's filter list in a
        // short window) bleeds down over the transparent player bar below.
        .clipped()
    }

    // MARK: Header (replaces the sidebar)

    private var header: some View {
        // Centre the tab switcher in the space LEFT of a fixed reserve for the toolbar buttons.
        // The reserve is constant, so the tabs sit in the same place on every screen (they don't
        // recenter when Grid adds Sort/Select) and always keep clear of the trailing cluster.
        // The view switcher itself lives in the window's title bar (see RootView.titlebarToolbar).
        HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
        .overlay(alignment: .trailing) { trailingButtons }
    }

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
            // Add / iPod / Friends / Search / Settings live in the window's title bar
            // (see RootView.titlebarToolbar).
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: ipod.device != nil)
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: state.isOnline)
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
            Label("Filter", systemImage: state.filter == .all
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
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
struct ScreenSwitch: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ipod: IPodWatcher

    private let items: [(String, AppState.Screen)] = [
        ("Crate", .crate), ("Grid", .grid), ("Playlists", .playlists), ("Wishlist", .wishlist)
    ]

    var body: some View {
        // Screens outside the four tabs (settings, recap, iPod) leave no segment selected.
        Picker("View", selection: Binding(
            get: { !state.searchOpen && items.contains { $0.1 == state.screen } ? state.screen : nil },
            set: { s in
                guard let s else { return }
                withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = false; state.screen = s }
            }
        )) {
            ForEach(items, id: \.1) { Text($0.0).tag(Optional($0.1)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
