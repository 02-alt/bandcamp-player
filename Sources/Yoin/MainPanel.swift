import SwiftUI

struct MainPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

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

            if let album = state.openedAlbum {
                AlbumDetailView(album: album).transition(.opacity)
            }

            if state.searchOpen {
                SearchOverlay().transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .glass(glow: true)
    }

    // MARK: Header (replaces the sidebar)

    private var header: some View {
        HStack(spacing: Space.s4) {
            Spacer()

            ScreenSwitch()

            Spacer()

            if !state.isConnected {
                Button { state.connect() } label: {
                    Text("Connect Bandcamp").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(p.accentInk)
                        .padding(.vertical, 8).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(p.accent))
                }.buttonStyle(.soft)
            }
            if state.screen == .grid {
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
            IconButton(system: "magnifyingglass") {
                withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = true }
            }
            IconButton(system: "gearshape") {
                withAnimation(.easeInOut(duration: 0.15)) { state.screen = .settings }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.screen {
        case .crate:     CrateView()
        case .grid:      GridView()
        case .artists:   ArtistsView()
        case .playlists: PlaylistsView()
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
        IconButton(system: "plus") { open() }
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

/// Segmented switch for the three collection views (was the sidebar nav).
struct ScreenSwitch: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 3) {
            segment("Crate", .crate)
            segment("Grid", .grid)
            segment("Artists", .artists)
            segment("Playlists", .playlists)
        }
        .padding(3)
        .background(Capsule().fill(p.glassFill))
        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
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
                .padding(.vertical, 6).padding(.horizontal, 14)
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
    }
}
