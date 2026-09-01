import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Playlists screen: a rail of playlists on the left, the selected playlist's
/// ordered tracks (drag to reorder, swipe/⌫ to remove) on the right.
struct PlaylistsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    private var selected: Playlist? {
        state.playlists.first { $0.id == state.selectedPlaylistID } ?? state.playlists.first
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
                .frame(width: 260)
            Divider().overlay(p.edgeSoft)
            Group {
                if let pl = selected {
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
    }

    // MARK: Left rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("Playlists").font(.system(size: 18, weight: .bold)).kerning(-0.3)
                Spacer()
                Button {
                    let pl = state.createPlaylist()
                    state.selectedPlaylistID = pl.id
                    state.renamingPlaylistID = pl.id
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text).frame(width: 30, height: 30)
                        .glass(in: Circle(), interactive: true)
                }.buttonStyle(.soft).help("New playlist")
            }
            .padding(.horizontal, Space.s2)

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
                            PlaylistRailRow(playlist: pl,
                                            selected: pl.id == (selected?.id))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(Space.s4)
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
                PlaylistMosaic(tracks: playlist.coverTracks, side: 40, custom: playlist.coverImageData)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text).lineLimit(1)
                    Text("\(playlist.tracks.count) track\(playlist.tracks.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(p.muted2)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            header
            if playlist.tracks.isEmpty {
                VStack(spacing: Space.s2) {
                    Text("This playlist is empty").font(.system(size: 14, weight: .medium)).foregroundStyle(p.muted)
                    Text("Right-click an album → “Add to playlist”.").font(.system(size: 12)).foregroundStyle(p.muted2)
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
            PlaylistMosaic(tracks: playlist.coverTracks, side: 116, custom: playlist.coverImageData)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                .overlay(alignment: .bottomTrailing) {
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
                .contextMenu {
                    Button("Change cover…") { pickCover() }
                    if playlist.coverImageData != nil {
                        Button("Remove custom cover") { state.setPlaylistCover(playlist.id, data: nil) }
                    }
                }
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("PLAYLIST").font(.system(size: 11, weight: .bold)).kerning(1.5).foregroundStyle(p.muted2)
                if isRenaming {
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
                        .onTapGesture(count: 2) { state.renamingPlaylistID = playlist.id }
                }
                Text("\(playlist.tracks.count) track\(playlist.tracks.count == 1 ? "" : "s")")
                    .font(.system(size: 13)).foregroundStyle(p.muted)

                HStack(spacing: Space.s3) {
                    Button { state.playPlaylist(playlist, on: player) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 12))
                            Text("Play").font(.system(size: 13, weight: .bold))
                        }
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
                        .foregroundStyle(p.muted)
                        .padding(.vertical, 9).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                    }
                    .buttonStyle(.soft).disabled(playlist.tracks.isEmpty)
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
            .onMove { from, to in state.moveInPlaylist(playlist.id, from: from, to: to) }
            .onDelete { offsets in state.removeFromPlaylist(playlist.id, at: offsets) }
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
                    Image(systemName: "music.note").font(.system(size: side * 0.34)).foregroundStyle(p.muted2)
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
