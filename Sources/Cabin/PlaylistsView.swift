import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Playlists screen — the same design as the iOS app, laid out for a Mac window: a
/// cover-led home ("Made for you" mixes, Radio station cards, your playlists, your Sets), and a
/// page per playlist / set with a centred cover header. Clicking a card opens it; its ▶ plays it
/// in place; right-click for Shuffle / Rename / Delete.
struct PlaylistsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    /// The "All stations" page is open.
    @State private var showStations = false
    /// Global frame of the "+" button, so the create menu anchors under it.
    @State private var plusFrame: CGRect = .zero

    /// The record whose page is open, if any (Liked Songs / Liked Albums are virtual).
    private var opened: Playlist? {
        guard let id = state.selectedPlaylistID else { return nil }
        if id == AppState.likedSongsID { return state.likedSongsPlaylist }
        if id == AppState.likedAlbumsID { return state.likedAlbumsSet }
        return state.playlists.first { $0.id == id }
    }

    var body: some View {
        Group {
            if showStations {
                RadioStationsView(onBack: { withAnimation(Motion.glide) { showStations = false } })
            } else if let pl = opened {
                PlaylistDetail(playlist: pl, onBack: { withAnimation(Motion.glide) { state.selectedPlaylistID = nil } })
                    .id(pl.id)
            } else {
                home
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await state.rebuildSmartPlaylistsIfStale() }
        .task(id: state.albums.count) { await state.refreshRadioSuggestions() }
        .task {
            // Screenshot/QA hook: CABIN_PLAYLIST=<name> opens that playlist / set ("stations" → All stations).
            guard let q = ProcessInfo.processInfo.environment["CABIN_PLAYLIST"] else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if q == "stations" { showStations = true; return }
            let all = [state.likedSongsPlaylist, state.likedAlbumsSet] + state.playlists
            state.selectedPlaylistID = all.first { $0.name.localizedCaseInsensitiveContains(q) }?.id
        }
    }

    // MARK: Home

    private let cell: CGFloat = 176
    private let gap: CGFloat = Space.s5

    private var home: some View {
        let made = state.playlists.filter { $0.isSmart }
        let mine = state.playlists.filter { !$0.isSmart && $0.kind == .playlist }
        let sets = state.playlists.filter { $0.kind == .set }
        let grid = [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: gap, alignment: .topLeading)]
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.s7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Playlists").font(.system(size: 34, weight: .bold)).kerning(-0.6).foregroundStyle(p.text)
                    Spacer()
                    Button {
                        state.showMenu(createMenuItems(), at: CGPoint(x: plusFrame.maxX - 220, y: plusFrame.maxY + 6))
                    } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .glassIconButton(side: 40).tip("New playlist or set")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { plusFrame = $0 }
                }

                if !made.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        railHeader("Made for you")
                        ScrollView(.horizontal) {
                            HStack(spacing: Space.s4) { ForEach(made) { mixCard($0, width: 340) } }
                                .padding(.horizontal, 2)
                        }
                        .scrollIndicators(.never)
                    }
                }

                VStack(alignment: .leading, spacing: Space.s3) {
                    railHeader("Radio") {
                        Button { withAnimation(Motion.glide) { showStations = true } } label: {
                            Text("All stations").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accent)
                        }
                        .buttonStyle(.soft).modifier(LinkCursor())
                    }
                    stationCards
                }

                VStack(alignment: .leading, spacing: Space.s3) {
                    railHeader("Your playlists")
                    // Liked Songs leads the grid as an ordinary tile — then your playlists, or a
                    // "New playlist" tile while you have none.
                    LazyVGrid(columns: grid, alignment: .leading, spacing: Space.s5) {
                        likedCard(side: cell)
                        ForEach(mine) { coverCard($0, side: cell) }
                        if mine.isEmpty { newPlaylistCard(side: cell) }
                    }
                }

                VStack(alignment: .leading, spacing: Space.s3) {
                    railHeader("Sets")
                    // Liked Albums (every hearted album) leads the row, then your own sets.
                    LazyVGrid(columns: grid, alignment: .leading, spacing: Space.s5) {
                        setCard(state.likedAlbumsSet, side: cell)
                        ForEach(sets) { setCard($0, side: cell) }
                        if sets.isEmpty { newSetCard(side: cell) }
                    }
                }
            }
            .padding(.horizontal, Space.s7)
            .padding(.top, Space.s4)
            .padding(.bottom, Space.s7)
        }
        .scrollIndicators(.never)
    }

    private func railHeader(_ title: String) -> some View { railHeader(title) { EmptyView() } }

    private func railHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 22, weight: .bold)).kerning(-0.4).foregroundStyle(p.text)
            Spacer()
            trailing()
        }
    }

    // MARK: Cards

    /// Liked Songs as a regular grid tile: a quiet heart cover, name and count, ▶ to play.
    private func likedCard(side: CGFloat) -> some View {
        let count = state.likedTracks.count
        return VStack(alignment: .leading, spacing: Space.s2) {
            Button { open(AppState.likedSongsID) } label: {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.glassFill)
                    .overlay {
                        Image(systemName: "heart.fill").font(.system(size: side * 0.26, weight: .semibold))
                            .foregroundStyle(p.muted)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
                    .frame(width: side, height: side)
            }
            .buttonStyle(.soft(hover: 1.0, press: 0.97, brighten: 0))
            .overlay(alignment: .bottomTrailing) {
                if count > 0 {
                    playBubble(dark: true) { player.shuffle = false; state.playPlaylist(state.likedSongsPlaylist, on: player) }
                        .padding(Space.s2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Liked Songs").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                Text(count == 0 ? "Click ♥ on a song" : "\(count) song\(count == 1 ? "" : "s")")
                    .font(.system(size: 13)).foregroundStyle(p.muted).lineLimit(1)
            }
        }
        .frame(width: side, alignment: .leading)
    }

    /// Dashed "New set" tile shown beside Liked Albums while you have no sets of your own.
    private func newSetCard(side: CGFloat) -> some View {
        dashedCard(title: "New set", detail: "A box of whole albums", side: side) {
            let s = state.createSet()
            state.selectedPlaylistID = s.id
            state.renamingPlaylistID = s.id
        }
    }

    /// Dashed "New playlist" tile shown in the grid while you have no playlists yet.
    private func newPlaylistCard(side: CGFloat) -> some View {
        dashedCard(title: "New playlist", detail: "Or right-click any song", side: side) {
            let pl = state.createPlaylist()
            state.selectedPlaylistID = pl.id
            state.renamingPlaylistID = pl.id
        }
    }

    private func dashedCard(title: String, detail: String, side: CGFloat, _ action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Button(action: action) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(p.edgeSoft, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .overlay {
                        Image(systemName: "plus").font(.system(size: 28, weight: .semibold)).foregroundStyle(p.muted)
                    }
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.soft(hover: 1.0, press: 0.97, brighten: 0))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                Text(detail).font(.system(size: 13)).foregroundStyle(p.muted).lineLimit(1)
            }
        }
        .frame(width: side, alignment: .leading)
    }

    /// Radio as cover cards — each station shows albums it will actually play and the plain fact
    /// behind it. Until there's history to build on, a single Library radio card stands in.
    private var stationCards: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Space.s4) {
                if state.radioSuggestionsLoaded && state.radioSuggestions.isEmpty {
                    emptyCard("Library radio", detail: "Endless mix from everything you own",
                              symbol: "antenna.radiowaves.left.and.right") { state.startLibraryRadio(on: player) }
                        .frame(width: 320)
                }
                ForEach(state.radioSuggestions) { stationCard($0, side: 160) }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
    }

    private func stationCard(_ s: RadioSuggestion, side: CGFloat) -> some View {
        let live = state.radioActive && state.currentRadioSeed == s.seed
        return Button { state.startStation(s.seed, on: player) } label: {
            VStack(alignment: .leading, spacing: Space.s2) {
                StationArt(covers: s.covers, side: side, live: live, starting: state.radioStarting == s.seed)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text(s.subtitle).font(.system(size: 12)).foregroundStyle(p.muted)
                        .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                }
            }
            .frame(width: side, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.97, brighten: 0))
        .appContextMenu {
            var items = [AppMenuItem(title: "Play", systemImage: "play.fill") { state.startStation(s.seed, on: player) }]
            if !state.isStationSaved(s.seed) {
                items.append(AppMenuItem(title: "Save station", systemImage: "plus") { state.saveStation(s.seed, name: s.savedName) })
            }
            return items
        }
        .accessibilityLabel("\(s.title) radio, \(s.subtitle)\(live ? ", on air" : "")")
    }

    /// A "Made for you" smart mix: its covers blurred into a wash behind the title and blurb.
    private func mixCard(_ pl: Playlist, width: CGFloat) -> some View {
        let h: CGFloat = 156
        return Button { open(pl.id) } label: {
            ZStack(alignment: .bottomLeading) {
                PlaylistMosaic(tracks: pl.coverTracks, side: width, custom: pl.coverImageData)
                    .frame(width: width, height: h).clipped()
                    .blur(radius: 26).scaleEffect(1.25)
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.05), .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                if let rule = pl.smart {
                    Label(rule.blurb, systemImage: rule.symbol)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .padding(Space.s4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                HStack(alignment: .bottom, spacing: Space.s3) {
                    PlaylistMosaic(tracks: pl.coverTracks, side: 64, custom: pl.coverImageData)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pl.name).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Text(pl.itemCountLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 44)
                }
                .padding(Space.s4)
            }
            .frame(width: width, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .overlay(alignment: .bottomTrailing) {
            if !pl.isEmpty { playBubble(dark: false) { play(pl) }.padding(Space.s3) }
        }
        .appContextMenu { cardMenu(pl) }
    }

    /// A playlist as a big square cover with its name and count underneath.
    private func coverCard(_ pl: Playlist, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Button { open(pl.id) } label: {
                PlaylistMosaic(tracks: pl.coverTracks, side: side, custom: pl.coverImageData)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
            }
            .buttonStyle(.soft(hover: 1.0, press: 0.97, brighten: 0))
            .overlay(alignment: .bottomTrailing) {
                if !pl.isEmpty { playBubble(dark: true) { play(pl) }.padding(Space.s2) }
            }
            .appContextMenu { cardMenu(pl) }
            cardCaption(pl)
        }
        .frame(width: side, alignment: .leading)
    }

    /// A set as fanned record sleeves (up to three covers) — reads as a box of albums.
    private func setCard(_ pl: Playlist, side: CGFloat) -> some View {
        let covers = Array(pl.coverTracks.prefix(3))
        let sleeve = side * 0.66
        return VStack(alignment: .leading, spacing: Space.s2) {
            Button { open(pl.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.glassFill)
                    if covers.isEmpty {
                        Image(systemName: pl.id == AppState.likedAlbumsID ? "heart.fill" : "square.stack.3d.up.fill")
                            .font(.system(size: 34)).foregroundStyle(p.muted2)
                    }
                    ForEach(Array(covers.enumerated().reversed()), id: \.offset) { i, t in
                        // Front sleeve centred and upright; the next ones peek out left and right behind it.
                        let spread: Double = [0, -1, 1][i]
                        PlaylistMosaic(tracks: [t], side: sleeve)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                            .rotationEffect(.degrees(spread * 9))
                            .offset(x: spread * side * 0.13, y: abs(spread) * 4)
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.soft(hover: 1.0, press: 0.97, brighten: 0))
            .overlay(alignment: .bottomTrailing) {
                if !pl.isEmpty { playBubble(dark: true) { play(pl) }.padding(Space.s2) }
            }
            .appContextMenu { cardMenu(pl) }
            cardCaption(pl)
        }
        .frame(width: side, alignment: .leading)
    }

    private func cardCaption(_ pl: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(pl.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
            Text(pl.itemCountLabel).font(.system(size: 13)).foregroundStyle(p.muted).lineLimit(1)
        }
    }

    /// Round ▶ that plays a record without opening it.
    private func playBubble(dark: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                .foregroundStyle(dark ? .white : .black)
                .frame(width: 38, height: 38)
                .background(Circle().fill(dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white)))
                .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.25 : 0), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.soft(hover: 1.06, press: 0.9, brighten: 0))
        .tip("Play")
        .accessibilityLabel("Play")
    }

    private func emptyCard(_ title: String, detail: String, symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s4) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(p.accent)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(p.text)
                    Text(detail).font(.system(size: 13)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(p.muted2)
            }
            .padding(Space.s4)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(p.edgeSoft, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
    }

    private func open(_ id: UUID) { withAnimation(Motion.glide) { state.selectedPlaylistID = id } }

    private func play(_ pl: Playlist, shuffled: Bool = false) {
        player.shuffle = false
        if pl.kind == .set { state.playSet(pl, on: player, shuffled: shuffled) }
        else { state.playPlaylist(pl, on: player, shuffled: shuffled) }
    }

    private func cardMenu(_ pl: Playlist) -> [AppMenuItem] {
        var items: [AppMenuItem] = []
        if !pl.isEmpty {
            items.append(AppMenuItem(title: "Play", systemImage: "play.fill") { play(pl) })
            items.append(AppMenuItem(title: "Shuffle", systemImage: "shuffle") { play(pl, shuffled: true) })
            items.append(.divider())
        }
        if pl.id == AppState.likedAlbumsID { return Array(items.dropLast()) }   // virtual: nothing to rename/delete
        if !pl.isSmart {
            items.append(AppMenuItem(title: "Rename", systemImage: "pencil") {
                state.renamingPlaylistID = pl.id; state.selectedPlaylistID = pl.id
            })
        }
        items.append(AppMenuItem(title: pl.kind == .set ? "Delete set" : "Delete playlist", systemImage: "trash",
                                 role: .destructive, holdToConfirm: true) {
            state.deletePlaylist(pl.id)
        })
        return items
    }

    // MARK: New menu (playlist / set / smart mixes)

    private func createMenuItems() -> [AppMenuItem] {
        var items: [AppMenuItem] = [
            AppMenuItem(title: "New playlist", systemImage: "music.note.list") {
                let pl = state.createPlaylist()
                state.selectedPlaylistID = pl.id
                state.renamingPlaylistID = pl.id
            },
            AppMenuItem(title: "New set", systemImage: "square.stack.3d.up") {
                let s = state.createSet()
                state.selectedPlaylistID = s.id
                state.renamingPlaylistID = s.id
            },
            .divider(),
        ]
        let (months, years) = periodMenuItems()
        var month = AppMenuItem(title: "Best of month…", systemImage: "trophy") {}
        month.submenu = months
        items.append(month)
        var year = AppMenuItem(title: "Best of year…", systemImage: "trophy.fill") {}
        year.submenu = years
        items.append(year)
        // Tempo shelves — auto-playlists bucketed by detected BPM (owned local files).
        var tempo = AppMenuItem(title: "By tempo…", systemImage: "metronome") {}
        tempo.submenu = TempoBand.allCases.map { band in
            AppMenuItem(title: band.title, systemImage: band.symbol) { state.createSmartPlaylist(.tempo(band)) }
        }
        items.append(tempo)
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
            AppMenuItem(title: "\(y)", systemImage: "calendar") { state.createSmartPlaylist(.bestOf(year: y, month: nil)) }
        }
        return (months, years)
    }
}

