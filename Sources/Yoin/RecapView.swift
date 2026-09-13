import SwiftUI
import AppKit

/// The year-end "recap" screen: a phyllotaxis spiral of the covers you played most,
/// with headline stats — exportable to a PNG poster you can share.
struct RecapView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    @State private var savedPlaylist = false
    @State private var loadingMix = false
    @State private var hovered: String?
    /// Built once on appear (and when the library / selected year changes), not on every `body`
    /// pass — the builder re-scans the whole library + play history.
    @State private var recap: Recap?
    /// Years that have listening history, newest first — for the per-year picker.
    @State private var years: [Int] = []
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    /// The album whose "how you listened" card is open, if any.
    @State private var insight: AlbumInsight?
    /// Spiral arrival: 0 = covers arranged as the year's digits, 1 = settled into the spiral.
    @State private var introProgress: CGFloat = 0
    /// User-applied sphere rotation (committed) plus the in-flight drag, in radians.
    @State private var yaw: Double = 0
    @State private var pitch: Double = 0
    @GestureState private var sphereDrag: CGSize = .zero
    /// Cached digit-shape sample points (normalised 0…1) keyed by "year|count".
    @State private var glyphCache: [String: [CGPoint]] = [:]

    /// Replay the arrival animation (covers form the year, then flow into the spiral).
    private func playIntro() {
        introProgress = 0
        withAnimation(.spring(response: 1.2, dampingFraction: 0.86).delay(0.45)) { introProgress = 1 }
    }

    /// Points tracing the year's digits, normalised to 0…1 (x right, y down). Rasterises the
    /// number once and samples its filled pixels, then caches per (year, cover-count).
    private func glyphPoints(_ text: String, count: Int) -> [CGPoint] {
        let key = "\(text)|\(count)"
        if let c = glyphCache[key] { return c }
        let W = 240, H = 88
        let cs = CGColorSpaceCreateDeviceGray()
        guard count > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                                             bytesPerRow: W, space: cs,
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 74, weight: .heavy), .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (CGFloat(W) - b.width) / 2 - b.minX,
                                   y: (CGFloat(H) - b.height) / 2 - b.minY)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return [] }
        let ptr = data.bindMemory(to: UInt8.self, capacity: W * H)
        var pts: [CGPoint] = []
        for y in stride(from: 0, to: H, by: 2) {
            for x in stride(from: 0, to: W, by: 2) where ptr[y * W + x] > 128 {
                pts.append(CGPoint(x: CGFloat(x) / CGFloat(W), y: 1 - CGFloat(y) / CGFloat(H)))
            }
        }
        guard !pts.isEmpty else { return [] }
        pts.shuffle()
        let out = (0..<count).map { pts[$0 % pts.count] }
        glyphCache[key] = out
        return out
    }

    var body: some View {
        ZStack {
            p.page.ignoresSafeArea()

            if let recap {
                if recap.isEmpty {
                    empty
                } else {
                    interactive(recap)
                }
                topBar(recap: recap)
            }
        }
        .onAppear {
            if years.isEmpty { years = RecapBuilder.years() }
            if !years.isEmpty, !years.contains(selectedYear) { selectedYear = years.first! }
            if recap == nil { recap = RecapBuilder.build(year: selectedYear, albums: state.albums) }
            playIntro()
        }
        .onChange(of: state.albums.count) { recap = RecapBuilder.build(year: selectedYear, albums: state.albums) }
        .onChange(of: selectedYear) { _, y in
            hovered = nil
            savedPlaylist = false
            recap = RecapBuilder.build(year: y, albums: state.albums)
            playIntro()
        }
        .sheet(item: $insight) { ins in
            AlbumInsightCard(insight: ins, palette: p,
                             onOpen: { openAlbum(ins.albumID) },
                             onClose: { insight = nil })
        }
    }

    /// Open the "how you listened" card for a tapped cover/row.
    private func openInsight(_ item: RecapItem) {
        insight = RecapBuilder.insight(for: item, year: selectedYear)
    }

    /// Leave the recap and show the album's detail page (the recap is a full screen, so we must
    /// switch `screen` too — setting `openedAlbumID` alone wouldn't navigate).
    private func openAlbum(_ id: UUID?) {
        insight = nil
        guard let id else { return }
        state.openedAlbumID = id
        state.screen = .crate
    }

    // MARK: Interactive, on-screen recap (the poster stays for PNG export)

    /// Short window: shrink the fixed header + top padding so the greedy spiral below keeps a
    /// usable size instead of collapsing (its side is min(width, height) of the leftover area).
    private var compactRecap: Bool { state.windowHeight < 720 }

    private func interactive(_ recap: Recap) -> some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: compactRecap ? Space.s4 : Space.s5) {
                    liveHeader(recap)
                    if years.count > 1 { yearPicker }
                    savePlaylistCard(recap)
                    spiralBlock(recap)
                    statRow(recap)
                    supportCard(recap)
                    if !recap.topSupportedArtists.isEmpty { supportedArtistsCard(recap) }
                    personaCard(recap)
                    topFiveCard(recap)
                    if !recap.topGenres.isEmpty { genreCard(recap) }
                    if !recap.months.isEmpty { monthsCard(recap) }
                    if let geo = countryStat(recap) { mapCard(geo) }
                    wishlistNudge
                }
                .frame(maxWidth: 640)
                Spacer(minLength: 0)
            }
            .padding(.top, compactRecap ? 44 : 72)                 // clear the top bar
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s6)
        }
    }

    // MARK: Year picker

    private var yearPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(years, id: \.self) { y in
                    let on = y == selectedYear
                    Button { withAnimation(.easeInOut(duration: 0.2)) { selectedYear = y } } label: {
                        Text(String(y)).font(.system(size: 13, weight: .bold))
                            .foregroundStyle(on ? p.accentInk : p.text)
                            .padding(.vertical, 7).padding(.horizontal, 16)
                            .background(Capsule().fill(on ? p.accent : p.glassFill))
                            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: on ? 0 : 1))
                    }
                    .buttonStyle(.soft)
                    .modifier(LinkCursor())
                }
            }.padding(.horizontal, 2)
        }
    }

    // MARK: Spiral, sized for the scroll column

    private func spiralBlock(_ recap: Recap) -> some View {
        GeometryReader { geo in spiral(recap, area: geo.size) }
            .frame(height: min(max(360, state.windowHeight * 0.5), 560))
            .padding(.vertical, Space.s5)   // breathing room so the globe never touches the cards
    }

    // MARK: Stat cards

    private func statRow(_ r: Recap) -> some View {
        let cols = [GridItem(.flexible(), spacing: Space.s3), GridItem(.flexible(), spacing: Space.s3)]
        return LazyVGrid(columns: cols, spacing: Space.s3) {
            statTile("clock", "minutes played in \(String(r.year))") { CountingNumber(target: r.totalMinutes) }
            statTile("sparkles", "albums new to you in \(String(r.year))") { Text("\(r.discoveryCount)") }
            statTile("flame", "longest daily streak") { Text("\(r.longestStreak) day\(r.longestStreak == 1 ? "" : "s")") }
            statTile("clock.badge", "you listened most around") { Text(r.peakHourLabel ?? "—") }
        }
    }

    private func statTile<V: View>(_ symbol: String, _ label: String,
                                   @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accent)
            value().font(.system(size: 26, weight: .heavy)).foregroundStyle(p.text)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    // MARK: Support — the heart of the recap (owned music, not streams)

    private func supportCard(_ r: Recap) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(p.accent)
                Text("YOU SUPPORTED ARTISTS").font(.system(size: 11, weight: .bold)).kerning(1.5).foregroundStyle(p.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.s5) {
                bigNumber("\(r.ownedArtists)", "artists")
                bigNumber("\(r.ownedAlbums)", "records you own")
                if r.totalPlays > 0 { bigNumber("\(r.percentOwned)%", "of your listening") }
            }
            Text(r.collectionSize > 0
                 ? "The music you played in \(String(r.year)) is yours — bought on Bandcamp, straight to the artists. Your collection now holds \(r.collectionSize) album\(r.collectionSize == 1 ? "" : "s")."
                 : "The music you played in \(String(r.year)) is yours — bought on Bandcamp, straight to the artists.")
                .font(.system(size: 12)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let facts = supportFacts(r) {
                Text(facts).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s5)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.accent.opacity(0.5), lineWidth: 1))
    }

    private func bigNumber(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 34, weight: .heavy)).foregroundStyle(p.text)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted2)
        }
    }

    /// The labels / collection-growth line under the support headline (nil when nothing to say).
    private func supportFacts(_ r: Recap) -> String? {
        var parts: [String] = []
        if r.labelCount > 0, let l = r.topLabel {
            parts.append(r.labelCount == 1 ? "All from the label \(l)." : "Across \(r.labelCount) labels — most from \(l).")
        }
        if r.albumsAddedThisYear > 0 {
            var s = "You added \(r.albumsAddedThisYear) album\(r.albumsAddedThisYear == 1 ? "" : "s") to your collection this year"
            if r.newlySupportedArtists > 0 {
                s += ", backing \(r.newlySupportedArtists) new artist\(r.newlySupportedArtists == 1 ? "" : "s")"
            }
            parts.append(s + ".")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Who you backed

    private func supportedArtistsCard(_ r: Recap) -> some View {
        card("Who you backed") {
            VStack(spacing: Space.s3) {
                ForEach(r.topSupportedArtists) { a in
                    HStack(spacing: Space.s3) {
                        RecapCover(item: RecapItem(albumID: nil, title: "", artist: "", plays: 0, seconds: 0,
                                                   artworkURL: a.artworkURL, artworkData: a.artworkData),
                                   size: 40, palette: p)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                            Text("\(a.albumsOwned) album\(a.albumsOwned == 1 ? "" : "s") owned · \(a.plays) play\(a.plays == 1 ? "" : "s")")
                                .font(.system(size: 11)).foregroundStyle(p.muted)
                        }
                        Spacer(minLength: 0)
                        if let s = a.bandcampURL, let url = URL(string: s) {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Image(systemName: "safari").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(p.muted).frame(width: 30, height: 30)
                                    .background(Circle().fill(p.glassFill))
                            }
                            .buttonStyle(.soft).modifier(LinkCursor()).tip("Open on Bandcamp")
                        }
                    }
                }
            }
        }
    }

    // MARK: Wishlist — support continues

    @ViewBuilder private var wishlistNudge: some View {
        let items = state.wishlist
        if !items.isEmpty {
            card("Keep supporting") {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("\(items.count) album\(items.count == 1 ? "" : "s") waiting in your wishlist — a couple of clicks from the artists who made them.")
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Space.s3) {
                            ForEach(items.prefix(8)) { w in
                                VStack(spacing: 5) {
                                    RecapCover(item: RecapItem(albumID: nil, title: w.title, artist: w.artist, plays: 0,
                                                               seconds: 0, artworkURL: w.artworkURL, artworkData: w.artworkData),
                                               size: 64, palette: p)
                                        .frame(width: 64, height: 64)
                                        .modifier(LinkCursor())
                                        .onTapGesture {
                                            if let s = w.bandcampItemURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
                                        }
                                    Text(w.title).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1).frame(width: 64)
                                }
                            }
                        }.padding(.horizontal, 2)
                    }
                    Button { withAnimation(.easeInOut(duration: 0.15)) { state.screen = .wishlist } } label: {
                        Text("Open wishlist").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(p.accentInk)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Capsule().fill(p.accent))
                    }
                    .buttonStyle(.soft)
                }
            }
        }
    }

    // MARK: Persona

    private func personaCard(_ r: Recap) -> some View {
        let persona = r.persona
        return HStack(spacing: Space.s4) {
            Image(systemName: persona.symbol)
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(p.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(p.glassFill))
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("IN \(String(r.year)) YOU WERE").font(.system(size: 10, weight: .bold)).kerning(1.4).foregroundStyle(p.muted2)
                Text(persona.title).font(.system(size: 20, weight: .heavy)).foregroundStyle(p.text)
                Text(persona.blurb).font(.system(size: 12)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s5)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    // MARK: Top 5

    private func topFiveCard(_ r: Recap) -> some View {
        card("Most played") {
            VStack(spacing: Space.s3) {
                ForEach(Array(r.top(5).enumerated()), id: \.element.id) { i, it in
                    HStack(spacing: Space.s3) {
                        Text("\(i + 1)").font(.system(size: 15, weight: .heavy)).foregroundStyle(p.muted2)
                            .frame(width: 18, alignment: .trailing)
                        RecapCover(item: it, size: 40, palette: p).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                            Text(it.artist).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text("\(it.plays) play\(it.plays == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted2)
                    }
                    .contentShape(Rectangle())
                    .modifier(LinkCursor())
                    .onTapGesture { openInsight(it) }
                }
            }
        }
    }

    // MARK: Genres

    private func genreCard(_ r: Recap) -> some View {
        let maxPlays = max(1, r.topGenres.first?.plays ?? 1)
        return card("Your sound") {
            VStack(spacing: Space.s3) {
                ForEach(r.topGenres) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(g.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                            Spacer()
                            Text("\(g.plays)").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted2)
                        }
                        GeometryReader { geo in
                            Capsule().fill(p.accent)
                                .frame(width: max(6, geo.size.width * CGFloat(g.plays) / CGFloat(maxPlays)))
                        }
                        .frame(height: 6)
                        .background(Capsule().fill(p.glassFill))
                    }
                }
            }
        }
    }

    // MARK: Month by month

    private func monthsCard(_ r: Recap) -> some View {
        let names = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return card("Your top album each month") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Space.s3) {
                    ForEach(r.months) { mt in
                        VStack(spacing: 6) {
                            RecapCover(item: mt.item, size: 72, palette: p).frame(width: 72, height: 72)
                                .modifier(LinkCursor())
                                .onTapGesture { openInsight(mt.item) }
                            Text(names[mt.month]).font(.system(size: 11, weight: .bold)).foregroundStyle(p.muted2)
                            Text(mt.item.title).font(.system(size: 10)).foregroundStyle(p.muted)
                                .lineLimit(1).frame(width: 72)
                        }
                    }
                }.padding(.horizontal, 2)
            }
        }
    }

    // MARK: Map of the year

    private func countryStat(_ r: Recap) -> (count: Int, top: String, topPlays: Int)? {
        let store = ArtistLocationStore.shared
        var counts: [String: Int] = [:]
        for it in r.items where !it.artist.isEmpty {
            guard let loc = store.location(forArtist: it.artist), !loc.isEmpty else { continue }
            let country = loc.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? loc
            if !country.isEmpty { counts[country, default: 0] += it.plays }
        }
        guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        return (counts.count, top.key, top.value)
    }

    private func mapCard(_ geo: (count: Int, top: String, topPlays: Int)) -> some View {
        HStack(spacing: Space.s4) {
            Image(systemName: "globe")
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(p.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(p.glassFill))
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("AROUND THE WORLD").font(.system(size: 10, weight: .bold)).kerning(1.4).foregroundStyle(p.muted2)
                Text(geo.count == 1 ? "1 country" : "\(geo.count) countries")
                    .font(.system(size: 20, weight: .heavy)).foregroundStyle(p.text)
                Text("Most from \(geo.top).").font(.system(size: 12)).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s5)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    // MARK: Finale — save the year as a playlist

    private func savePlaylistCard(_ r: Recap) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("KEEP THE YEAR").font(.system(size: 11, weight: .bold)).kerning(1.5).foregroundStyle(p.accent)
            Text("Save your \(String(r.year)) in a playlist")
                .font(.system(size: 18, weight: .heavy)).foregroundStyle(p.text)
            Text("The tracks you played most this year, in one place — ready to play anytime.")
                .font(.system(size: 12)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s3) {
                Button {
                    state.saveRecapPlaylist(r)
                    withAnimation(.easeOut(duration: 0.15)) { savedPlaylist = true }
                } label: {
                    Label(savedPlaylist ? "Saved to playlists" : "Save \(String(r.year)) playlist",
                          systemImage: savedPlaylist ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(p.accentInk)
                        .padding(.vertical, 11).padding(.horizontal, Space.s5)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.soft).disabled(savedPlaylist).modifier(LinkCursor())

                Button {
                    guard !loadingMix else { return }
                    withAnimation(.easeOut(duration: 0.15)) { loadingMix = true }
                    state.playRecapMix(r, on: player) {
                        withAnimation(.easeOut(duration: 0.15)) { loadingMix = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if loadingMix {
                            ProgressView().controlSize(.small)
                            Text("Building your mix…").font(.system(size: 13, weight: .bold))
                        } else {
                            Label("Play the mix", systemImage: "play.fill").font(.system(size: 13, weight: .bold))
                        }
                    }
                    .foregroundStyle(p.text)
                    .padding(.vertical, 11).padding(.horizontal, Space.s5)
                    .background(Capsule().fill(p.glassFill))
                    .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                }
                .buttonStyle(.soft).disabled(loadingMix).modifier(LinkCursor())
            }
            if savedPlaylist {
                Button { withAnimation(.easeInOut(duration: 0.15)) { state.screen = .playlists } } label: {
                    Text("Open playlists →").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accent)
                }
                .buttonStyle(.plain).modifier(LinkCursor())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s5)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.accent.opacity(0.5), lineWidth: 1))
    }

    // MARK: Card shell

    private func card<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(1.5).foregroundStyle(p.muted2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s5)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    private func liveHeader(_ recap: Recap) -> some View {
        VStack(spacing: Space.s3) {
            // The avatar is the first thing to go on a short window — it costs the most height and
            // the name/year line already identifies the recap.
            if let img = state.profile.avatarImage, !compactRecap {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 56, height: 56).clipShape(Circle())
                    .overlay(Circle().strokeBorder(p.edge, lineWidth: 1))
            }
            Text(state.profile.hasName ? "\(state.profile.name.uppercased()) · \(String(recap.year))" : "YOUR \(String(recap.year))")
                .font(.system(size: 12, weight: .bold)).kerning(3).foregroundStyle(p.muted)
        }
    }

    private func spiral(_ recap: Recap, area: CGSize) -> some View {
        let items = Array(recap.items.prefix(150))
        let count = max(1, items.count)
        let maxPlays = Double(items.first?.plays ?? 1)
        let side = min(area.width, area.height)
        let center = CGPoint(x: area.width / 2, y: area.height / 2)

        // Item metadata per cover (position/size come from the live sphere projection below).
        let placements: [Placement] = items.enumerated().map { i, item in
            Placement(item: item, rank: i + 1, position: .zero, size: 0)
        }

        // Arrival: covers start arranged as the year's digits, then flow onto the sphere.
        let glyph = glyphPoints(String(recap.year), count: count)
        let boxW = area.width * 0.72
        let boxH = boxW * (88.0 / 240.0)
        let boxX = center.x - boxW / 2
        let boxY = center.y - boxH / 2
        func startPoint(_ i: Int) -> CGPoint {
            guard i < glyph.count else { return center }
            return CGPoint(x: boxX + glyph[i].x * boxW, y: boxY + glyph[i].y * boxH)
        }
        let e = introProgress * introProgress * (3 - 2 * introProgress)   // smoothstep

        // Fibonacci sphere → a slowly rotating globe of covers (the laurent.fyi look). Covers
        // toward the viewer are larger and drawn on top; the back hemisphere is smaller and dim.
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let sphereR = side * 0.43
        let baseCover = side * 0.16
        let persp = 2.4
        let tilt = -0.32
        func project(_ i: Int, _ t: Double, _ extraYaw: Double, _ extraPitch: Double) -> (pt: CGPoint, scale: CGFloat, z: Double) {
            let yy = 1 - (Double(i) / Double(max(1, count - 1))) * 2
            let rad = (1 - yy * yy).squareRoot()
            let th = golden * Double(i)
            var x = cos(th) * rad, z = sin(th) * rad
            let phi = t * 0.03 + extraYaw                        // very slow spin + drag around Y
            (x, z) = (x * cos(phi) + z * sin(phi), -x * sin(phi) + z * cos(phi))
            var y = yy
            let pt = max(-1.3, min(0.9, tilt + extraPitch))      // fixed tilt + drag, clamped
            (y, z) = (y * cos(pt) - z * sin(pt), y * sin(pt) + z * cos(pt))
            let scale = persp / (persp - z)
            return (CGPoint(x: center.x + CGFloat(x) * sphereR * CGFloat(scale),
                            y: center.y + CGFloat(y) * sphereR * CGFloat(scale)),
                    CGFloat(scale), z)
        }
        // Put the most-played albums around the equator (the prominent, front-facing band) rather
        // than the poles, so the top covers stay big and easy to reach as the globe turns.
        func slotY(_ j: Int) -> Double { 1 - Double(j) / Double(max(1, count - 1)) * 2 }
        let equatorSlot = (0..<count).sorted { abs(slotY($0)) < abs(slotY($1)) }

        // Committed rotation plus the live drag (horizontal → spin, vertical → tilt).
        let liveYaw = yaw + Double(sphereDrag.width) * 0.008
        let livePitch = pitch + Double(sphereDrag.height) * 0.008

        return TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(placements) { pl in
                    let i = pl.rank - 1
                    let isHot = hovered == pl.id
                    let frac = maxPlays > 0 ? Double(pl.item.plays) / maxPlays : 0
                    let proj = project(equatorSlot[i], t, liveYaw, livePitch)
                    let sz = proj.scale * baseCover * CGFloat(0.85 + 0.3 * frac) * (0.34 + 0.66 * e)
                    let start = startPoint(i)
                    let pos = CGPoint(x: start.x + (proj.pt.x - start.x) * e,
                                      y: start.y + (proj.pt.y - start.y) * e)
                    let backDim = 0.5 + 0.5 * ((proj.z + 1) / 2)
                    RecapCover(item: pl.item, size: sz, palette: p)
                        .frame(width: sz, height: sz)
                        .scaleEffect(isHot ? 1.16 : 1)
                        .opacity(isHot ? 1 : backDim * Double(0.35 + 0.65 * e))
                        .shadow(color: .black.opacity(isHot ? 0.5 : 0), radius: isHot ? 18 : 0, y: isHot ? 10 : 0)
                        .position(pos)
                        .zIndex(isHot ? 1000 : proj.z * 100)
                        .modifier(LinkCursor())
                        .onTapGesture { openInsight(pl.item) }
                }

                if let hid = hovered, let pl = placements.first(where: { $0.id == hid }) {
                    let proj = project(equatorSlot[pl.rank - 1], t, liveYaw, livePitch)
                    infoCard(pl)
                        .position(x: min(max(120, proj.pt.x), area.width - 120),
                                  y: max(64, proj.pt.y - proj.scale * baseCover / 2 - 64))
                        .zIndex(2000).transition(.opacity).allowsHitTesting(false)
                }
            }
            .frame(width: area.width, height: area.height)
            .contentShape(Rectangle())
            // Drag to look around the globe: horizontal spins, vertical tilts.
            .gesture(
                DragGesture(minimumDistance: 3)
                    .updating($sphereDrag) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        yaw += Double(v.translation.width) * 0.008
                        pitch += Double(v.translation.height) * 0.008
                    }
            )
            // Hover picks the frontmost (largest-z) cover under the pointer, recomputed at the
            // current time so it tracks the spin. Disabled until the arrival settles.
            .onContinuousHover { phase in
                guard introProgress > 0.98 else { return }
                let now = Date().timeIntervalSinceReferenceDate
                var target: String?
                if case .active(let pt) = phase {
                    target = placements
                        .map { ($0, project(equatorSlot[$0.rank - 1], now, liveYaw, livePitch)) }
                        .filter { let s = $0.1.scale * baseCover
                                  return abs(pt.x - $0.1.pt.x) <= s / 2 && abs(pt.y - $0.1.pt.y) <= s / 2 }
                        .max { $0.1.z < $1.1.z }?.0.id
                }
                if target != hovered {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { hovered = target }
                }
            }
        }
    }

    private func infoCard(_ pl: Placement) -> some View {
        let minutes = max(1, Int((pl.item.seconds / 60).rounded()))
        return VStack(alignment: .leading, spacing: 6) {
            Text("#\(pl.rank) MOST PLAYED").font(.system(size: 10, weight: .bold)).kerning(1.2).foregroundStyle(p.muted2)
            Text(pl.item.title).font(.system(size: 14, weight: .bold)).foregroundStyle(p.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(pl.item.artist).font(.system(size: 12)).foregroundStyle(p.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s2) {
                miniStat("\(pl.item.plays)", "play\(pl.item.plays == 1 ? "" : "s")")
                miniStat("\(minutes)", "min")
            }.padding(.top, 2)
        }
        .padding(Space.s4)
        // Cap the width and let the title/artist wrap to two lines so the whole thing is
        // readable instead of truncating in a fixed 200pt box.
        .frame(maxWidth: 260, alignment: .leading)
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
            Text("Your \(String(selectedYear)) recap is still empty")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(p.text)
            Text("Play some music and your most-listened covers\nwill bloom into a poster here.")
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundStyle(p.muted)
        }
    }
}


