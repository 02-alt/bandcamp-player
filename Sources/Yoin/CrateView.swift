import SwiftUI

/// The 3D "record crate" — covers receding into depth, front cover = current album.
struct CrateView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    /// Off by default: the deck is swipe/scroll/click/arrow-key navigable, so the on-screen ◀ ▶
    /// buttons are redundant clutter. Opt back in from Settings ▸ Accessibility for an explicit,
    /// always-visible target (keyboard/motor use, or anyone who prefers a button to a gesture).
    @AppStorage("crateArrows") private var crateArrows = false

    /// Smallest layout (a tiny, near-square window): the header is gone and the deck shows a single
    /// large focused cover with just a sliver of each neighbour. Set by MainPanel from the panel size.
    var solo: Bool = false

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
        Group {
            if state.albums.isEmpty {
                CollectionEmptyState()
            } else {
                deckLayout
            }
        }
        .task { if state.isConnected { await state.buildFriendOwnership() } }
        // ← / → flip through the crate (matching the ◀ ▶ buttons). Withdrawn while search or the
        // command palette is open so their own lists keep the arrow keys.
        .background { crateKeyNav }
    }

    @ViewBuilder private var crateKeyNav: some View {
        if !state.searchOpen && !state.paletteOpen && state.visibleAlbums.count > 1 {
            Button("") { state.flip(-1) }.keyboardShortcut(.leftArrow, modifiers: []).hidden()
            Button("") { state.flip(1) }.keyboardShortcut(.rightArrow, modifiers: []).hidden()
        }
    }

    private var deckLayout: some View {
        GeometryReader { geo in
            // Below this width the deck + side panel no longer fit side-by-side.
            let compact = geo.size.width < 820
            // How much of the feature panel the current height affords; below `.hidden` ONLY the
            // cover carousel remains (the player bar lives in RootView and is always present).
            let detail = Self.featureDetail(forHeight: geo.size.height)

            // Small height (feature panel gone) → a plain flat carousel: upright, evenly spaced,
            // filling the width. "Wall" keeps its signature spread even then.
            let flat = detail == .hidden && state.crateStyle != .spread
            // While there's still a little vertical room, tuck a title/artist label under each cover;
            // shrink further and the labels drop away, leaving just the covers.
            let flatTitles = flat && geo.size.height >= 250

            // Scale the front cover to fill as much of the deck area as fits. When the feature panel
            // is hidden the deck owns the whole height, so the cover can grow much larger — but leave
            // headroom for the label row when titles are shown.
            let flatHeightFactor: CGFloat = detail == .hidden ? (flatTitles ? 0.52 : 0.66) : 0.46
            let cardSize: CGFloat = compact
                ? min(min(max(geo.size.width * 0.62, 220), geo.size.height * flatHeightFactor), 480)
                : min(min(max(geo.size.width * 0.5, 240), geo.size.height * 0.82), 640)

            if solo {
                // A clearly taller-than-wide window → a vertical coverflow (focused cover big and
                // centred, neighbours receding up and down). Otherwise the horizontal single-cover
                // layout (one big cover, a sliver of each side neighbour).
                let portrait = geo.size.height > geo.size.width * 1.15
                if portrait {
                    let card = min(geo.size.width * 0.78, geo.size.height * 0.44)
                    deck(cardSize: card, fanned: false, width: geo.size.width,
                         solo: true, portrait: true, height: geo.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let soloCard = min(geo.size.width * 0.72, geo.size.height * 0.92)
                    deck(cardSize: soloCard, fanned: false, width: geo.size.width, solo: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if compact {
                VStack(spacing: Space.s5) {
                    deck(cardSize: cardSize, fanned: true, width: geo.size.width, flat: flat, flatTitles: flatTitles)
                        // With a panel below, cap the deck so a short window keeps room for it; once
                        // the panel is gone (very short window) let the carousel take the whole area.
                        .frame(maxWidth: .infinity, maxHeight: detail == .hidden ? .infinity : geo.size.height * 0.52)
                        .padding(.top, Space.s6)   // keep the fan clear of the header buttons
                    if detail != .hidden {
                        ScrollView(.vertical, showsIndicators: false) {
                            feature(compact: true, detail: detail)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if detail == .hidden {
                // No room for the side panel — the carousel spans the full width.
                deck(cardSize: cardSize, fanned: state.crateStyle == .spread, width: geo.size.width, flat: flat, flatTitles: flatTitles)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Sized to the content, not the deck: the panel is right-anchored and its column is
                // left-aligned, so any width beyond what the text/controls need becomes dead space
                // between the column and the window's right border. 224 comfortably holds a two-line
                // title, the tag pills and the filter list without leaving the short Play+♥ row
                // stranded far from the edge.
                let featureWidth = min(224, geo.size.width * 0.26)
                let deckWidth = geo.size.width - featureWidth - Space.s6
                // The feature panel is up (medium/large window): keep the tight pile — a big hero
                // cover with the rest peeking behind. Only "Wall" fans its covers wide. (Short
                // windows drop the panel entirely and switch to the flat carousel above.)
                let fanned = state.crateStyle == .spread
                HStack(spacing: Space.s6) {
                    // The deck occupies the space left of the feature panel.
                    deck(cardSize: cardSize, fanned: fanned, width: deckWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    feature(compact: false, detail: detail)
                        .frame(width: featureWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    /// Progressive disclosure of the feature panel as the window height shrinks. Items drop from
    /// the bottom up (least essential first: filter list → tags/owners → controls → title), and
    /// below `.title` the panel disappears entirely, leaving just the cover carousel + player bar
    /// (the two non-negotiable elements at the minimum window size).
    enum FeatureDetail: Int, Comparable {
        case hidden = 0   // nothing — the carousel spans the whole content area
        case title        // NOW SPINNING + title + artist
        case controls     // + Play / favourite / prev-next row
        case tags         // + LOSSLESS/format pills + "owns this" note
        case full         // + filter list (all / favourites / …)
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    static func featureDetail(forHeight h: CGFloat) -> FeatureDetail {
        // Thresholds track the panel's actual stacked content height (title ~114, +controls,
        // +tags/owners ~100, +filter list ~176 → ~435 at full) plus a little slack — not a
        // generous reserve. Set too high, the filter list vanished on ordinary MacBook-sized
        // windows (the deck sits below the tab bar and above the docked player bar, so it only
        // clears ~660 on a very tall window); ~520 shows the full panel wherever it genuinely fits.
        switch h {
        case ..<300: return .hidden
        case ..<380: return .title
        case ..<450: return .controls
        case ..<520: return .tags
        default:     return .full
        }
    }

    // MARK: Deck

    private func deck(cardSize: CGFloat, fanned: Bool, width: CGFloat, flat: Bool = false, flatTitles: Bool = false, solo: Bool = false, portrait: Bool = false, height: CGFloat = 0) -> some View {
        let albums = state.visibleAlbums
        // Flat mode fills the width with an even row, so show as many as fit (not the fan's fixed cap).
        let vis = flat ? min(albums.count, Int(width / (cardSize + flatGap(cardSize))) + 2) : visible
        // Flat mode centres the focused card and fans neighbours to both sides; how many fit per side.
        let flatHalf = flat ? Int(width / (2 * (cardSize + flatGap(cardSize)))) + 1 : 0
        // Portrait coverflow stacks covers vertically; how many fit above/below the focused one.
        let vHalf = portrait ? max(1, Int(height / (2 * coverflowVStep(cardSize))) + 1) : 0
        return ZStack {
            if albums.isEmpty {
                Text("Nothing here yet").font(.system(size: 15)).foregroundStyle(p.muted)
            }
            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                let d = depth(of: index, count: albums.count)
                let n = albums.count
                // Signed distance from the focused card: negative = to its left, positive = right.
                let off = d <= n / 2 ? d : d - n
                if solo ? (portrait ? abs(off) <= vHalf : abs(off) <= 1) : (flat ? abs(off) <= flatHalf : d < vis) {
                    let g = portrait ? coverflowVTransform(off: off, cardSize: cardSize)
                                 : solo ? soloTransform(off: off, cardSize: cardSize, width: width)
                                 : flat ? flatTransform(off: off, cardSize: cardSize)
                                 : (fanned ? fanTransform(d, cardSize: cardSize, width: width)
                                           : stackTransform(d, cardSize: cardSize))
                    VStack(spacing: 6) {
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
                        // Sink the receding tail into shadow so it doesn't show through the
                        // feature-panel text on the right (esp. bright covers). Front two stay clear.
                        // Flat carousel keeps every card evenly bright — no tail dimming.
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(flat ? 0 : min(0.6, max(0, Double(d) - 1) * 0.16)))
                        }
                        .shadow(color: .black.opacity(0.45), radius: g.shadow, x: flat ? 0 : -14, y: flat ? 10 : 18)

                        // Flat carousel with room to spare: a title/artist label beneath each cover.
                        if flatTitles {
                            VStack(spacing: 1) {
                                Text(album.title).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(p.text)
                                Text(album.artist).font(.system(size: 11))
                                    .foregroundStyle(p.muted)
                            }
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.center)
                            .frame(width: cardSize)
                        }
                    }
                        .scaleEffect(g.scale, anchor: g.scaleAnchor)
                        .rotation3DEffect(.degrees(g.rotY), axis: (x: 0, y: 1, z: 0), anchor: g.rotAnchor, perspective: 0.6)
                        .rotation3DEffect(.degrees(g.rotX), axis: (x: 1, y: 0, z: 0))
                        .offset(x: g.x, y: g.y)
                        .opacity(g.op)
                        // Portrait coverflow stacks overlap, so draw nearest-to-focus on top.
                        .zIndex(portrait ? Double(1000 - abs(off)) : Double(vis - d))
                        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: state.front)
                        .modifier(LinkCursor())
                        .onTapGesture {
                            if didDrag { return }   // ignore the tap that ends a drag
                            if d == 0 {
                                // Horizontal single-cover solo (short narrow window) has no room for
                                // the album screen, so its focused cover plays. The portrait coverflow
                                // (tall window) and the wider layouts open the album page instead.
                                if solo && !portrait { state.play(album, on: player) }
                                else { state.openedAlbumID = album.id }
                            } else { state.flip(d <= vis / 2 ? d : -(albums.count - d)) }
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
                    // Horizontal layouts: drag left → forward. Portrait coverflow is vertical, so
                    // drag up → forward instead (the natural gesture for a tall window).
                    let travel = portrait ? -value.translation.height : -value.translation.width
                    let steps = Int((travel / dragPerCard).rounded())
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

    /// Gap between cards in the flat carousel (a bit of breathing room, scaled to the cover size).
    private func flatGap(_ cardSize: CGFloat) -> CGFloat { cardSize * 0.24 }

    /// Short & wide windows: a plain horizontal carousel — cards upright (no tilt), same size, evenly
    /// spaced. The focused album sits centred and reads full-bright; its neighbours fan out to either
    /// side and dim slightly with distance. Flip/drag/scroll slide the row. `off` is the signed
    /// distance from the focused card (0 = centre, negative = left, positive = right).
    private func flatTransform(off: Int, cardSize: CGFloat) -> CardGeometry {
        let step = cardSize + flatGap(cardSize)
        return (
            x: CGFloat(off) * step,                        // 0 = centred in the deck
            y: 0,
            scale: 1,                                      // upright, uniform — a regular carousel
            rotY: 0,
            rotX: 0,
            op: off == 0 ? 1 : max(0.4, 1 - Double(abs(off)) * 0.16),
            shadow: off == 0 ? 22 : 12,
            scaleAnchor: .center,
            rotAnchor: .center
        )
    }

    /// Vertical spacing between stacked covers in the portrait coverflow (they overlap, so < card).
    private func coverflowVStep(_ cardSize: CGFloat) -> CGFloat { cardSize * 0.44 }

    /// Portrait coverflow: the focused cover sits big and centred, neighbours recede up and down,
    /// shrinking, dimming and tilting into depth like a vertical wheel. `off` is the signed distance
    /// from the focused cover (negative = above, positive = below).
    private func coverflowVTransform(off: Int, cardSize: CGFloat) -> CardGeometry {
        let d = abs(off)
        return (
            x: 0,
            y: CGFloat(off) * coverflowVStep(cardSize),
            scale: off == 0 ? 1 : max(0.5, 1 - CGFloat(d) * 0.13),
            rotY: 0,
            rotX: Double(off) * 20,                         // tilt neighbours away, curling the stack
            op: off == 0 ? 1 : max(0.32, 1 - Double(d) * 0.22),
            shadow: off == 0 ? 28 : 8,
            scaleAnchor: .center,
            rotAnchor: .center
        )
    }

    /// Solo layout: the focused cover fills the centre; each neighbour is pushed to the window edge
    /// so only a dim sliver peeks in. `off` is the signed distance (−1 = left, 0 = centre, +1 = right).
    private func soloTransform(off: Int, cardSize: CGFloat, width: CGFloat) -> CardGeometry {
        let sliver = cardSize * 0.14                        // how much of a neighbour stays visible
        let edge = width / 2 + cardSize / 2 - sliver        // centre of a neighbour, mostly off-screen
        return (
            x: CGFloat(off) * edge,                         // 0 = centred
            y: 0,
            scale: 1,
            rotY: 0,
            rotX: 0,
            op: off == 0 ? 1 : 0.4,
            shadow: off == 0 ? 26 : 8,
            scaleAnchor: .center,
            rotAnchor: .center
        )
    }

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

    private func feature(compact: Bool, detail: FeatureDetail) -> some View {
        let a = state.current
        let owners = state.owners(of: a)
        return VStack(alignment: .leading, spacing: 0) {
            // NOW SPINNING + title + artist form one tight block, bottom-anchored in a fixed-height
            // area (114 = header + two title lines + artist). The block hugs the tags line below, so
            // the title sits tight above the artist with no reserved gap, while everything from the
            // tags down stays FIXED whether the title is one or two lines — the only slack is above
            // NOW SPINNING, at the top of the panel where there's room to spare.
            VStack(alignment: .leading, spacing: 0) {
                Text("NOW SPINNING").font(.system(size: 11)).kerning(1).foregroundStyle(p.muted2)
                    .padding(.bottom, Space.s3)
                // Title + artist blur-swap as you flip albums (keyed on the album id so SwiftUI
                // treats each album's text as a fresh view and runs the transition).
                VStack(alignment: .leading, spacing: 0) {
                    titleView(a)
                        .font(.system(size: 26, weight: .bold)).kerning(-0.5)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Text(a.year.isEmpty ? a.artist : "\(a.artist) · \(a.year)")
                        .font(.system(size: 14)).foregroundStyle(p.muted)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.top, Space.s2)
                }
                .id(a.id)
                .transition(.blurReplace)
            }
            .frame(height: 114, alignment: .bottomLeading)
            .animation(.easeInOut(duration: 0.35), value: a.id)

            if detail >= .tags {
                HStack(spacing: Space.s2) {
                    if a.lossless { Pill(text: "LOSSLESS", filled: true) }
                    Pill(text: a.format)
                }
                .padding(.top, Space.s4)

                // Owners note in a fixed-height slot so the Play row below never shifts as you flip
                // between albums a friend owns and ones they don't — the note just fades in/out here.
                HStack(spacing: Space.s2) {
                    if !owners.isEmpty {
                        OwnersMacaron(owners: owners, size: 24)
                        Text(owners.count == 1 ? "Someone you follow owns this"
                                                : "\(owners.count) people you follow own this")
                            .font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                    }
                }
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.s4).padding(.bottom, Space.s5)
            }

            if detail >= .controls {
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
                    if crateArrows {
                        flipButton("chevron.left", tip: "Previous album") { state.flip(-1) }
                        flipButton("chevron.right", tip: "Next album") { state.flip(1) }
                    }
                }
                // When the tags/owners block above is hidden, restore the gap under the title.
                .padding(.top, detail >= .tags ? 0 : Space.s5)
            }

            if detail >= .full {
                FilterList().padding(.top, compact ? Space.s4 : Space.s7)
            }
            if !compact { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: detail)
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