// MARK: - Playlist / set page

/// Wraps a picked image for the cover crop sheet so `.sheet(item:)` always has content.
private struct CoverCropRequest: Identifiable {
    let id = UUID()
    let image: NSImage
}

private struct PlaylistDetail: View {
    let playlist: Playlist
    var onBack: () -> Void
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @FocusState private var nameFocused: Bool
    @State private var draftName = ""
    @State private var coverCrop: CoverCropRequest?
    @State private var addAlbumsShown = false
    @State private var moreFrame: CGRect = .zero

    private var isRenaming: Bool { state.renamingPlaylistID == playlist.id }
    private var isLikedList: Bool { playlist.id == AppState.likedSongsID }
    private var isLikedAlbums: Bool { playlist.id == AppState.likedAlbumsID }
    /// Liked Songs / Liked Albums / smart playlists aren't hand-editable (no rename/cover/reorder).
    private var isReadOnly: Bool { isLikedList || isLikedAlbums || playlist.isSmart }

    /// The record currently spinning, if it belongs to this set — drives the header takeover.
    private var nowSpinning: SetAlbum? {
        let id = state.nowPlayingAlbumID ?? player.current?.albumID
        return playlist.albumRefs.first { $0.id == id }
    }

    var body: some View {
        Group {
            if playlist.isEmpty {
                VStack(spacing: Space.s5) {
                    header
                    VStack(spacing: Space.s2) {
                        Text(isLikedList ? "No liked songs yet"
                             : isLikedAlbums ? "No liked albums yet"
                             : playlist.isSmart ? "Nothing here yet"
                             : playlist.kind == .set ? "This set is empty" : "This playlist is empty")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(p.muted)
                        Text(isLikedList ? "Click the heart on any song to save it here."
                             : isLikedAlbums ? "Click the heart on any album to save it here."
                             : playlist.isSmart ? "It fills in automatically as you listen."
                             : playlist.kind == .set ? "Right-click an album → “Add to set”." : "Right-click an album → “Add to playlist”.")
                            .font(.system(size: 13)).foregroundStyle(p.muted2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, Space.s7)
            } else if playlist.kind == .set {
                // The header rides inside the grid's scroll view so the whole page scrolls.
                SetGrid(playlist: playlist, onAdd: isReadOnly ? nil : { addAlbumsShown = true },
                        header: AnyView(header.padding(.bottom, Space.s5)))
                    .padding(.horizontal, Space.s7)
            } else {
                trackList
            }
        }
        .overlay(alignment: .topLeading) { topBar }
        .sheet(item: $coverCrop) { req in
            ProfileCropSheet(image: req.image, square: true, title: "Crop cover",
                             onCancel: { coverCrop = nil },
                             onCrop: { data in
                state.setPlaylistCover(playlist.id, data: data)
                coverCrop = nil
            })
            .environment(\.palette, p)
        }
        .sheet(isPresented: $addAlbumsShown) {
            AddAlbumsToSetSheet(setID: playlist.id).environmentObject(state).environment(\.palette, p)
        }
    }

    /// Back (to the Playlists home) and, for editable records, the ••• actions.
    private var topBar: some View {
        HStack {
            IconButton(system: "chevron.left", label: "Back", tip: "Back to Playlists", action: onBack)
            Spacer()
            let items = moreItems()
            if !items.isEmpty {
                Button { state.showMenu(items, at: CGPoint(x: moreFrame.maxX - 220, y: moreFrame.maxY + 6)) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 22, height: 22)
                }
                .glassIconButton(side: 40).tip("More")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { moreFrame = $0 }
            }
        }
        .padding(.horizontal, Space.s5).padding(.top, Space.s2)
    }

    private func moreItems() -> [AppMenuItem] {
        var items: [AppMenuItem] = []
        if playlist.isSmart {
            if case .bestOf(let y, let m?)? = playlist.smart {
                items.append(AppMenuItem(title: "Show receipt for \(SmartRule.monthName(m))", systemImage: "ticket") {
                    state.receiptMonth = ReceiptMonth(year: y, month: m)
                })
            }
            items.append(AppMenuItem(title: "Refresh", systemImage: "arrow.clockwise") {
                Task { await state.rebuildSmartPlaylist(playlist.id) }
            })
            items.append(.divider())
            items.append(AppMenuItem(title: "Delete playlist", systemImage: "trash", role: .destructive, holdToConfirm: true) {
                state.deletePlaylist(playlist.id); onBack()
            })
            return items
        }
        guard !isLikedList && !isLikedAlbums else { return [] }
        items.append(AppMenuItem(title: "Rename", systemImage: "pencil") { state.renamingPlaylistID = playlist.id })
        items.append(AppMenuItem(title: "Change cover…", systemImage: "photo") { pickCover() })
        if playlist.coverImageData != nil {
            items.append(AppMenuItem(title: "Remove custom cover", systemImage: "photo.badge.arrow.down") {
                state.setPlaylistCover(playlist.id, data: nil)
            })
        }
        if playlist.kind == .set {
            items.append(AppMenuItem(title: "Add albums…", systemImage: "plus") { addAlbumsShown = true })
            var sort = AppMenuItem(title: "Sort by", systemImage: "arrow.up.arrow.down") {}
            sort.submenu = [AppMenuItem(title: "Artist", systemImage: "music.mic") { state.sortSet(playlist.id, by: .artist) },
                            AppMenuItem(title: "Album title", systemImage: "textformat") { state.sortSet(playlist.id, by: .album) }]
            items.append(sort)
        }
        items.append(.divider())
        items.append(AppMenuItem(title: playlist.kind == .set ? "Delete set" : "Delete playlist", systemImage: "trash",
                                 role: .destructive, holdToConfirm: true) {
            state.deletePlaylist(playlist.id); onBack()
        })
        return items
    }

    private func pickCover() {
        pickImageFile { img in coverCrop = CoverCropRequest(image: img) }
    }

    /// Play this record, dispatching to the set or playlist queue builder. `shuffled` starts at a
    /// random point with the order mixed up.
    private func play(shuffled: Bool = false) {
        player.shuffle = false   // the queue itself is shuffled; skips then walk it in order
        if playlist.kind == .set { state.playSet(playlist, on: player, shuffled: shuffled) }
        else { state.playPlaylist(playlist, on: player, shuffled: shuffled) }
    }

    /// Apple Music-style vertical header: centred cover, name, count, then Play / Shuffle.
    private var header: some View {
        VStack(spacing: Space.s4) {
            Group {
                if let cur = nowSpinning {
                    // While a record from this box is spinning, the header features it.
                    recordCover(cur, side: 220)
                        .overlay(alignment: .bottomLeading) {
                            NowPlayingBars(color: .white).padding(8)
                                .background(Circle().fill(.black.opacity(0.55))).padding(8)
                        }
                } else {
                    PlaylistMosaic(tracks: playlist.coverTracks, side: 220, custom: playlist.coverImageData,
                                   symbol: isLikedList ? "heart.fill" : isLikedAlbums ? "heart.fill" : playlist.smart?.symbol)
                        .onTapGesture { if !isReadOnly { pickCover() } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.3), value: nowSpinning?.id)

            VStack(spacing: 4) {
                if isRenaming && !isReadOnly {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 26, weight: .bold)).kerning(-0.4)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(p.text)
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .onAppear { draftName = playlist.name; nameFocused = true }
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                        .frame(maxWidth: 420)
                } else {
                    Text(playlist.name).font(.system(size: 26, weight: .bold)).kerning(-0.4)
                        .foregroundStyle(p.text).multilineTextAlignment(.center).lineLimit(2)
                        .onTapGesture(count: 2) { if !isReadOnly { state.renamingPlaylistID = playlist.id } }
                }
                if let cur = nowSpinning {
                    Label("\(cur.title) · \(cur.artist)", systemImage: "music.note")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.accent)
                        .lineLimit(1)
                } else {
                    Text(playlist.itemCountLabel)
                        .font(.system(size: 14)).foregroundStyle(p.muted)
                }
            }
            HStack(spacing: Space.s3) {
                Button { play() } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(p.accentInk)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(p.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.soft(hover: 1.02, press: 0.97, brighten: 0))
                .disabled(playlist.isEmpty)
                .onHover { if $0, playlist.kind == .playlist { state.prewarmPlaylist(playlist) } }
                Button { play(shuffled: true) } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(p.glassFill))
                        .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.soft(hover: 1.04, press: 0.95, brighten: 0))
                .disabled(playlist.isEmpty)
                .tip("Shuffle")
                .accessibilityLabel("Shuffle")
            }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.s5)
    }

    private func recordCover(_ ref: SetAlbum, side: CGFloat) -> some View {
        let gradient = LinearGradient(colors: [Color(white: ref.g0), Color(white: ref.g1)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        return RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(gradient)
            .frame(width: side, height: side)
            .overlay {
                if let data = ref.artworkData, let img = ArtworkCache.image(data: data) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else if let url = ref.artworkURL {
                    CachedRemoteImage(url: url) { Color.clear }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // Manual drag-gesture reorder (SwiftUI's .onDrag/.onDrop don't fire reliably for rows inside a
    // ScrollView on macOS). draggingID = row in flight; dragY = its live vertical offset.
    @State private var draggingID: UUID?
    @State private var dragY: CGFloat = 0
    @State private var lastTranslation: CGFloat = 0
    /// One row's on-screen height incl. the LazyVStack spacing — the step size for index math.
    private let rowH: CGFloat = 46

    /// The header scrolls with the tracks, like the iOS page.
    private var trackList: some View {
        ScrollView {
            header.padding(.bottom, Space.s5)
            LazyVStack(spacing: 2) {
                ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { i, track in
                    PlaylistTrackRow(
                        index: i, track: track,
                        reorderable: !isReadOnly,
                        deletable: !playlist.isSmart && !isLikedAlbums,
                        dragging: draggingID == track.id,
                        onPlay: { state.playPlaylist(playlist, on: player, startAt: i) },
                        onDelete: { deleteTrack(track, at: i) },
                        dragOffsetY: draggingID == track.id ? dragY : 0,
                        onDragChanged: isReadOnly ? nil : { th in dragChanged(track, translationY: th) },
                        onDragEnded: isReadOnly ? nil : { dragEnded() })
                    .zIndex(draggingID == track.id ? 1 : 0)
                }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, Space.s7)
            .padding(.bottom, Space.s7)
        }
        .scrollIndicators(.never)
    }

    /// Live reorder: accumulate the handle's drag, and each time it crosses a row height, move the
    /// dragged track one slot and subtract that height back out so it stays under the cursor.
    private func dragChanged(_ track: PlaylistTrack, translationY: CGFloat) {
        if draggingID != track.id { draggingID = track.id; dragY = 0; lastTranslation = 0 }
        dragY += translationY - lastTranslation
        lastTranslation = translationY
        guard let cur = playlist.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let steps = Int((dragY / rowH).rounded())
        guard steps != 0 else { return }
        let target = max(0, min(playlist.tracks.count - 1, cur + steps))
        if target != cur {
            state.reorderPlaylistTrack(playlist.id, from: cur, to: target)
            dragY -= CGFloat(target - cur) * rowH
        }
    }

    private func dragEnded() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            draggingID = nil; dragY = 0; lastTranslation = 0
        }
    }

    /// Remove one track: unlike for the Liked list, plain remove for an ordinary playlist.
    private func deleteTrack(_ track: PlaylistTrack, at i: Int) {
        if isLikedList { state.unlikeSongs(at: IndexSet(integer: i)) }
        else if !playlist.isSmart { state.removeTrackFromPlaylist(playlist.id, trackID: track.id) }
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
    var reorderable = false
    var deletable = false
    var dragging = false
    let onPlay: () -> Void
    var onDelete: () -> Void = {}
    var dragOffsetY: CGFloat = 0
    /// Non-nil when reorderable — the handle drives these with its DragGesture (kept off the play
    /// Button, which would swallow the gesture on macOS).
    var onDragChanged: ((CGFloat) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.s3) {
            // Click-to-play covers the cover + titles; the trailing controls live outside it.
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))

            if deletable {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(p.muted)
                }
                .buttonStyle(.soft)
                .opacity(hovering ? 1 : 0)
                .help("Remove from playlist")
                .accessibilityLabel("Remove \(track.title) from playlist")
            }
            if reorderable, let onDragChanged, let onDragEnded {
                Image(systemName: "line.3.horizontal").font(.system(size: 14))
                    .foregroundStyle(dragging ? p.text : p.muted)
                    .opacity(hovering || dragging ? 1 : 0.4)
                    .padding(.horizontal, 4).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .modifier(LinkCursor())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { onDragChanged($0.translation.height) }
                            .onEnded { _ in onDragEnded() }
                    )
                    .help("Drag to reorder")
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(p.glassFill).opacity(hovering || dragging ? 1 : 0))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(p.accent.opacity(dragging ? 0.7 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .scaleEffect(dragging ? 1.02 : 1)
        .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: dragging ? 10 : 0, y: dragging ? 5 : 0)
        .offset(y: dragOffsetY)
        .onHover { hovering = $0 }
    }
}

