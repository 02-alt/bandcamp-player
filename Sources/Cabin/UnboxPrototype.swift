import SwiftUI
import AppKit

// MARK: - New-album card (prototype)
//
// A stand-alone feel test for the "when you buy a new album" moment. Kept deliberately simple:
// a single card with the album's info + two actions (First Listen, Share). First Listen opens a
// distinct focused screen; finishing it lands on a "thank the artist" card. Nothing here touches
// the real library — it runs on baked-in sample covers so we can iterate on the layout/flow.

/// One album for the prototype — a real one from the library (with artwork) or a gradient fallback.
private struct ProtoAlbum: Identifiable {
    let id = UUID()
    let title: String
    let artist: String
    var artwork: NSImage? = nil
    var artworkURL: URL? = nil
    var accent: Color = .white               // dominant cover colour, for the buttons/heart
    var accent2: Color = Color(white: 0.2)   // used only by the gradient fallback
    var source: Album? = nil                 // the real library album, for actual playback
}

/// A single prototype album from a real library album (cover + auto-extracted accent).
private func makeProtoAlbum(from a: Album) -> ProtoAlbum {
    var p = ProtoAlbum(title: a.title, artist: a.artist, artwork: a.artwork, artworkURL: a.artworkURL, source: a)
    if let cg = a.artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil),
       let c = AmbientColor.extract(from: cg) { p.accent = c }
    return p
}

/// Fallback for when the album can't be resolved (e.g. a track with no albumID): build the
/// prototype straight from the playing track so First Listen still renders.
private func makeProtoAlbum(from t: Track) -> ProtoAlbum {
    let img = t.artworkData.flatMap { NSImage(data: $0) }
    var p = ProtoAlbum(title: t.title, artist: t.artist, artwork: img, artworkURL: t.artworkURL, source: nil)
    if let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil),
       let c = AmbientColor.extract(from: cg) { p.accent = c }
    return p
}

/// Build prototype albums from the real library; fall back to gradient samples for an empty library.
private func makeProtoAlbums(from albums: [Album]) -> [ProtoAlbum] {
    let real = albums.prefix(30).map(makeProtoAlbum(from:))
    return real.isEmpty ? sampleAlbums : Array(real)
}

/// Presents the First Listen screen standalone (from the Crate button / context menu), for a real album.
struct FirstListenPresenter: View {
    let album: Album
    /// One-shot First Listen starts playback on appear; as a Now Playing style the track is
    /// already playing, so pass `false` to keep it from restarting from the top.
    var restartPlayback: Bool = true
    var onClose: () -> Void = {}
    var body: some View {
        FirstListenScreen(album: makeProtoAlbum(from: album), source: album,
                          restartPlayback: restartPlayback,
                          onFinish: onClose, onClose: onClose)
    }
}

/// First Listen bound to the live player, used as a Now Playing style. Prefers the resolved
/// album (so notes/credits/liner load); falls back to the current track so it always renders
/// while something is playing — never the old Now Playing.
struct FirstListenNowPlaying: View {
    let album: Album?
    let track: Track?
    var onClose: () -> Void = {}
    var body: some View {
        if let proto = album.map(makeProtoAlbum(from:)) ?? track.map(makeProtoAlbum(from:)) {
            FirstListenScreen(album: proto, source: album, restartPlayback: false,
                              onFinish: onClose, onClose: onClose)
        }
    }
}

private let sampleAlbums: [ProtoAlbum] = [
    .init(title: "Ambient Works", artist: "Selene",
          accent: Color(red: 0.36, green: 0.55, blue: 0.92), accent2: Color(red: 0.16, green: 0.20, blue: 0.42)),
    .init(title: "Ferric", artist: "Kōya",
          accent: Color(red: 0.93, green: 0.42, blue: 0.28), accent2: Color(red: 0.42, green: 0.12, blue: 0.10)),
    .init(title: "Meadowlark", artist: "Junia",
          accent: Color(red: 0.30, green: 0.72, blue: 0.52), accent2: Color(red: 0.10, green: 0.30, blue: 0.24)),
]

/// A few placeholder tracks for the card / First Listen screen.
private let sampleTracks: [(String, String)] = [
    ("Opening", "3:12"), ("Drift", "4:05"), ("Ferric", "2:58"),
    ("Meadowlark", "5:21"), ("Closing", "3:44"),
]

/// An album cover: the real artwork (embedded or remote), else a gradient stand-in.
@ViewBuilder
private func albumCover(_ album: ProtoAlbum) -> some View {
    if let img = album.artwork {
        Image(nsImage: img).resizable().scaledToFill()
    } else if let url = album.artworkURL {
        CachedRemoteImage(url: url) { gradientCover(album) }
    } else {
        gradientCover(album)
    }
}

