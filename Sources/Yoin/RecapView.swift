import SwiftUI
import AppKit

/// The year-end "recap" screen: a phyllotaxis spiral of the covers you played most,
/// with headline stats — exportable to a PNG poster you can share.
struct RecapView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    @State private var copied = false
    @State private var hovered: String?

    private var year: Int { Calendar.current.component(.year, from: Date()) }
    private var recap: Recap { RecapBuilder.build(year: year, albums: state.albums) }

    var body: some View {
        let recap = self.recap
        ZStack {
            p.page.ignoresSafeArea()

            if recap.isEmpty {
                empty
            } else {
                interactive(recap)
            }

            topBar(recap: recap)
        }
    }

    // MARK: Interactive, on-screen recap (the poster stays for PNG export)

    private func interactive(_ recap: Recap) -> some View {
        VStack(spacing: Space.s5) {
            liveHeader(recap)
            GeometryReader { geo in
                spiral(recap, area: geo.size)
            }
        }
        .padding(.top, 72)                 // clear the top bar
        .padding(.horizontal, Space.s6)
        .padding(.bottom, Space.s5)
    }

    private func liveHeader(_ recap: Recap) -> some View {
        VStack(spacing: Space.s3) {
            if let img = state.profile.avatarImage {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 56, height: 56).clipShape(Circle())
                    .overlay(Circle().strokeBorder(p.edge, lineWidth: 1))
            }
            Text(state.profile.hasName ? "\(state.profile.name.uppercased()) · \(String(recap.year))" : "YOUR \(String(recap.year))")
                .font(.system(size: 12, weight: .bold)).kerning(3).foregroundStyle(p.muted)
            Text("in covers").font(.system(size: 34, weight: .heavy)).foregroundStyle(p.text)
            HStack(spacing: Space.s2) {
                pill("\(recap.albumCount) album\(recap.albumCount == 1 ? "" : "s")")
                pill(recap.totalSeconds >= 3600 ? "\(Int(recap.totalHours.rounded())) h" : "\(max(1, Int((recap.totalSeconds/60).rounded()))) min")
                if let top = recap.topArtist { pill("Top · \(top)") }
            }
        }
    }

    private func spiral(_ recap: Recap, area: CGSize) -> some View {
        let items = Array(recap.items.prefix(150))
        let count = max(1, items.count)
        let maxPlays = Double(items.first?.plays ?? 1)
        let side = min(area.width, area.height)
        let maxCover = side * 0.26
        let region = side * 0.98
        let golden = 137.50776 * Double.pi / 180
        let denom = max(1.0, Double(count - 1).squareRoot())
        let spacing = (region / 2 - maxCover / 2) / CGFloat(denom)
        let center = CGPoint(x: area.width / 2, y: area.height / 2)

        let placements: [Placement] = items.enumerated().map { i, item in
            let r = spacing * CGFloat(Double(i).squareRoot())
            let a = Double(i) * golden
            let pos = CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
            let frac = maxPlays > 0 ? Double(item.plays) / maxPlays : 0
            let s = maxCover * (0.42 + 0.58 * CGFloat(pow(frac, 0.6)))
            return Placement(item: item, rank: i + 1, position: pos, size: s)
        }

        return ZStack {
            ForEach(placements.reversed()) { pl in
                let isHot = hovered == pl.id
                RecapCover(item: pl.item, size: pl.size, palette: p)
                    .frame(width: pl.size, height: pl.size)
                    .scaleEffect(isHot ? 1.22 : 1)
                    .shadow(color: .black.opacity(isHot ? 0.5 : 0.2), radius: isHot ? 18 : 6, y: isHot ? 10 : 3)
                    .position(pl.position)
                    .zIndex(isHot ? 1000 : Double(count - pl.rank))
                    .modifier(LinkCursor())
                    .onHover { inside in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                            if inside { hovered = pl.id } else if hovered == pl.id { hovered = nil }
                        }
                    }
                    .onTapGesture { if let id = pl.item.albumID { state.openedAlbumID = id } }
            }

            if let hid = hovered, let pl = placements.first(where: { $0.id == hid }) {
                infoCard(pl).position(cardPosition(pl, area: area)).zIndex(2000)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: area.width, height: area.height)
    }

    private func infoCard(_ pl: Placement) -> some View {
        let minutes = max(1, Int((pl.item.seconds / 60).rounded()))
        return VStack(alignment: .leading, spacing: 6) {
            Text("#\(pl.rank) MOST PLAYED").font(.system(size: 10, weight: .bold)).kerning(1.2).foregroundStyle(p.muted2)
            Text(pl.item.title).font(.system(size: 14, weight: .bold)).foregroundStyle(p.text).lineLimit(1)
            Text(pl.item.artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
            HStack(spacing: Space.s2) {
                miniStat("\(pl.item.plays)", "play\(pl.item.plays == 1 ? "" : "s")")
                miniStat("\(minutes)", "min")
            }.padding(.top, 2)
        }
        .padding(Space.s4)
        .frame(width: 200, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.page))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private func miniStat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: 15, weight: .heavy)).foregroundStyle(p.text)
            Text(unit).font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted2)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .background(Capsule().fill(p.glassFill))
    }

    /// Place the card above the cover, flipping below / clamping so it stays on screen.
    private func cardPosition(_ pl: Placement, area: CGSize) -> CGPoint {
        let cardW: CGFloat = 200, cardH: CGFloat = 108, gap: CGFloat = 14
        var y = pl.position.y - pl.size / 2 - gap - cardH / 2
        if y - cardH / 2 < 0 { y = pl.position.y + pl.size / 2 + gap + cardH / 2 }
        let x = min(max(cardW / 2, pl.position.x), area.width - cardW / 2)
        return CGPoint(x: x, y: min(max(cardH / 2, y), area.height - cardH / 2))
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .bold)).kerning(0.3)
            .padding(.vertical, 6).padding(.horizontal, 14).foregroundStyle(p.text)
            .background(Capsule().fill(p.glassFill))
            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    private struct Placement: Identifiable {
        let item: RecapItem
        let rank: Int
        let position: CGPoint
        let size: CGFloat
        var id: String { item.id }
    }

    private func topBar(recap: Recap) -> some View {
        VStack {
            HStack(spacing: Space.s3) {
                IconButton(system: "xmark", label: "Close recap", tip: "Close recap") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.screen = .crate }
                }
                Spacer()
                if !recap.isEmpty {
                    Button { copyLink(recap) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copied ? "checkmark" : "link")
                            Text(copied ? "Link copied" : "Share top 10")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(p.text)
                        .padding(.vertical, 8).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                    }.buttonStyle(.soft)

                    Button { export(recap) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export PNG").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(p.accentInk)
                        .padding(.vertical, 8).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(p.accent))
                    }.buttonStyle(.soft)
                }
            }
            .padding(Space.s5)
            Spacer()
        }
    }

    private var empty: some View {
        VStack(spacing: Space.s4) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(p.muted)
            Text("Your \(String(year)) recap is still empty")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(p.text)
            Text("Play some music and your most-listened covers\nwill bloom into a poster here.")
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundStyle(p.muted)
        }
    }

    // MARK: Share link

    private func copyLink(_ recap: Recap) {
        guard let url = RecapShare.url(for: recap, name: state.profile.name) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeIn(duration: 0.2)) { copied = false }
        }
    }

    // MARK: PNG export

    @MainActor
    private func export(_ recap: Recap) {
        let poster = RecapPoster(recap: recap, palette: p, profile: state.profile)
            .frame(width: RecapPoster.size.width, height: RecapPoster.size.height)
            .environment(\.palette, p)

        let renderer = ImageRenderer(content: poster)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Yoin \(String(recap.year)).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}

