import SwiftUI

// MARK: - Saved stations (left rail, Radio mode)

/// The left-rail list of saved radio stations.
struct SavedRadiosRail: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    var body: some View {
        if state.savedRadios.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("No saved stations yet.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(p.muted)
                Text("Start a mood or artist radio, then tap ＋ in Up Next to save it here.")
                    .font(.system(size: 12)).foregroundStyle(p.muted2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.s2).padding(.top, Space.s3)
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(state.savedRadios) { r in
                        SavedRadioRow(radio: r,
                                      playing: state.radioActive && state.currentRadioLabel == r.name)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct SavedRadioRow: View {
    let radio: SavedRadio
    let playing: Bool
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button { state.playSavedRadio(radio, on: player) } label: {
            HStack(spacing: Space.s3) {
                Group {
                    if state.radioStarting == radio.seed {
                        OrbLoader(size: 16)
                    } else {
                        Image(systemName: radio.seed.icon).font(.system(size: 14))
                            .foregroundStyle(playing ? p.accent : p.text)
                    }
                }
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.glassFill))
                VStack(alignment: .leading, spacing: 1) {
                    Text(radio.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(playing ? p.accent : p.text).lineLimit(1)
                    Text(radio.seed.kindLabel + " radio").font(.system(size: 11)).foregroundStyle(p.muted2)
                }
                Spacer(minLength: 0)
                if playing { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11)).foregroundStyle(p.accent) }
            }
            .padding(.vertical, 6).padding(.horizontal, Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(p.glassFill).opacity(playing ? 1 : (hovering ? 0.5 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .onHover { hovering = $0 }
        .appContextMenu {
            [AppMenuItem(title: "Play", systemImage: "play.fill") { state.playSavedRadio(radio, on: player) },
             AppMenuItem(title: "Delete station", systemImage: "trash", role: .destructive, holdToConfirm: true) {
                 state.deleteSavedRadio(radio.id)
             }]
        }
    }
}

// MARK: - Radio detail (right pane, Radio mode)

/// The Radio screen's main pane: a now-playing banner, "Made for you" mixes, and how-to hint.
struct RadioDetail: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @AppStorage("yoin.autoDJ") private var autoDJ = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s5) {
                if state.radioActive { nowPlaying }
                madeForYou
                Text("Right-click an artist or an album → “Start radio” to spin up a station from it, then save it from Up Next.")
                    .font(.system(size: 12)).foregroundStyle(p.muted2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var nowPlaying: some View {
        VStack(spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("NOW PLAYING").font(.system(size: 9, weight: .bold)).kerning(1).opacity(0.8)
                    Text(state.currentRadioLabel ?? "Radio").font(.system(size: 16, weight: .bold))
                }
                Spacer()
                if !state.isCurrentRadioSaved {
                    Button { state.saveCurrentRadio() } label: {
                        Label("Save", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.accent)
                            .padding(.vertical, 6).padding(.horizontal, Space.s3)
                            .background(Capsule().fill(p.accent.opacity(0.15)))
                    }.buttonStyle(.soft)
                }
                Button { state.stopRadio(on: player) } label: {
                    Text("Stop").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentInk)
                        .padding(.vertical, 6).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(p.accent))
                }.buttonStyle(.soft)
            }
            // Auto-DJ: blend the station's tracks with a beat-matched crossfade.
            HStack(spacing: Space.s2) {
                Image(systemName: "slider.horizontal.2.square").font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Auto-DJ mix").font(.system(size: 13, weight: .semibold))
                    Text(player.djMode ? "Unavailable while DJ mode is on"
                                       : "Beat-matched crossfade between tracks")
                        .font(.system(size: 10)).opacity(0.75)
                }
                Spacer()
                Toggle("", isOn: $autoDJ).labelsHidden()
                    .disabled(player.djMode)
            }
            .foregroundStyle(p.accent)
            .opacity(player.djMode ? 0.5 : 1)
            .onChange(of: autoDJ) { _, on in
                // Apply live to the running station (persisted via @AppStorage for next start).
                if state.radioActive { player.autoDJ = on && !player.djMode }
            }
        }
        .foregroundStyle(p.accent)
        .padding(Space.s4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(p.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(p.accent.opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder private var madeForYou: some View {
        let artists = state.dailyMixArtists(count: 4)
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("MADE FOR YOU").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                Spacer()
                if !artists.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { state.refreshDailyMixes() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                            Text("New mixes").font(.system(size: 11, weight: .semibold))
                        }.foregroundStyle(p.muted)
                    }
                    .buttonStyle(.soft)
                    .help("Shuffle to a fresh set of mixes")
                    .accessibilityLabel("New mixes")
                }
            }
            if artists.isEmpty {
                Text("Play a little music and your daily mixes will appear here.")
                    .font(.system(size: 12)).foregroundStyle(p.muted2)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.s4)], alignment: .leading, spacing: Space.s4) {
                    ForEach(artists, id: \.self) { artist in mixCard(artist: artist) }
                }
                .padding(.top, Space.s2)
            }
        }
    }

    /// A square, Apple-Music-style tile for one of today's mixes: the artist name set big as the
    /// artwork over a signature gradient. Spins while its station is being built.
    private func mixCard(artist: String) -> some View {
        let loading = state.radioStarting == .artist(artist)
        let colors = Self.gradient(for: artist)
        return Button { state.startRadioForArtist(artist, on: player) } label: {
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                // Darkening scrim so the white name keeps enough contrast on the lighter gradients.
                LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.34)],
                               startPoint: .top, endPoint: .bottom)
                // Big typographic name — the "artwork".
                Text(artist)
                    .font(.system(size: 28, weight: .heavy)).kerning(-0.6)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.45)
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Radio glyph (top-left) + small tag (bottom-left).
                VStack {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Text("RADIO").font(.system(size: 9, weight: .heavy)).kerning(1.2)
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                    }
                }
                .padding(12)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                if loading {
                    ZStack {
                        Rectangle().fill(.black.opacity(0.35))
                        VStack(spacing: 6) {
                            OrbLoader(size: 26)
                            Text("Starting…").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        }
        .buttonStyle(.soft)
        .disabled(loading)
        .help("Start a station from \(artist)")
        .accessibilityLabel("\(artist) mix")
        .accessibilityValue(loading ? "Starting" : "")
        .accessibilityHint("Starts an endless station based on \(artist)")
        .appContextMenu {
            [AppMenuItem(title: "Play", systemImage: "play.fill") {
                state.startRadioForArtist(artist, on: player)
             },
             AppMenuItem(title: "New mixes", systemImage: "arrow.clockwise") {
                withAnimation(.easeInOut(duration: 0.2)) { state.refreshDailyMixes() }
             }]
        }
    }

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b) }

    /// A stable, distinct two-stop gradient derived from the name, so each mix keeps its own colour
    /// across launches (String.hashValue is randomised per run, so we sum unicode scalars instead).
    private static func gradient(for name: String) -> [Color] {
        let palettes: [[Color]] = [
            [c(0.15, 0.62, 0.63), c(0.10, 0.36, 0.62)],   // teal → blue
            [c(0.98, 0.55, 0.15), c(0.90, 0.17, 0.24)],   // orange → red
            [c(0.96, 0.30, 0.62), c(0.55, 0.20, 0.80)],   // pink → purple
            [c(0.34, 0.20, 0.60), c(0.09, 0.11, 0.28)],   // violet → navy
            [c(0.60, 0.42, 0.88), c(0.86, 0.36, 0.66)],   // lilac → pink (deepened for white text)
            [c(0.98, 0.68, 0.20), c(0.86, 0.22, 0.55)],   // amber → magenta
            [c(0.14, 0.66, 0.44), c(0.10, 0.42, 0.52)],   // green → teal
            [c(0.95, 0.60, 0.15), c(0.92, 0.34, 0.18)],   // amber → orange (deepened for white text)
            [c(0.30, 0.35, 0.62), c(0.16, 0.18, 0.32)],   // indigo → slate
            [c(0.72, 0.12, 0.16), c(0.12, 0.10, 0.12)],   // crimson → black
        ]
        // Sum of scalars is always ≥ 0, but mask to be certain the index can never go negative.
        let h = name.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) } & Int.max
        return palettes[h % palettes.count]
    }
}
