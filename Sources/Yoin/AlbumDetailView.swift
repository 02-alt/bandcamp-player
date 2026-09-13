import SwiftUI

/// Full album screen — cover, info, actions, and the tracklist.
struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var artistLoc = ArtistLocationStore.shared
    @Environment(\.palette) private var p

    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var artistBio: ArtistBio? = nil
    @State private var artistBioLoaded = false
    @State private var creditsShown = false        // read-only credits (the "Credits" button)
    @State private var editCreditsShown = false    // editable credits panel (right-click ▸ Manage)
    @State private var editShown = false
    @State private var trackRef: TrackRef?
    @State private var coverZoomed = false
    @State private var artistHover = false
    @State private var locationHover = false
    @State private var moreFrame: CGRect = .zero
    @Namespace private var coverNS
    @AppStorage("shareCardAmbient") private var shareCardAmbient = true

    /// The panel's live height, so a short window shrinks the fixed header (cover + title) instead
    /// of letting it slide under the docked player bar.
    @State private var panelHeight: CGFloat = 800
    private var compactHeight: Bool { panelHeight < 600 }
    /// Narrow (portrait) window: a centred, single-column layout — cover, title/artist and a lone
    /// Play button stacked and centred, sized to fit the width. Uses the real NSWindow width.
    private var narrow: Bool { state.windowWidth < 750 }
    private var coverSide: CGFloat {
        if narrow { return min(state.windowWidth - 96, 280) }
        return compactHeight ? 128 : 220
    }
    private var titleSize: CGFloat { narrow ? 26 : (compactHeight ? 24 : 34) }

    /// Identifies a track for the per-track credits sheet.
    private struct TrackRef: Identifiable { let id = UUID(); let title: String; let index: Int }

    private var isCurrentAlbum: Bool { state.nowPlayingAlbumID == album.id }
    /// The live album from state, so cover/title/credits update as enrichment lands.
    private var live: Album { state.album(id: album.id) ?? album }

    var body: some View {
        ZStack(alignment: .top) {
            // Transparent fill (not an opaque page) so RootView's ambient background shows through
            // the whole screen — no black block behind the album. MainPanel hides the crate below.
            // (RootView already lays down the cover-tinted ambient; a second wash here would double
            // the tint and wash out muted text below the WCAG AA contrast floor.)
            Color.clear.ignoresSafeArea()

            VStack(alignment: .leading, spacing: compactHeight ? Space.s4 : Space.s6) {
                // Header row. Kept above the cover in z-order so the Back button always wins the
                // tap even if the cover's frame/shadow reaches up into this row.
                HStack {
                    IconButton(system: "chevron.left", tip: "Back") { state.openedAlbumID = nil }
                    Spacer()
                }
                .zIndex(1)

                // Cover + info
                if narrow {
                    narrowHeader
                } else {
                HStack(alignment: .bottom, spacing: Space.s6) {
                    ZStack {
                        Color.clear.frame(width: coverSide, height: coverSide)   // reserves layout while zoomed
                        if !coverZoomed {
                            AlbumArt(album: live, corner: 18)
                                .frame(width: coverSide, height: coverSide)
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
                        .font(.system(size: titleSize, weight: .bold)).kerning(-0.6)
                        .lineLimit(2).truncationMode(.tail)
                        HStack(spacing: 6) {
                            Button { state.openArtist(live.artist) } label: {
                                Text(live.artist)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(p.text.opacity(0.9))
                                    .underline(artistHover, color: p.muted)
                            }
                            .buttonStyle(.soft)
                            .modifier(LinkCursor())
                            .onHover { artistHover = $0 }
                            .help("View artist")
                            if !live.year.isEmpty {
                                Text("· \(live.year)").font(.system(size: 15)).foregroundStyle(p.muted)
                            }
                        }

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
                                .tip(live.isFavourite ? "Remove from favourites" : "Favourite album")
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
                }

                Divider().overlay(p.edgeSoft)

                // Tracklist. The header is pinned above the scroll so it stays put while the rows
                // scroll behind the player bar (rather than scrolling away with them).
                VStack(alignment: .leading, spacing: Space.s3) {
                    HStack {
                        Text("TRACKS").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                        Spacer()
                        Text("Right-click a track for its credits")
                            .font(.system(size: 11)).foregroundStyle(p.muted2)
                    }

                    ScrollView {
                    VStack(alignment: .leading, spacing: Space.s3) {
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
                        wishlistNudge
                        linerNotes
                        artistBioSection
                        moreFromArtist
                        playedStat
                    }
                    // Clear the docked player bar the list now scrolls behind, so the last rows /
                    // footer can still be scrolled fully into view above it.
                    .padding(.bottom, state.playerBarHeight + Space.s6)
                    }.scrollIndicators(.hidden)
                }
            }
            // Bottom padding is handled inside the scroll content instead, so the tracklist runs to
            // the window's bottom edge and continues behind the translucent player bar.
            .padding(.horizontal, Space.s7)
            .padding(.top, compactHeight ? Space.s4 : Space.s7)

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
        // Extend past the player bar's bottom safe-area inset so the tracklist can scroll behind it.
        .ignoresSafeArea(.container, edges: .bottom)
        // Flat, full-bleed screen — clip to bounds (so the ignoresSafeArea page fill doesn't spill
        // past the panel) but without rounded corners, so it doesn't read as a floating card.
        .clipShape(Rectangle())
        // Track the panel height so a short window shrinks the fixed header instead of pushing it
        // under the player bar.
        .background(GeometryReader { g in
            Color.clear
                .onAppear { panelHeight = g.size.height }
                .onChange(of: g.size.height) { _, h in panelHeight = h }
        })
        .task(id: album.id) { await load() }
        .sheet(isPresented: $creditsShown) {
            CreditsSheet(albumID: album.id, readOnly: true)
                .environment(\.palette, p).environmentObject(state)
        }
        .sheet(isPresented: $editCreditsShown) {
            CreditsSheet(albumID: album.id, readOnly: false)
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

    /// Narrow (portrait) header: cover, title/artist and a single Play button, centred and stacked,
    /// sized to fit the width. Secondary actions (favourite, download, credits, more) are dropped —
    /// they live in the wider layout and the right-click menu.
    private var narrowHeader: some View {
        VStack(spacing: Space.s5) {
            ZStack {
                Color.clear.frame(width: coverSide, height: coverSide)   // reserves layout while zoomed
                if !coverZoomed {
                    AlbumArt(album: live, corner: 18)
                        .frame(width: coverSide, height: coverSide)
                        .matchedGeometryEffect(id: "albumCover", in: coverNS)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                        .modifier(LinkCursor())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { coverZoomed = true }
                        }
                }
            }

            VStack(spacing: Space.s2) {
                Text(live.source == .bandcamp ? "BANDCAMP ALBUM" : "IN YOUR LIBRARY")
                    .font(.system(size: 11)).kerning(1).foregroundStyle(p.muted2)
                Text(live.title)
                    .font(.system(size: titleSize, weight: .bold)).kerning(-0.6)
                    .foregroundStyle(p.text)
                    .multilineTextAlignment(.center).lineLimit(2).truncationMode(.tail)
                Button { state.openArtist(live.artist) } label: {
                    Text(live.artist)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.text.opacity(0.9))
                }
                .buttonStyle(.soft).modifier(LinkCursor()).help("View artist")
            }

            Button { state.play(live, on: player) } label: {
                Image(systemName: "play.fill").font(.system(size: 20))
                    .foregroundStyle(p.accentInk)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(p.accent))
            }
            .buttonStyle(.soft)
            .opacity(live.isPlayable ? 1 : 0.4).disabled(!live.isPlayable)
            .tip("Play")
        }
        .frame(maxWidth: .infinity)
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
        guard let cur = player.current else { return false }
        // When this album is the known now-playing source, match by identity / index / title.
        if isCurrentAlbum, cur.id == track.id || cur.title == track.title || player.index == i {
            return true
        }
        // Otherwise the same song may be playing from another source (e.g. the iPod, or a
        // duplicate album) — match it by title + artist so the row still lights up.
        return cur.title == track.title && !track.artist.isEmpty
            && cur.artist.caseInsensitiveCompare(track.artist) == .orderedSame
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
                                  createNew: { state.beginPlaylistDraft(track: track) }),
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
        .tip("More")
    }

    /// The overflow menu: the shared, intent-grouped album menu, with the Bandcamp-specific
    /// bits slotted into it — "Open on Bandcamp" in the library group, the re-download/refresh
    /// maintenance pair inside the "Manage" flyout, and "Share album…" before Select.
    private var albumMoreMenu: [AppMenuItem] {
        var source: [AppMenuItem] = []
        var manage: [AppMenuItem] = []
        if live.source == .bandcamp {
            // A first download stays visible (handled by albumMenuItems); only the re-download of an
            // already-downloaded album is a maintenance action → into Manage.
            if live.isDownloaded, live.bandcampDownloadURL != nil {
                let downloading = state.downloads[live.id] == .downloading
                manage.append(AppMenuItem(title: "Re-download in FLAC",
                                          systemImage: downloading ? "arrow.down.circle" : "arrow.down") {
                    if !downloading { state.download(live) }
                })
            }
            manage.append(AppMenuItem(title: "Refresh from Bandcamp", systemImage: "arrow.clockwise") {
                Task { await reloadFromBandcamp() }
            })
        }
        // Editing the credits (fetch / edit / reset / re-match) is a maintenance action → Manage.
        manage.append(AppMenuItem(title: "Album credits…", systemImage: "square.and.pencil") {
            editCreditsShown = true
        })
        if live.source == .bandcamp {
            if let s = live.bandcampItemURL, let url = URL(string: s) {
                source.append(AppMenuItem(title: "Open on Bandcamp", systemImage: "safari") {
                    NSWorkspace.shared.open(url)
                })
            }
        }
        let share = AppMenuItem(title: "Share album…", systemImage: "square.and.arrow.up") { shareAlbum() }
        return albumMenuItems(for: live, state: state, player: player,
                              sourceActions: source, manageExtras: manage, trailingActions: [share])
    }

    /// Render a shareable "ALBUM" card (same poster as Now Playing) and open the macOS share sheet.
    private func shareAlbum() {
        Task { @MainActor in
            let a = live
            let img = await resolvedAlbumCover(a)
            let bcURL = a.bandcampItemURL.flatMap { URL(string: $0) }
            let n = tracks.count
            let bits = [a.year.isEmpty ? nil : a.year,
                        n > 0 ? "\(n) track\(n == 1 ? "" : "s")" : nil].compactMap { $0 }
            let card = NowPlayingCard(title: a.title, artist: a.artist, cover: img,
                                      coverFallback: a.cover, palette: p,
                                      ambient: nil,
                                      ambientBackground: shareCardAmbient,
                                      skin: .none, skinColors: [],
                                      link: bcURL?.host,
                                      eyebrow: "ALBUM",
                                      subtitle: bits.isEmpty ? nil : bits.joined(separator: " · "))
            if let image = ShareCard.render(card) {
                ShareCard.present(image, anchorView: nil, url: bcURL)
            } else {
                state.showNotice("Couldn't create the share image.")
            }
        }
    }

    private func resolvedAlbumCover(_ a: Album) async -> NSImage? {
        if let img = a.artwork { return img }
        if let url = a.artworkURL, let (d, _) = try? await URLSession.shared.data(from: url) {
            return NSImage(data: d)
        }
        return nil
    }

    /// Re-fetch this album's tracklist + liner notes from Bandcamp (drops stale/expired stream
    /// URLs), and re-play it if it's the current album.
    private func reloadFromBandcamp() async {
        loading = true
        state.invalidateNotes(for: live.id)
        TracklistCache.shared.invalidate(forItemURL: live.bandcampItemURL)
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
                        .tip("Download album")
                }
            } else if album.isDownloaded {
                circleButton("checkmark", label: "Downloaded") {}
                    .tip("Downloaded")
                    .accessibilityAddTraits(.isSelected)
            }
        }
    }

    private var circleProgress: some View {
        ZStack { Circle().fill(p.glassFill); OrbLoader(size: 24) }
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
        // Render the tracklist instantly from cache (even if stream URLs are stale), then
        // resolve in the background to confirm fresh, playable URLs.
        if let cached = TracklistCache.shared.displayTracks(for: album) {
            tracks = cached
            loading = false
        } else {
            tracks = []
        }
        let fresh = await state.resolveTracks(for: album)
        // Keep the cached list on a transient failure (fresh == []); only clear when we have
        // nothing cached to fall back on, so the empty-state error still shows for dead albums.
        if !fresh.isEmpty {
            tracks = fresh
        } else if TracklistCache.shared.displayTracks(for: album) == nil {
            tracks = []
        }
        loading = false
        state.loadNotes(for: album.id)
        if !artistBioLoaded {
            artistBioLoaded = true
            let titles = state.libraryAlbums(byArtist: album.artist).map(\.title)
            artistBio = await ArtistBioService.bio(artist: album.artist, ownedAlbumTitles: titles)
        }
    }

    /// A gentle "support this artist" nudge: if you still have *other* albums by the same artist
    /// sitting on your wishlist (and don't already own them), surface them here with a buy link —
    /// and lean in on Bandcamp Friday, when the artist keeps essentially the whole sale.
    @ViewBuilder private var wishlistNudge: some View {
        let wished = state.wishlistAlbums(byArtist: live.artist)
            .filter { $0.id != live.id && state.libraryAlbum(forBandcampURL: $0.bandcampItemURL) == nil }
        if !wished.isEmpty {
            let friday = BandcampFriday.isToday()
            VStack(alignment: .leading, spacing: Space.s3) {
                Divider().overlay(p.edgeSoft).padding(.vertical, Space.s2)
                HStack(spacing: 7) {
                    Image(systemName: friday ? "gift.fill" : "heart")
                        .font(.system(size: 12)).foregroundStyle(friday ? p.accent : p.muted2)
                    Text(friday ? "IT'S BANDCAMP FRIDAY" : "STILL ON YOUR WISHLIST")
                        .font(.system(size: 11, weight: .bold)).kerning(1)
                        .foregroundStyle(friday ? p.accent : p.muted2)
                }
                Text(nudgeLine(count: wished.count, friday: friday))
                    .font(.system(size: 12)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Space.s2) { ForEach(wished) { wishRow($0) } }
            }
            .padding(friday ? Space.s4 : 0)
            .background {
                if friday {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.accent.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(p.accent.opacity(0.35), lineWidth: 1))
                }
            }
            .padding(.top, Space.s3)
        }
    }

    private func nudgeLine(count: Int, friday: Bool) -> String {
        let n = count == 1 ? "an album" : "\(count) albums"
        let them = count == 1 ? "it" : "them"
        if friday {
            return "The artist keeps almost all of every sale today. You've kept \(n) by \(live.artist) on your wishlist — a good day to bring \(them) home."
        }
        return "You've kept \(n) by \(live.artist) on your wishlist — support them straight on Bandcamp."
    }

    private func wishRow(_ album: Album) -> some View {
        HStack(spacing: Space.s3) {
            AlbumArt(album: album, corner: 8).frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                if !album.year.isEmpty {
                    Text(album.year).font(.system(size: 11)).foregroundStyle(p.muted2)
                }
            }
            Spacer(minLength: Space.s3)
            if let s = album.bandcampItemURL, let url = URL(string: s) {
                Button { NSWorkspace.shared.open(url) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cart").font(.system(size: 11))
                        Text("Buy").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(p.accentInk)
                    .padding(.vertical, 7).padding(.horizontal, Space.s3)
                    .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.soft).tip("Buy on Bandcamp")
            }
        }
        .padding(Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.glassFill))
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

    /// The artist bio (same source as First Listen / the Artist page), so the album page is a
    /// one-stop info hub.
    @ViewBuilder private var artistBioSection: some View {
        if let bio = artistBio, !bio.text.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                notesSection("ABOUT \(live.artist.uppercased())", bio.text)
                Button {
                    if let s = bio.sourceURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }
                } label: {
                    Text("via \(bio.sourceName)").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(p.muted2).underline(bio.sourceURL != nil)
                }
                .buttonStyle(.plain).disabled(bio.sourceURL == nil)
            }
        }
    }

    /// Other owned albums by the same artist — a horizontal shelf at the bottom of the page.
    @ViewBuilder private var moreFromArtist: some View {
        let others = state.albums.filter {
            $0.id != live.id && $0.artist.caseInsensitiveCompare(live.artist) == .orderedSame
        }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                Divider().overlay(p.edgeSoft).padding(.vertical, Space.s2)
                Text("MORE FROM \(live.artist.uppercased())")
                    .font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                    .lineLimit(1).truncationMode(.tail)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Space.s4) {
                        ForEach(others) { other in
                            Button { withAnimation(.easeInOut(duration: 0.2)) { state.openedAlbumID = other.id } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumArt(album: other, corner: 10)
                                        .frame(width: 116, height: 116)
                                        .shadow(color: .black.opacity(0.3), radius: 8, y: 6)
                                    Text(other.title).font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(p.text).lineLimit(1)
                                        .frame(width: 116, alignment: .leading)
                                    if !other.year.isEmpty {
                                        Text(other.year).font(.system(size: 11)).foregroundStyle(p.muted2)
                                    }
                                }
                            }
                            .buttonStyle(.soft(hover: 1.03, press: 0.98, brighten: 0))
                            .appContextMenu { albumMenuItems(for: other, state: state, player: player) }
                        }
                    }
                    .padding(.top, Space.s2)
                }
            }
            .padding(.top, Space.s3)
        }
    }

    /// A quiet footer stat: how many times you've played this album, with a record-collector
    /// "condition" grade derived from that play count (mirrors the turntable's vinyl wear).
    private var playedStat: some View {
        let plays = state.playCount(for: album)
        return VStack(alignment: .leading, spacing: Space.s2) {
            Divider().overlay(p.edgeSoft).padding(.vertical, Space.s2)
            // Artist's home from MusicBrainz — the same cache behind the collection map.
            if let loc = artistLoc.location(forArtist: album.artist) {
                Button {
                    state.mapFocusLocation = loc
                    state.openedAlbumID = nil
                    withAnimation(.easeInOut(duration: 0.25)) { state.mapOpen = true }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 12)).foregroundStyle(p.muted2)
                        Text(loc).font(.system(size: 12)).foregroundStyle(p.muted)
                            .underline(locationHover, color: p.muted2)
                    }
                }
                .buttonStyle(.soft)
                .modifier(LinkCursor())
                .onHover { locationHover = $0 }
                .help("Show on the map")
            }
            HStack(spacing: 7) {
                Image(systemName: "play.circle").font(.system(size: 12)).foregroundStyle(p.muted2)
                Text(plays == 0
                     ? "Not played yet"
                     : "Played \(plays) time\(plays == 1 ? "" : "s") · \(condition(VinylPatina.wear(forCount: plays)))")
                    .font(.system(size: 12)).foregroundStyle(p.muted)
            }
            .padding(.bottom, Space.s3)
        }
    }

    /// Record-collector condition grades from play-count wear.
    private func condition(_ wear: Double) -> String {
        switch wear {
        case ..<0.05: "Mint"
        case ..<0.25: "Near Mint"
        case ..<0.55: "Very Good"
        case ..<0.8:  "Well-played"
        default:      "Well-loved"
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
                .tip(liked ? "Unfavourite song" : "Favourite song")

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
                .tip("More")
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
