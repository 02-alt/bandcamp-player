import SwiftUI

/// Full album screen — cover, info, actions, and the tracklist.
struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @AppStorage("ambientTheming") private var ambientTheming = true

    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var creditsShown = false
    @State private var editShown = false
    @State private var trackRef: TrackRef?
    @State private var coverZoomed = false
    @State private var moreFrame: CGRect = .zero
    @Namespace private var coverNS

    /// Identifies a track for the per-track credits sheet.
    private struct TrackRef: Identifiable { let id = UUID(); let title: String; let index: Int }

    private var isCurrentAlbum: Bool { state.nowPlayingAlbumID == album.id }
    /// The live album from state, so cover/title/credits update as enrichment lands.
    private var live: Album { state.albums.first { $0.id == album.id } ?? album }

    var body: some View {
        ZStack(alignment: .top) {
            p.page.ignoresSafeArea()
            // Ambient wash so the album screen picks up the cover colour like the panels do.
            if ambientTheming, let ambient = state.ambient {
                LinearGradient(colors: [ambient.opacity(0.22), ambient.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom)
                    .blendMode(.plusLighter)
                    .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: Space.s6) {
                // Header row
                HStack {
                    IconButton(system: "chevron.left") { state.openedAlbumID = nil }
                        .accessibilityLabel("Back")
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
                        Group {
                            if AlbumTheme.isForeverAlone(live) {
                                Text(live.title).foregroundStyle(AlbumTheme.gold)
                                    .shadow(color: Color(red: 0.85, green: 0.65, blue: 0.25).opacity(0.55), radius: 8, y: 1)
                            } else {
                                Text(live.title).foregroundStyle(p.text)
                            }
                        }
                        .font(.system(size: 34, weight: .bold)).kerning(-0.6)
                        .lineLimit(2).truncationMode(.tail)
                        Text(live.year.isEmpty ? live.artist : "\(live.artist) · \(live.year)")
                            .font(.system(size: 15)).foregroundStyle(p.muted)

                        HStack(spacing: Space.s2) {
                            if live.lossless { Pill(text: live.isDownloaded ? "FLAC · OFFLINE" : "LOSSLESS", filled: true) }
                            Pill(text: live.format)
                        }.padding(.top, 2)

                        let owners = state.owners(of: live)
                        if !owners.isEmpty {
                            HStack(spacing: Space.s2) {
                                OwnersMacaron(owners: owners, size: 26)
                                Text(owners.count == 1 ? "Someone you follow owns this"
                                                        : "\(owners.count) people you follow own this")
                                    .font(.system(size: 12)).foregroundStyle(p.muted)
                            }.padding(.top, 2)
                        }

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

                            circleButton(live.isFavourite ? "heart.fill" : "heart", bounce: live.isFavourite,
                                         label: live.isFavourite ? "Remove from favourites" : "Favourite album") { state.toggleFavourite(live.id) }
                                .accessibilityAddTraits(live.isFavourite ? [.isSelected] : [])
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

                            moreButton
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
                            emptyTracks
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                                    AlbumTrackRow(index: i,
                                                  track: track,
                                                  playing: rowPlaying(i, track),
                                                  liked: state.isLiked(track),
                                                  menuItems: { trackMenuItems(i, track) },
                                                  onPlay: { state.nowPlayingAlbumID = album.id; player.play(tracks, startAt: i) },
                                                  onLike: { state.toggleLikedSong(track) })
                                }
                            }
                        }
                        linerNotes
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

    /// Is this row the currently-playing track? Match on identity OR title/index — the detail
    /// list and the player queue are resolved separately, so their Track UUIDs differ.
    private func rowPlaying(_ i: Int, _ track: Track) -> Bool {
        let isCurrentTrack = player.current?.id == track.id
            || player.current?.title == track.title
            || (player.current != nil && player.index == i)
        return isCurrentAlbum && isCurrentTrack
    }

    /// The shared per-track menu used by both right-click and the row's "…" button.
    private func trackMenuItems(_ i: Int, _ track: Track) -> [AppMenuItem] {
        let liked = state.isLiked(track)
        return [
            AppMenuItem(title: liked ? "Unfavourite song" : "Favourite song",
                        systemImage: liked ? "heart.slash" : "heart") { state.toggleLikedSong(track) },
            AppMenuItem(title: "Play", systemImage: "play.fill") {
                state.nowPlayingAlbumID = album.id; player.play(tracks, startAt: i)
            },
            addToPlaylistMenuItem(state: state,
                                  add: { state.addTrack(track, toPlaylist: $0) },
                                  createNew: { state.createPlaylistAndAdd(track: track) }),
            .divider(),
            AppMenuItem(title: "View credits", systemImage: "person.2.fill") {
                trackRef = TrackRef(title: track.title, index: i)
            }
        ]
    }

    /// Album-level "…" overflow: opens the app-styled menu (re-download, refresh, and the
    /// standard album actions) anchored under the button.
    private var moreButton: some View {
        circleButton("ellipsis", label: "More actions") {
            state.showMenu(albumMoreMenu, at: CGPoint(x: moreFrame.minX - 150, y: moreFrame.maxY + 6))
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { moreFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in moreFrame = f }
        })
        .help("More")
    }

    /// The overflow menu: a re-download/refresh pair up top (only for Bandcamp albums), then the
    /// shared album actions used everywhere else.
    private var albumMoreMenu: [AppMenuItem] {
        var items: [AppMenuItem] = []
        if live.source == .bandcamp {
            if live.bandcampDownloadURL != nil {
                let downloading = state.downloads[live.id] == .downloading
                items.append(AppMenuItem(title: live.isDownloaded ? "Re-download in FLAC" : "Download in FLAC",
                                         systemImage: downloading ? "arrow.down.circle" : "arrow.down") {
                    if !downloading { state.download(live) }
                })
            }
            items.append(AppMenuItem(title: "Refresh from Bandcamp", systemImage: "arrow.clockwise") {
                Task { await reloadFromBandcamp() }
            })
            if let s = live.bandcampItemURL, let url = URL(string: s) {
                items.append(AppMenuItem(title: "Open on Bandcamp", systemImage: "safari") {
                    NSWorkspace.shared.open(url)
                })
            }
            items.append(.divider())
        }
        items.append(contentsOf: albumMenuItems(for: live, state: state, player: player))
        return items
    }

    /// Re-fetch this album's tracklist + liner notes from Bandcamp (drops stale/expired stream
    /// URLs), and re-play it if it's the current album.
    private func reloadFromBandcamp() async {
        loading = true
        state.invalidateNotes(for: live.id)
        let fresh = await state.resolveTracks(for: live)
        await MainActor.run {
            tracks = fresh
            loading = false
            state.loadNotes(for: live.id)
            if isCurrentAlbum { state.play(live, on: player) }
        }
    }

    private var downloadButton: some View {
        Group {
            if album.canDownload, state.downloads[album.id] != .done {
                if state.downloads[album.id] == .downloading {
                    circleProgress
                } else {
                    circleButton("arrow.down", label: "Download album") { state.download(album) }
                }
            } else if album.isDownloaded {
                circleButton("checkmark", label: "Downloaded") {}
                    .accessibilityAddTraits(.isSelected)
            }
        }
    }

    private var circleProgress: some View {
        ZStack { Circle().fill(p.glassFill); OrbLoader(size: 64) }
            .frame(width: 40, height: 40)
            .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    private func circleButton(_ system: String, bounce: Bool = false, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 14)).foregroundStyle(p.text)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 40, height: 40)
                .background(Circle().fill(p.glassFill))
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
        }.buttonStyle(.soft).accessibilityLabel(label)
    }

    /// Shown when the album resolved zero playable tracks. This can mean the album is
    /// genuinely empty/unstreamable *or* that Bandcamp was momentarily unreachable
    /// (`resolveTracks` returns `[]` on network/auth failures too) — so we never auto-remove.
    /// Offer a Retry for the transient case, and a manual Remove for the dead one.
    private var emptyTracks: some View {
        VStack(spacing: Space.s3) {
            Text("Couldn't load tracks for this album.")
                .font(.system(size: 13)).foregroundStyle(p.muted)
            Text("Bandcamp may be unreachable, or this album is no longer streamable.")
                .font(.system(size: 12)).foregroundStyle(p.muted2)
                .multilineTextAlignment(.center)
            HStack(spacing: Space.s2) {
                pillButton("Retry", systemImage: "arrow.clockwise") { Task { await load() } }
                pillButton("Remove from library", systemImage: "trash", destructive: true) {
                    state.deleteAlbums([album.id])
                }
            }
            .padding(.top, Space.s1)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.vertical, Space.s4)
    }

    /// Small glass capsule button matching the header's Credits button.
    private func pillButton(_ title: String, systemImage: String, destructive: Bool = false,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(destructive ? Color.red : p.text)
            .padding(.vertical, 9).padding(.horizontal, Space.s4)
            .background(Capsule().fill(p.glassFill))
            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
        }.buttonStyle(.soft)
    }

    private func load() async {
        loading = true
        tracks = await state.resolveTracks(for: album)
        loading = false
        state.loadNotes(for: album.id)
    }

    /// Bandcamp liner notes — the album's "about" description and the artist's credits block.
    @ViewBuilder private var linerNotes: some View {
        if let about = live.about, !about.isEmpty {
            notesSection("ABOUT", about)
        }
        if let credits = live.bcCredits, !credits.isEmpty {
            notesSection("CREDITS", credits)
        }
    }

    private func notesSection(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Divider().overlay(p.edgeSoft).padding(.vertical, Space.s2)
            Text(heading).font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            Text(body)
                .font(.system(size: 13)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, Space.s3)
    }
}

