import SwiftUI

/// The 3D "record crate" — covers receding into depth, front cover = current album.
struct CrateView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    // "Wall" style shows a deeper, wider spread of covers.
    private var visible: Int { state.crateStyle == .spread ? 14 : 9 }
    private let dragPerCard: CGFloat = 55   // px of horizontal drag per album step

    @State private var dragBaseFront: Int? = nil
    /// True during (and briefly after) a deck drag, so the card's tap-to-flip doesn't
    /// fire on release and yank the crate back to where it started.
    @State private var didDrag = false
    /// Accumulated trackpad swipe distance, so a smooth two-finger flick steps card-by-card.
    @State private var scrollAccum: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // Below this width the deck + side panel no longer fit side-by-side.
            let compact = geo.size.width < 820
            // Scale the front cover to the space available (clamped to a sane range).
            // Compact stacks the deck above the panel, so cap by height to leave room below.
            let cardSize: CGFloat = compact
                ? min(min(max(geo.size.width * 0.55, 170), geo.size.height * 0.34), 330)
                : min(min(max(geo.size.width * 0.46, 180), geo.size.height * 0.72), 560)

            if compact {
                VStack(spacing: Space.s5) {
                    deck(cardSize: cardSize, fanned: true, width: geo.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, Space.s6)   // keep the fan clear of the header buttons
                    feature(compact: true)
                }
            } else {
                let featureWidth = min(260, geo.size.width * 0.28)
                // Only when the deck is dramatically wider than tall (a very low window) does
                // the pile look lost — there the fan uses the horizontal space. Normal windows,
                // even wide ones, keep the pile.
                let deckWidth = geo.size.width - featureWidth - Space.s6
                let shortWide = deckWidth / max(1, geo.size.height) > 3
                // "Wall" always fans (its whole point is the wide spread); the others only
                // fan in short/wide windows and otherwise keep the pile.
                let fanned = shortWide || state.crateStyle == .spread
                HStack(spacing: Space.s6) {
                    // The fan spans the deck's own width (the space left of the feature panel).
                    deck(cardSize: cardSize, fanned: fanned, width: deckWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    feature(compact: false)
                        .frame(width: featureWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .task { if state.isConnected { await state.buildFriendOwnership() } }
    }

    // MARK: Deck

    private func deck(cardSize: CGFloat, fanned: Bool, width: CGFloat) -> some View {
        let albums = state.visibleAlbums
        return ZStack {
            if albums.isEmpty {
                Text("Nothing here yet").font(.system(size: 15)).foregroundStyle(p.muted)
            }
            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                let d = depth(of: index, count: albums.count)
                if d < visible {
                    let g = fanned ? fanTransform(d, cardSize: cardSize, width: width)
                                   : stackTransform(d, cardSize: cardSize)
                    Group {
                        // Vinyl style: the front album is a record pulled from its sleeve.
                        if state.crateStyle == .vinyl && d == 0 {
                            VinylFront(album: album, corner: 14,
                                       wear: VinylPatina.wear(forCount: state.playCount(forAlbum: album.id)))
                        } else {
                            AlbumArt(album: album, corner: 14)
                        }
                    }
                        .frame(width: cardSize, height: cardSize)
                        .shadow(color: .black.opacity(0.45), radius: g.shadow, x: -14, y: 18)
                        .scaleEffect(g.scale, anchor: g.scaleAnchor)
                        .rotation3DEffect(.degrees(g.rotY), axis: (x: 0, y: 1, z: 0), anchor: g.rotAnchor, perspective: 0.6)
                        .rotation3DEffect(.degrees(g.rotX), axis: (x: 1, y: 0, z: 0))
                        .offset(x: g.x, y: g.y)
                        .opacity(g.op)
                        .zIndex(Double(visible - d))
                        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: state.front)
                        .modifier(LinkCursor())
                        .onTapGesture {
                            if didDrag { return }   // ignore the tap that ends a drag
                            if d == 0 { state.openedAlbumID = album.id }
                            else { state.flip(d <= visible / 2 ? d : -(albums.count - d)) }
                        }
                        .appContextMenu { albumMenuItems(for: album, state: state, player: player) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    didDrag = true   // a real drag started (past minimumDistance)
                    let base = dragBaseFront ?? state.front
                    if dragBaseFront == nil { dragBaseFront = base }
                    // Drag left → travel forward through the crate.
                    let steps = Int((-value.translation.width / dragPerCard).rounded())
                    let n = state.visibleAlbums.count
                    guard n > 0 else { return }
                    let target = ((base + steps) % n + n) % n
                    if target != state.front {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            state.front = target
                        }
                    }
                }
                .onEnded { _ in
                    dragBaseFront = nil
                    // Clear shortly after so the release tap is swallowed, but real taps
                    // (a moment later) still work.
                    if didDrag {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { didDrag = false }
                    }
                }
        )
        // Trackpad two-finger swipe (or mouse wheel) flips through the crate too.
        .onScrollWheel { dx, dy, precise, ended in
            if ended { scrollAccum = 0; return }
            // Use the dominant axis so a vertical-only wheel navigates as well.
            let raw = abs(dx) >= abs(dy) ? dx : dy
            scrollAccum += precise ? raw : raw * 8
            let threshold: CGFloat = 46   // swipe distance per card step
            let steps = Int(scrollAccum / threshold)
            guard steps != 0 else { return }
            scrollAccum -= CGFloat(steps) * threshold
            let n = state.visibleAlbums.count
            guard n > 0 else { return }
            // Swipe left / wheel down (negative delta) travels forward, matching the drag.
            let target = ((state.front - steps) % n + n) % n
            if target != state.front {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.front = target }
            }
        }
    }

    private func depth(of index: Int, count n: Int) -> Int {
        guard n > 0 else { return 0 }
        return (index - state.front + n) % n
    }

    private typealias CardGeometry = (x: CGFloat, y: CGFloat, scale: Double, rotY: Double, rotX: Double, op: Double, shadow: CGFloat, scaleAnchor: UnitPoint, rotAnchor: UnitPoint)

    /// Non-compact: covers stacked in a shallow pile behind the front cover. Offsets scale
    /// with the cover size so the pile keeps peeking out on big screens too.
    private func stackTransform(_ d: Int, cardSize: CGFloat) -> CardGeometry {
        let t = CGFloat(d)
        return (
            x: (t * 0.075 - 0.05) * cardSize,   // each cover behind peeks a little further right
            y: -t * 0.018 * cardSize,
            scale: max(0.6, 1 - Double(d) * 0.04),
            rotY: -26,
            rotX: 6,
            op: max(0.28, 1 - Double(d) * 0.11),
            shadow: d == 0 ? 30 : 18,
            scaleAnchor: .center,
            rotAnchor: .center
        )
    }

    /// Compact: a coverflow "shelf" — front cover hugs the left, the rest recede
    /// across the card width toward a vanishing point on the right. Covers share a
    /// common baseline (bottom-anchored scaling) and pivot from their leading edge,
    /// so they read as records standing in a crate rather than a jagged pile.
    private func fanTransform(_ d: Int, cardSize: CGFloat, width: CGFloat) -> CardGeometry {
        let t = visible > 1 ? Double(d) / Double(visible - 1) : 0   // 0 (front) … 1 (deepest)
        let spread = state.crateStyle == .spread
        // Wall spaces covers evenly (linear) and keeps them large/visible; the others bunch
        // toward a vanishing point and dissolve the tail.
        let ease = spread ? t : 1 - pow(1 - t, 1.6)
        // Vinyl style pulls a record out to the left of the front sleeve — shift the whole
        // fan right so the disc has room and isn't clipped by the panel edge.
        let vinylInset: CGFloat = state.crateStyle == .vinyl ? cardSize * 0.42 : 0
        let leftPad = cardSize * 0.46 + vinylInset                  // front card hugs the left edge
        let reach = max(0, width - leftPad - cardSize * 0.2)        // travel to the right edge
        return (
            x: -width / 2 + leftPad + CGFloat(ease) * reach,
            y: -CGFloat(t) * cardSize * 0.03,                       // subtle rise toward the vanishing point
            scale: 1 - t * (spread ? 0.28 : 0.42),                  // Wall shrinks less → more visible
            rotY: (spread ? -24 : -34) - t * (spread ? 3 : 6),
            rotX: 0,
            op: max(spread ? 0.3 : 0, 1 - pow(t, spread ? 1.0 : 0.85) * (spread ? 0.8 : 1.2)),
            shadow: d == 0 ? 26 : max(3, 14 * (1 - CGFloat(t))),
            scaleAnchor: .bottom,                                   // common baseline → clean shelf line
            rotAnchor: .leading                                     // pivot the left edge → curls into depth
        )
    }

    // MARK: Feature panel

    private func feature(compact: Bool) -> some View {
        let a = state.current
        return VStack(alignment: .leading, spacing: 0) {
            Text("NOW SPINNING").font(.system(size: 11)).kerning(1).foregroundStyle(p.muted2)
                .padding(.bottom, Space.s3)
            titleView(a)
                .font(.system(size: 26, weight: .bold)).kerning(-0.5)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            Text(a.year.isEmpty ? a.artist : "\(a.artist) · \(a.year)")
                .font(.system(size: 14)).foregroundStyle(p.muted)
                .lineLimit(1).truncationMode(.tail)
                .padding(.top, Space.s2)

            HStack(spacing: Space.s2) {
                if a.lossless { Pill(text: "LOSSLESS", filled: true) }
                Pill(text: a.format)
            }
            .padding(.vertical, Space.s4)

            let owners = state.owners(of: a)
            if !owners.isEmpty {
                HStack(spacing: Space.s2) {
                    OwnersMacaron(owners: owners, size: 24)
                    Text(owners.count == 1 ? "Someone you follow owns this"
                                            : "\(owners.count) people you follow own this")
                        .font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                }
                .padding(.bottom, Space.s4)
            }

            HStack(spacing: Space.s2) {
                Button { state.play(a, on: player) } label: {
                    HStack(spacing: Space.s2) {
                        Image(systemName: "play.fill").font(.system(size: 12))
                        Text("Play").font(.system(size: 13, weight: .bold)).lineLimit(1)
                    }
                    .foregroundStyle(p.accentInk)
                    .padding(.vertical, 11).padding(.horizontal, Space.s5)
                    .background(Capsule().fill(p.accent))
                    .fixedSize()
                }
                .buttonStyle(.soft)
                .opacity(a.isPlayable ? 1 : 0.4)
                .disabled(!a.isPlayable)

                flipButton(a.isFavourite ? "heart.fill" : "heart", tip: a.isFavourite ? "Remove favourite" : "Favourite", bounce: a.isFavourite) { state.toggleFavourite(a.id) }
                flipButton("chevron.left", tip: "Previous album") { state.flip(-1) }
                flipButton("chevron.right", tip: "Next album") { state.flip(1) }
            }

            FilterList().padding(.top, compact ? Space.s4 : Space.s7)
            if !compact { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The now-spinning title. Special albums get a bespoke treatment (gold for "Forever Alone").
    @ViewBuilder private func titleView(_ a: Album) -> some View {
        if AlbumTheme.isForeverAlone(a) {
            Text(a.title)
                .foregroundStyle(AlbumTheme.gold)
                .shadow(color: Color(red: 0.85, green: 0.65, blue: 0.25).opacity(0.55), radius: 8, y: 1)
        } else {
            Text(a.title).foregroundStyle(p.text)
        }
    }

    private func flipButton(_ system: String, tip: String, bounce: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15, weight: .medium))
                .foregroundStyle(p.text)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 40, height: 40)
                .background(Circle().fill(p.glassFill))
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .tip(tip)
    }

}