// MARK: - Set (vinyl-box) grid

/// A set's page body: a grid of whole-album covers you flip through, click to open, drag to
/// reorder, and right-click to play-from-here or remove.
private struct SetGrid: View {
    let playlist: Playlist
    var onAdd: (() -> Void)? = nil
    /// Page header scrolled with the grid, so the whole page scrolls together.
    var header: AnyView? = nil
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    private let cols = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Space.s4)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let header { header }
                LazyVGrid(columns: cols, alignment: .leading, spacing: Space.s4) {
                    ForEach(playlist.albumRefs) { ref in
                        cover(ref).id(ref.id)
                    }
                    if let onAdd {
                        Button(action: onAdd) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(p.edgeSoft, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    Image(systemName: "plus").font(.system(size: 26, weight: .semibold))
                                        .foregroundStyle(p.muted)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add albums to set")
                    }
                }
                .padding(.top, Space.s2)
                .padding(.bottom, Space.s6)
            }
            .scrollIndicators(.never)
            .onAppear { state.repairSet(playlist.id) }
            // Follow playback: scroll the now-playing record into view.
            .onChange(of: currentAlbumID) { _, id in
                guard let id, playlist.albumRefs.contains(where: { $0.id == id }) else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// The album currently sounding, from single-album play or set/playlist play.
    private var currentAlbumID: UUID? { state.nowPlayingAlbumID ?? player.current?.albumID }

    /// Resolve a set's stored record to the live library album (by id, else title+artist).
    private func liveAlbum(_ ref: SetAlbum) -> Album? {
        state.albums.first { $0.id == ref.id }
            ?? state.albums.first {
                $0.title.localizedCaseInsensitiveCompare(ref.title) == .orderedSame
                    && $0.artist.localizedCaseInsensitiveCompare(ref.artist) == .orderedSame
            }
    }

    private func openAlbum(_ ref: SetAlbum) {
        if let a = liveAlbum(ref) { state.openedAlbumID = a.id }
    }

    private func playAlbum(_ ref: SetAlbum) {
        guard let album = liveAlbum(ref) else { return }
        player.shuffle = false
        state.play(album, on: player)
    }

    private func cover(_ ref: SetAlbum) -> some View {
        SetCover(ref: ref, nowPlaying: currentAlbumID == ref.id)
            .contentShape(Rectangle())
            .onTapGesture { openAlbum(ref) }
            .modifier(LinkCursor())
            .draggable(ref.id.uuidString)
            .dropDestination(for: String.self) { items, _ in reorder(items, before: ref) }
            .appContextMenu { menu(ref) }
    }

    /// `.move(to:)` inserts *before* the destination offset.
    private func reorder(_ items: [String], before ref: SetAlbum) -> Bool {
        guard playlist.id != AppState.likedAlbumsID,
              let src = items.first,
              let from = playlist.albumRefs.firstIndex(where: { $0.id.uuidString == src }),
              let toIdx = playlist.albumRefs.firstIndex(where: { $0.id == ref.id }),
              from != toIdx else { return false }
        state.moveInSet(playlist.id, from: IndexSet(integer: from), to: from < toIdx ? toIdx + 1 : toIdx)
        return true
    }

    private func menu(_ ref: SetAlbum) -> [AppMenuItem] {
        [AppMenuItem(title: "Play album", systemImage: "play.fill") { playAlbum(ref) },
         AppMenuItem(title: "Play from here", systemImage: "play.square.stack") { player.shuffle = false; state.playSet(playlist, on: player, startAtAlbum: ref.id) },
         playlist.id == AppState.likedAlbumsID
            ? AppMenuItem(title: "Remove from Liked Albums", systemImage: "heart.slash", role: .destructive) { state.toggleFavourite(ref.id) }
            : AppMenuItem(title: "Remove from set", systemImage: "trash", role: .destructive) { state.removeFromSet(playlist.id, albumID: ref.id) }]
    }
}