private func gradientCover(_ album: ProtoAlbum) -> some View {
    ZStack {
        LinearGradient(colors: [album.accent, album.accent2],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        Circle().fill(.white.opacity(0.12)).frame(width: 160).offset(x: -50, y: -50).blur(radius: 30)
        Circle().fill(.black.opacity(0.18)).frame(width: 120).offset(x: 60, y: 55).blur(radius: 24)
    }
}

struct UnboxPrototypeView: View {
    enum Phase { case card, listen, thanks }

    /// The real library, passed in when the overlay opens. Empty → gradient samples.
    var realAlbums: [Album] = []
    /// Dismiss the overlay.
    var onClose: () -> Void = {}

    @EnvironmentObject private var state: AppState
    @State private var albumIndex = 0
    @State private var phase: Phase = .card
    @State private var toast: String? = nil
    @State private var albums: [ProtoAlbum] = sampleAlbums
    /// The real tracklist (with durations) for the album on screen, so the card's "INCLUDING" list and
    /// LENGTH match the actual record. Resolved per-album; falls back to samples when unavailable.
    @State private var cardTracks: [Track] = []
    @State private var tracksResolved = false   // true once loadCardTracks has settled
    @State private var tiltX: CGFloat = 0   // cover parallax (degrees)
    @State private var tiltY: CGFloat = 0

    // Arrival choreography — the record lands, its glow blooms, then the actions settle in.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var headerIn = false
    @State private var coverIn = false
    @State private var buttonsIn = false

    private let p = Palette(scheme: .dark)   // the reveal is always dark; match the app's palette

    private var album: ProtoAlbum { albums.isEmpty ? sampleAlbums[0] : albums[albumIndex % albums.count] }
    /// Demo: show the Bandcamp Friday badge on every other cover. Real: BandcampFriday.isToday(purchaseDate).
    private var boughtOnBandcampFriday: Bool { albumIndex % 2 == 0 }

    var body: some View {
        ZStack {
            // Frost + dim the real app sitting behind this overlay. A heavier material = more blur.
            Color.clear.background(.thickMaterial).ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()

            hero

            demoNav

            topBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(Space.s5)

            if phase == .listen {
                FirstListenScreen(album: album, source: album.source,
                                  onFinish: { withAnimation(.easeInOut(duration: 0.4)) { phase = .thanks } },
                                  onClose:  { withAnimation(.easeInOut(duration: 0.4)) { phase = .card } })
                    .transition(.opacity)
                    .zIndex(2)
            }

            if phase == .thanks {
                ThanksCard(album: album,
                           liked: album.source.map { state.album(id: $0.id)?.isFavourite ?? $0.isFavourite } ?? false,
                           canLike: album.source != nil,
                           onThank: {
                               if let s = album.source?.bandcampItemURL, let url = URL(string: s) {
                                   NSWorkspace.shared.open(url)
                                   flashToast("Opened \(album.artist) on Bandcamp")
                               } else {
                                   flashToast("No Bandcamp page for this album")
                               }
                           },
                           onLike:  { if let id = album.source?.id { state.toggleFavourite(id) } },
                           onDone:  { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { phase = .card } })
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(2)
            }

            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(.black.opacity(0.8)))
                    .overlay(Capsule().stroke(.white.opacity(0.15)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .frame(minWidth: 460, minHeight: 640)
        .onAppear {
            let built = makeProtoAlbums(from: realAlbums)
            if !built.isEmpty { albums = built }
            reveal()
        }
        .task(id: album.source?.id) { await loadCardTracks() }
    }

    /// Resolve the on-screen album's real tracklist (with durations) for the card, preferring the
    /// instant cache and only fetching when nothing's cached.
    private func loadCardTracks() async {
        cardTracks = []
        tracksResolved = false
        guard let src = album.source else { return }
        var tracks = TracklistCache.shared.displayTracks(for: src) ?? []
        // Empty, or a legacy cache entry with no durations — re-scrape so the LENGTH line is
        // correct. Legacy entries are invalidated first so resolve doesn't just return them again.
        if tracks.isEmpty || tracks.contains(where: { $0.duration == nil }) {
            if !tracks.isEmpty { TracklistCache.shared.invalidate(forItemURL: src.bandcampItemURL) }
            let fresh = await state.resolveTracks(for: src)
            if album.source?.id != src.id { return }   // ignore a stale resolve after cycling
            if !fresh.isEmpty { tracks = fresh }
        }
        guard album.source?.id == src.id else { return }
        cardTracks = tracks
        tracksResolved = true
    }

    /// The record arrives: header fades in, the cover springs up from below with a soft
    /// overshoot while its glow blooms behind it, then the actions settle in last.
    private func reveal() {
        guard !reduceMotion else { headerIn = true; coverIn = true; buttonsIn = true; return }
        withAnimation(.easeOut(duration: 0.4)) { headerIn = true }
        withAnimation(.spring(response: 0.62, dampingFraction: 0.74).delay(0.08)) { coverIn = true }
        withAnimation(.easeOut(duration: 0.4).delay(0.34)) { buttonsIn = true }
    }

    // MARK: The hero (big cover + overlaid info + buttons)

    private var hero: some View {
        GeometryReader { geo in
            let cover = min(geo.size.width * 0.68, geo.size.height * 0.58)
            let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            VStack(spacing: Space.s5) {
                header
                    .opacity(headerIn ? 1 : 0)
                    .offset(y: headerIn ? 0 : 8)

                ZStack(alignment: .bottomLeading) {
                    albumCover(album)
                        .frame(width: cover, height: cover)
                        .clipShape(shape)
                        .overlay(   // top scrim so the tracklist stays legible over any cover
                            LinearGradient(colors: [.black.opacity(0.5), .clear],
                                           startPoint: .top, endPoint: .center)
                                .clipShape(shape))
                        .overlay(gloss.clipShape(shape))          // moving sheen
                        .shadow(color: .black.opacity(0.55), radius: 34, x: -tiltY, y: 22 + tiltX)

                    tracklistCorner
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(Space.s4)

                    infoPanel
                        .frame(width: cover * 0.66, alignment: .leading)
                        .padding(Space.s4)
                }
                .frame(width: cover, height: cover)
                // Tilt the cover + info only …
                .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                // … then the soft colour glow sits BEHIND, un-tilted, so its blurred edge can't
                // poke out on the side as the cover rotates.
                .background(
                    albumCover(album)
                        .frame(width: cover, height: cover)
                        .clipShape(shape)
                        .blur(radius: 55).opacity(0.45).scaleEffect(1.12)
                )
                .onContinuousHover { hover in
                    switch hover {
                    case .active(let p):
                        let dx = (p.x / cover) - 0.5
                        let dy = (p.y / cover) - 0.5
                        withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) {
                            tiltY = dx * 1.4
                            tiltX = -dy * 1.4
                        }
                    case .ended:
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { tiltX = 0; tiltY = 0 }
                    }
                }
                // Arrival: rise + settle with a soft overshoot, glow blooming with it.
                .scaleEffect(coverIn ? 1 : 0.86)
                .offset(y: coverIn ? 0 : 44)
                .opacity(coverIn ? 1 : 0)

                heroButtons
                    .opacity(buttonsIn ? 1 : 0)
                    .offset(y: buttonsIn ? 0 : 12)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    /// Makes clear what this screen is.
    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11))
                Text("NEW IN YOUR COLLECTION").font(.system(size: 11, weight: .bold)).kerning(1)
            }
            .foregroundStyle(p.muted2)
            Text("You just bought this album.")
                .font(.system(size: 13)).foregroundStyle(p.muted)
        }
    }

    /// Right-aligned tracklist in the cover's top-right corner (album-back styling).
    private var tracklistCorner: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(spacing: 1) {   // LENGTH sits above, centred over INCLUDING; block stays in the corner
                let length = totalLengthLabel
                if !length.isEmpty {
                    Text("LENGTH \(length)").font(.system(size: 10, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text("INCLUDING:").font(.system(size: 18, weight: .heavy)).kerning(-0.2)
            }
            .padding(.bottom, 5)
            ForEach(Array(displayTracks.enumerated()), id: \.offset) { i, t in
                Text("\(i + 1). \"\(t.0.uppercased())\"\(t.1.isEmpty ? "" : "  \(t.1)")")
                    .font(.system(size: 13, weight: .medium))
            }
            if extraTrackCount > 0 {
                Text("+\(extraTrackCount) more").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
    }

    private static func mmss(_ secs: TimeInterval) -> String {
        let s = Int(secs.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The real album's tracks (title + length), capped at 7 so the corner stays short; falls back to
    /// the sample placeholders when we couldn't resolve a real tracklist.
    private var displayTracks: [(String, String)] {
        if !cardTracks.isEmpty {
            return cardTracks.prefix(7).map { ($0.title, $0.duration.map(Self.mmss) ?? "") }
        }
        return sampleTracks
    }

    /// How many real tracks are hidden by the 7-track cap (0 when not truncated / on the samples).
    private var extraTrackCount: Int { max(0, cardTracks.count - 7) }

    /// Total running time of the *whole* record (not just the shown 7), when durations are known.
    private var totalLengthLabel: String {
        if !cardTracks.isEmpty {
            // Hide until the tracklist has settled — otherwise a partial sum during load
            // shows a misleadingly short length (the "19:20 by moment" flicker).
            guard tracksResolved else { return "" }
            let durations = cardTracks.compactMap(\.duration)
            guard durations.count == cardTracks.count else { return "" }
            return Self.mmss(durations.reduce(0, +))
        }
        // Fallback to the sample placeholders' total.
        let secs = sampleTracks.reduce(0) { acc, t in
            let parts = t.1.split(separator: ":").compactMap { Int($0) }
            return acc + (parts.count == 2 ? parts[0] * 60 + parts[1] : 0)
        }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    /// A diagonal specular sheen that slides as the cover tilts.
    private var gloss: some View {
        LinearGradient(colors: [.white.opacity(0.28), .clear],
                       startPoint: .topLeading, endPoint: .center)
            .blendMode(.plusLighter)
            .offset(x: tiltY * 2.5, y: tiltX * 2.5)
            .allowsHitTesting(false)
    }

    /// The frosted info panel over the cover's bottom-left — light like a printed insert card.
    private var infoPanel: some View {
        let ink = Color(white: 0.10)
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.system(size: 20, weight: .bold)).kerning(-0.4)
                    Text(album.artist).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.opacity(0.55))
                }
                Spacer()
                Text("PD1P-\(2000 + albumIndex)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(ink.opacity(0.5))
            }

            Text("You directly supported \(album.artist) by buying this album — straight from them, no middle layer.")
                .font(.system(size: 12)).foregroundStyle(ink.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            // Bandcamp Friday — the day fees are waived, so 100% goes to the artist. Extra weight
            // for the support message. (Real logic: BandcampFriday.isToday(purchaseDate); demo drives
            // it off the cover index so both states are visible while cycling.)
            if boughtOnBandcampFriday {
                HStack(spacing: 4) {
                    Image(systemName: "star.circle.fill").font(.system(size: 10))
                    Text("Bought on Bandcamp Friday").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(ink.opacity(0.8))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(ink.opacity(0.10)))
                .overlay(Capsule().strokeBorder(ink.opacity(0.18)))
            }

            HStack {
                Text("■ Cabin record ■").font(.system(size: 9, weight: .medium))
                Spacer()
                Text(Date.now, format: .dateTime.day().month(.abbreviated).year())
                    .font(.system(size: 9))
            }
            .foregroundStyle(ink.opacity(0.45))
        }
        .foregroundStyle(ink)
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Solid light fill so the insert reads white over any cover (a translucent material took
        // on the dark art behind it and looked grey until you tilted over a lighter area).
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color(white: 0.95))
        )
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }

    private var heroButtons: some View {
        HStack(spacing: Space.s2) {
            Button { withAnimation(.easeInOut(duration: 0.4)) { phase = .listen } } label: {
                Label("First Listen", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Capsule().fill(p.accent))
                    .foregroundStyle(p.accentInk)
            }
            .buttonStyle(.soft)

            Button { flashToast("Share card created") } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Capsule().fill(p.glassFill))
                    .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                    .foregroundStyle(p.text)
            }
            .buttonStyle(.soft)
        }
    }

    // MARK: Top bar (close)

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.14)))
                    .overlay(Circle().stroke(.white.opacity(0.2)))
                    .foregroundStyle(.white)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Demo-only: discreet edge arrows to preview other albums from the library.
    private var demoNav: some View {
        HStack {
            demoChevron("chevron.left")  { cycle(-1) }
            Spacer()
            demoChevron("chevron.right") { cycle(1) }
        }
        .padding(.horizontal, Space.s5)
    }

    private func demoChevron(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cycle(_ delta: Int) {
        guard !albums.isEmpty else { return }
        phase = .card
        albumIndex = (albumIndex + delta + albums.count) % albums.count
    }

    private func flashToast(_ message: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = message }
        let token = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == token { withAnimation(.easeInOut(duration: 0.3)) { toast = nil } }
        }
    }
}

