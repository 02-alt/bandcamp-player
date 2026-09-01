import SwiftUI

/// Full album screen — cover, info, actions, and the tracklist.
struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var creditsShown = false
    @State private var editShown = false
    @State private var trackRef: TrackRef?
    @State private var coverZoomed = false
    @Namespace private var coverNS

    /// Identifies a track for the per-track credits sheet.
    private struct TrackRef: Identifiable { let id = UUID(); let title: String; let index: Int }

    private var isCurrentAlbum: Bool { state.nowPlayingAlbumID == album.id }
    /// The live album from state, so cover/title/credits update as enrichment lands.
    private var live: Album { state.albums.first { $0.id == album.id } ?? album }

    var body: some View {
        ZStack(alignment: .top) {
            p.page.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Space.s6) {
                // Header row
                HStack {
                    Button { state.openedAlbumID = nil } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                            Text("Back").font(.system(size: 13, weight: .semibold))
                        }.foregroundStyle(p.muted)
                    }.buttonStyle(.soft)
                    Spacer()
                }

                // Cover + info
                HStack(alignment: .bottom, spacing: Space.s6) {
                    ZStack {
                        Color.clear.frame(width: 220, height: 220)   // reserves layout while zoomed
                        if !coverZoomed {
                            AlbumArt(album: live, corner: 18)
                                .frame(width: 220, height: 220)
                                .matchedGeometryEffect(id: "albumCover", in: coverNS)
                                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                                .modifier(LinkCursor())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                        coverZoomed = true
                                    }
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text(live.source == .bandcamp ? "BANDCAMP ALBUM" : "IN YOUR LIBRARY")
                            .font(.system(size: 11)).kerning(1).foregroundStyle(p.muted2)
                        Text(live.title).font(.system(size: 34, weight: .bold)).kerning(-0.6)
                            .lineLimit(2).truncationMode(.tail)
                        Text(live.year.isEmpty ? live.artist : "\(live.artist) · \(live.year)")
                            .font(.system(size: 15)).foregroundStyle(p.muted)

                        HStack(spacing: Space.s2) {
                            if live.lossless { Pill(text: live.isDownloaded ? "FLAC · OFFLINE" : "LOSSLESS", filled: true) }
                            Pill(text: live.format)
                        }.padding(.top, 2)

                        HStack(spacing: Space.s3) {
                            Button { state.play(live, on: player) } label: {
                                HStack(spacing: Space.s2) {
                                    Image(systemName: "play.fill").font(.system(size: 12))
                                    Text("Play").font(.system(size: 13, weight: .bold))
                                }
                                .foregroundStyle(p.accentInk)
                                .padding(.vertical, 11).padding(.horizontal, Space.s5)
                                .background(Capsule().fill(p.accent))
                            }
                            .buttonStyle(.soft)
                            .opacity(live.isPlayable ? 1 : 0.4).disabled(!live.isPlayable)

                            circleButton(live.isFavourite ? "heart.fill" : "heart", bounce: live.isFavourite) { state.toggleFavourite(live.id) }
                            downloadButton

                            Button { creditsShown = true } label: {
                                HStack(spacing: Space.s2) {
                                    Image(systemName: "person.2.fill").font(.system(size: 12))
                                    Text("Credits").font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(p.text)
                                .padding(.vertical, 11).padding(.horizontal, Space.s4)
                                .background(Capsule().fill(p.glassFill))
                                .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                            }
                            .buttonStyle(.soft)
                        }.padding(.top, Space.s3)
                    }
                    Spacer()
                }

                Divider().overlay(p.edgeSoft)

                // Tracklist
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        HStack {
                            Text("TRACKS").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                            Spacer()
                            Text("Right-click a track for its credits")
                                .font(.system(size: 11)).foregroundStyle(p.muted2)
                        }
                        if loading {
                            OrbLoadingRow(text: "Loading tracks…", size: 64)
                        } else if tracks.isEmpty {
                            Text("Couldn't load tracks for this album.")
                                .font(.system(size: 13)).foregroundStyle(p.muted)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                                    trackRow(i, track)
                                }
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            .padding(Space.s7)

            // Tap-to-zoom cover lightbox.
            if coverZoomed {
                GeometryReader { geo in
                    let side = min(min(geo.size.width, geo.size.height) - 120, 640)
                    ZStack {
                        Rectangle().fill(.black.opacity(0.82)).ignoresSafeArea()
                            .transition(.opacity)
                        AlbumArt(album: live, corner: 28)
                            .frame(width: max(side, 200), height: max(side, 200))
                            .matchedGeometryEffect(id: "albumCover", in: coverNS)
                            .shadow(color: .black.opacity(0.6), radius: 50, y: 24)
                            .modifier(LinkCursor())
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                            coverZoomed = false
                        }
                    }
                }
                .zIndex(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .task(id: album.id) { await load() }
        .sheet(isPresented: $creditsShown) {
            CreditsSheet(albumID: album.id)
                .environment(\.palette, p).environmentObject(state)
        }
        .sheet(item: $trackRef) { ref in
            TrackCreditsSheet(albumID: album.id, title: ref.title, index: ref.index)
                .environment(\.palette, p).environmentObject(state)
        }
        .sheet(isPresented: $editShown) {
            EditDetailsSheet(albumID: album.id)
                .environment(\.palette, p).environmentObject(state)
        }
        .onAppear { consumeEditRequest() }
        .onChange(of: state.editRequestID) { _, _ in consumeEditRequest() }
    }

    /// Auto-open the Edit sheet when something (e.g. Combine) requested it for this album.
    private func consumeEditRequest() {
        if state.editRequestID == album.id {
            state.editRequestID = nil
            editShown = true
        }
    }

    private func trackRow(_ i: Int, _ track: Track) -> some View {
        // Match on identity OR title/index — the detail list and the player queue are
        // resolved separately, so their Track UUIDs differ even for the same song.
        let isCurrentTrack = player.current?.id == track.id
            || player.current?.title == track.title
            || (player.current != nil && player.index == i)
        let playing = isCurrentAlbum && isCurrentTrack
        return Button {
            state.nowPlayingAlbumID = album.id
            player.play(tracks, startAt: i)
        } label: {
            HStack(spacing: Space.s4) {
                ZStack {
                    if playing && player.isPlaying {
                        NowPlayingBars(color: p.accent)
                    } else if playing {
                        Image(systemName: "pause.fill").font(.system(size: 11)).foregroundStyle(p.accent)
                    } else {
                        Text("\(i + 1)").font(.system(size: 13, design: .monospaced)).foregroundStyle(p.muted2)
                    }
                }.frame(width: 26)
                Text(track.title).font(.system(size: 14, weight: playing ? .semibold : .regular))
                    .foregroundStyle(playing ? p.accent : p.text.opacity(0.85)).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, Space.s3).padding(.horizontal, Space.s3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(playing ? p.glassFill : .clear))
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 10, active: playing)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.995, brighten: 0))
        .appContextMenu {
            [
                AppMenuItem(title: "Play", systemImage: "play.fill") {
                    state.nowPlayingAlbumID = album.id; player.play(tracks, startAt: i)
                },
                AppMenuItem(title: "View credits", systemImage: "person.2.fill") {
                    trackRef = TrackRef(title: track.title, index: i)
                }
            ]
        }
    }

    private var downloadButton: some View {
        Group {
            if album.canDownload, state.downloads[album.id] != .done {
                if state.downloads[album.id] == .downloading {
                    circleProgress
                } else {
                    circleButton("arrow.down") { state.download(album) }
                }
            } else if album.isDownloaded {
                circleButton("checkmark") {}
            }
        }
    }

    private var circleProgress: some View {
        ZStack { Circle().fill(p.glassFill); OrbLoader(size: 64) }
            .frame(width: 40, height: 40)
            .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    private func circleButton(_ system: String, bounce: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 14)).foregroundStyle(p.text)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 40, height: 40)
                .background(Circle().fill(p.glassFill))
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
        }.buttonStyle(.soft)
    }

    private func load() async {
        loading = true
        tracks = await state.resolveTracks(for: album)
        loading = false
    }
}

/// A tiny animated equalizer shown next to the currently-playing track.
struct NowPlayingBars: View {
    var color: Color
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                Capsule().fill(color)
                    .frame(width: 3, height: animating ? 13 : 4)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: animating)
            }
        }
        .frame(height: 14)
        .onAppear { animating = true }
    }
}