/// One album in a set: a square cover that fills its grid cell, with title/artist below. The
/// currently-playing record gets an accent ring + a live equalizer badge.
private struct SetCover: View {
    let ref: SetAlbum
    var nowPlaying: Bool = false
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let gradient = LinearGradient(colors: [Color(white: ref.g0), Color(white: ref.g1)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(gradient)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let data = ref.artworkData, let img = ArtworkCache.image(data: data) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else if let url = ref.artworkURL {
                        CachedRemoteImage(url: url) { Color.clear }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if nowPlaying {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(p.accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if nowPlaying {
                        NowPlayingBars(color: .white)
                            .padding(6)
                            .background(Circle().fill(.black.opacity(0.55)))
                            .padding(6)
                    }
                }
                .shadow(color: nowPlaying ? p.accent.opacity(0.45) : .black.opacity(0.35),
                        radius: nowPlaying ? 12 : 8, y: 4)
            Text(ref.title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(nowPlaying ? p.accent : p.text).lineLimit(1)
            Text(ref.artist).font(.system(size: 11))
                .foregroundStyle(p.muted).lineLimit(1)
        }
        .animation(.easeInOut(duration: 0.25), value: nowPlaying)
    }
}

/// Pick albums from the library to add to a Set — click toggles membership (checkmark = in the set).
private struct AddAlbumsToSetSheet: View {
    let setID: UUID
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var inSet: Set<UUID> {
        Set(state.playlists.first { $0.id == setID }?.albumRefs.map(\.id) ?? [])
    }
    private var albums: [Album] {
        let all = state.albums
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query)
            || $0.artist.localizedCaseInsensitiveContains(query) }
    }
    private let cols = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: Space.s4)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                Text("Add to set").font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
                TextField("Albums & artists", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Space.s5)
            Divider().overlay(p.edgeSoft)
            ScrollView {
                LazyVGrid(columns: cols, alignment: .leading, spacing: Space.s4) {
                    ForEach(albums) { album in
                        let added = inSet.contains(album.id)
                        Button {
                            if added { state.removeFromSet(setID, albumID: album.id) }
                            else { state.addAlbum(album, toSet: setID) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AlbumArt(album: album, corner: 8)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        if added {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(p.accent, lineWidth: 3)
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                                            .font(.system(size: 22)).symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, added ? p.accent : Color.black.opacity(0.5))
                                            .padding(6)
                                    }
                                    .opacity(added ? 0.7 : 1)
                                Text(album.title).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(p.text).lineLimit(1)
                                Text(album.artist).font(.system(size: 11))
                                    .foregroundStyle(p.muted).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Space.s5)
            }
            .scrollIndicators(.never)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 640)
        .background(p.page)
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
                if let custom, let img = ArtworkCache.image(data: custom) {
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
    }

    @ViewBuilder
    private func cover(_ t: PlaylistTrack) -> some View {
        let gradient = LinearGradient(colors: [Color(white: t.g0), Color(white: t.g1)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        Rectangle().fill(gradient)
            .overlay {
                if let data = t.artworkData, let img = ArtworkCache.image(for: t.id, data: data) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else if let url = t.artworkURL {
                    CachedRemoteImage(url: url) { Color.clear }
                }
            }
            .clipped()
    }
}