/// A number that counts up from zero on appear — the little celebratory flourish on the
/// headline minutes. Eases out over ~1.1s; the digit roll comes from `.numericText()`.
private struct CountingNumber: View {
    let target: Int
    @State private var shown = 0

    var body: some View {
        Text(shown.formatted())
            .contentTransition(.numericText())
            .onAppear(perform: run)
    }

    private func run() {
        guard target > 0 else { return }
        let steps = 28
        let total = 1.1
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)                 // ease-out cubic
            DispatchQueue.main.asyncAfter(deadline: .now() + total * t) {
                withAnimation(.linear(duration: total / Double(steps))) {
                    shown = Int((Double(target) * eased).rounded())
                }
            }
        }
    }
}

/// "How you listened to this album" — the card shown when you tap a cover/row in the recap.
private struct AlbumInsightCard: View {
    let insight: AlbumInsight
    let palette: Palette
    var onOpen: () -> Void
    var onClose: () -> Void

    private var p: Palette { palette }
    private let monthNames = ["", "January", "February", "March", "April", "May", "June",
                              "July", "August", "September", "October", "November", "December"]

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            HStack(alignment: .top, spacing: Space.s4) {
                RecapCover(item: insight.asRecapItem, size: 64, palette: p).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HOW YOU LISTENED").font(.system(size: 10, weight: .bold)).kerning(1.4).foregroundStyle(p.muted2)
                    Text(insight.title).font(.system(size: 17, weight: .bold)).foregroundStyle(p.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(insight.artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconButton(system: "xmark", tip: "Close", action: onClose)
            }

            HStack(spacing: Space.s3) {
                numTile("\(insight.plays)", "play\(insight.plays == 1 ? "" : "s")")
                numTile("\(insight.minutes)", "min")
                numTile("\(insight.longestStreak)", "day streak")
            }

            VStack(spacing: 0) {
                if let t = insight.topTrack {
                    factRow("Favourite track", t + (insight.topTrackPlays > 0 ? "  ·  \(insight.topTrackPlays)×" : ""))
                }
                if let m = insight.peakMonth, m >= 1, m <= 12 {
                    factRow("Played most in", monthNames[m])
                }
                if let d = insight.firstListen {
                    factRow("First heard", Self.dateFmt.string(from: d))
                }
                if let d = insight.lastListen, insight.plays > 1 {
                    factRow("Last heard", Self.dateFmt.string(from: d))
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.glassFill))

            if insight.albumID != nil {
                Button(action: onOpen) {
                    Text("Open album").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(p.accentInk)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.soft)
            }
        }
        .padding(Space.s6)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(p.page))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    private func numTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .heavy)).foregroundStyle(p.text)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Space.s3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.glassFill))
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: Space.s3) {
            Text(label).font(.system(size: 12)).foregroundStyle(p.muted2)
            Spacer(minLength: Space.s3)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, Space.s4).padding(.vertical, 10)
    }
}

/// One cover in the spiral: remote artwork with a monochrome fallback.
private struct RecapCover: View {
    let item: RecapItem
    let size: CGFloat
    let palette: Palette

    // Decode the embedded artwork once (not on every body pass — the spiral rebuilds all its
    // covers each time the hovered cover changes).
    @State private var decoded: NSImage?

    private var corner: CGFloat { max(4, size * 0.14) }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(palette.glassFill)
            .overlay {
                // Bound the image to the square BEFORE clipping — `scaledToFill().clipShape()`
                // without a frame lets a non-square cover (a tall import) overflow the tile.
                Group {
                    if let img = decoded {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else if item.artworkData == nil, let url = item.artworkURL {
                        CachedRemoteImage(url: url) { Color.clear }
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(palette.edgeSoft, lineWidth: 1))
            .onAppear { if decoded == nil, let d = item.artworkData { decoded = NSImage(data: d) } }
    }
}
