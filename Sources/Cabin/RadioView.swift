import SwiftUI

// The Radio surfaces, ported from the iOS app so both platforms share one design: station cards
// on the Playlists home (`StationArt`) and the "All stations" page (`RadioStationsView`).

/// Up to four covers from a station's pool (one fills the tile, four make a 2×2), with a radio
/// badge that turns into ON AIR while the station plays.
struct StationArt: View {
    let covers: [Album]
    let side: CGFloat
    var live = false
    var starting = false
    var corner: CGFloat = 14
    @Environment(\.palette) private var p

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if covers.count >= 4 {
                VStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<2, id: \.self) { c in AlbumArt(album: covers[r * 2 + c], corner: 0) }
                        }
                    }
                }
            } else if let lead = covers.first {
                AlbumArt(album: lead, corner: 0)
            } else {
                shape.fill(p.glassFill)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(live ? p.accent : p.edgeSoft, lineWidth: live ? 2 : 1))
        .overlay(alignment: .topLeading) {
            if side >= 80 {
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.uiCaption.weight(.bold))
                        .symbolEffect(.variableColor.iterative, isActive: live)
                    if live { Text("ON AIR").font(.uiCaption.weight(.heavy)).kerning(0.6) }
                }
                // The accent is the app's text colour (white in dark mode), so the live badge uses
                // the accent's ink on top — white-on-white made ON AIR unreadable.
                .foregroundStyle(live ? p.accentInk : .white)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(Capsule().fill(live ? AnyShapeStyle(p.accent) : AnyShapeStyle(.ultraThinMaterial)))
                .shadow(color: .black.opacity(live ? 0.35 : 0), radius: 4, y: 1)
                .padding(Space.s2)
            }
        }
        .overlay {
            if starting {
                shape.fill(.black.opacity(0.35))
                ProgressView().controlSize(.small).tint(.white)
            }
        }
    }
}