// MARK: - First Listen screen
//
// Deliberately unlike the normal player: full-bleed, dim, minimal chrome — meant to feel like
// sitting down with the record for its first play-through.
private struct FirstListenScreen: View {
    let album: ProtoAlbum
    let source: Album?
    var restartPlayback: Bool = true   // false when used as a persistent Now Playing style
    let onFinish: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("ambientTheming") private var ambientTheming = true
    private let p = Palette(scheme: .dark)

    @State private var appeared = false
    @State private var hovering = false             // mini mode: reveal the controls on hover
    @State private var lyrics: SyncedLyrics? = nil
    @State private var albumTracks: [Track] = []   // the album's tracklist, for the ruler at rest
    @State private var started = false
    // Ruler scrub state.
    @State private var scrubbing = false
    @State private var hoveringTape = false       // reveals the (otherwise dimmed) track label
    @State private var scrubPos: Double = 0      // fractional album position while dragging
    @State private var dragStartPos: Double = 0
    // Side panels: the left "Notes" card (artist bio / album notes / credits, tabbed) and the
    // right synced-lyrics column. Both open from the bottom bar; the centre cover never shifts.
    @State private var showNotes = false
    @State private var showLyrics = false
    @State private var notesTab: NotesTab = .artist
    @State private var artistBio: ArtistBio? = nil
    @State private var bioLoaded = false
    @State private var albumAbout: ArtistBio? = nil   // Genius album description (fallback for the About tab)
    @State private var albumAboutLoaded = false
    @State private var geniusCredits: [GeniusCredit]? = nil   // per-track credits from Genius
    @State private var creditsLoading = false                 // Genius lookup in flight

