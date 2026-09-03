import SwiftUI

struct GridView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: Space.s6)]

    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: Space.s4) {
            FilterChips()
            ScrollView {
                let albums = state.visibleAlbums
                if albums.isEmpty {
                    Text("Nothing here yet").font(.system(size: 14)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                if state.sort == .artist {
                    groupedGrid(albums)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s6) {
                        ForEach(albums) { album in
                            AlbumCard(album: album)
                        }
                    }
                    .padding(.top, Space.s2)
                    .padding(.bottom, state.selecting ? 72 : 0)   // room for the action bar
                }
            }
            .scrollIndicators(.hidden)
        }
        .task { if state.isConnected { await state.buildFriendOwnership() } }
        .overlay(alignment: .bottom) {
            if state.selecting { selectionBar }
        }
        .background { shortcuts }
        .confirmationDialog("Remove \(state.selection.count) album\(state.selection.count == 1 ? "" : "s") from your library?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove \(state.selection.count)", role: .destructive) { state.deleteSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("They're removed from Yoin only — your audio files stay on disk, and removed Bandcamp albums can be restored from Settings.")
        }
    }

    /// Albums already sorted by artist, split into consecutive per-artist groups.
    private func artistGroups(_ albums: [Album]) -> [(name: String, albums: [Album])] {
        var groups: [(name: String, albums: [Album])] = []
        for album in albums {
            if groups.last?.name == album.artist {
                groups[groups.count - 1].albums.append(album)
            } else {
                groups.append((name: album.artist, albums: [album]))
            }
        }
        return groups
    }

    /// Grid grouped by artist, each section led by a big Apple-Music-style title (the
    /// folded-in Artists view). Headers scroll with the content rather than pinning.
    @ViewBuilder private func groupedGrid(_ albums: [Album]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s6) {
            ForEach(Array(artistGroups(albums).enumerated()), id: \.offset) { index, group in
                Section {
                    ForEach(group.albums) { album in
                        AlbumCard(album: album)
                    }
                } header: {
                    artistHeader(group.name, first: index == 0)
                }
            }
        }
        .padding(.bottom, state.selecting ? 72 : 0)   // room for the action bar
    }

    private func artistHeader(_ name: String, first: Bool) -> some View {
        Text(name)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(p.text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, first ? Space.s2 : Space.s6)
            .padding(.bottom, Space.s2)
            .appContextMenu {
                [AppMenuItem(title: "Start radio", systemImage: "dot.radiowaves.left.and.right") {
                    state.startRadioForArtist(name, on: player)
                }]
            }
    }

    /// Hidden buttons that back the keyboard shortcuts (Delete / ⌘A / Esc).
    @ViewBuilder private var shortcuts: some View {
        Button("") {
            if state.selecting && !state.selection.isEmpty { confirmDelete = true }
        }.keyboardShortcut(.delete, modifiers: []).hidden()

        Button("") {
            if state.selecting { state.selectAllVisible() }
        }.keyboardShortcut("a", modifiers: .command).hidden()

        Button("") {
            if state.selecting { state.enterSelection(false) }
        }.keyboardShortcut(.escape, modifiers: []).hidden()
    }

    /// Floating bar with the selection count and bulk actions.
    private var selectionBar: some View {
        HStack(spacing: Space.s3) {
            Text("\(state.selection.count) selected")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
            Spacer()
            Button("Select all") { state.selectAllVisible() }
                .buttonStyle(.soft).foregroundStyle(p.muted).font(.system(size: 12, weight: .semibold))
            Button { state.enrichSelection(state.selection) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.2").font(.system(size: 12))
                    Text("Find credits").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(p.text)
                .padding(.vertical, 9).padding(.horizontal, Space.s4)
                .background(Capsule().fill(p.glassFill))
                .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
            }
            .buttonStyle(.soft)
            .disabled(state.selection.isEmpty)
            Button { confirmDelete = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 12))
                    Text("Delete").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 9).padding(.horizontal, Space.s4)
                .background(Capsule().fill(Color.red.opacity(state.selection.isEmpty ? 0.35 : 0.9)))
            }
            .buttonStyle(.soft)
            .disabled(state.selection.isEmpty)
        }
        .padding(.vertical, Space.s3).padding(.horizontal, Space.s5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(p.edge, lineWidth: 1))
        .padding(.bottom, Space.s4)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A single grid cover: lifts toward the cursor on hover and reveals a play button.
private struct AlbumCard: View {
    let album: Album
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var hovering = false

    private var selected: Bool { state.selection.contains(album.id) }

