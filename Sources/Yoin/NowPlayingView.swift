import SwiftUI

/// Full-window Now Playing screen. Flat and disc-centric (no skeuomorphism):
/// a circular album disc with a progress ring, ambient blurred cover, clean transport.
struct NowPlayingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    @State private var baseAngle = 0.0
    @State private var spinStart: Date? = nil
    @State private var dragOffset: CGFloat = 0

    // Jog-wheel scrub state.
    @State private var scrubbing = false
    @State private var lastAngle: Double? = nil
    @State private var scrubStartTime = 0.0
    @State private var scrubAccumDeg = 0.0
    @State private var scrubTarget = 0.0     // where the last scrub pointed — the release lands here
    @State private var wasPlaying = false

    // Turntable scratch audio (local files only; streams keep the silent jog).
    @State private var scratch = ScratchAudio()
    @State private var scratchActive = false

    // Whether the DJ pitch fader is shown (toggled by the icon next to the volume bar).
    @State private var pitchVisible = true

    private let degPerSecond = 12.0   // ~30s per revolution — a slow turn
    private let secPerRevolution = 18.0   // drag sensitivity: one full turn = 18s of audio

    private var album: Album { state.nowPlayingAlbum ?? state.current }
    private var title: String { player.current?.title ?? album.title }
    private var artist: String { player.current?.artist ?? album.artist }
    private var coverImage: NSImage? {
        if let d = player.current?.artworkData { return NSImage(data: d) }
        return album.artwork
    }
    private var coverURL: URL? { player.current?.artworkURL ?? album.artworkURL }

    var body: some View {
        GeometryReader { geo in
            let disc = min(min(geo.size.width * 0.5, geo.size.height * 0.44), 420)
            ZStack {
                VStack(spacing: Space.s6) {
                    header

                    Spacer(minLength: 0)

                    // Hero disc + progress ring, with the DJ pitch fader alongside it.
                    HStack(spacing: Space.s5) {
                        let showFader = player.djMode && pitchVisible
                        if showFader { Color.clear.frame(width: 34, height: 1) }   // balance so the disc stays centered
                        ZStack {
                            Circle().stroke(p.text.opacity(0.12), lineWidth: 4)
                            Circle()
                                .trim(from: 0, to: player.progress)
                                .stroke(p.text, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            spinningDisc(disc)
                        }
                        .frame(width: disc + 28, height: disc + 28)
                        if showFader { djFader(height: disc * 0.82).frame(width: 34) }
                    }

                    // Title / artist.
                    VStack(spacing: 6) {
                        Text(title).font(.system(size: 24, weight: .bold)).kerning(-0.4)
                            .lineLimit(1).truncationMode(.tail)
                        Button { openAlbum() } label: {
                            Text(artist).font(.system(size: 15)).foregroundStyle(p.muted).lineLimit(1)
                        }.buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
                    }
                    .frame(maxWidth: disc + 120)

                    scrubber.frame(maxWidth: disc + 120)

                    transport

                    Spacer(minLength: 0)

                    bottomBar.frame(maxWidth: disc + 120)
                }
                .padding(Space.s7)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .offset(y: dragOffset)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in dragOffset = max(0, v.translation.height) }
                    .onEnded { v in
                        if v.translation.height > 120 { collapse() }
                        else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragOffset = 0 } }
                    }
            )
        }
        // Page fill + ambient blurred-cover backdrop, both full-bleed so no bare
        // strip shows at the window's bottom edge (the backdrop must cover the same
        // area as the page, safe areas included).
        .background {
            ZStack {
                p.page
                cover
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.35)
                    .overlay(p.page.opacity(0.78))
            }
            .clipped()
            .ignoresSafeArea()
        }
        .task(id: player.current?.streamURL) {
            // Decode the track up-front (streams are buffered) so scratching starts with no lag.
            if let url = player.current?.streamURL {
                await scratch.preload(url)
            }
        }
        .onChange(of: player.isPlaying, initial: true) { _, playing in
            if playing {
                if spinStart == nil { spinStart = Date() }
            } else if let s = spinStart {
                baseAngle += Date().timeIntervalSince(s) * degPerSecond
                spinStart = nil
            }
        }
    }

    /// Album disc that turns slowly while playing, driven by a clock so the
    /// progress ticks (every 0.2s) don't stutter or reset the rotation.
    private func spinningDisc(_ size: CGFloat) -> some View {
        TimelineView(.animation(paused: !player.isPlaying || scrubbing)) { tl in
            // Auto-spin freezes while scrubbing; the finger drives rotation instead.
            let live = scrubbing ? 0 : (spinStart.map { tl.date.timeIntervalSince($0) * degPerSecond } ?? 0)
            cover
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .overlay(Circle().fill(p.page).frame(width: size * 0.06)) // spindle
                .rotationEffect(.degrees(baseAngle + live))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                .contentShape(Circle())
                .modifier(LinkCursor())
                .highPriorityGesture(scrubGesture(size))
        }
    }

    /// Rotational drag on the disc → scrub the track (rewind / fast-forward).
    private func scrubGesture(_ size: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                let c = CGPoint(x: size / 2, y: size / 2)
                let ang = atan2(Double(v.location.y - c.y), Double(v.location.x - c.x)) * 180 / .pi
                if !scrubbing {
                    // Begin: bake the current auto-spin into baseAngle, silence AVPlayer.
                    if let s = spinStart { baseAngle += Date().timeIntervalSince(s) * degPerSecond }
                    if player.current == nil {
                        // First launch: nothing queued. Spinning starts the shown album —
                        // there's nothing to scrub until it's actually playing.
                        if album.isPlayable { state.play(album, on: player) }
                        else if let first = state.albums.first(where: { $0.isPlayable }) { state.play(first, on: player) }
                        wasPlaying = true
                    } else {
                        wasPlaying = player.isPlaying
                        if wasPlaying { player.beginScrub() }
                    }
                    scrubStartTime = player.currentTime
                    scrubAccumDeg = 0
                    lastAngle = ang
                    scrubbing = true
                    // Engage real scratch audio when this is a loaded local track.
                    scratchActive = scratch.isLoaded(player.current?.streamURL)
                    if scratchActive { scratch.begin(atSeconds: player.currentTime, volume: player.volume) }
                    return
                }
                var d = ang - (lastAngle ?? ang)
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }   // unwrap across ±180°
                lastAngle = ang
                scrubAccumDeg += d
                baseAngle += d                                          // disc follows the finger
                let target = scrubStartTime + (scrubAccumDeg / 360.0) * secPerRevolution
                scrubTarget = target
                if scratchActive { scratch.update(toSeconds: target) }  // authentic scratch sound
                player.scrub(to: target)                                // keep position + UI synced
            }
            .onEnded { _ in
                guard scrubbing else { return }
                scrubbing = false
                lastAngle = nil
                if scratchActive { scratch.end(); scratchActive = false }   // stop the scratch sound
                // Land exactly where the user scrubbed to — not the scratch read-head, which
                // drifts on partially-buffered streams and snapped the position back.
                player.scrub(to: scrubTarget)
                spinStart = wasPlaying ? Date() : nil  // resume the auto-spin cleanly
                player.endScrub(resumePlaying: wasPlaying)
            }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Button { collapse() } label: {
                Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(p.text)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(p.glassFill))
                    .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            }.buttonStyle(.soft)
            Spacer()
            Text("NOW PLAYING").font(.system(size: 11, weight: .bold)).kerning(1.5).foregroundStyle(p.muted2)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
    }

    /// Vertical DJ pitch fader beside the disc — drag to slow/speed the track (pitch follows).
    /// Top = 1.5×, bottom = 0.5×, centre detent = 1.0×.
    private func djFader(height: CGFloat) -> some View {
        VStack(spacing: 8) {
            Text(String(format: "%.2f×", player.speed))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                .fixedSize()
            GeometryReader { g in
                let h = g.size.height
                let frac = (1.5 - player.speed) / 1.0   // 1.5 at top (0) … 0.5 at bottom (1)
                ZStack {
                    Capsule().fill(p.text.opacity(0.15)).frame(width: 4)
                    Rectangle().fill(p.muted2).frame(width: 14, height: 1)   // centre detent at 1.0×
                    Circle().fill(p.text).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .offset(y: (frac - 0.5) * (h - 16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let f = min(1, max(0, v.location.y / h))   // 0 top … 1 bottom
                    var s = 1.5 - f                            // top fast, bottom slow
                    if abs(s - 1.0) < 0.03 { s = 1.0 }         // snap to normal near centre
                    player.speed = s
                })
                .modifier(LinkCursor())
            }
            .frame(height: height)
            Text("DJ").font(.system(size: 9, weight: .bold)).kerning(1.2).foregroundStyle(p.muted2)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.text.opacity(0.15)).frame(height: 4)
                    Capsule().fill(p.text).frame(width: g.size.width * player.progress, height: 4)
                    Circle().fill(p.text).frame(width: 12, height: 12)
                        .offset(x: max(0, g.size.width * player.progress - 6))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.seek(fraction: v.location.x / g.size.width)
                })
            }
            .frame(height: 16)
            HStack {
                Text(timeString(player.currentTime))
                Spacer()
                Text(timeString(player.duration))
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
        }
    }

    /// On first launch nothing is queued, so a bare `toggle()` no-ops. Start the album this
    /// screen is showing (falling back to the first playable one), otherwise just play/pause.
    private func playOrToggle() {
        if player.current == nil {
            if album.isPlayable { state.play(album, on: player) }
            else if let first = state.albums.first(where: { $0.isPlayable }) { state.play(first, on: player) }
        } else {
            player.toggle()
        }
    }

    private var transport: some View {
        HStack(spacing: Space.s7) {
            Button { player.prev() } label: {
                Image(systemName: "backward.fill").font(.system(size: 20))
                    .foregroundStyle(player.current == nil ? p.muted2 : p.text)
            }.buttonStyle(.soft).disabled(player.current == nil)

            Button { playOrToggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22))
                    .foregroundStyle(p.accentInk)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: player.isPlaying)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(p.accent))
            }.buttonStyle(.soft)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 20))
                    .foregroundStyle(player.hasNext ? p.text : p.muted2)
            }.buttonStyle(.soft).disabled(!player.hasNext)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: Space.s5) {
            Button { state.toggleFavourite(album.id) } label: {
                Image(systemName: album.isFavourite ? "heart.fill" : "heart").font(.system(size: 16))
                    .foregroundStyle(album.isFavourite ? p.text : p.muted)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: album.isFavourite)
            }.buttonStyle(.soft)

            Image(systemName: "speaker.fill").font(.system(size: 12)).foregroundStyle(p.muted2)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.text.opacity(0.15)).frame(height: 4)
                    Capsule().fill(p.text).frame(width: g.size.width * player.volume, height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.volume = min(1, max(0, v.location.x / g.size.width))
                })
            }
            .frame(height: 16)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12)).foregroundStyle(p.muted2)

            // Toggle the DJ pitch fader's visibility (only relevant in DJ mode).
            if player.djMode {
                Button { withAnimation(.easeInOut(duration: 0.15)) { pitchVisible.toggle() } } label: {
                    Image(systemName: pitchVisible ? "eye" : "eye.slash").font(.system(size: 13))
                        .foregroundStyle(pitchVisible ? p.text : p.muted2)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.soft)
                .help(pitchVisible ? "Hide pitch fader" : "Show pitch fader")
            }
        }
    }

    // MARK: Cover

    @ViewBuilder private var cover: some View {
        if let img = coverImage {
            Image(nsImage: img).resizable()
        } else if let url = coverURL {
            CachedRemoteImage(url: url) { Rectangle().fill(album.cover) }
        } else {
            Rectangle().fill(album.cover)
        }
    }

    // MARK: Actions

    private func collapse() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
            player.expanded = false
            dragOffset = 0
        }
    }

    private func openAlbum() {
        state.openedAlbumID = album.id
        collapse()
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