/// The self-contained poster that gets rendered to PNG. Takes an explicit palette so
/// it renders correctly through ImageRenderer (which is outside the view environment).
struct RecapPoster: View {
    let recap: Recap
    let palette: Palette
    var profile: Profile = Profile()

    static let size = CGSize(width: 1000, height: 1220)
    /// How many covers to place — enough to feel abundant, few enough to stay legible.
    private static let maxCovers = 150

    private var placements: [Placement] {
        let items = Array(recap.items.prefix(Self.maxCovers))
        let maxPlays = Double(items.first?.plays ?? 1)
        let golden = 137.50776 * Double.pi / 180
        let spacing: CGFloat = 30
        let center = CGPoint(x: Self.size.width / 2, y: 470)

        return items.enumerated().map { i, item in
            let r = spacing * CGFloat((Double(i)).squareRoot())
            let a = Double(i) * golden
            let pos = CGPoint(x: center.x + r * CGFloat(cos(a)),
                              y: center.y + r * CGFloat(sin(a)))
            let frac = maxPlays > 0 ? Double(item.plays) / maxPlays : 0
            let s = 26 + CGFloat(pow(frac, 0.6)) * 66   // 26…92 pt, biggest = most played
            return Placement(item: item, position: pos, size: s)
        }
    }

