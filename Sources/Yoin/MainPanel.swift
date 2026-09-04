import SwiftUI
import AppKit

struct MainPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @AppStorage("ambientTheming") private var ambientTheming = true

    var body: some View {
        ZStack {
            Group {
                if state.screen == .settings {
                    SettingsView()
                } else if state.screen == .recap {
                    RecapView()
                } else {
                    VStack(spacing: Space.s5) {
                        header
                        content
                    }
                    .padding(Space.s7)
                }
            }

            if let artist = state.openedArtist {
                ArtistView(name: artist).transition(.opacity)
            }

            if let album = state.openedAlbum {
                AlbumDetailView(album: album).transition(.opacity)
            }

            if state.searchOpen {
                SearchOverlay().transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .glass(glow: true, tint: ambientTheming ? state.ambient : nil)
    }

    // MARK: Header (replaces the sidebar)

    private var header: some View {
        // Centre the tab switcher in the space LEFT of a fixed reserve for the toolbar buttons.
        // The reserve is constant, so the tabs sit in the same place on every screen (they don't
        // recenter when Grid adds Sort/Select) and always keep clear of the trailing cluster.
        HStack(spacing: 0) {
            ScreenSwitch()
                .frame(maxWidth: .infinity, alignment: .center)
            Color.clear.frame(width: 240, height: 1)
        }
        .overlay(alignment: .trailing) { trailingButtons }
    }

    private var trailingButtons: some View {
        HStack(spacing: Space.s4) {
            if !state.isConnected {
                Button { state.connect() } label: {
                    Text("Connect Bandcamp").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(p.accentInk)
                        .padding(.vertical, 8).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(p.accent))
                }.buttonStyle(.soft)
            }
            if state.screen == .grid {
                SortMenuButton()
                Button { state.enterSelection(!state.selecting) } label: {
                    Text(state.selecting ? "Done" : "Select")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.selecting ? p.accentInk : p.muted)
                        .padding(.vertical, 8).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(state.selecting ? p.accent : p.glassFill))
                        .overlay(Capsule().strokeBorder(state.selecting ? .clear : p.edgeSoft, lineWidth: 1))
                }.buttonStyle(.soft)
            }
            PlusMenuButton()
            if state.isConnected {
                IconButton(system: "person.2", label: "Friends", tip: "Friends") { state.openFriends() }
            }
            IconButton(system: "magnifyingglass", label: "Search", tip: "Search") {
                withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = true }
            }
            IconButton(system: "gearshape", label: "Settings", tip: "Settings") {
                withAnimation(.easeInOut(duration: 0.15)) { state.screen = .settings }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.screen {
        case .crate:     CrateView()
        case .grid:      GridView()
        case .playlists: PlaylistsView()
        case .wishlist:  WishlistView()
        case .ipod:      IPodView()
        case .recap, .settings: EmptyView()
        }
    }
}

/// The "+" button: looks like the other circular icon buttons, but opens the app's
/// custom rounded menu (add music / sync Bandcamp) anchored beneath it on left-click.
private struct PlusMenuButton: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @State private var frame: CGRect = .zero

    var body: some View {
        IconButton(system: "plus", label: "Add music", tip: "Add music") { open() }
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { frame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in frame = f }
                }
            )
    }

    private func open() {
        var items: [AppMenuItem] = [
            AppMenuItem(title: "Import files or folder…", systemImage: "folder") { state.pickAndImport() },
            AppMenuItem(title: "Import from Apple Music…", systemImage: "music.note") { state.importFromAppleMusic() },
            .divider(),
            AppMenuItem(title: "Discover on Bandcamp…", systemImage: "safari") {
                NSWorkspace.shared.open(URL(string: "https://bandcamp.com/discover")!)
            },
            .divider(),
        ]
        if state.isConnected {
            items.append(AppMenuItem(title: state.sync == .syncing ? "Syncing Bandcamp…" : "Sync Bandcamp",
                                     systemImage: "arrow.triangle.2.circlepath") {
                Task { await state.syncBandcamp(announce: true) }
            })
        } else {
            items.append(AppMenuItem(title: "Connect Bandcamp…", systemImage: "link") { state.connect() })
        }
        state.showMenu(items, at: CGPoint(x: frame.minX, y: frame.maxY + 6))
    }
}

/// The grid's sort control: a circular icon button that opens the app-styled menu
/// with the ordering options (Added / Artist / Title / Year), a checkmark on the active one.
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

/// Segmented switch for the collection views (was the sidebar nav).
struct ScreenSwitch: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ipod: IPodWatcher
    @Environment(\.palette) private var p
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 3) {
            segment("Crate", .crate)
            segment("Grid", .grid)
            segment("Playlists", .playlists)
            segment("Wishlist", .wishlist)
            // The iPod tab only exists while a click-wheel iPod is connected.
            if ipod.device != nil {
                segment("iPod", .ipod)
            }
        }
        .padding(3)
        .background(Capsule().fill(p.glassFill))
        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
        // If the iPod is unplugged while its tab is open, fall back to the Crate.
        .onChange(of: ipod.device) { _, dev in
            if dev == nil && state.screen == .ipod { state.screen = .crate }
        }
    }

    private func segment(_ label: String, _ screen: AppState.Screen) -> some View {
        let on = state.screen == screen
        return Button {
            withAnimation(Motion.glide) { state.screen = screen }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).fixedSize()
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.vertical, Space.s2).padding(.horizontal, Space.s4)
                .background {
                    // The selected pill is a single shape that glides between segments.
                    if on {
                        Capsule().fill(p.glassFill)
                            .overlay(Capsule().strokeBorder(p.edge, lineWidth: 1))
                            .matchedGeometryEffect(id: "screenPill", in: ns)
                    }
                }
                .contentShape(Capsule())
                .hoverHighlight(active: on)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
