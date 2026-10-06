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
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10, weight: .bold))
                        .symbolEffect(.variableColor.iterative, isActive: live)
                    if live { Text("ON AIR").font(.system(size: 10, weight: .heavy)).kerning(0.6) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(Capsule().fill(live ? AnyShapeStyle(p.accent) : AnyShapeStyle(.ultraThinMaterial)))
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
                                 AppMenuItem(title: "Delete station", systemImage: "trash", role: .destructive, holdToConfirm: true) {
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
            Text("RADIO").font(.system(size: 11)).kerning(1).foregroundStyle(p.muted2)
            Text("Stations").font(.system(size: 34, weight: .bold)).kerning(-0.6).foregroundStyle(p.text)
            let count = state.savedRadios.count + state.radioSuggestions.count + state.placeStations.count
            Text("\(count) station\(count == 1 ? "" : "s") · endless, from your own library")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text.opacity(0.9))
            if state.radioActive, let label = state.currentRadioLabel {
                HStack(spacing: Space.s3) {
                    Label("On air: \(label)", systemImage: "dot.radiowaves.left.and.right")
                        .symbolEffect(.variableColor.iterative)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.accent).lineLimit(1)
                    Button { state.saveCurrentRadio() } label: {
                        Label(state.isCurrentRadioSaved ? "Saved" : "Save", systemImage: state.isCurrentRadioSaved ? "checkmark" : "plus")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .modifier(GlassButton()).controlSize(.large).disabled(state.isCurrentRadioSaved)
                    Button { state.stopRadio(on: player) } label: {
                        Label("Stop", systemImage: "stop.fill").font(.system(size: 13, weight: .bold))
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
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .padding(Space.s4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(alignment: .bottom, spacing: Space.s3) {
                    StationArt(covers: covers, side: 72, corner: 10)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library radio").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        Text("\(state.albums.filter(\.isPlayable).count) albums").font(.system(size: 12, weight: .medium))
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
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
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
                        Text(trailing).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.muted)
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
                items.append(AppMenuItem(title: "Save station", systemImage: "plus") { state.saveStation(s.seed, name: s.savedName) })
            }
            return items
        }
    }

    /// The hub's station card: big cover mosaic with the radio / ON AIR badge, title and the plain
    /// fact behind it; ▶ on hover; click plays.
    private func card(seed: RadioSeed, title: String, subtitle: String, covers: [Album],
                      menu: @escaping () -> [AppMenuItem]) -> some View {
        let live = state.radioActive && state.currentRadioSeed == seed
        return Button { state.startStation(seed, on: player) } label: {
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
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(live ? p.accent : p.text).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(p.muted)
                        .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                }
            }
            .frame(width: side, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.97, brighten: 0))
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
                .background(Circle().fill(dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white)))
                .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.25 : 0), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.soft(hover: 1.06, press: 0.9, brighten: 0))
        .tip("Play")
        .accessibilityLabel("Play")
    }
}