    var body: some View {
        GeometryReader { geo in content(size: geo.size) }
    }

    /// Height drives the vertical layout: the cover is sized from the room left after the fixed chrome,
    /// the title/transport scale with it, spacing tightens, and as the window gets short we drop the
    /// volume slider then the ruler. Width drives the sides: the two panels shrink in width together
    /// and vanish once they'd get too narrow; below `narrow` we go full compact — a big cover with no
    /// ruler, no pills and no panels, like the mini player.
    private func content(size: CGSize) -> some View {
        let h = size.height
        let w = size.width
        let tight = h < 720          // small laptop / dragged short: tighten vertical rhythm
        let narrow = w < 500         // compact mode: big cover, drop ruler + pills + panels
        let mini = w < 480           // smallest tier: cover fills the window, controls on hover only
        let showVolume = h >= 560
        let gap: CGFloat = tight ? Space.s3 : Space.s5
        // Fixed, top-down height cut-offs, ordered and monotonic: each band, once dropped as the window
        // shrinks, stays dropped — nothing reappears lower down. The ruler goes first, then the volume
        // fader, then the bottom pills; below `narrow` width we're already in the compact big-cover
        // layout (all three gone).
        let showRuler = !narrow && h >= 640
        let showPills = !narrow && h >= 520
        // The ruler band is sized to the ruler's real footprint (top pad + ticks + label) so the centred
        // column never rides up under it, even with no slack on a short window.
        let rulerFootprint: CGFloat = tight ? 92 : 124
        let rulerReserve: CGFloat = showRuler ? rulerFootprint : Space.s5
        let bottomReserve: CGFloat = showPills ? 66 : Space.s5
        let centerW = min(340, max(240, w - 48))
        // The cover is a *flexible square*: this is only its MAX side. Inside the column it shrinks to
        // whatever vertical room is left after the fixed controls, so it can never overlap them — no
        // hand-tuned chrome constant, no overflow. Compact mode lets it grow wider.
        let coverCap = min(centerW, narrow ? 360 : 320)
        // Type/transport scale tracks the cover's likely on-screen size. A rough height budget is fine
        // here — it only affects font size, never whether anything fits.
        let uiCover = max(140, min(coverCap, h - rulerReserve - bottomReserve - 190))
        let ui = min(max(uiCover / 300, 0.85), 1.15)
        // Both side panels share one symmetric width that shrinks with the window; below `panelW`'s
        // floor there's no room and both hide together (the cover stays perfectly centred either way).
        let panelPad: CGFloat = Space.s5
        let panelGap: CGFloat = Space.s4
        let maxPanelW = w / 2 - centerW / 2 - panelPad - panelGap
        let panelW = min(300, maxPanelW)
        let panelsFit = !narrow && maxPanelW >= 180
        let panelH = max(240, min(520, h - rulerReserve - bottomReserve))
        // Centre each panel within its side region (window edge ↔ centre column) instead of hugging the
        // edge, so on a wide window the gap sits equally on both sides of the panel. Floored at the base
        // padding so it never crowds the edge at the tight end.
        let sideRegion = w / 2 - centerW / 2
        let sidePad = max(panelPad, (sideRegion - panelW) / 2)

        return Group {
        if mini {
            miniPlayer(size)
        } else {
        ZStack {
            // Bespoke per-album skin (Yeezus / Admiral / Dollcorpse …) when one applies; else the
            // cover-derived ambient wash over the page colour.
            if ambientTheming, AlbumTheme.hasBackground(source) {
                AlbumTheme.background(for: source, colors: state.ambientPalette).ignoresSafeArea()
            } else {
                p.page.ignoresSafeArea()
                album.accent.opacity(0.10).blendMode(.plusLighter).ignoresSafeArea()
                albumCover(album).frame(width: 520, height: 520).clipShape(Circle())
                    .blur(radius: 140).opacity(0.3).ignoresSafeArea()
            }

            // Centre column stays truly centred; the side panels hang off the edges so a missing
            // lyrics panel never shifts the cover off-centre. The reserve padding centres it within
            // the band between the ruler and the pills so it never overlaps them.
            centerColumn(coverCap: coverCap, ui: ui, gap: gap, showVolume: showVolume)
                .frame(width: centerW)
                .padding(.top, rulerReserve).padding(.bottom, bottomReserve)
                .frame(maxHeight: .infinity)
                .opacity(appeared ? 1 : 0)
        }
        .frame(width: w, height: h)
        .overlay(alignment: .top) {
            if showRuler {
                trackRuler
                    .frame(maxWidth: 640)
                    .padding(.top, tight ? Space.s4 : Space.s7)
                    .padding(.horizontal, Space.s4)
                    .opacity(appeared ? 1 : 0)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .leading) {
            if showNotes, panelsFit {
                notesColumn
                    .frame(width: panelW)
                    .frame(maxHeight: panelH)
                    .padding(.leading, sidePad)
                    .opacity(appeared ? 1 : 0)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            if showLyrics, panelsFit, let lyrics {   // opened by the "Lyrics" pill
                lyricsColumn(lyrics)
                    .frame(width: panelW)
                    .frame(maxHeight: panelH)
                    .padding(.trailing, sidePad)
                    .opacity(appeared ? 1 : 0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onFinish) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.text)
                    .frame(width: 32, height: 32)
                    .glass(in: Circle())
            }
            .buttonStyle(.soft)
            .accessibilityLabel("Close")
            .padding(Space.s5)
        }
        .overlay(alignment: .bottom) {
            // Left "Notes" pill opens the tabbed card; right "Lyrics" pill opens the synced column.
            // The heart stays dead-centre; equal-width side groups keep it from shifting, and a pill
            // only appears when its panel actually has something to show. Hidden in compact mode.
            if showPills {
            HStack(spacing: Space.s4) {
                HStack {
                    togglePill("About", "info.circle", isOn: showNotes) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showNotes.toggle() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                likeButton

                HStack {
                    // Always present (dimmed when this track has no synced lyrics), so toggling
                    // lyrics no longer lives in the right-click menu.
                    togglePill("Lyrics", "quote.bubble", isOn: showLyrics) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showLyrics.toggle() }
                    }
                    .disabled(lyrics == nil)
                    .opacity(lyrics == nil ? 0.4 : 1)
                    .help(lyrics == nil ? "No lyrics for this track"
                                        : (showLyrics ? "Hide lyrics" : "Show lyrics"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 560)
            .padding(.bottom, Space.s6)
            .opacity(appeared ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: lyrics == nil)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        }   // else: the full layout
        }   // Group
        // Smoothly resize the cover and slide the bands in/out as the window crosses a breakpoint,
        // rather than popping. Reduce Motion falls back to no animation.
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: showRuler)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: showPills)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: showVolume)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: narrow)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: mini)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            if let source {
                if restartPlayback, !started {
                    started = true
                    state.play(source, on: player)
                }
                state.loadNotes(for: source.id)   // fetch about/credits for the sheet
            }
            if !bioLoaded {
                bioLoaded = true
                let titles = state.libraryAlbums(byArtist: album.artist).map(\.title)
                Task { artistBio = await ArtistBioService.bio(artist: album.artist, ownedAlbumTitles: titles) }
            }
            if !albumAboutLoaded {
                albumAboutLoaded = true
                // Fall back to Wikipedia (then Genius) for the album description when the source has
                // none (e.g. an imported / non-Bandcamp album like Yeezus, where `about` is empty).
                let artist = album.artist, title = album.title
                Task { albumAbout = await ArtistBioService.albumDescription(artist: artist, album: title) }
            }
        }
        .task(id: player.current?.id) { await loadLyrics() }
        .task(id: player.current?.id) { await loadCredits() }
        .task(id: source?.id) { await loadAlbumTracks() }
        .appContextMenu { firstListenMenuItems() }
    }

    /// The album's tracklist, so the ruler shows real tracks before playback starts (instead of
    /// "LOADING"). Cached list is instant; only fetches when there's nothing cached.
    private func loadAlbumTracks() async {
        guard let src = source else { albumTracks = []; return }
        if let cached = TracklistCache.shared.displayTracks(for: src) { albumTracks = cached }
        if albumTracks.isEmpty {
            let fresh = await state.resolveTracks(for: src)
            if !fresh.isEmpty { albumTracks = fresh }
        }
    }

    /// Right-click menu for the First Listen / Now Playing screen: the current track's actions
    /// (add to playlist, favourite, go to album, …). The lyrics toggle moved to the always-present
    /// bottom "Lyrics" pill, so it's no longer here.
    private func firstListenMenuItems() -> [AppMenuItem] {
        player.current.map { nowPlayingTrackMenuItems(for: $0, state: state, player: player, includeEffects: true) } ?? []
    }

    // MARK: Liner notes / credits — the left "Notes" card (tabbed)

    /// The tabs inside the left Notes card: the artist bio, the album's own notes, and credits.
    private enum NotesTab: Hashable {
        case artist, album, credits
        var title: String {
            switch self {
            case .artist:  "Artist"
            case .album:   "Album"
            case .credits: "Credits"
            }
        }
    }

    /// The album's about / credits text (fetched via state.loadNotes), or nil.
    private var liveSource: Album? { source.flatMap { state.album(id: $0.id) } ?? source }

    /// The pill that toggles a side panel (Notes / Lyrics), accented while its panel is open.
    private func togglePill(_ label: String, _ icon: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isOn ? p.accent : p.text)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .glass(in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? p.accent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.soft)
    }

    /// Paragraph ink for the notes column. Brighter than `p.muted` (0.70) because the column floats
    /// card-less over the cover-tinted ambient, which can be pale (e.g. a light gradient) — so body
    /// text needs more contrast than the app's normal muted tier to stay readable.
    private var bodyInk: Color { p.scheme == .dark ? Color(white: 0.92) : Color(white: 0.14) }

    /// The left column, floating text (no card). Always shows all three tabs — Artist / Album /
    /// Credits — so you can switch between them; the Credits tab is per-song (follows playback).
    private var notesColumn: some View {
        let tabs: [NotesTab] = [.artist, .album, .credits]
        let active = notesTab
        return VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.self) { t in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { notesTab = t } } label: {
                        Text(t.title.uppercased())
                            .font(.system(size: 10, weight: .bold)).kerning(0.5)
                            .lineLimit(1).fixedSize()          // never wrap when the panel is narrow
                            .foregroundStyle(active == t ? p.text : p.muted2)
                            .padding(.vertical, 5).padding(.horizontal, 7)
                            .background(Capsule().fill(active == t ? p.glassFill : Color.clear))
                            .overlay(Capsule().strokeBorder(active == t ? p.edgeSoft : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.soft)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                notesBody(active).frame(maxWidth: .infinity, alignment: .leading)
                    .id(active)   // cross-fade the body when the tab changes
                    .transition(.opacity)
            }
        }
        // Floating text — no card background; a soft shadow keeps it legible over any cover.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 1)
    }

    @ViewBuilder
    private func notesBody(_ tab: NotesTab) -> some View {
        switch tab {
        case .artist:
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(album.artist.uppercased()).font(.system(size: 11, weight: .bold)).kerning(1)
                    .foregroundStyle(p.muted2)
                if let bio = artistBio, !bio.text.isEmpty {
                    Text(bio.text).font(.system(size: 13)).foregroundStyle(bodyInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    attribution("via \(bio.sourceName)", url: bio.sourceURL)
                } else {
                    Text("No artist description.").font(.system(size: 13)).foregroundStyle(p.muted2)
                }
            }
            .textSelection(.enabled)
        case .album:
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("ABOUT THIS ALBUM").font(.system(size: 11, weight: .bold)).kerning(1)
                    .foregroundStyle(p.muted2)
                if let about = liveSource?.about, !about.isEmpty {
                    Text(about).font(.system(size: 13)).foregroundStyle(bodyInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let about = albumAbout, !about.text.isEmpty {
                    Text(about.text).font(.system(size: 13)).foregroundStyle(bodyInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    attribution("via \(about.sourceName)", url: about.sourceURL)
                } else {
                    Text("No album description.").font(.system(size: 13)).foregroundStyle(p.muted2)
                }
                albumTracklist
            }
            .textSelection(.enabled)
        case .credits:
            creditsBody
        }
    }

    /// The album's tracklist beneath the About panel — numbered titles, tap a row to jump to it.
    @ViewBuilder private var albumTracklist: some View {
        if !albumTracks.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("TRACKLIST").font(.system(size: 11, weight: .bold)).kerning(1)
                    .foregroundStyle(p.muted2)
                    .padding(.top, Space.s3)
                ForEach(Array(albumTracks.enumerated()), id: \.element.id) { i, t in
                    let isCurrent = player.current?.albumID == t.albumID && player.current?.trackIndex == i
                    Button {
                        if let src = source { state.nowPlayingAlbumID = src.id }
                        player.play(albumTracks, startAt: i)
                    } label: {
                        HStack(spacing: Space.s3) {
                            Text("\(i + 1)").font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(p.muted2).frame(width: 18, alignment: .trailing)
                            Text(t.title).font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? p.accent : p.muted).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Credits for the CURRENT song: Genius's per-track role/name list when available (so it's
    /// song-by-song), else the album's own Bandcamp credits, else a placeholder. The heading names
    /// the track so it's clear which song these belong to.
    @ViewBuilder
    private var creditsBody: some View {
        let song = player.current?.title
        VStack(alignment: .leading, spacing: Space.s3) {
            Text((song?.isEmpty == false ? song! : "Credits").uppercased())
                .font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            if let credits = geniusCredits, !credits.isEmpty {
                ForEach(Array(credits.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.role).font(.system(size: 13, weight: .bold)).foregroundStyle(p.text)
                        Text(c.names).font(.system(size: 13)).foregroundStyle(bodyInk)
                    }
                }
                attribution("via Genius", url: nil)
            } else if creditsLoading {
                Text("Finding credits…").font(.system(size: 13)).foregroundStyle(p.muted2)
            } else if let bc = liveSource?.bcCredits, !bc.isEmpty {
                Text(bc).font(.system(size: 13)).foregroundStyle(bodyInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No credits for this song.").font(.system(size: 13)).foregroundStyle(p.muted2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func attribution(_ label: String, url: String?) -> some View {
        Button {
            if let s = url, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        } label: {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(p.muted2)
                .underline(url != nil)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    // MARK: Mini — the cover fills the window; controls hover over it

    /// The smallest tier: the cover fills the whole window edge-to-edge, and the only chrome is a
    /// prev/play/next cluster plus a bottom timeline that fade in while the pointer is over the window.
    /// At rest it's just the art.
    private func miniPlayer(_ size: CGSize) -> some View {
        ZStack {
            Color.black
            albumCover(album)
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()

            // Scrim for legibility — only while the controls are showing.
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.15), .black.opacity(0.7)],
                           startPoint: .center, endPoint: .bottom)
                .opacity(hovering ? 1 : 0)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: Space.s5) {
                    miniButton("backward.fill") { player.prev() }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(p.accentInk)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(p.accent))
                    }
                    .buttonStyle(.soft)
                    miniButton("forward.fill") { player.next() }
                }
                Spacer(minLength: 0)
                miniScrubber
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s3)
            }
            .opacity(hovering ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.2)) { hovering = h } }
        .overlay(alignment: .topTrailing) {
            Button(action: onFinish) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .glass(in: Circle())
            }
            .buttonStyle(.soft)
            .padding(Space.s3)
            .opacity(hovering ? 1 : 0)
        }
    }

    private func miniButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .glass(in: Circle())
        }
        .buttonStyle(.soft)
        .accessibilityLabel(Self.transportLabel(icon))
    }

    /// VoiceOver name for the icon-only transport buttons (they carry no visible text).
    private static func transportLabel(_ icon: String) -> String {
        icon.contains("backward") ? "Previous track" : icon.contains("forward") ? "Next track" : icon
    }

    /// Thin, label-less progress line pinned to the bottom of the cover; drag/tap to seek.
    private var miniScrubber: some View {
        GeometryReader { g in
            let frac = player.progress
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: max(0, g.size.width * frac))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                guard player.duration > 0 else { return }
                player.seek(fraction: max(0, min(1, v.location.x / g.size.width)))
            })
        }
        .frame(height: 10)
    }

    // MARK: Center — cover + transport

    private func centerColumn(coverCap: CGFloat, ui: CGFloat, gap: CGFloat, showVolume: Bool) -> some View {
        VStack(spacing: gap) {
            Spacer(minLength: 0)
            // Flexible square cover: `coverCap` is only the MAX side. The fixed controls below take
            // their natural height first, and this square shrinks into whatever vertical room is left,
            // so it can never overlap them — the two spacers just centre the cluster when there's slack.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: coverCap, maxHeight: coverCap)
                .overlay { albumCover(album).scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                .scaleEffect(appeared ? 1 : 0.92)

            // Album eyebrow sits apart from the name; title + artist stay a tight pair (HIG rhythm).
            VStack(spacing: 8) {
                Text(album.title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                    .lineLimit(1)
                VStack(spacing: 4) {
                    Text(player.current?.title ?? album.title)
                        .font(.system(size: 22 * ui, weight: .bold)).kerning(-0.5).foregroundStyle(p.text)
                        .lineLimit(1)
                    Text(album.artist).font(.system(size: 14 * ui, weight: .semibold)).foregroundStyle(p.muted)
                        .lineLimit(1)
                }
            }
            .padding(.top, 6)   // breathing room below the cover
            .fixedSize(horizontal: false, vertical: true)   // never let the title block be squeezed

            scrubber
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.s6 * ui) {
                transportButton("backward.fill") { player.prev() }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20 * ui, weight: .semibold))
                        .foregroundStyle(p.accentInk)
                        .frame(width: 56 * ui, height: 56 * ui)
                        .background(Circle().fill(p.accent))
                }
                .buttonStyle(.soft)
                transportButton("forward.fill") { player.next() }
            }
            .fixedSize(horizontal: false, vertical: true)

            if showVolume {
                volumeSlider
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Spacer(minLength: 0)
        }
    }

    private var volumeSlider: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(p.muted2)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.text.opacity(0.15))
                    Capsule().fill(p.text.opacity(0.7)).frame(width: max(0, g.size.width * player.volume))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.volume = max(0, min(1, v.location.x / g.size.width))
                })
            }
            .frame(width: 130, height: 12)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(p.muted2)
        }
        .padding(.top, Space.s2)
    }

    private var likeButton: some View {
        let liked = player.current.map { state.isLiked($0) } ?? false
        return Button {
            if let t = player.current { state.toggleLikedSong(t) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(liked ? p.accent : p.text)
                .frame(width: 42, height: 42)
                .glass(in: Circle())
        }
        .buttonStyle(.soft)
        .help(liked ? "Remove from Liked Songs" : "Like this song")
    }

    private func transportButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(p.text)
                .frame(width: 44, height: 44)
                .glass(in: Circle())
        }
        .buttonStyle(.soft)
        .accessibilityLabel(Self.transportLabel(icon))
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                let frac = player.progress
                ZStack(alignment: .leading) {
                    Capsule().fill(p.text.opacity(0.15))
                    Capsule().fill(p.text).frame(width: max(0, g.size.width * frac))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    guard player.duration > 0 else { return }
                    player.seek(fraction: max(0, min(1, v.location.x / g.size.width)))
                })
            }
            .frame(height: 12)
            HStack {
                Text(timeString(clock.time)).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted2)
                Spacer()
                Text(timeString(clock.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted2)
            }
        }
    }

    // MARK: Top — tracklist ruler (horizontal dial; current track under the centre playhead)

    private var trackRuler: some View {
        let spacing: CGFloat = 44
        // Use the live playback queue when playing; otherwise the album's own tracklist, so the
        // ruler shows real tracks at rest instead of "LOADING".
        let usingQueue = !player.queue.isEmpty
        let tracks = usingQueue ? player.queue : albumTracks
        let count = tracks.count
        let maxPos = Double(max(count - 1, 0)) + 0.999
        let liveCur = usingQueue ? Double(player.index) + min(max(player.progress, 0), 0.999) : 0
        let displayCur = scrubbing ? scrubPos : liveCur
        // Track sitting under the centre playhead right now (drives the label).
        let labelIdx = min(max(Int(displayCur.rounded(.down)), 0), max(count - 1, 0))
        let centeredIdx = Int(displayCur.rounded())   // the active track — its number is hidden

        return VStack(spacing: Space.s3) {
            // Keep the "First Listen" ceremony title; drop the plain "Now Playing" label.
            if restartPlayback {
                Text("FIRST LISTEN")
                    .font(.system(size: 11, weight: .bold)).kerning(2)
                    .foregroundStyle(p.muted2)
                    .padding(.bottom, Space.s3)
            }
            GeometryReader { g in
                let center = g.size.width / 2
                let baseX = center - CGFloat(displayCur) * spacing
                ZStack {
                    Canvas { ctx, size in
                        guard !tracks.isEmpty else { return }
                        let midY = size.height / 2
                        let half = size.width * 0.5
                        for i in 0..<count {
                            let x = baseX + CGFloat(i) * spacing
                            // Major tick per track, with a discreet track number above it.
                            if x > -2, x < size.width + 2 {
                                let a = max(0.15, 1 - abs(x - center) / half)
                                var path = Path()
                                path.move(to: CGPoint(x: x, y: midY - 8)); path.addLine(to: CGPoint(x: x, y: midY + 12))
                                ctx.stroke(path, with: .color(p.text.opacity(a * 0.65)), lineWidth: 2)
                                if i != centeredIdx {   // hide the active track's number
                                    ctx.draw(
                                        Text("\(i + 1)")
                                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                                            .foregroundStyle(p.text.opacity(a * 0.3)),
                                        at: CGPoint(x: x, y: midY - 17), anchor: .center)
                                }
                            }
                            // Minor ticks between tracks.
                            for m in 1..<4 {
                                let mx = x + spacing * CGFloat(m) / 4
                                guard mx > 0, mx < size.width else { continue }
                                let a = max(0.06, 1 - abs(mx - center) / half)
                                var mp = Path()
                                mp.move(to: CGPoint(x: mx, y: midY - 5)); mp.addLine(to: CGPoint(x: mx, y: midY + 5))
                                ctx.stroke(mp, with: .color(p.text.opacity(a * 0.3)), lineWidth: 1)
                            }
                        }
                    }
                    // Centre playhead.
                    Rectangle().fill(p.accent).frame(width: 2, height: 34)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !scrubbing { scrubbing = true; dragStartPos = liveCur }
                            // Drag the strip like a dial: right = earlier, left = later.
                            scrubPos = min(maxPos, max(0, dragStartPos - Double(v.translation.width / spacing)))
                        }
                        .onEnded { v in
                            let target: Int
                            if abs(v.translation.width) < 3 {   // a tap → jump to the tapped track
                                target = Int(round((v.location.x - baseX) / spacing))
                            } else {                             // a drag → snap to the track at centre
                                target = Int(scrubPos.rounded())
                            }
                            let ci = min(max(target, 0), max(count - 1, 0))
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { scrubbing = false }
                            if usingQueue {
                                if player.queue.indices.contains(ci), ci != player.index {
                                    player.play(player.queue, startAt: ci)
                                }
                            } else if tracks.indices.contains(ci), let src = source {
                                // Not playing yet — tapping a tick starts the album at that track.
                                state.nowPlayingAlbumID = src.id
                                player.play(tracks, startAt: ci)
                            }
                        }
                )
            }
            .frame(height: 48)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))

            if tracks.indices.contains(labelIdx) {
                // Dim + smaller by default (it echoes the centre title); grows brighter on hover
                // or while scrubbing, when the track number/name actually matters.
                let active = scrubbing || hoveringTape
                Text("\(labelIdx + 1). \(tracks[labelIdx].title.uppercased())")
                    .font(.system(size: active ? 12 : 9, weight: .medium, design: .monospaced))
                    .kerning(active ? 2 : 1.5)
                    .foregroundStyle(scrubbing ? p.accent : p.text.opacity(active ? 1 : 0.4))
                    .lineLimit(1)
                    .animation(nil, value: labelIdx)
                    .animation(.easeOut(duration: 0.18), value: active)
            } else {
                Text("LOADING").font(.system(size: 12, weight: .medium, design: .monospaced)).kerning(2)
                    .foregroundStyle(p.muted2)
            }
        }
        .onHover { hoveringTape = $0 }
    }

    // MARK: Right — synced lyrics

    private func lyricsColumn(_ lyrics: SyncedLyrics) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("LYRICS").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            LyricsPanel(lyrics: lyrics, onSeek: { player.scrub(to: $0) })
                .environment(\.palette, p)
        }
    }

    private func loadLyrics() async {
        lyrics = nil
        guard let track = player.current else { return }
        lyrics = await LyricsService.synced(artist: track.artist, title: track.title,
                                            album: album.title, durationSec: player.duration)
    }

    private func loadCredits() async {
        geniusCredits = nil
        guard let track = player.current else { creditsLoading = false; return }
        let key = track.title.lowercased()
        // Trust only a NON-EMPTY persisted entry (survives relaunch → instant on replay). An empty
        // cached entry is treated as "unknown" and re-fetched, so an older poisoned "no credits"
        // entry (a transient miss that got cached as []) self-heals instead of sticking forever.
        if let sid = source?.id, let saved = state.album(id: sid)?.geniusCredits?[key], !saved.isEmpty {
            creditsLoading = false
            geniusCredits = saved
            return
        }
        creditsLoading = true
        // Genius credits take a couple of seconds (search + song lookup); the Credits tab shows a
        // "Finding credits…" state meanwhile instead of a premature "no credits".
        let c = await GeniusService.credits(artist: track.artist, title: track.title, album: album.title)
        guard player.current?.id == track.id else { return }
        geniusCredits = c
        creditsLoading = false
        // Persist only a real result — never an empty/failed one, so a transient miss can't poison
        // the cache into a permanent "No credits".
        if let sid = source?.id, let c, !c.isEmpty {
            state.cacheGeniusCredits(albumID: sid, key: key, credits: c)
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - End-of-album card

private struct ThanksCard: View {
    let album: ProtoAlbum
    let liked: Bool
    let canLike: Bool
    let onThank: () -> Void
    let onLike: () -> Void
    let onDone: () -> Void

    private let p = Palette(scheme: .dark)

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()

            VStack(spacing: Space.s4) {
                Image(systemName: "heart.fill").font(.system(size: 28)).foregroundStyle(p.accent)
                Text("That's the record.").font(.system(size: 20, weight: .bold)).kerning(-0.4)
                    .foregroundStyle(p.text)
                Text("You directly supported \(album.artist) by buying this album. Tell them why it matters to you.")
                    .font(.system(size: 13)).foregroundStyle(p.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: Space.s2) {
                    Button(action: onThank) {
                        Label("Thank the artist", systemImage: "hand.wave.fill")
                            .font(.system(size: 14, weight: .bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Capsule().fill(p.accent))
                            .foregroundStyle(p.accentInk)
                    }
                    .buttonStyle(.soft)

                    if canLike {
                        Button(action: onLike) {
                            Label(liked ? "Favourited" : "Favourite album",
                                  systemImage: liked ? "heart.fill" : "heart")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Capsule().fill(p.text.opacity(0.08)))
                                .overlay(Capsule().stroke(p.text.opacity(0.12)))
                                .foregroundStyle(liked ? p.accent : p.text)
                        }
                        .buttonStyle(.soft)
                    }

                    Button(action: onDone) {
                        Text("Done").font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(p.muted)
                    }
                    .buttonStyle(.soft)
                }
                .padding(.top, Space.s2)
            }
            .padding(Space.s6)
            .frame(width: 320)
            .glass(radius: Radius.card, glow: true)
        }
    }
}