    /// Too few albums for a spiral (it just looks like one lonely tile) — show a
    /// clean lineup with a "keep listening" nudge instead.
    private var isSparse: Bool { recap.items.count <= 5 }

    var body: some View {
        ZStack {
            palette.page

            if isSparse {
                sparseCovers
            } else {
                // Covers: draw outer (small) first so the biggest, most-played sits on top.
                ForEach(placements.reversed()) { pl in
                    RecapCover(item: pl.item, size: pl.size, palette: palette)
                        .frame(width: pl.size, height: pl.size)
                        .position(pl.position)
                }
            }

            VStack {
                header
                Spacer()
                footer
            }
            .padding(Space.s7)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var sparseCovers: some View {
        VStack(spacing: Space.s6) {
            HStack(alignment: .top, spacing: Space.s4) {
                ForEach(Array(recap.items.prefix(5))) { item in
                    VStack(spacing: 10) {
                        RecapCover(item: item, size: 150, palette: palette)
                            .frame(width: 150, height: 150)
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(1).truncationMode(.tail)
                        Text("\(item.plays) play\(item.plays == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.muted2)
                    }
                    .frame(width: 150)
                }
            }
            Text("Just getting started — keep listening and your \(String(recap.year)) poster fills in.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
    }

    private var header: some View {
        VStack(spacing: Space.s3) {
            if let img = profile.avatarImage {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 64, height: 64).clipShape(Circle())
                    .overlay(Circle().strokeBorder(palette.edge, lineWidth: 1))
            }
            Text(profile.hasName
                 ? "\(profile.name.uppercased()) · \(String(recap.year))"
                 : "YOUR \(String(recap.year))")
                .font(.system(size: 13, weight: .bold)).kerning(3)
                .foregroundStyle(palette.muted)
            Text("in covers")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(palette.text)
            HStack(spacing: Space.s2) {
                statPill("\(recap.albumCount) album\(recap.albumCount == 1 ? "" : "s")")
                statPill(timeText)
                if let top = recap.topArtist { statPill("Top · \(top)") }
            }
        }
    }

    /// Hours once there's at least one; minutes below that so short years don't read "0 h".
    private var timeText: String {
        if recap.totalSeconds >= 3600 { return "\(Int(recap.totalHours.rounded())) h" }
        return "\(max(1, Int((recap.totalSeconds / 60).rounded()))) min"
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if let top = recap.items.first {
                Text("Most played — \(top.title) · \(top.artist)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.muted)
            }
            Text("yoin.fm")
                .font(.system(size: 11, weight: .bold)).kerning(1.5)
                .foregroundStyle(palette.muted2)
        }
    }

    private func statPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold)).kerning(0.3)
            .padding(.vertical, 6).padding(.horizontal, 14)
            .foregroundStyle(palette.text)
            .background(Capsule().fill(palette.glassFill))
            .overlay(Capsule().strokeBorder(palette.edgeSoft, lineWidth: 1))
    }

    private struct Placement: Identifiable {
        let item: RecapItem
        let position: CGPoint
        let size: CGFloat
        var id: String { item.id }
    }
}

/// One cover in the spiral: remote artwork with a monochrome fallback.
private struct RecapCover: View {
    let item: RecapItem
    let size: CGFloat
    let palette: Palette

    private var corner: CGFloat { max(4, size * 0.14) }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(palette.glassFill)
            .overlay {
                if let data = item.artworkData, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                } else if let url = item.artworkURL {
                    CachedRemoteImage(url: url) { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(palette.edgeSoft, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
    }
}