/// The clickable filter list (all / favourites / downloaded / bandcamp / imported) with live counts.
struct FilterList: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Namespace private var ns

    private let rows: [(AppState.Filter, String)] = [
        (.all, "all"), (.favourites, "favourites"), (.downloaded, "downloaded"),
        (.bandcamp, "bandcamp"), (.imported, "imported")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                let on = state.filter == r.0
                Button {
                    withAnimation(Motion.glide) { state.filter = r.0 }
                } label: {
                    HStack(spacing: 8) {
                        // Active-row indicator that glides between rows.
                        Capsule()
                            .fill(on ? p.accent : .clear)
                            .frame(width: 3, height: 14)
                            .overlay {
                                if on { Capsule().fill(p.accent).matchedGeometryEffect(id: "filterBar", in: ns) }
                            }
                        HStack(spacing: 4) {
                            Text(r.1).font(.system(size: 13, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? p.text : p.muted)
                            Text("\(state.count(for: r.0))").font(.system(size: 9)).baselineOffset(6)
                                .foregroundStyle(p.muted2)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: 8, active: on)
                }
                .buttonStyle(.soft(hover: 1.0, press: 0.97, brighten: 0))
            }
        }
    }
}

/// The two cover-carousel looks the user can pick in Settings.
enum CrateStyle: String, CaseIterable, Identifiable {
    case coverflow, vinyl, spread
    var id: String { rawValue }
    var label: String {
        switch self {
        case .coverflow: "Coverflow"
        case .vinyl:     "Vinyl"
        case .spread:    "Wall"
        }
    }
    var blurb: String {
        switch self {
        case .coverflow: "Covers fanned in a shelf"
        case .vinyl:     "Front album pulled from its sleeve"
        case .spread:    "More covers, spread wide"
        }
    }
}