    var body: some View {
        Button {
            if state.selecting { state.toggleSelect(album.id) }
            else { state.openedAlbumID = album.id }
        } label: {
            VStack(alignment: .leading, spacing: Space.s3) {
                AlbumArt(album: album)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        if album.isFavourite && !state.selecting { favBadge }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !state.selecting {
                            let owners = state.owners(of: album)
                            if !owners.isEmpty {
                                OwnersMacaron(owners: owners).padding(Space.s2)
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if !state.selecting { downloadControl(album) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if state.selecting { selectionBadge }
                    }
                    .overlay { if !state.selecting { hoverPlay } }
                    .overlay {
                        if state.selecting && selected {
                            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                .strokeBorder(p.accent, lineWidth: 3)
                        }
                    }
                    .scaleEffect(hovering && !state.selecting ? 1.035 : 1)
                    .shadow(color: .black.opacity(hovering ? 0.5 : 0.3),
                            radius: hovering ? 22 : 14, y: hovering ? 16 : 10)
                    .animation(Motion.lift, value: hovering)
                    .opacity(state.selecting && !selected ? 0.6 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(album.artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .onHover { hovering = $0 }
        .appContextMenu { albumMenuItems(for: album, state: state, player: player) }
    }

    /// Check/circle shown in the top-right of each cover while selecting.
    private var selectionBadge: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(selected ? p.accent : .white.opacity(0.9))
            .background(Circle().fill(selected ? .white : .black.opacity(0.35)).padding(3))
            .padding(Space.s2)
    }

    /// Play button that fades up from the cover on hover.
    @ViewBuilder private var hoverPlay: some View {
        if album.isPlayable {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(.black.opacity(hovering ? 0.28 : 0))
                Button { state.play(album, on: player) } label: {
                    Image(systemName: "play.fill").font(.system(size: 16))
                        .foregroundStyle(p.accentInk)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(p.accent))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(.soft)
                .scaleEffect(hovering ? 1 : 0.6)
                .opacity(hovering ? 1 : 0)
            }
            .animation(Motion.lift, value: hovering)
            .allowsHitTesting(hovering)
        }
    }

    private var favBadge: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 11))
            .foregroundStyle(p.accentInk)
            .frame(width: 28, height: 28)
            .background(Circle().fill(p.accent))
            .padding(Space.s2)
    }

    @ViewBuilder
    private func downloadControl(_ album: Album) -> some View {
        let badge: (Image, Bool) -> AnyView = { image, spinning in
            AnyView(
                ZStack {
                    Circle().fill(.ultraThinMaterial).overlay(Circle().strokeBorder(p.edge, lineWidth: 1))
                    if spinning { OrbLoader(size: 64) }
                    else { image.font(.system(size: 12)).foregroundStyle(p.text) }
                }
                .frame(width: 30, height: 30).padding(Space.s2)
            )
        }
        switch state.downloads[album.id] {
        case .downloading:
            badge(Image(systemName: "arrow.down"), true)
        case .done:
            badge(Image(systemName: "checkmark"), false)
        case .failed:
            Button { state.download(album) } label: { badge(Image(systemName: "exclamationmark.arrow.circlepath"), false) }
                .buttonStyle(.soft)
        case nil:
            if album.isDownloaded {
                badge(Image(systemName: "checkmark"), false)
            } else if album.canDownload {
                Button { state.download(album) } label: { badge(Image(systemName: "arrow.down"), false) }
                    .buttonStyle(.soft)
            }
        }
    }
}

/// Horizontal filter chips for the Grid (All / Favourites / Downloaded / Bandcamp / Imported).
struct FilterChips: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Namespace private var ns

    private let rows: [(AppState.Filter, String)] = [
        (.all, "All"), (.favourites, "Favourites"), (.downloaded, "Downloaded"),
        (.bandcamp, "Bandcamp"), (.imported, "Imported")
    ]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.s2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    let on = state.filter == r.0
                    Button {
                        withAnimation(Motion.glide) { state.filter = r.0 }
                    } label: {
                        HStack(spacing: 5) {
                            Text(r.1).font(.system(size: 12, weight: .semibold))
                            Text("\(state.count(for: r.0))").font(.system(size: 11)).foregroundStyle(on ? p.accentInk.opacity(0.7) : p.muted2)
                        }
                        .foregroundStyle(on ? p.accentInk : p.muted)
                        .padding(.vertical, 7).padding(.horizontal, Space.s3)
                        .background {
                            if on {
                                Capsule().fill(p.accent).matchedGeometryEffect(id: "filterChip", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                        .hoverHighlight(active: on)
                    }
                    .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}
