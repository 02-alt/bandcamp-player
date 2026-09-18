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
                                if !solo && !firstRun { header }
                                content(solo: solo)
                            }
                            // Flat layout: pull the header up to reclaim the old card's top margin,
                            // keeping just enough clearance for the window's traffic-light buttons.
                            .padding(.horizontal, solo ? Space.s4 : Space.s7)
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
        HStack(spacing: 0) {
            ScreenSwitch()
                .frame(maxWidth: .infinity, alignment: .center)
            // Balances the centred tabs against the trailing cluster, but stays compressible so the
            // header never floors the window width (which would block the narrow "solo" layout).
            Color.clear.frame(maxWidth: 240, maxHeight: 1)
        }
        .overlay(alignment: .trailing) { trailingButtons }
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
                    .foregroundStyle(p.muted)
                    .padding(.vertical, 8).padding(.horizontal, Space.s4)
                    .background(Capsule().fill(p.glassFill))
                    .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                }
                .buttonStyle(.soft)
                .help("You're offline — tap to see your downloaded albums")
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
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
            // Appears (with a spring pop) only while a click-wheel iPod is connected; opens the
            // full-window iPod mode. Highlighted while that mode is showing.
            if ipod.device != nil {
                IPodModeButton()
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
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

/// Circular iPod button in the trailing cluster (replaces the old iPod tab). Toggles the
/// full-window iPod mode on/off, tinted with the accent while that mode is active. Pops in with
/// a spring + a one-shot bounce when an iPod is first connected.
private struct IPodModeButton: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = false

    private var active: Bool { state.screen == .ipod }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                state.screen = active ? .crate : .ipod
            }
        } label: {
            Image(systemName: "ipod")
                .font(.system(size: 14))
                .foregroundStyle(active ? p.accentInk : p.text)
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 36, height: 36)
                .background(Circle().fill(active ? p.accent : p.glassFill))
                .overlay(Circle().strokeBorder(active ? .clear : p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .tip("iPod")
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .onAppear { if !reduceMotion { bounce.toggle() } }
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
    @EnvironmentObject var ipod: IPodWatcher
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
    private var previewScreen: AppState.Screen {
        if let x = dragX { return nearest(toX: x) }
        return state.screen
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
            .padding(3)
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
        // If the iPod is unplugged while its tab is open, fall back to the Crate.
        .onChange(of: ipod.device) { _, dev in
            if dev == nil && state.screen == .ipod { state.screen = .crate }
        }
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
        if let rect = frames[previewScreen] {
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
            withAnimation(Motion.glide) { state.screen = screen }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).fixedSize()
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.vertical, Space.s2).padding(.horizontal, Space.s4)
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