/// The front album rendered as a vinyl record slipped halfway out of its sleeve —
/// the sleeve is the cover art; the disc's centre label reuses the cover.
struct VinylFront: View {
    let album: Album
    var corner: CGFloat = 14
    /// Play-count wear on the pulled-out record (0 = mint).
    var wear: Double = 0
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack(alignment: .leading) {
                // The record, pulled out to the left (drawn behind the sleeve).
                disc(s * 0.98).offset(x: -s * 0.5)
                // The sleeve = the album cover.
                AlbumArt(album: album, corner: corner)
                    .frame(width: s, height: s)
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 6, y: 8)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .accessibilityElement()
        .accessibilityLabel("Now spinning: \(album.title) by \(album.artist)")
    }

    private func disc(_ diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.black)
            // Grooves.
            ForEach(0..<6, id: \.self) { i in
                Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    .padding(diameter * (0.07 + Double(i) * 0.058))
            }
            // Soft sheen sweeping across the vinyl.
            Circle().fill(AngularGradient(
                colors: [.white.opacity(0.12), .clear, .white.opacity(0.06), .clear, .white.opacity(0.10)],
                center: .center))
                .blendMode(.plusLighter)
            // Play-count patina.
            VinylPatina(wear: wear).clipShape(Circle())
            // Centre label = the cover art, clipped round.
            AlbumArt(album: album, corner: 0)
                .frame(width: diameter * 0.4, height: diameter * 0.4)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1))
            // Spindle hole.
            Circle().fill(p.page).frame(width: diameter * 0.035)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.5), radius: 22, x: -10, y: 14)
    }
}
