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

/// Build prototype albums from the real library; fall back to gradient samples for an empty library.
private func makeProtoAlbums(from albums: [Album]) -> [ProtoAlbum] {
    let real = albums.prefix(30).map(makeProtoAlbum(from:))
    return real.isEmpty ? sampleAlbums : Array(real)
}

/// Presents the First Listen screen standalone (from the Crate button / context menu), for a real album.
struct FirstListenPresenter: View {
    let album: Album
    var onClose: () -> Void = {}
    var body: some View {
        FirstListenScreen(album: makeProtoAlbum(from: album), source: album,
                          onFinish: onClose, onClose: onClose)
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

    @State private var albumIndex = 0
    @State private var phase: Phase = .card
    @State private var toast: String? = nil
    @State private var albums: [ProtoAlbum] = sampleAlbums
    @State private var tiltX: CGFloat = 0   // cover parallax (degrees)
    @State private var tiltY: CGFloat = 0

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
                           onThank: { flashToast("Opened \(album.artist) on Bandcamp") },
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
        }
    }

    // MARK: The hero (big cover + overlaid info + buttons)

    private var hero: some View {
        GeometryReader { geo in
            let cover = min(geo.size.width * 0.68, geo.size.height * 0.58)
            let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            VStack(spacing: Space.s5) {
                header

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

                heroButtons
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
                Text("LENGTH \(totalLengthLabel)").font(.system(size: 8, weight: .semibold)).kerning(0.5)
                    .foregroundStyle(.white.opacity(0.8))
                Text("INCLUDING:").font(.system(size: 18, weight: .heavy)).kerning(-0.2)
            }
            .padding(.bottom, 5)
            ForEach(Array(sampleTracks.enumerated()), id: \.offset) { i, t in
                Text("\(i + 1). \"\(t.0.uppercased())\"  \(t.1)")
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
    }

    private var totalLengthLabel: String {
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
                    Image(systemName: "star.circle.fill").font(.system(size: 8))
                    Text("Bought on Bandcamp Friday").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(ink.opacity(0.8))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(ink.opacity(0.10)))
                .overlay(Capsule().strokeBorder(ink.opacity(0.18)))
            }

            HStack {
                Text("■ Yoin record ■").font(.system(size: 9, weight: .medium))
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
    let onFinish: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var clock: PlaybackClock
    private let p = Palette(scheme: .dark)

    @State private var appeared = false
    @State private var lyrics: SyncedLyrics? = nil
    @State private var started = false
    // Ruler scrub state.
    @State private var scrubbing = false
    @State private var scrubPos: Double = 0      // fractional album position while dragging
    @State private var dragStartPos: Double = 0
    @State private var info: InfoTab? = nil       // about / liner-notes / credits sheet
    @State private var artistBio: ArtistBio? = nil
    @State private var bioLoaded = false
    @State private var geniusCredits: [GeniusCredit]? = nil   // per-track credits from Genius

    var body: some View {
        ZStack {
            // Ambient background from the cover, over the app's page colour.
            p.page.ignoresSafeArea()
            album.accent.opacity(0.10).blendMode(.plusLighter).ignoresSafeArea()
            albumCover(album).frame(width: 520, height: 520).clipShape(Circle())
                .blur(radius: 140).opacity(0.3).ignoresSafeArea()

            // Centre column stays truly centred; the side panels hang off the edges so a missing
            // lyrics panel never shifts the cover off-centre.
            centerColumn
                .frame(width: 340)
                .opacity(appeared ? 1 : 0)
        }
        .overlay(alignment: .top) {
            trackRuler
                .frame(maxWidth: 640)
                .padding(.top, Space.s7)
                .opacity(appeared ? 1 : 0)
        }
        .overlay(alignment: .trailing) {
            if let lyrics {   // only show the lyrics panel when there are synced lyrics
                lyricsColumn(lyrics)
                    .frame(width: 300)
                    .frame(maxHeight: 520)
                    .padding(.trailing, Space.s8)
                    .opacity(appeared ? 1 : 0)
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
            .padding(Space.s5)
        }
        .overlay(alignment: .bottom) {
            // Heart stays dead-centre; pills fill equal-width side groups so a missing pill can't
            // shift it. Only offer a pill when it actually has content (no dead-end empty sheets).
            HStack(spacing: Space.s4) {
                HStack(spacing: Space.s4) {
                    if artistBio?.text.isEmpty == false {
                        infoPill("About", "info.circle") { openInfo(.about) }
                    }
                    if liveSource?.about?.isEmpty == false {
                        infoPill("Liner notes", "text.alignleft") { openInfo(.notes) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                likeButton

                HStack(spacing: Space.s4) {
                    if liveSource?.bcCredits?.isEmpty == false || geniusCredits?.isEmpty == false {
                        infoPill("Credits", "person.2.fill") { openInfo(.credits) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 560)
            .padding(.bottom, Space.s6)
            .opacity(appeared ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: artistBio)
            .animation(.easeInOut(duration: 0.25), value: geniusCredits)
        }
        .overlay {
            if let info { infoSheet(info) }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            if !started, let source {
                started = true
                state.play(source, on: player)
                state.loadNotes(for: source.id)   // fetch about/credits for the sheet
            }
            if !bioLoaded {
                bioLoaded = true
                let titles = state.libraryAlbums(byArtist: album.artist).map(\.title)
                Task { artistBio = await ArtistBioService.bio(artist: album.artist, ownedAlbumTitles: titles) }
            }
        }
        .task(id: player.current?.id) { await loadLyrics() }
        .task(id: player.current?.id) { await loadCredits() }
    }

    // MARK: Liner notes / credits

    private enum InfoTab { case about, notes, credits }

    private func openInfo(_ tab: InfoTab) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { info = tab }
    }

    private func infoPill(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(p.text)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .glass(in: Capsule())
        }
        .buttonStyle(.soft)
    }

    /// The album's about / credits text (fetched via state.loadNotes), or nil.
    private var liveSource: Album? { source.flatMap { state.album(id: $0.id) } ?? source }

    @ViewBuilder
    private func infoSheet(_ tab: InfoTab) -> some View {
        let title: String = {
            switch tab {
            case .about:   return "About \(album.artist)"
            case .notes:   return "Liner notes"
            case .credits: return "Credits"
            }
        }()
        // Credits: prefer the artist's own Bandcamp credits (plain text), else Genius (structured).
        let creditsFromGenius = (liveSource?.bcCredits?.isEmpty != false) && (geniusCredits?.isEmpty == false)
        let body: String? = {
            switch tab {
            case .about:   return artistBio?.text
            case .notes:   return liveSource?.about
            case .credits: return liveSource?.bcCredits
            }
        }()
        let empty = tab == .about ? "No description found for this artist."
                                  : "No \(title.lowercased()) for this album."
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { info = nil } }

            VStack(alignment: .leading, spacing: Space.s4) {
                HStack {
                    Text(title).font(.system(size: 16, weight: .bold)).kerning(-0.3).foregroundStyle(p.text)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.25)) { info = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.muted).frame(width: 28, height: 28).glass(in: Circle())
                    }
                    .buttonStyle(.soft)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    if tab == .credits, creditsFromGenius, let credits = geniusCredits {
                        VStack(alignment: .leading, spacing: Space.s4) {
                            ForEach(Array(credits.enumerated()), id: \.offset) { _, c in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.role).font(.system(size: 13, weight: .bold)).foregroundStyle(p.text)
                                    Text(c.names).font(.system(size: 13)).foregroundStyle(p.muted)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    } else {
                        Text(body?.isEmpty == false ? body! : empty)
                            .font(.system(size: 13)).foregroundStyle(p.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxHeight: 320)

                // Attribution.
                if tab == .about, let bio = artistBio, !bio.text.isEmpty {
                    attribution("via \(bio.sourceName)", url: bio.sourceURL)
                } else if tab == .credits, creditsFromGenius {
                    attribution("via Genius", url: nil)
                }
            }
            .padding(Space.s6)
            .frame(maxWidth: 520)
            .glass(radius: Radius.card, glow: true)
            .padding(Space.s6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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

    // MARK: Center — cover + transport

    private var centerColumn: some View {
        VStack(spacing: Space.s5) {
            Spacer()
            albumCover(album)
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                .scaleEffect(appeared ? 1 : 0.92)

            VStack(spacing: 3) {
                Text("FIRST LISTEN").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                Text(player.current?.title ?? album.title)
                    .font(.system(size: 22, weight: .bold)).kerning(-0.5).foregroundStyle(p.text)
                    .lineLimit(1)
                Text(album.artist).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.muted)
            }

            scrubber

            HStack(spacing: Space.s6) {
                transportButton("backward.fill") { player.prev() }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(p.accentInk)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(p.accent))
                }
                .buttonStyle(.soft)
                transportButton("forward.fill") { player.next() }
            }

            volumeSlider

            Spacer()
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
        let maxPos = Double(max(player.queue.count - 1, 0)) + 0.999
        let liveCur = Double(player.index) + min(max(player.progress, 0), 0.999)
        let displayCur = scrubbing ? scrubPos : liveCur
        // Track sitting under the centre playhead right now (drives the label).
        let labelIdx = min(max(Int(displayCur.rounded(.down)), 0), max(player.queue.count - 1, 0))
        let centeredIdx = Int(displayCur.rounded())   // the active track — its number is hidden

        return VStack(spacing: Space.s3) {
            GeometryReader { g in
                let center = g.size.width / 2
                let baseX = center - CGFloat(displayCur) * spacing
                ZStack {
                    Canvas { ctx, size in
                        guard !player.queue.isEmpty else { return }
                        let midY = size.height / 2
                        let half = size.width * 0.5
                        for i in 0..<player.queue.count {
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
                            let ci = min(max(target, 0), max(player.queue.count - 1, 0))
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { scrubbing = false }
                            if player.queue.indices.contains(ci), ci != player.index {
                                player.play(player.queue, startAt: ci)
                            }
                        }
                )
            }
            .frame(height: 48)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))

            if player.queue.indices.contains(labelIdx) {
                Text("\(labelIdx + 1). \(player.queue[labelIdx].title.uppercased())")
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).kerning(2)
                    .foregroundStyle(scrubbing ? p.accent : p.text).lineLimit(1)
                    .animation(nil, value: labelIdx)
            } else {
                Text("LOADING").font(.system(size: 12, weight: .medium, design: .monospaced)).kerning(2)
                    .foregroundStyle(p.muted2)
            }
        }
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
        guard let track = player.current else { return }
        let c = await GeniusService.credits(artist: track.artist, title: track.title, album: album.title)
        if player.current?.id == track.id { geniusCredits = c }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - End-of-album card

private struct ThanksCard: View {
    let album: ProtoAlbum
    let onThank: () -> Void
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

