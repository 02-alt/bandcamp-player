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

/// All stations: what's on air (save it), library radio, the history stations, every place in
/// your collection, and the stations you've saved.
struct RadioStationsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s6) {
                Text("Radio").font(.system(size: 28, weight: .bold)).kerning(-0.5).foregroundStyle(p.text)

                // Now-playing station: save it.
                if state.radioActive, let label = state.currentRadioLabel {
                    HStack(spacing: Space.s3) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(p.accent)
                            .symbolEffect(.variableColor.iterative)
                        Text("On air: \(label)").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { state.saveCurrentRadio() } label: {
                            Label(state.isCurrentRadioSaved ? "Saved" : "Save", systemImage: state.isCurrentRadioSaved ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .modifier(GlassButton()).disabled(state.isCurrentRadioSaved)
                        Button { state.stopRadio(on: player) } label: {
                            Text("Stop").font(.system(size: 13, weight: .semibold))
                        }
                        .modifier(GlassButton(prominent: true))
                    }
                    .padding(.horizontal, Space.s2)
                }

                // Library radio — one click, endless mix from everything you own.
                Button { state.startLibraryRadio(on: player) } label: {
                    HStack(spacing: Space.s4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(p.accentInk)
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.accent))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Library radio").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
                            Text("Endless mix from your whole library").font(.system(size: 13)).foregroundStyle(p.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "play.fill").font(.system(size: 15)).foregroundStyle(p.muted2)
                    }
                    .padding(Space.s4)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.glassFill))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))

                if !state.savedRadios.isEmpty {
                    section("YOUR STATIONS") {
                        ForEach(state.savedRadios) { r in
                            row(seed: r.seed, title: r.name, subtitle: r.seed.kindLabel, covers: state.stationCovers(for: r.seed))
                                .appContextMenu {
                                    [AppMenuItem(title: "Play", systemImage: "play.fill") { state.playSavedRadio(r, on: player) },
                                     .divider(),
                                     AppMenuItem(title: "Delete", systemImage: "trash", role: .destructive) { state.deleteSavedRadio(r.id) }]
                                }
                        }
                    }
                }

                let history = state.radioSuggestions.filter { if case .place = $0.seed { return false } else { return true } }
                if !history.isEmpty {
                    section("FROM YOUR LISTENING") {
                        ForEach(history) { s in stationRow(s) }
                    }
                }

                if !state.placeStations.isEmpty {
                    section("PLACES") {
                        ForEach(state.placeStations) { s in stationRow(s) }
                    }
                }
            }
            .padding(.horizontal, Space.s7).padding(.top, PageUnderTitlebar.top).padding(.bottom, Space.s7)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .modifier(PageUnderTitlebar())
        .task { await state.refreshRadioSuggestions() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(title).font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            content()
        }
    }

    private func stationRow(_ s: RadioSuggestion) -> some View {
        row(seed: s.seed, title: s.title, subtitle: s.subtitle, covers: s.covers)
            .appContextMenu {
                var items = [AppMenuItem(title: "Play", systemImage: "play.fill") { state.startStation(s.seed, on: player) }]
                if !state.isStationSaved(s.seed) {
                    items.append(AppMenuItem(title: "Save station", systemImage: "plus") { state.saveStation(s.seed, name: s.savedName) })
                }
                return items
            }
    }

    private func row(seed: RadioSeed, title: String, subtitle: String, covers: [Album]) -> some View {
        let live = state.radioActive && state.currentRadioSeed == seed
        return Button { state.startStation(seed, on: player) } label: {
            HStack(spacing: Space.s3) {
                if covers.isEmpty {
                    Image(systemName: seed.icon).font(.system(size: 16))
                        .foregroundStyle(p.text).frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.glassFill))
                } else {
                    StationArt(covers: covers, side: 48, live: live, corner: 10)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(live ? p.accent : p.text).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if state.radioStarting == seed { ProgressView().controlSize(.small) }
                else if live {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 13)).foregroundStyle(p.accent)
                        .symbolEffect(.variableColor.iterative)
                } else { Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(p.muted2) }
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
    }
}