/// The Radio page (from the Playlists hub's "See All"): cover-first, in the same design as the
/// hub and the album pages — an album-page style header (with what's on air), Library radio as a
/// wide cover-wash card, then every station as a grid of big station covers.
struct RadioStationsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var allPlaces = false

    private let side: CGFloat = 176
    private var grid: [GridItem] { [GridItem(.adaptive(minimum: side, maximum: side), spacing: Space.s5, alignment: .topLeading)] }

    /// A few covers from across the library for the Library radio card — favourites first.
    private var libraryCovers: [Album] {
        let withArt = state.albums.filter { $0.isPlayable && ($0.artworkURL != nil || $0.artworkData != nil) }
        return Array((withArt.filter(\.isFavourite) + withArt.filter { !$0.isFavourite }).prefix(4))
    }

    var body: some View {
        let history = state.radioSuggestions.filter { if case .place = $0.seed { return false } else { return true } }
        let places = state.placeStations
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s7) {
                header

                HStack(alignment: .top, spacing: Space.s5) {
                    libraryCard
                    Spacer(minLength: 0)
                }

                if !state.savedRadios.isEmpty {
                    section("Your stations") {
                        ForEach(state.savedRadios) { r in
                            card(seed: r.seed, title: r.name, subtitle: r.seed.kindLabel + " radio",
                                 covers: state.stationCovers(for: r.seed)) {
                                [AppMenuItem(title: "Play", systemImage: "play.fill") { state.playSavedRadio(r, on: player) },
                                 .divider(),
                                 AppMenuItem(title: "Delete Station", systemImage: "trash", role: .destructive, holdToConfirm: true) {
                                     state.deleteSavedRadio(r.id)
                                 }]
                            }
                        }
                    }
                }

                if !history.isEmpty {
                    section("From your listening") {
                        ForEach(history) { s in suggestionCard(s) }
                    }
                }

                if !places.isEmpty {
                    let shown = allPlaces ? places : Array(places.prefix(5))
                    section("Places", trailing: places.count > 5 ? (allPlaces ? "Show less" : "Show all \(places.count)") : nil,
                            onTrailing: { withAnimation(Motion.glide) { allPlaces.toggle() } }) {
                        ForEach(shown) { s in suggestionCard(s) }
                    }
                }
            }
            .padding(.horizontal, Space.s7).padding(.top, PageUnderTitlebar.top).padding(.bottom, Space.s7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .modifier(PageUnderTitlebar())
        .task { await state.refreshRadioSuggestions() }
    }

    // MARK: Header (album-page style)

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("RADIO").font(.uiSubheadline).kerning(1).foregroundStyle(p.muted2)
            Text("Stations").font(.system(size: 34, weight: .bold)).kerning(-0.6).foregroundStyle(p.text)
            let count = state.savedRadios.count + state.radioSuggestions.count + state.placeStations.count
            Text("\(count) station\(count == 1 ? "" : "s") · endless, from your own library")
                .font(.uiTitle3.weight(.semibold)).foregroundStyle(p.text.opacity(0.9))
            if state.radioActive, let label = state.currentRadioLabel {
                HStack(spacing: Space.s3) {
                    Button { state.openRadioQueue() } label: {
                        Label("On air: \(label)", systemImage: "dot.radiowaves.left.and.right")
                            .symbolEffect(.variableColor.iterative)
                            .font(.uiBody.weight(.semibold)).foregroundStyle(p.accent).lineLimit(1)
                    }
                    .buttonStyle(.soft).modifier(LinkCursor()).tip("Show what's on air")
                    Button { state.saveCurrentRadio() } label: {
                        Label(state.isCurrentRadioSaved ? "Saved" : "Save", systemImage: state.isCurrentRadioSaved ? "checkmark" : "plus")
                            .font(.uiBody.weight(.semibold))
                    }
                    .modifier(GlassButton()).controlSize(.large).disabled(state.isCurrentRadioSaved)
                    Button { state.stopRadio(on: player) } label: {
                        Label("Stop", systemImage: "stop.fill").font(.uiBody.weight(.bold))
                    }
                    .modifier(GlassButton(prominent: true)).controlSize(.large)
                }
                .padding(.top, Space.s2)
            }
        }
    }

    // MARK: Library radio — wide cover-wash card (like the hub's Made for You cards)

    private var libraryCard: some View {
        let width: CGFloat = 380, h: CGFloat = 176
        let covers = libraryCovers
        return Button { state.startLibraryRadio(on: player) } label: {
            ZStack(alignment: .bottomLeading) {
                StationArt(covers: covers, side: width, corner: 0)
                    .frame(width: width, height: h).clipped()
                    .blur(radius: 26).scaleEffect(1.25)
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.05), .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                Label("Endless mix from your whole library", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.uiCallout.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .padding(Space.s4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(alignment: .bottom, spacing: Space.s3) {
                    StationArt(covers: covers, side: 72, corner: 10)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library radio").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        Text("\(state.albums.filter(\.isPlayable).count) albums").font(.uiCallout.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 44)
                }
                .padding(Space.s4)
            }
            .frame(width: width, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.soft(hover: 1.0, press: Press.large, brighten: 0))
        .modifier(HoverOverlay(alignment: .bottomTrailing) {
            playBubble(dark: false) { state.startLibraryRadio(on: player) }.padding(Space.s3)
        })
        .accessibilityLabel("Library radio, endless mix from your whole library")
    }

    // MARK: Sections + cards

    private func section<Content: View>(_ title: String, trailing: String? = nil, onTrailing: @escaping () -> Void = {},
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 18, weight: .bold)).kerning(-0.3).foregroundStyle(p.text)
                Spacer()
                if let trailing {
                    Button(action: onTrailing) {
                        Text(trailing).font(.uiBody.weight(.semibold)).foregroundStyle(p.muted)
                    }
                    .buttonStyle(.soft).modifier(LinkCursor())
                }
            }
            LazyVGrid(columns: grid, alignment: .leading, spacing: Space.s5) { content() }
        }
    }

    private func suggestionCard(_ s: RadioSuggestion) -> some View {
        card(seed: s.seed, title: s.title, subtitle: s.subtitle, covers: s.covers) {
            var items = [AppMenuItem(title: "Play", systemImage: "play.fill") { state.startStation(s.seed, on: player) }]
            if !state.isStationSaved(s.seed) {
                items.append(AppMenuItem(title: "Save Station", systemImage: "plus") { state.saveStation(s.seed, name: s.savedName) })
            }
            return items
        }
    }

    /// The hub's station card: big cover mosaic with the radio / ON AIR badge, title and the plain
    /// fact behind it; ▶ on hover; click plays.
    private func card(seed: RadioSeed, title: String, subtitle: String, covers: [Album],
                      menu: @escaping () -> [AppMenuItem]) -> some View {
        let live = state.radioActive && state.currentRadioSeed == seed
        return Button { live ? state.openRadioQueue() : state.startStation(seed, on: player) } label: {
            VStack(alignment: .leading, spacing: Space.s2) {
                Group {
                    if covers.isEmpty {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.glassFill)
                            .overlay(Image(systemName: seed.icon).font(.system(size: 34)).foregroundStyle(p.muted2))
                            .frame(width: side, height: side)
                    } else {
                        StationArt(covers: covers, side: side, live: live, starting: state.radioStarting == seed)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.uiTitle3.weight(.semibold)).foregroundStyle(live ? p.accent : p.text).lineLimit(1)
                    Text(subtitle).font(.uiCallout).foregroundStyle(p.muted)
                        .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                }
            }
            .frame(width: side, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: Press.medium, brighten: 0))
        .modifier(HoverOverlay(alignment: .topTrailing) {
            playBubble(dark: true) { state.startStation(seed, on: player) }
                .padding(.top, side - 38 - Space.s2).padding(.trailing, Space.s2)
        })
        .appContextMenu(menu)
        .accessibilityLabel("\(title) radio, \(subtitle)\(live ? ", on air" : "")")
    }

    private func playBubble(dark: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                .foregroundStyle(dark ? .white : .black)
                .frame(width: 38, height: 38)
                // The material follows the window's scheme, not `dark` — pin it dark so a Light
                // app doesn't put a white glyph on white frost over the cover.
                .background(Circle().fill(dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white))
                    .environment(\.colorScheme, .dark))
                .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.25 : 0), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.soft(hover: 1.06, press: Press.small, brighten: 0))
        .tip("Play")
        .accessibilityLabel("Play")
    }
}


