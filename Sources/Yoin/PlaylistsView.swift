import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The two halves of the Playlists screen, toggled by the header segmented control.
enum LibraryRailMode { case playlists, radio }

/// The Playlists screen: a rail of playlists on the left, the selected playlist's
/// ordered tracks (drag to reorder, swipe/⌫ to remove) on the right.
struct PlaylistsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    /// Global frame of the "+" button, so the create menu anchors under it.
    @State private var plusFrame: CGRect = .zero
    /// Which half of this screen is showing — Playlists or Radio.
    @State private var mode: LibraryRailMode = .playlists

    private var selected: Playlist? {
        if state.selectedPlaylistID == AppState.likedSongsID { return state.likedSongsPlaylist }
        return state.playlists.first { $0.id == state.selectedPlaylistID } ?? state.playlists.first
    }

    // MARK: New-playlist menu (app-styled, with month/year flyouts)

    private func createMenuItems() -> [AppMenuItem] {
        var items: [AppMenuItem] = [
            AppMenuItem(title: "Empty playlist", systemImage: "music.note.list") {
                let pl = state.createPlaylist()
                state.selectedPlaylistID = pl.id
                state.renamingPlaylistID = pl.id
            },
            .divider(),
            AppMenuItem(title: "Rarely played", systemImage: "sparkles") {
                state.createSmartPlaylist(.rarelyPlayed)
            }
        ]
        let (months, years) = periodMenuItems()
        var month = AppMenuItem(title: "Best of month…", systemImage: "trophy") {}
        month.submenu = months
        items.append(month)
        var year = AppMenuItem(title: "Best of year…", systemImage: "trophy.fill") {}
        year.submenu = years
        items.append(year)
        return items
    }

    /// Every month / year you've actually listened in (most recent first), plus the current
    /// period so the menu is never empty on a fresh library.
    private func periodMenuItems() -> (months: [AppMenuItem], years: [AppMenuItem]) {
        let cal = Calendar.current
        var monthKeys = Set<Int>()   // year * 100 + month
        var yearKeys = Set<Int>()
        for e in HistoryStore.load() where e.isRealListen {
            let c = cal.dateComponents([.year, .month], from: e.date)
            if let y = c.year, let m = c.month { monthKeys.insert(y * 100 + m); yearKeys.insert(y) }
        }
        let nowC = cal.dateComponents([.year, .month], from: Date())
        if let y = nowC.year, let m = nowC.month { monthKeys.insert(y * 100 + m); yearKeys.insert(y) }

        let months = monthKeys.sorted(by: >).map { key -> AppMenuItem in
            let y = key / 100, m = key % 100
            return AppMenuItem(title: "\(SmartRule.monthName(m)) \(y)", systemImage: "calendar") {
                state.createSmartPlaylist(.bestOf(year: y, month: m))
            }
        }
        let years = yearKeys.sorted(by: >).map { y in
            AppMenuItem(title: "\(y)", systemImage: "calendar") {
                state.createSmartPlaylist(.bestOf(year: y, month: nil))
            }
        }
        return (months, years)
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
                .frame(width: 260)
            Divider().overlay(p.edgeSoft)
            Group {
                if mode == .radio {
                    RadioDetail()
                } else if let pl = selected {
                    PlaylistDetail(playlist: pl)
                } else {
                    emptyDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if state.selectedPlaylistID == nil { state.selectedPlaylistID = state.playlists.first?.id }
        }
        .task { await state.rebuildSmartPlaylistsIfStale() }
    }

    /// Playlists ⟷ Radio header switch (sits where the screen title was).
    private var modeToggle: some View {
        HStack(spacing: 2) {
            ForEach([("Playlists", LibraryRailMode.playlists), ("Radio", .radio)], id: \.0) { title, m in
                let on = mode == m
                Button { withAnimation(Motion.glide) { mode = m } } label: {
                    Text(title).font(.system(size: 14, weight: .bold)).kerning(-0.2)
                        .foregroundStyle(on ? p.text : p.muted2)
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        .background(Capsule().fill(on ? p.glassFill : .clear))
                }.buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
            }
        }
    }

    // MARK: Left rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                modeToggle
                Spacer()
                if mode == .playlists {
                    Button {
                        state.showMenu(createMenuItems(), at: CGPoint(x: plusFrame.minX, y: plusFrame.maxY + 6))
                    } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.text).frame(width: 30, height: 30)
                            .glass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.soft).help("New playlist")
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { plusFrame = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, f in plusFrame = f }
                    })
                }
            }
            .padding(.horizontal, Space.s2)

            if mode == .playlists { playlistsRail } else { SavedRadiosRail() }
        }
        .padding(Space.s4)
    }

    @ViewBuilder private var playlistsRail: some View {
        likedRow
        if state.playlists.isEmpty {
            Text("No playlists yet.\nRight-click any album →\n“Add to playlist”.")
                .font(.system(size: 12)).foregroundStyle(p.muted2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.s2).padding(.top, Space.s3)
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(state.playlists) { pl in
                        PlaylistRailRow(playlist: pl, selected: pl.id == (selected?.id))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The pinned "Liked Songs" row (a virtual playlist).
    private var likedRow: some View {
        let isSel = state.selectedPlaylistID == AppState.likedSongsID
        return Button { state.selectedPlaylistID = AppState.likedSongsID } label: {
            HStack(spacing: Space.s3) {
                PlaylistMosaic(tracks: state.likedSongsPlaylist.coverTracks, side: 40, symbol: "heart.fill")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Liked Songs").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text("\(state.likedTracks.count) song\(state.likedTracks.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(p.muted2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(p.glassFill).opacity(isSel ? 1 : 0))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSel ? p.edge : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
    }

    private var emptyDetail: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "music.note.list").font(.system(size: 34)).foregroundStyle(p.muted2)
            Text("Create a playlist to get started")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(p.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rail row

private struct PlaylistRailRow: View {
    let playlist: Playlist
    let selected: Bool
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button { state.selectedPlaylistID = playlist.id } label: {
            HStack(spacing: Space.s3) {
                PlaylistMosaic(tracks: playlist.coverTracks, side: 40, custom: playlist.coverImageData, symbol: playlist.smart?.symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text).lineLimit(1)
                    HStack(spacing: 4) {
                        if playlist.isSmart {
                            Image(systemName: "sparkles").font(.system(size: 8))
                            Text("Auto ·").font(.system(size: 11))
                        }
                        Text("\(playlist.tracks.count) track\(playlist.tracks.count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(p.muted2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(p.glassFill).opacity(selected ? 1 : (hovering ? 0.5 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? p.edge : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .onHover { hovering = $0 }
        .appContextMenu {
            [AppMenuItem(title: "Rename", systemImage: "pencil") { state.renamingPlaylistID = playlist.id; state.selectedPlaylistID = playlist.id },
             AppMenuItem(title: "Delete playlist", systemImage: "trash", role: .destructive, holdToConfirm: true) { state.deletePlaylist(playlist.id) }]
        }
    }
}

// MARK: - Detail pane

/// Wraps a picked image for the cover crop sheet so `.sheet(item:)` always has content.
private struct CoverCropRequest: Identifiable {
    let id = UUID()
    let image: NSImage
}

private struct PlaylistDetail: View {
    let playlist: Playlist
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @FocusState private var nameFocused: Bool
    @State private var draftName = ""
    @State private var coverCrop: CoverCropRequest?

    private var isRenaming: Bool { state.renamingPlaylistID == playlist.id }
    private var isLikedList: Bool { playlist.id == AppState.likedSongsID }
    /// Smart playlists and Liked Songs aren't hand-editable (no rename/cover/reorder).
    private var isReadOnly: Bool { playlist.isSmart || isLikedList }
    private var headerSymbol: String? { isLikedList ? "heart.fill" : playlist.smart?.symbol }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            header
            if playlist.tracks.isEmpty {
                VStack(spacing: Space.s2) {
                    Text(isLikedList ? "No liked songs yet" : "This playlist is empty")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(p.muted)
                    Text(playlist.isSmart ? "It fills in automatically as you listen."
                         : isLikedList ? "Tap the heart on any song to add it here."
                         : "Right-click an album → “Add to playlist”.")
                        .font(.system(size: 12)).foregroundStyle(p.muted2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                trackList
            }
        }
        .padding(Space.s6)
        .sheet(item: $coverCrop) { req in
            ProfileCropSheet(image: req.image, square: true, title: "Crop cover",
                             onCancel: { coverCrop = nil },
                             onCrop: { data in
                state.setPlaylistCover(playlist.id, data: data)
                coverCrop = nil
            })
            .environment(\.palette, p)
        }
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            coverCrop = CoverCropRequest(image: img)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Space.s5) {
            PlaylistMosaic(tracks: playlist.coverTracks, side: 116, custom: playlist.coverImageData, symbol: headerSymbol)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                .overlay(alignment: .bottomTrailing) {
                    if !isReadOnly {
                        Button { pickCover() } label: {
                            Image(systemName: "camera.fill").font(.system(size: 11))
                                .foregroundStyle(p.accentInk)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(p.accent))
                                .overlay(Circle().strokeBorder(p.page, lineWidth: 2))
                        }
                        .buttonStyle(.soft).offset(x: 4, y: 4)
                        .help("Change cover")
                    }
                }
                .contextMenu {
                    if !isReadOnly {
                        Button("Change cover…") { pickCover() }
                        if playlist.coverImageData != nil {
                            Button("Remove custom cover") { state.setPlaylistCover(playlist.id, data: nil) }
                        }
                    }
                }
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(isLikedList ? "LIKED SONGS" : playlist.isSmart ? "SMART PLAYLIST" : "PLAYLIST")
                    .font(.system(size: 11, weight: .bold)).kerning(1.5).foregroundStyle(p.muted2)
                if isRenaming && !isReadOnly {
                    TextField("Playlist name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .bold)).kerning(-0.5)
                        .foregroundStyle(p.text)
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .onAppear { draftName = playlist.name; nameFocused = true }
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                } else {
                    Text(playlist.name).font(.system(size: 30, weight: .bold)).kerning(-0.5)
                        .foregroundStyle(p.text).lineLimit(2)
                        .onTapGesture(count: 2) { if !isReadOnly { state.renamingPlaylistID = playlist.id } }
                }
                Text(playlist.smart?.blurb
                     ?? (isLikedList ? "\(playlist.tracks.count) song\(playlist.tracks.count == 1 ? "" : "s")"
                         : "\(playlist.tracks.count) track\(playlist.tracks.count == 1 ? "" : "s")"))
                    .font(.system(size: 13)).foregroundStyle(p.muted)

                HStack(spacing: Space.s3) {
                    Button { state.playPlaylist(playlist, on: player) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 12))
                            Text("Play").font(.system(size: 13, weight: .bold))
                        }
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(p.accentInk)
                        .padding(.vertical, 9).padding(.horizontal, Space.s5)
                        .background(Capsule().fill(p.accent))
                    }
                    .buttonStyle(.soft).disabled(playlist.tracks.isEmpty)

                    Button {
                        player.shuffle = true
                        state.playPlaylist(playlist, on: player)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle").font(.system(size: 12))
                            Text("Shuffle").font(.system(size: 13, weight: .bold))
                        }
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(p.muted)
                        .padding(.vertical, 9).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                    }
                    .buttonStyle(.soft).disabled(playlist.tracks.isEmpty)

                    if playlist.isSmart {
                        let rebuilding = state.rebuildingSmart.contains(playlist.id)
                        Button { Task { await state.rebuildSmartPlaylist(playlist.id) } } label: {
                            Group {
                                if rebuilding {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .foregroundStyle(p.muted)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(p.glassFill))
                            .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                        }
                        .buttonStyle(.soft).disabled(rebuilding).help("Refresh")
                    }
                }
                .padding(.top, Space.s2)
            }
            Spacer()
        }
    }

    private var trackList: some View {
        List {
            ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { i, track in
                PlaylistTrackRow(index: i, track: track) {
                    state.playPlaylist(playlist, on: player, startAt: i)
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .onMove { from, to in if !isReadOnly { state.moveInPlaylist(playlist.id, from: from, to: to) } }
            .onDelete { offsets in
                if isLikedList { state.unlikeSongs(at: offsets) }
                else if !playlist.isSmart { state.removeFromPlaylist(playlist.id, at: offsets) }
            }
            .moveDisabled(isReadOnly)
            .deleteDisabled(playlist.isSmart)   // Liked Songs allows swipe-to-remove (= unlike)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
    }

    private func commitName() {
        if !draftName.trimmingCharacters(in: .whitespaces).isEmpty {
            state.renamePlaylist(playlist.id, to: draftName)
        }
        state.renamingPlaylistID = nil
    }
}

private struct PlaylistTrackRow: View {
    let index: Int
    let track: PlaylistTrack
    let onPlay: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: Space.s3) {
                ZStack {
                    Text("\(index + 1)").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(p.muted2).opacity(hovering ? 0 : 1)
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .foregroundStyle(p.text).opacity(hovering ? 1 : 0)
                }
                .frame(width: 22)
                PlaylistMosaic(tracks: [track], side: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(p.text).lineLimit(1)
                    Text("\(track.artist) · \(track.albumTitle)")
                        .font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(p.glassFill).opacity(hovering ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .onHover { hovering = $0 }
    }
}

// MARK: - Cover mosaic

/// A stacked 1–4 cover mosaic that stands in for a playlist's artwork.
struct PlaylistMosaic: View {
    let tracks: [PlaylistTrack]
    let side: CGFloat
    var custom: Data? = nil
    /// When set (smart playlist / liked songs), the empty state uses this SF Symbol and a
    /// matching badge is stamped in the corner once there are covers.
    var symbol: String? = nil
    @Environment(\.palette) private var p

    var body: some View {
        let covers = Array(tracks.prefix(4))
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(p.glassFill)
            .frame(width: side, height: side)
            .overlay {
                if let custom, let img = NSImage(data: custom) {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: side, height: side)
                } else if covers.isEmpty {
                    Image(systemName: symbol ?? "music.note")
                        .font(.system(size: side * 0.3)).foregroundStyle(p.muted2)
                } else if covers.count < 4 {
                    cover(covers[0])
                } else {
                    let cols = [GridItem(.fixed(side / 2), spacing: 0), GridItem(.fixed(side / 2), spacing: 0)]
                    LazyVGrid(columns: cols, spacing: 0) {
                        ForEach(covers) { t in cover(t).frame(width: side / 2, height: side / 2) }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let symbol, !covers.isEmpty, custom == nil {
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(side * 0.09)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(side * 0.05)
                }
            }
    }

    @ViewBuilder
    private func cover(_ t: PlaylistTrack) -> some View {
        let gradient = LinearGradient(colors: [Color(white: t.g0), Color(white: t.g1)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        Rectangle().fill(gradient)
            .overlay {
                if let data = t.artworkData, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else if let url = t.artworkURL {
                    CachedRemoteImage(url: url) { Color.clear }
                }
            }
            .clipped()
    }
}
