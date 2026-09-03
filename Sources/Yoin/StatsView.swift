import SwiftUI

/// Always-on listening stats, shown as a card in Settings: streaks, this month's
/// headline numbers, top artists & genres, and a contribution-style heatmap.
struct ListeningStatsCard: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    @State private var stats: ListeningStats?
    /// Collapsed by default: shows only the top-artist tile, with the full breakdown behind a chevron.
    @AppStorage("statsExpanded") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chart.bar.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.muted2).frame(width: 16)
                    Text("LISTENING STATS").font(.system(size: 11, weight: .bold)).kerning(1)
                        .foregroundStyle(p.muted2)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(p.muted2)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse listening stats" : "Expand listening stats")
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Space.s5) {
                if let s = stats, !s.isEmpty {
                    if s.heroArtist != nil { HeroFlipTile(stats: s) }
                    if expanded {
                        tiles(s)
                        if !s.topArtists.isEmpty {
                            breakdown(title: "Top artists this month", items: s.topArtists)
                        }
                        if !s.genres.isEmpty {
                            breakdown(title: "Genres", items: s.genres)
                        }
                        heatmap(s)
                    }
                } else {
                    Text("Play some music and your stats will show up here.")
                        .font(.system(size: 12)).foregroundStyle(p.muted2)
                }
            }
            .padding(Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(p.glassFill))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .onAppear { stats = StatsBuilder.build(albums: state.albums) }
    }

    // MARK: Headline tiles

    private func tiles(_ s: ListeningStats) -> some View {
        HStack(spacing: Space.s3) {
            if let genre = s.genres.first {
                tile(value: genre.name, unit: "top genre", caption: "\(genre.plays) plays", icon: "guitars.fill", big: false)
            }
            tile(value: "\(s.monthListens)", unit: "plays this month",
                 caption: "\(s.totalListens) all-time", icon: "play.circle.fill")
            tile(value: hours(s.monthSeconds), unit: "listened this month", caption: nil, icon: "clock.fill")
        }
    }

    private func tile(value: String, unit: String, caption: String?, icon: String, big: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(p.muted2)
            Text(value).font(.system(size: big ? 26 : 18, weight: .bold, design: .rounded)).kerning(-0.5)
                .foregroundStyle(p.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted).lineLimit(1)
            if let caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(p.muted2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.page.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    // MARK: Bars

    private func breakdown(title: String, items: [NamedCount]) -> some View {
        let peak = max(1, items.map(\.plays).max() ?? 1)
        return VStack(alignment: .leading, spacing: Space.s3) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
            VStack(spacing: 7) {
                ForEach(items) { item in
                    HStack(spacing: Space.s3) {
                        Text(item.name).font(.system(size: 12)).foregroundStyle(p.muted)
                            .lineLimit(1).frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(p.edgeSoft).frame(height: 6)
                                Capsule().fill(p.text)
                                    .frame(width: max(6, geo.size.width * CGFloat(item.plays) / CGFloat(peak)), height: 6)
                            }
                            .frame(maxHeight: .infinity)
                        }
                        .frame(height: 12)
                        Text("\(item.plays)").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(p.muted2).frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Heatmap

    private func heatmap(_ s: ListeningStats) -> some View {
        // Chunk the trailing days into columns of 7 (one week each).
        let weeks = stride(from: 0, to: s.heatmap.count, by: 7).map {
            Array(s.heatmap[$0..<min($0 + 7, s.heatmap.count)])
        }
        let peak = max(1, s.heatmapPeak)
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("Last \(StatsBuilder.heatmapWeeks) weeks").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                HStack(spacing: 3) {
                    Text("less").font(.system(size: 9)).foregroundStyle(p.muted2)
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2).fill(cellColor(level, isKey: true)).frame(width: 9, height: 9)
                    }
                    Text("more").font(.system(size: 9)).foregroundStyle(p.muted2)
                }
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week) { day in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cellColor(Double(day.count) / Double(peak), isKey: day.count == 0 ? false : true))
                                .frame(width: 12, height: 12)
                                .help(day.count == 0 ? "No plays" : "\(day.count) play\(day.count == 1 ? "" : "s")")
                        }
                    }
                }
            }
        }
    }

    /// Monochrome ramp: empty cells read as a faint outline, busy days as solid text colour.
    private func cellColor(_ fraction: Double, isKey: Bool) -> Color {
        if fraction <= 0 { return isKey ? p.text.opacity(0.10) : p.text.opacity(0.06) }
        return p.text.opacity(0.20 + 0.75 * min(1, fraction))
    }

    private func hours(_ seconds: Double) -> String {
        let h = seconds / 3600
        if h >= 1 { return String(format: "%.1fh", h) }
        return "\(Int((seconds / 60).rounded()))m"
    }
}

// MARK: - Hero flip tile (top artist → most-played track)

/// The top-artist card. Tap it and it spins around to reveal that artist's
/// single most-played track.
private struct HeroFlipTile: View {
    let stats: ListeningStats
    @Environment(\.palette) private var p
    @State private var angle: Double = 0

    private var flipped: Bool { angle >= 90 }
    private var canFlip: Bool { stats.heroTopTrack != nil }

    var body: some View {
        ZStack {
            front.opacity(flipped ? 0 : 1)
            back.opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 1, y: 0, z: 0))
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.page.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if canFlip {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11)).foregroundStyle(p.muted2)
                    .padding(Space.s3)
                    .opacity(flipped ? 0 : 0.9)
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0))
        .contentShape(Rectangle())
        .onTapGesture {
            guard canFlip else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { angle = flipped ? 0 : 180 }
        }
        .help(canFlip ? "Tap to see the most-played track" : "")
    }

    // Front — the artist.
    private var front: some View {
        HStack(spacing: Space.s4) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR TOP ARTIST").font(.system(size: 10, weight: .bold)).kerning(1.2)
                    .foregroundStyle(p.muted2)
                Text(stats.heroArtist?.name ?? "—").font(.system(size: 22, weight: .bold, design: .rounded)).kerning(-0.4)
                    .foregroundStyle(p.text).lineLimit(1).minimumScaleFactor(0.7)
                Text("\(stats.heroArtist?.plays ?? 0) play\((stats.heroArtist?.plays ?? 0) == 1 ? "" : "s") all-time")
                    .font(.system(size: 12)).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
        }
    }

    // Back — their most-played track.
    private var back: some View {
        HStack(spacing: Space.s4) {
            cover.overlay {
                Image(systemName: "waveform").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white).shadow(radius: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("MOST PLAYED TRACK").font(.system(size: 10, weight: .bold)).kerning(1.2)
                    .foregroundStyle(p.muted2)
                Text(stats.heroTopTrack ?? "—").font(.system(size: 19, weight: .bold, design: .rounded)).kerning(-0.3)
                    .foregroundStyle(p.text).lineLimit(2).minimumScaleFactor(0.7)
                Text("\(stats.heroTopTrackPlays) play\(stats.heroTopTrackPlays == 1 ? "" : "s") · \(stats.heroArtist?.name ?? "")")
                    .font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var cover: some View {
        let gradient = LinearGradient(colors: [Color(white: stats.heroG0), Color(white: stats.heroG1)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        return RoundedRectangle(cornerRadius: 10, style: .continuous).fill(gradient)
            .frame(width: 56, height: 56)
            .overlay {
                if let data = stats.heroArtworkData, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let url = stats.heroArtworkURL {
                    CachedRemoteImage(url: url) { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "music.mic").font(.system(size: 20)).foregroundStyle(p.muted2)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}