/// The playing station, full window (click an ON AIR card): the station's covers big on the left
/// with its name and controls, and on the right what's playing now and everything coming up —
/// cover-first rows you can click to jump to. Esc or ✕ closes it.
struct RadioQueueView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    private var seed: RadioSeed? { state.currentRadioSeed }
    private var covers: [Album] { seed.map { state.stationCovers(for: $0) } ?? [] }
    private var subtitle: String? {
        guard let seed else { return nil }
        return (state.radioSuggestions + state.placeStations).first { $0.seed == seed }?.subtitle ?? seed.kindLabel + " radio"
    }
    private var upNext: [(Int, Track)] {
        guard player.queue.indices.contains(player.index) else { return [] }
        return Array(player.queue.enumerated().dropFirst(player.index + 1))
    }

    var body: some View {
        GeometryReader { geo in
            let artSide = min(380, max(220, min(geo.size.width * 0.32, geo.size.height - 260)))
            HStack(alignment: .top, spacing: Space.s7) {
                stationColumn(artSide)
                    .frame(width: artSide)
                queueColumn
            }
            .padding(.horizontal, Space.s7)
            .padding(.top, WindowSize.titlebarHeight + Space.s5)
            .padding(.bottom, state.playerBarHeight + Space.s5)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background { AmbientBackground(album: state.nowPlayingAlbum ?? player.current?.albumID.flatMap { state.album(id: $0) }, palette: p) }
        .overlay(alignment: .topTrailing) {
            IconButton(system: "xmark", label: "Close", tip: "Close (Esc)") { state.closeRadioQueue() }
                .padding(.trailing, Space.s5).padding(.top, Space.s2)
        }
        .background(Button("") { state.closeRadioQueue() }.keyboardShortcut(.escape, modifiers: []).hidden())
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Station

    private func stationColumn(_ side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            StationArt(covers: covers, side: side, live: true, corner: 20)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("ON AIR").font(.uiSubheadline).kerning(1).foregroundStyle(p.muted2)
                Text(state.currentRadioLabel ?? "Radio").font(.system(size: 30, weight: .bold)).kerning(-0.5)
                    .foregroundStyle(p.text).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.uiBody).foregroundStyle(p.muted).lineLimit(2)
                }
            }
            HStack(spacing: Space.s3) {
                Button { player.toggle() } label: {
                    Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.uiBody.weight(.bold)).padding(.horizontal, Space.s1)
                }
                .modifier(GlassButton(prominent: true)).controlSize(.extraLarge)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 14)).frame(width: 22, height: 22)
                }
                .glassIconButton(side: 40).tip("Skip")
                Button { state.saveCurrentRadio() } label: {
                    Image(systemName: state.isCurrentRadioSaved ? "checkmark" : "plus").font(.system(size: 14)).frame(width: 22, height: 22)
                }
                .glassIconButton(side: 40).disabled(state.isCurrentRadioSaved)
                .tip(state.isCurrentRadioSaved ? "Saved" : "Save station")
                Button { state.stopRadio(on: player) } label: {
                    Image(systemName: "stop.fill").font(.uiBody).frame(width: 22, height: 22)
                }
                .glassIconButton(side: 40).tip("Stop radio")
            }
        }
    }

    // MARK: Queue

    private var queueColumn: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            if let cur = player.current {
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text("NOW PLAYING").font(.uiSubheadline.weight(.bold)).kerning(1).foregroundStyle(p.muted2)
                    HStack(spacing: Space.s4) {
                        TrackCover(track: cur, side: 84)
                            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cur.title).font(.system(size: 20, weight: .bold)).foregroundStyle(p.text).lineLimit(2)
                            Text(albumLine(cur)).font(.uiBody).foregroundStyle(p.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if player.isPlaying { NowPlayingBars(color: p.accent) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack {
                    Text("UP NEXT").font(.uiSubheadline.weight(.bold)).kerning(1).foregroundStyle(p.muted2)
                    Spacer()
                    Text("The station keeps adding as you listen").font(.uiSubheadline).foregroundStyle(p.muted2)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(upNext, id: \.1.id) { i, t in
                            QueueRow(track: t, line: albumLine(t)) { player.jump(to: i) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func albumLine(_ t: Track) -> String {
        if let a = t.albumID.flatMap({ state.album(id: $0) }) { return "\(t.artist) · \(a.title)" }
        return t.artist
    }
}

/// A track's cover: its own artwork, else its album's, else the gradient.
private struct TrackCover: View {
    let track: Track
    let side: CGFloat
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let album = track.albumID.flatMap({ state.album(id: $0) }) {
                AlbumArt(album: album, corner: 0)
            } else if let data = track.artworkData, let img = ArtworkCache.image(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else if let url = track.artworkURL {
                CachedRemoteImage(url: url) { Color.clear }
            } else {
                LinearGradient(colors: [Color(white: track.g0), Color(white: track.g1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 60 ? 12 : 6, style: .continuous))
    }
}

/// One upcoming track: cover, title, artist · album; click to jump to it.
private struct QueueRow: View {
    let track: Track
    let line: String
    let onPlay: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: Space.s3) {
                TrackCover(track: track, side: 44)
                    .overlay {
                        if hovering {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                            Image(systemName: "play.fill").font(.uiCallout).foregroundStyle(.white)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 14)).foregroundStyle(p.text.opacity(0.9)).lineLimit(1)
                    Text(line).font(.uiCallout).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let d = track.duration, d > 0 {
                    Text("\(Int(d) / 60):" + String(format: "%02d", Int(d) % 60))
                        .font(.uiCallout.monospacedDigit()).foregroundStyle(p.muted2)
                }
            }
            .padding(.vertical, Space.s2).padding(.horizontal, Space.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: Press.surface, brighten: 0))
        .hoverHighlight(cornerRadius: 10)
        .onHover { hovering = $0 }
        .help("Play now")
    }
}