/// One tracklist row with trailing like + "…" controls.
private struct AlbumTrackRow: View {
    let index: Int
    let track: Track
    let playing: Bool
    let liked: Bool
    let menuItems: () -> [AppMenuItem]
    let onPlay: () -> Void
    let onLike: () -> Void
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var hovering = false
    @State private var moreFrame: CGRect = .zero

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: Space.s4) {
                ZStack {
                    if playing && player.isPlaying {
                        NowPlayingBars(color: p.accent)
                    } else if playing {
                        Image(systemName: "pause.fill").font(.system(size: 11)).foregroundStyle(p.accent)
                    } else {
                        // Number ↔ play button cross-fade on hover.
                        Text("\(index + 1)").font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(p.muted2).opacity(hovering ? 0 : 1)
                        Image(systemName: "play.fill").font(.system(size: 11))
                            .foregroundStyle(p.text).opacity(hovering ? 1 : 0)
                    }
                }
                .frame(width: 26)
                .animation(.easeInOut(duration: 0.12), value: hovering)

                Text(track.title).font(.system(size: 14, weight: playing ? .semibold : .regular))
                    .foregroundStyle(playing ? p.accent : p.text.opacity(0.85)).lineLimit(1)
                Spacer(minLength: Space.s3)

                // Like this song.
                Button(action: onLike) {
                    Image(systemName: liked ? "heart.fill" : "heart").font(.system(size: 13))
                        .foregroundStyle(liked ? p.accent : p.muted2)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.soft)
                .opacity(liked || hovering ? 1 : 0.35)
                .help(liked ? "Unfavourite song" : "Favourite song")

                // More actions (app-styled menu, anchored under the button).
                Button {
                    state.showMenu(menuItems(), at: CGPoint(x: moreFrame.minX - 150, y: moreFrame.maxY + 6))
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14))
                        .foregroundStyle(p.muted)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.soft)
                .opacity(hovering ? 1 : 0.35)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { moreFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in moreFrame = f }
                })
                .help("More")
            }
            .padding(.vertical, Space.s3).padding(.horizontal, Space.s3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(playing ? p.glassFill : .clear))
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 10, active: playing)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.995, brighten: 0))
        .onHover { hovering = $0 }
        .appContextMenu(menuItems)
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
