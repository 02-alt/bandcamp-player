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
        // The record slides out full-size — request the 1200px cover, seeded from the thumbnail.
        CachedRemoteImage(url: url, hiRes: true) { gradientCover(album) }
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
                    .padding(.horizontal, 6)
            }
            .modifier(GlassButton(prominent: true))
            .controlSize(.extraLarge)

            Button { flashToast("Share card created") } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .modifier(GlassButton())
            .controlSize(.extraLarge)
        }
    }

    // MARK: Top bar (close)

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .glassIconButton(side: 32)
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
    /// The glow colour: the app-wide now-playing tint when this is the playing album (so First
    /// Listen matches every other screen), else this album's own cover colour.
    private var ambientTint: Color? {
        if let s = source, s.id == state.nowPlayingAlbum?.id { return nil }
        return album.accent
    }
    var restartPlayback: Bool = true   // false when used as a persistent Now Playing style
    let onFinish: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    // Apple Music–style player (below the 1470×900 landmark): at most one side panel open at a time.
    @State private var openPanel: SidePanel? = nil
    private enum SidePanel: Hashable { case lyrics, credits }
    @State private var moreFrame: CGRect = .zero
    // Wide-but-short window: a two-column layout (cover left, player right) whose right column
    // switches between the transport, the lyrics and the credits.
    @State private var landscapeTab: LandscapeTab = .player
    private enum LandscapeTab: Hashable { case player, lyrics, credits }
    // Editorial (wide+tall) right column: the lower section switches between the tracklist and
    // synced lyrics. Tracklist by default; the Lyrics tab only appears when the track has them.
    @State private var editorialSection: EditorialSection = .tracklist
    private enum EditorialSection: Hashable { case tracklist, lyrics }
    @State private var artistBio: ArtistBio? = nil
    @State private var bioLoaded = false
    @State private var albumAbout: ArtistBio? = nil   // Genius album description (fallback for the About tab)
    @State private var albumAboutLoaded = false
    @State private var geniusCredits: [GeniusCredit]? = nil   // per-track credits from Genius
    @State private var creditsLoading = false                 // Genius lookup in flight

    var body: some View {
        GeometryReader { geo in content(size: geo.size) }
    }

    /// Play / pause. With nothing loaded yet (a fresh launch, before anything was played) there's
    /// nothing to toggle — start the album on screen instead.
    private func togglePlay() {
        if player.current == nil, let source {
            state.play(source, on: player)
        } else {
            player.toggle()
        }
    }

    /// Height drives the vertical layout: the cover is sized from the room left after the fixed chrome,
    /// the title/transport scale with it, spacing tightens, and as the window gets short we drop the
    /// volume slider then the ruler. Width drives the sides: the two panels shrink in width together
    /// and vanish once they'd get too narrow; below `narrow` we go full compact — a big cover with no
    /// ruler, no pills and no panels, like the mini player.
    private func content(size: CGSize) -> some View {
        let h = size.height
        let w = size.width
        // Below the laptop landmark (Layout.swift) the window gets the Apple Music–style player;
        // the layouts below are for larger windows. Measured on the window (÷ UI zoom), not `size`,
        // which starts below the title-bar strip.
        let small = state.sizeBand < .laptop
        // Laptop size: the centred layout below, with a square cover, fixed type, Music's vertical
        // rhythm, and close / volume moved into the window toolbar.
        let laptop = state.sizeBand == .laptop
        let tight = h < 720          // small laptop / dragged short: tighten vertical rhythm
        let narrow = w < 500         // compact mode: big cover, drop ruler + pills + panels
        let mini = w < 480           // smallest tier: cover fills the window, controls on hover only
        // Wide-but-short: the vertical stack can't fit, so pivot to two columns — cover left,
        // a player/lyrics/credits column on the right (transport always pinned).
        // Very short windows (any width ≥640) use the compact cover-left / controls-right landscape
        // layout — it's built for short heights, so nothing crops. Above this, wide windows get the
        // richer editorial layout (which scales down to here).
        let landscape = w >= 640 && h < 430
        // Editorial (two-column) layout: only a *medium* landscape window that stays within BOTH a max
        // width and a max height — ≥900 wide but ≤1200, ≤920 tall, and wider than it is tall. Exceed
        // EITHER the width or the height cap (a bigger or taller window) and it uses the centred "main"
        // hero instead; so does a portrait/near-square window. Below 430 tall → `landscapeLayout`.
        let big = w >= 900 && w <= 1200 && h >= 430 && h <= 920 && w >= h * 1.1
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
        // At laptop size the toolbar already clears the title strip, so the ruler sits higher.
        let rulerReserve: CGFloat = laptop ? 100 : (showRuler ? rulerFootprint : Space.s5)
        let bottomReserve: CGFloat = showPills ? 66 : Space.s5
        // On a roomy window, grow the hero (and the column it lives in) so the cover commands the
        // space instead of floating small in the middle. This is the common centred layout for
        // portrait / near-square windows — its cover was previously pinned at 320 regardless of size.
        let roomy = !narrow && w >= 560 && h >= 720
        let centerW = min(roomy ? 560 : 340, max(240, w - 48))
        // The cover is a *flexible square*: this is only its MAX side. Inside the column it shrinks to
        // whatever vertical room is left after the fixed controls, so it can never overlap them — no
        // hand-tuned chrome constant, no overflow. Compact mode lets it grow wider.
        let coverCap = min(centerW, narrow ? 360 : (roomy ? 560 : 320))
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
        if small {
            smallPlayer(size)
        } else if mini {
            miniPlayer(size)
        } else if landscape {
            landscapeLayout(size)
        } else if big {
            editorialLayout(size)
        } else {
        ZStack {
            // The shared ambient background (same as the main window, Now Playing and Art mode).
            AmbientBackground(album: source, palette: p, tint: ambientTint)

            // Centre column stays truly centred; the side panels hang off the edges so a missing
            // lyrics panel never shifts the cover off-centre. The reserve padding centres it within
            // the band between the ruler and the pills so it never overlaps them.
            Group {
                if laptop {
                    laptopColumn(side: max(240, min(520, h - rulerReserve - bottomReserve - 207 - Space.s5 * 2)))
                } else {
                    centerColumn(coverCap: coverCap, ui: ui, gap: gap, showVolume: showVolume)
                }
            }
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
                    .padding(.top, laptop ? Space.s4 : (tight ? Space.s4 : Space.s7))
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
        .overlay(alignment: .topTrailing) { if !laptop && !nativeButtons { closeButton } }
        // Desktop size: close + mini player float below the title bar as larger native glass buttons.
        .overlay(alignment: .topLeading) { if nativeButtons { floatingWindowButtons } }
        .toolbar { if laptop && !player.artMode { smallToolbar } }   // Art mode covers the window
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
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: landscape)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: big)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: small)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            // Screenshot/QA hook: CABIN_PANEL=credits|lyrics opens a side panel in the small player.
            switch ProcessInfo.processInfo.environment["CABIN_PANEL"] {
            case "credits": openPanel = .credits; notesTab = .credits
            case "lyrics": openPanel = .lyrics
            default: break
            }
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
        var items = player.current.map { nowPlayingTrackMenuItems(for: $0, state: state, player: player, includeEffects: true) } ?? []
        // Art mode (fullscreen cover) — same entry the Now Playing screen offers.
        if !items.isEmpty { items.append(.divider()) }
        items.append(AppMenuItem(title: "Art mode", systemImage: "photo.artframe") {
            withAnimation(.easeInOut(duration: 0.3)) { player.artMode = true }
        })
        return items
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
            if nativeButtons {
                Label(label, systemImage: icon).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 4).padding(.vertical, 2)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 11))
                    Text(label).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(isOn ? p.accent : p.text)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .glass(in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? p.accent.opacity(0.5) : .clear, lineWidth: 1))
            }
        }
        .modifier(NativeGlassButton(on: nativeButtons, prominent: isOn, shape: .capsule))
    }

    /// Desktop size: the centred layout's buttons are native Liquid Glass controls.
    private var nativeButtons: Bool { state.sizeBand == .desktop }

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
                Text(album.title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(1)
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
                albumTracklist()
            }
            .textSelection(.enabled)
        case .credits:
            creditsBody
        }
    }

    /// The album's tracklist beneath the About panel — numbered titles, tap a row to jump to it.
    /// `showHeader` is off where a section switcher already labels it (the editorial column).
    @ViewBuilder private func albumTracklist(showHeader: Bool = true) -> some View {
        if !albumTracks.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                if showHeader {
                    Text("TRACKLIST").font(.system(size: 11, weight: .bold)).kerning(1)
                        .foregroundStyle(p.muted2)
                        .padding(.top, Space.s3)
                }
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
                    .buttonStyle(.soft(hover: 1.0, press: Press.surface, brighten: 0))
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
                    Button { togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .modifier(GlassButton(prominent: true, shape: .circle))
                    .controlSize(.extraLarge)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
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
                    .frame(width: 20, height: 20)
            }
            .glassIconButton(side: 28)
            .accessibilityLabel("Close")
            .padding(Space.s3)
            .opacity(hovering ? 1 : 0)
        }
    }

    private func miniButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .glassIconButton(side: 40)
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

    // MARK: Small + default window (below 1470×900) — Apple Music–style player

    /// One centred column — cover, title row, scrubber, transport — with glass chrome in the corners
    /// (close + mini player top-left, volume top-right, the Lyrics / Credits switch bottom-right).
    /// Opening a panel slides the column into the left half and shows the panel in the right half;
    /// only one panel is open at a time. Text and controls keep one fixed size; only the cover
    /// grows with the window.
    private func smallPlayer(_ size: CGSize) -> some View {
        // Fixed chrome: `size` already starts below the title-bar strip, where the top capsules sit
        // (level with the traffic lights); the bottom bar holds the panel switch. Plus the fixed
        // controls under the cover.
        let topPad: CGFloat = 12, bottomBar: CGFloat = 64, controlsH: CGFloat = 170
        // Cover cap: 360 below the default-size landmark, 440 from it up to the laptop landmark.
        let side = max(220, min(state.sizeBand == .standard ? 440 : 360, size.height - topPad - bottomBar - controlsH))
        return ZStack {
            backdrop
            HStack(spacing: 0) {
                playerColumn(side: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let panel = openPanel {
                    // Same height as the player column and centred like it, so the panel's
                    // top lines up with the cover's top edge instead of hugging the title bar.
                    panelView(panel)
                        .frame(maxWidth: 440)
                        .frame(height: side + controlsH, alignment: .top)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, Space.s5)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.top, topPad).padding(.bottom, bottomBar)
            .opacity(appeared ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .toolbar { if !player.artMode { smallToolbar } }   // Art mode covers the window
        .overlay(alignment: .bottomTrailing) { panelSwitch }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.88), value: openPanel)
    }

    private var smallLikeButton: some View {
        let liked = player.current.map { state.isLiked($0) } ?? false
        return Button {
            if let t = player.current { state.toggleLikedSong(t) }
        } label: { circleIcon(liked ? "heart.fill" : "heart") }
        .modifier(GlassButton(prominent: liked, shape: .circle))
        .controlSize(.large)
        .accessibilityLabel(liked ? "Unlike" : "Like")
        .help(liked ? "Remove from Liked Songs" : "Like this song")
    }

    /// Scrubber with elapsed / remaining time, like Music.
    private var smallScrubber: some View {
        VStack(spacing: 4) {
            scrubberBar
            HStack {
                Text(timeString(clock.time)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                Spacer()
                Text("-" + timeString(max(0, clock.duration - clock.time)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
            }
        }
    }

    @ViewBuilder private var backdrop: some View {
        // The shared ambient background (same as the main window, Now Playing and Art mode).
        AmbientBackground(album: source, palette: p, tint: ambientTint)
    }

    private func playerColumn(side: CGFloat) -> some View {
        // The controls run a little wider than the cover, like Music.
        let controlsW = side + 56
        return VStack(spacing: Space.s5) {
            Color.clear
                .frame(width: side, height: side)
                .overlay { albumCover(album).scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                .scaleEffect(appeared ? 1 : 0.94)
            VStack(spacing: Space.s3) {
                HStack(spacing: Space.s2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current?.title ?? album.title)
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(p.text)
                        Text("\(album.artist) — \(album.title)")
                            .font(.system(size: 14)).foregroundStyle(p.muted)
                    }
                    .lineLimit(1)
                    Spacer(minLength: Space.s3)
                    smallLikeButton
                    moreButton
                }
                smallScrubber
                transportRow
            }
            .frame(width: controlsW)
        }
    }

    private var transportRow: some View {
        HStack {
            modeButton("shuffle", on: player.shuffle, label: "Shuffle") { player.shuffle.toggle() }
            Spacer()
            glyphButton("backward.fill", size: 24, label: "Previous track") { player.prev() }
            Spacer()
            glyphButton(player.isPlaying ? "pause.fill" : "play.fill", size: 32,
                        label: player.isPlaying ? "Pause" : "Play") { togglePlay() }
            Spacer()
            glyphButton("forward.fill", size: 24, label: "Next track") { player.next() }
            Spacer()
            modeButton("repeat.1", on: player.repeatOne, label: "Repeat one") { player.repeatOne.toggle() }
        }
    }

    /// A bare transport glyph (no disc behind it), like Music's controls.
    private func glyphButton(_ icon: String, size: CGFloat, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(p.text)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.soft)
        .accessibilityLabel(label)
    }

    /// Shuffle / repeat: small, muted until switched on.
    private func modeButton(_ icon: String, on: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? p.accent : p.muted)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.soft)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .help(label)
    }

    /// Small glass circle for the title-row actions (heart, more).
    private func circleIcon(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            .frame(width: 20, height: 20)
    }

    private var moreButton: some View {
        Button {
            state.showMenu(firstListenMenuItems(), at: CGPoint(x: moreFrame.minX, y: moreFrame.maxY + 4))
        } label: { circleIcon("ellipsis") }
        .glassIconButton(side: 30)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { moreFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in moreFrame = f }
        })
        .accessibilityLabel("More actions")
        .help("More")
    }

    // MARK: Corner chrome

    /// Close + mini player, in one glass capsule beside the traffic lights.
    /// Close + mini player (leading) and AirPlay + volume (trailing), as real window-toolbar items —
    /// so they get the native Liquid Glass capsules, and dragging the volume slider doesn't drag
    /// the window (a plain view in the title-bar strip does).
    @ToolbarContentBuilder private var smallToolbar: some ToolbarContent {
        windowToolbarItems
        if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: Space.s3) {
                AirPlayButton(color: NSColor(p.muted), activeColor: NSColor(p.text))
                    .frame(width: 20, height: 20)
                    .help("AirPlay / output device")
                Divider().frame(height: 18)
                Slider(value: Binding(get: { player.volume },
                                      set: { player.volume = max(0, min(1, $0)) }), in: 0...1)
                    .frame(width: 115)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(player.volume * 100))%")
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(p.muted)
            }
            .padding(.horizontal, Space.s2)
        }
    }

    /// Close + mini player, as a native toolbar group beside the traffic lights.
    @ToolbarContentBuilder private var windowToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: onFinish) { Image(systemName: "xmark") }
                .help("Close")
                .modifier(LinkCursor())
            Button { MiniPlayerController.shared.toggle() } label: { Image(systemName: "pip") }
                .help("Mini Player")
                .modifier(LinkCursor())
        }
    }

    /// Close + mini player as two large native glass buttons, detached from the title bar.
    private var floatingWindowButtons: some View {
        HStack(spacing: Space.s3) {
            Button(action: onFinish) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .modifier(NativeGlassButton(on: true))
            .accessibilityLabel("Close").help("Close")
            Button { MiniPlayerController.shared.toggle() } label: {
                Image(systemName: "pip").font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .modifier(NativeGlassButton(on: true))
            .accessibilityLabel("Mini Player").help("Mini Player")
        }
        .padding(.leading, Space.s5).padding(.top, Space.s4)
    }

    /// Lyrics / Credits switch — tapping one opens its panel (closing the other); tapping it again closes it.
    private var panelSwitch: some View {
        HStack(spacing: Space.s2) {
            panelButton(.lyrics, icon: "quote.bubble", label: "Lyrics", enabled: lyrics != nil)
            panelButton(.credits, icon: "person.2", label: "Credits", enabled: true)
        }
        .padding(.trailing, Space.s4).padding(.bottom, Space.s4)
    }

    private func panelButton(_ panel: SidePanel, icon: String, label: String, enabled: Bool) -> some View {
        let on = openPanel == panel
        return Button {
            openPanel = on ? nil : panel
            if panel == .credits, !on { notesTab = .credits }
        } label: {
            Image(systemName: on ? icon + ".fill" : icon).font(.system(size: 15, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .modifier(GlassButton(prominent: on, shape: .circle))
        .controlSize(.large)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .help(enabled ? label : "No lyrics for this track")
    }

    @ViewBuilder private func panelView(_ panel: SidePanel) -> some View {
        switch panel {
        case .lyrics:
            if let lyrics {
                lyricsColumn(lyrics)
            } else {
                Text("No lyrics for this song.").font(.system(size: 13)).foregroundStyle(p.muted2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .credits:
            notesColumn
        }
    }

    // MARK: Laptop size — the centred hero, tightened

    /// The centred column at laptop size: a square cover of a fixed side, then Music's vertical
    /// rhythm — cover → 24 → title → 20 → scrubber → 20 → transport — with fixed type and controls.
    /// (Volume lives in the toolbar at this size.)
    private func laptopColumn(side: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: side, height: side)
                .overlay { albumCover(album).scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                .scaleEffect(appeared ? 1 : 0.92)
            VStack(spacing: 4) {
                Text(player.current?.title ?? album.title)
                    .font(.system(size: 22, weight: .bold)).kerning(-0.5).foregroundStyle(p.text)
                    .lineLimit(1)
                Text(album.artist).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.muted)
                    .lineLimit(1)
            }
            .padding(.top, Space.s5)
            scrubber
                .frame(width: side)
                .padding(.top, 20)
            HStack(spacing: Space.s6) {
                transportButton("backward.fill") { player.prev() }
                Button { togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .modifier(GlassButton(prominent: true, shape: .circle))
                .controlSize(.extraLarge)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                transportButton("forward.fill") { player.next() }
            }
            .padding(.top, 20)
        }
        .frame(maxHeight: .infinity)   // centred between the ruler and the pills
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

            // Title + artist stay a tight pair (HIG rhythm); the album name now heads the About panel.
            VStack(spacing: 4) {
                Text(player.current?.title ?? album.title)
                    .font(.system(size: 22 * ui, weight: .bold)).kerning(-0.5).foregroundStyle(p.text)
                    .lineLimit(1)
                Text(album.artist).font(.system(size: 14 * ui, weight: .semibold)).foregroundStyle(p.muted)
                    .lineLimit(1)
            }
            .padding(.top, 6)   // breathing room below the cover
            .fixedSize(horizontal: false, vertical: true)   // never let the title block be squeezed

            scrubber
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.s6 * ui) {
                transportButton("backward.fill") { player.prev() }
                Button { togglePlay() } label: {
                    if nativeButtons {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 48, height: 48)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20 * ui, weight: .semibold))
                            .foregroundStyle(p.accentInk)
                            .frame(width: 56 * ui, height: 56 * ui)
                            .background(Circle().fill(p.accent))
                    }
                }
                .modifier(NativeGlassButton(on: nativeButtons, prominent: true))
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
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

    // MARK: Editorial (wide + tall window) — big cover + transport left, artist/bio/tracklist right

    /// Magazine-spread layout for large windows: the enlarged hero and its transport sit in the left
    /// column, and the horizontal space that used to sit empty becomes an info column (artist, bio,
    /// tracklist) on the right. Replaces the centred layout only when the window is both wide & tall.
    private func editorialLayout(_ size: CGSize) -> some View {
        ZStack {
            // Same shared ambient background as every other layout.
            AmbientBackground(album: source, palette: p, tint: ambientTint)
            GeometryReader { g in
                let ah = g.size.height, aw = g.size.width
                let pad: CGFloat = Space.s7
                // Reserve the padding from the available area up front, so the cluster is laid out
                // INSIDE the window (never `maxHeight:.infinity` + outer padding, which overflowed the
                // bottom and clipped the transport).
                let availW = aw - pad * 2, availH = ah - pad * 2
                // Everything scales together as the window resizes: cover, type, and transport ride
                // `ui`, so a short window shows a smaller version and a big window a larger one — never
                // a fixed cluster marooned in the middle.
                let ui = min(max(availH / 620, 0.78), 1.15)
                let showVol = availH >= 600
                // Cover: bounded by the height left after the (ui-scaled) controls, ~42% of the width,
                // and a generous max so it grows on big screens.
                let controlsH: CGFloat = (showVol ? 230 : 172) * ui
                let side = max(150, min(availH - controlsH, availW * 0.42, 620))
                // Info column: a readable, capped width (so text never sprawls), at least enough to
                // exist. The cluster is exactly cover + gap + info — no internal empty gap — and is
                // centred as ONE unit, so big windows get *symmetric* margins, not a left-pooled block.
                let infoW = max(280, min(availW - side - pad, 520))
                let clusterW = side + pad + infoW
                HStack(alignment: .top, spacing: pad) {
                    leftHero(side: side, showVolume: showVol, ui: ui)
                        .frame(width: side)
                        .frame(maxHeight: .infinity, alignment: .center)
                    editorialInfo(ui: ui)
                        .frame(width: infoW, alignment: .leading)
                }
                .frame(width: clusterW, height: availH, alignment: .center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(appeared ? 1 : 0)
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    /// Left column: the enlarged cover with the title + transport directly beneath it. The cover is a
    /// *flexible* square (`side` is only its MAX) — the fixed controls below claim their natural height
    /// first and the cover shrinks into whatever's left, so on a short window it never pushes the
    /// transport off-screen. The two spacers centre the cluster when there's slack.
    private func leftHero(side: CGFloat, showVolume: Bool, ui: CGFloat) -> some View {
        VStack(spacing: Space.s4 * ui) {
            Spacer(minLength: 0)
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: side, maxHeight: side)
                .overlay { albumCover(album).scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                .scaleEffect(appeared ? 1 : 0.92)
            VStack(spacing: 4) {
                Text(player.current?.title ?? album.title)
                    .font(.system(size: 22 * ui, weight: .bold)).kerning(-0.5)
                    .foregroundStyle(p.text).lineLimit(1)
                Text(album.artist).font(.system(size: 14 * ui, weight: .semibold))
                    .foregroundStyle(p.muted).lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
            scrubber.fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s6 * ui) {
                transportButton("backward.fill", size: 44 * ui) { player.prev() }
                Button { togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20 * ui, weight: .semibold))
                        .frame(width: 36 * ui, height: 36 * ui)
                }
                .modifier(GlassButton(prominent: true, shape: .circle)).controlSize(.extraLarge)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                transportButton("forward.fill", size: 44 * ui) { player.next() }
            }
            .fixedSize(horizontal: false, vertical: true)
            if showVolume {
                HStack(spacing: Space.s4) {
                    volumeSlider.frame(maxWidth: 220 * ui)
                    likeButton
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                likeButton   // keep the favourite action even when the volume row is dropped
            }
            Spacer(minLength: 0)
        }
    }

    /// Right column: the info that used to hide behind the "About" pill, now always visible — artist
    /// name + bio on top, then a Tracklist / Lyrics switcher whose section fills the rest of the
    /// column so it never reads as empty. Lyrics live here (only offered when the track has them).
    private func editorialInfo(ui: CGFloat) -> some View {
        let hasLyrics = lyrics != nil
        let section: EditorialSection = hasLyrics ? editorialSection : .tracklist
        return VStack(alignment: .leading, spacing: Space.s5 * ui) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ARTIST").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                Text(album.artist).font(.system(size: 26 * ui, weight: .bold)).kerning(-0.4)
                    .foregroundStyle(p.text).fixedSize(horizontal: false, vertical: true)
            }
            if let bio = artistBio, !bio.text.isEmpty {
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text(bio.text).font(.system(size: 14)).foregroundStyle(bodyInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    attribution("via \(bio.sourceName)", url: bio.sourceURL)
                }
            }
            // Section switcher (doubles as the header). "Lyrics" only when the track has synced ones.
            HStack(spacing: 3) {
                editorialSectionTab("Tracklist", .tracklist, current: section)
                if hasLyrics { editorialSectionTab("Lyrics", .lyrics, current: section) }
            }
            Group {
                if section == .lyrics, let lyrics {
                    LyricsPanel(lyrics: lyrics, onSeek: { player.scrub(to: $0) })
                        .environment(\.palette, p)
                } else {
                    ScrollView { albumTracklist(showHeader: false).padding(.trailing, Space.s3) }
                        .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, Space.s2)
    }

    /// One pill in the editorial right-column section switcher.
    private func editorialSectionTab(_ label: String, _ tab: EditorialSection, current: EditorialSection) -> some View {
        let on = current == tab
        return Button { withAnimation(.easeInOut(duration: 0.2)) { editorialSection = tab } } label: {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(Capsule().fill(on ? p.glassFill : .clear)
                    .overlay(Capsule().strokeBorder(on ? p.edge : .clear, lineWidth: 1)))
                .hoverHighlight(active: on)
        }
        .buttonStyle(.soft(hover: 1.0, press: Press.small, brighten: 0))
        .modifier(LinkCursor())
        .accessibilityLabel("\(label) tab")
    }

    /// Close chip, shared by the full and landscape layouts.
    private var closeButton: some View {
        Button(action: onFinish) {
            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .glassIconButton(side: 40)
        .accessibilityLabel("Close")
        .padding(Space.s5)
    }

    // MARK: Landscape (wide + short window) — cover left, player/lyrics/credits right

    private func landscapeLayout(_ size: CGSize) -> some View {
        let hasLyrics = lyrics != nil
        let aw = size.width, ah = size.height
        let pad: CGFloat = Space.s5
        let ui = min(max(ah / 430, 0.75), 1.25)          // shrink when short, grow when tall
        // Reading tab? Give the cover a smaller width share so lyrics/credits get more room.
        let reading = hasLyrics ? (landscapeTab != .player) : (landscapeTab == .credits)
        // Size from the REAL window (`size`), not an inner GeometryReader that the full-bleed backdrop
        // inflates — and cap the cover to the height left after padding (×0.92 slack) so it can never
        // run past the visible bottom. Both columns match this height; the cluster centres.
        let side = max(110, min((ah - pad * 2) * 0.92, aw * (reading ? 0.30 : 0.38), 400))
        return ZStack {
            landscapeBackdrop
            HStack(spacing: Space.s5 * ui) {
                Color.clear
                    .frame(width: side, height: side)
                    .overlay { albumCover(album).scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                    .scaleEffect(appeared ? 1 : 0.92)
                landscapeRight(hasLyrics: hasLyrics, ui: ui)
                    .frame(maxHeight: side)
            }
            .padding(pad)
            .opacity(appeared ? 1 : 0)
        }
        .frame(width: aw, height: ah)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var landscapeBackdrop: some View {
        AmbientBackground(album: source, palette: p, tint: ambientTint)
    }

    private func landscapeRight(hasLyrics: Bool, ui: CGFloat) -> some View {
        let tab: LandscapeTab = (landscapeTab == .lyrics && !hasLyrics) ? .player : landscapeTab
        return VStack(alignment: .leading, spacing: Space.s3 * ui) {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.current?.title ?? album.title)
                    .font(.system(size: 21 * ui, weight: .bold)).kerning(-0.4).foregroundStyle(p.text).lineLimit(1)
                Text(album.artist).font(.system(size: 13 * ui, weight: .semibold)).foregroundStyle(p.text.opacity(0.75)).lineLimit(1)
            }
            landscapeTabs(hasLyrics: hasLyrics, ui: ui)

            if tab == .player {
                // No panel to show — centre the transport cluster so there's no empty void.
                Spacer(minLength: Space.s2)
                scrubber.fixedSize(horizontal: false, vertical: true)
                landscapeTransport(ui)
                Spacer(minLength: Space.s2)
            } else {
                // Lyrics / Credits: give the panel the whole column, dock a slim one-row control
                // bar (compact transport + inline scrubber + volume) at the bottom.
                Group {
                    if tab == .lyrics, let lyrics { lyricsColumn(lyrics) } else { notesColumn }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                landscapeCompactControls(ui).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func landscapeTransport(_ ui: CGFloat) -> some View {
        VStack(spacing: Space.s2) {
            // Transport centred beneath the progress bar.
            HStack(spacing: Space.s5 * ui) {
                transportButton("backward.fill") { player.prev() }
                Button { togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18 * ui, weight: .semibold))
                        .frame(width: 32 * ui, height: 32 * ui)
                }
                .modifier(GlassButton(prominent: true, shape: .circle)).controlSize(.extraLarge)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                transportButton("forward.fill") { player.next() }
            }
            .frame(maxWidth: .infinity)
            volumeSlider.frame(maxWidth: 220)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Slim single-row controls for the Lyrics / Credits tabs, so the panel keeps the column.
    private func landscapeCompactControls(_ ui: CGFloat) -> some View {
        HStack(spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                transportButton("backward.fill") { player.prev() }
                Button { togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .modifier(GlassButton(prominent: true, shape: .circle)).controlSize(.large)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                transportButton("forward.fill") { player.next() }
            }
            Text(timeString(clock.time)).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(p.muted).monospacedDigit()
            scrubberBar.frame(maxWidth: .infinity)
            Text(timeString(clock.duration)).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(p.muted).monospacedDigit()
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(p.muted)
                Slider(value: Binding(get: { player.volume },
                                      set: { player.volume = max(0, min(1, $0)) }), in: 0...1)
                    .controlSize(.small).tint(p.text).frame(width: 80)
            }
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(player.volume * 100))%")
        }
    }

    private func landscapeTabs(hasLyrics: Bool, ui: CGFloat) -> some View {
        let tabs: [(LandscapeTab, String)] = hasLyrics
            ? [(.player, "Player"), (.lyrics, "Lyrics"), (.credits, "Credits")]
            : [(.player, "Player"), (.credits, "Credits")]
        let current: LandscapeTab = (landscapeTab == .lyrics && !hasLyrics) ? .player : landscapeTab
        return HStack(spacing: 3) {
            ForEach(tabs, id: \.0) { t in
                let on = current == t.0
                Button { withAnimation(.easeInOut(duration: 0.2)) { landscapeTab = t.0 } } label: {
                    Text(t.1).font(.system(size: 12 * ui, weight: .semibold))
                        .foregroundStyle(on ? p.text : p.muted)
                        .padding(.vertical, 6 * ui).padding(.horizontal, 12 * ui)
                        .background(Capsule().fill(on ? p.glassFill : .clear)
                            .overlay(Capsule().strokeBorder(on ? p.edge : .clear, lineWidth: 1)))
                        .hoverHighlight(active: on)   // visible hover feedback on the tabs
                }
                .buttonStyle(.soft(hover: 1.0, press: Press.small, brighten: 0))
                .modifier(LinkCursor())
                .accessibilityLabel("\(t.1) tab")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    private var volumeSlider: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(p.muted)
            // Native macOS slider — the real Apple knob/track — instead of a hand-drawn thumb.
            Slider(value: Binding(get: { player.volume },
                                  set: { player.volume = max(0, min(1, $0)) }), in: 0...1)
                .controlSize(.small)
                .tint(p.text)   // neutral white fill (album accent can be dark → invisible)
                .frame(width: 130)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(p.muted)
        }
        .padding(.top, Space.s2)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(player.volume * 100))%")
    }

    private var likeButton: some View {
        let liked = player.current.map { state.isLiked($0) } ?? false
        return Button {
            if let t = player.current { state.toggleLikedSong(t) }
        } label: {
            if nativeButtons {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(liked ? p.accent : p.text)
                    .frame(width: 42, height: 42)
                    .glass(in: Circle())
            }
        }
        .modifier(NativeGlassButton(on: nativeButtons, prominent: liked))
        .help(liked ? "Remove from Liked Songs" : "Like this song")
    }

    private func transportButton(_ icon: String, size: CGFloat = 44, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if nativeButtons {
                Image(systemName: icon).font(.system(size: size * 0.36, weight: .semibold))
                    .frame(width: size - 12, height: size - 12)
            } else {
                Image(systemName: icon).font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(p.text)
                    .frame(width: size, height: size)
                    .glass(in: Circle())
            }
        }
        .modifier(NativeGlassButton(on: nativeButtons))
        .accessibilityLabel(Self.transportLabel(icon))
    }

    /// The progress track + draggable handle (no time labels), reusable inline.
    private var scrubberBar: some View {
        GeometryReader { g in
            let frac = max(0, min(1, player.progress))
            let x = g.size.width * frac
            ZStack(alignment: .leading) {
                Capsule().fill(p.text.opacity(0.22))
                Capsule().fill(p.text).frame(width: max(0, x))
                Circle().fill(p.text)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: x - 6)
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                guard player.duration > 0 else { return }
                player.seek(fraction: max(0, min(1, v.location.x / g.size.width)))
            })
        }
        .frame(height: 18)   // taller hit target
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            scrubberBar
            HStack {
                Text(timeString(clock.time)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                Spacer()
                Text(timeString(clock.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
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
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(GlassButton(prominent: true))
                    .controlSize(.extraLarge)

                    if canLike {
                        Button(action: onLike) {
                            Label(liked ? "Favourited" : "Favourite album",
                                  systemImage: liked ? "heart.fill" : "heart")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .modifier(GlassButton(prominent: liked))
                        .controlSize(.extraLarge)
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

/// Native Liquid Glass button style (macOS 26+) when `on`; otherwise the app's soft press style,
/// with the label drawing its own surface.
private struct NativeGlassButton: ViewModifier {
    let on: Bool
    var prominent = false
    var shape: ButtonBorderShape = .circle

    func body(content: Content) -> some View {
        if on, #available(macOS 26.0, *) {
            // Explicit tints: the app sets a white `.tint` at the root, which would otherwise fill
            // every glass button solid white.
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(shape).tint(.white).foregroundStyle(.black)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(shape).tint(nil).foregroundStyle(.white)
            }
        } else if on {
            content.modifier(LegacyGlassChrome(fill: prominent ? .white : .white.opacity(0.12),
                                               ink: prominent ? .black : .white, shape: shape))
        } else {
            content.buttonStyle(.soft)
        }
    }
}
