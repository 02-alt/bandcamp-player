import SwiftUI
import AppKit

/// Full-window Now Playing screen. Flat and disc-centric (no skeuomorphism):
/// a circular album disc with a progress ring, ambient blurred cover, clean transport.
struct NowPlayingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    // Note: the playhead clock is deliberately NOT observed here. Reading it (even one property)
    // would re-render this whole ~1200-line body ~10×/s. Progress ring + scrubber are leaf views
    // (`DiscProgressRing`, `NowPlayingScrubber`) that own the clock instead.
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("ambientTheming") private var ambientTheming = true
    @AppStorage("shareCardAmbient") private var shareCardAmbient = true

    @StateObject private var shareAnchor = NSViewAnchor()
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

    // Faint vinyl surface-noise loop, on only in turntable mode while playing.
    @State private var crackle = CrackleAudio()
    @AppStorage("vinylCrackle") private var vinylCrackle = true

    // Whether the DJ pitch fader is shown (toggled by the icon next to the volume bar).
    @State private var pitchVisible = true

    // Time-synced lyrics (LRCLIB). `lyrics` is the fetched result for the current track (nil =
    // none available); `showLyrics` swaps the hero disc for the scrolling lyric list. The toggle
    // only appears when synced lyrics actually exist, per the Settings copy.
    @AppStorage("lyricsEnabled") private var lyricsEnabled = true
    @State private var lyrics: SyncedLyrics?
    @State private var showLyrics = false

    // About / Credits — same info First Listen shows, surfaced here too.
    @State private var infoTab: TrackInfoTab? = nil
    @State private var npBio: ArtistBio? = nil
    @State private var npBioArtist = ""            // artist the loaded bio belongs to
    @State private var npGenius: [GeniusCredit]? = nil
    @Namespace private var heroNS

    // Turntable record speed: 33⅓ (LP), 45 or 78 (singles). Pressing the record-switch cycles it,
    // shrinking the disc to a single and repitching the audio via the varispeed engine.
    @State private var rpm = 33

    // Slowed + Reverb: the FX popover (Pitch + Reverb sliders) opened from a pill under the title.
    @State private var showFX = false

    // Decoded hero artwork, cached. `NSImage(data:)` re-decodes the full-res art on every call, and
    // `cover` is read ~60×/s inside the spinning TimelineView *and* on every body invalidation for
    // the background blur — so decoding lazily here would peg the main thread and make taps lag.
    // Decode once when the source track/album changes; reuse the same instance every frame.
    @State private var heroImage: NSImage?

    private let degPerSecond = 12.0   // ~30s per revolution — a slow turn
    private let secPerRevolution = 18.0   // drag sensitivity: one full turn = 18s of audio

    /// Whether the hero disc is drawn as a full turntable (record + platter + tonearm).
    private var turntable: Bool { state.nowPlayingStyle == .turntable }
    /// The disc's actual turn rate — coupled to the DJ pitch fader so speeding the track up
    /// visibly spins the record faster (turntable pitch control), like a real deck.
    private var spinDegPerSecond: Double { degPerSecond * (player.djMode ? player.speed : 1) }

    private var np: NowPlayingSubject { state.nowPlaying(player.current) }
    private var album: Album { np.album }
    private var title: String { np.title }
    private var artist: String { np.artist }
    private var coverURL: URL? { np.coverURL }
    /// Not in your Bandcamp collection — nudge to buy it and support the artist. Covers imported
    /// local files, wishlist previews, and albums surfaced from a friend's collection.
    private var notOwned: Bool {
        // In the owned library: a local import still nudges to buy on Bandcamp; an owned Bandcamp
        // album never does (even if its item URL is missing). Anything not in the library
        // (wishlist preview / a friend's item) is not owned.
        if state.albumIndex[album.id] != nil { return album.source == .local }   // O(1) vs scanning albums
        return true
    }
    /// A direct Bandcamp album page to buy this, when one exists (wishlist and friend items carry it).
    private var buyURL: URL? {
        guard notOwned, album.source == .bandcamp, let s = album.bandcampItemURL else { return nil }
        return URL(string: s)
    }

    /// A soft chip that buys the exact album on Bandcamp, or searches for imported tracks with no page.
    private var supportNudge: some View {
        let canBuy = buyURL != nil
        return Button { supportOnBandcamp() } label: {
            HStack(spacing: 5) {
                Image(systemName: "bag").font(.system(size: 10, weight: .semibold))
                Text(canBuy ? "Buy on Bandcamp" : "Support \(artist) on Bandcamp")
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(p.muted)
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(Capsule().fill(p.glassFill))
            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .padding(.top, 2)
        .help(canBuy ? "You don't own this — buy it on Bandcamp to support the artist"
                     : "You imported this track — find it on Bandcamp to support the artist")
    }

    // MARK: Effects — FX pill + popover (room/vinyl DSP, crackle, slowed + reverb)

    /// Whether the room/vinyl DSP is currently colouring the sound.
    private var roomActive: Bool { player.roomEnabled && !Room.preset(named: player.roomPresetName).isNeutral }

    /// A soft "FX" chip under the title that opens the effects menu: room/vinyl presets, the vinyl
    /// crackle toggle, and (in DJ mode) the slowed + reverb sliders. A dot marks it when any
    /// tone-shaping effect is engaged.
    private var fxPill: some View {
        let active = roomActive || player.pitch != 0 || player.reverbMix > 0
        return Button { showFX.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .semibold))
                Text("FX").font(.system(size: 11, weight: .bold)).kerning(0.5)
                if active { Circle().fill(p.accent).frame(width: 5, height: 5) }
            }
            .foregroundStyle(active ? p.text : p.muted)
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(Capsule().fill(p.glassFill))
            .overlay(Capsule().strokeBorder(active ? p.accent.opacity(0.5) : p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .padding(.top, 2)
        .help("Effects — room & vinyl, crackle, slowed + reverb")
        .accessibilityLabel("Effects")
        .accessibilityValue(active ? "On" : "Off")
        .popover(isPresented: $showFX, arrowEdge: .bottom) { fxPopover }
    }

    private var fxPopover: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            // ── Room & vinyl DSP ────────────────────────────────
            VStack(alignment: .leading, spacing: Space.s3) {
                fxSectionHeader("Room & vinyl", systemImage: "speaker.wave.2")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    roomChip(Room.off)
                    ForEach(Room.presets) { roomChip($0) }
                }

                // Effect-strength bar — dimmed until a preset is picked.
                let hasRoom = roomActive
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Amount").font(.system(size: 12, weight: .medium)).foregroundStyle(p.text)
                        Spacer()
                        Text("\(Int((player.roomAmount * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                    }
                    Slider(value: $player.roomAmount, in: 0...1)
                        .controlSize(.small).tint(p.accent)
                        .accessibilityLabel("Effect amount")
                }
                .opacity(hasRoom ? 1 : 0.4)
                .disabled(!hasRoom)
            }

            Divider().overlay(p.edgeSoft)

            // ── Vinyl crackle ───────────────────────────────────
            Toggle(isOn: $vinylCrackle) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Vinyl crackle").font(.system(size: 12, weight: .medium)).foregroundStyle(p.text)
                    Text("Analog surface warmth").font(.system(size: 10)).foregroundStyle(p.muted2)
                }
            }
            .toggleStyle(.switch).tint(p.accent)

            // ── Slowed + reverb (downloaded tracks, DJ engine) ──
            if player.djMode {
                Divider().overlay(p.edgeSoft)
                VStack(alignment: .leading, spacing: Space.s3) {
                fxSectionHeader("Slowed + reverb", systemImage: "waveform")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Speed").font(.system(size: 12, weight: .medium)).foregroundStyle(p.text)
                        Spacer()
                        Text(String(format: "%.2f×", player.speed))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                    }
                    Slider(value: $player.speed, in: 0.5...1.5)
                        .controlSize(.small).tint(p.accent)
                        .accessibilityLabel("Playback speed")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Extra pitch").font(.system(size: 12, weight: .medium)).foregroundStyle(p.text)
                        Spacer()
                        Text(player.pitch == 0 ? "0 st" : String(format: "%+.0f st", player.pitch))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                    }
                    Slider(value: Binding(
                        get: { player.pitch },
                        set: { player.pitch = abs($0) < 0.5 ? 0 : $0.rounded() }
                    ), in: -12...12)
                    .controlSize(.small).tint(p.accent)
                    .accessibilityLabel("Extra pitch, semitones")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Reverb").font(.system(size: 12, weight: .medium)).foregroundStyle(p.text)
                        Spacer()
                        Text(String(format: "%.0f%%", player.reverbMix))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                    }
                    Slider(value: Binding(
                        get: { player.reverbMix },
                        set: { player.reverbMix = $0.rounded() }
                    ), in: 0...100)
                    .controlSize(.small).tint(p.accent)
                    .accessibilityLabel("Reverb wet/dry mix")
                }
                HStack(spacing: Space.s2) {
                    // One-tap preset: slow the track and wrap it in reverb.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            player.speed = 0.80; player.pitch = 0; player.reverbMix = 40
                        }
                    } label: {
                        Text("Slowed + reverb").font(.system(size: 11, weight: .bold)).foregroundStyle(p.accentInk)
                            .padding(.vertical, 6).padding(.horizontal, 12)
                            .background(Capsule().fill(p.accent))
                    }
                    .buttonStyle(.soft)
                    // Reset the whole chain: the turntable speed (which bends pitch), the extra pitch
                    // shift, AND the reverb — the old button left the speed alone.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            player.speed = 1.0; player.pitch = 0; player.reverbMix = 0
                        }
                    } label: {
                        Text("Reset").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
                            .padding(.vertical, 5).padding(.horizontal, 12)
                            .background(Capsule().fill(p.glassFill))
                            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                    }
                    .buttonStyle(.soft)
                    .disabled(player.speed == 1.0 && player.pitch == 0 && player.reverbMix == 0)
                    .help("Reset speed, pitch and reverb")
                    Spacer(minLength: 0)
                }
                Text("Applies to downloaded tracks.").font(.system(size: 10)).foregroundStyle(p.muted2)
                }
            }
        }
        .padding(Space.s5)
        .frame(width: 340)
    }

    private func fxSectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
                .accessibilityHidden(true)
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.8)
                .foregroundStyle(p.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }

    /// A room-preset chip for the FX popover. Tapping selects it (and enables the room DSP);
    /// tapping "Off" turns it off. Fills its grid cell so the menu reads as a tidy set.
    private func roomChip(_ profile: RoomProfile) -> some View {
        let isOff = profile.name == Room.off.name
        let on = isOff ? !roomActive : (player.roomEnabled && player.roomPresetName == profile.name)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isOff { player.roomEnabled = false }
                else { player.roomPresetName = profile.name; player.roomEnabled = true }
            }
        } label: {
            Text(profile.name).font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(on ? p.accentInk : p.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7).padding(.horizontal, 8)
                .background(Capsule().fill(on ? p.accent : p.glassFill))
                .overlay(Capsule().strokeBorder(on ? .clear : p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .accessibilityLabel("Room preset: \(profile.name)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// The right-click menu for the whole Now Playing screen: track actions plus the DJ
    /// pitch-fader show/hide (when DJ mode is on).
    private func screenMenuItems() -> [AppMenuItem] {
        var items = player.current.map { nowPlayingTrackMenuItems(for: $0, state: state, player: player, includeEffects: true) } ?? []

        // Art mode lives here now (its bottom-bar button was replaced by the lyrics toggle).
        if !items.isEmpty { items.append(.divider()) }
        items.append(AppMenuItem(title: "Art mode", systemImage: "photo.artframe") {
            withAnimation(.easeInOut(duration: 0.3)) { player.artMode = true }
        })

        // On compact windows the bottom utility bar is hidden, so surface its remaining actions
        // (lyrics toggle, share) here — otherwise they'd be unreachable.
        let barHidden = (NSApp.keyWindow?.contentView?.frame.height ?? 0) < 1000
        if barHidden {
            if lyricsEnabled && lyrics != nil {
                items.append(AppMenuItem(title: showLyrics ? "Hide lyrics" : "Show lyrics",
                                         systemImage: "quote.bubble") {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { showLyrics.toggle() }
                })
            }
            if player.current != nil {
                items.append(AppMenuItem(title: "Share now playing", systemImage: "square.and.arrow.up") {
                    shareNowPlaying()
                })
            }
        }

        if !items.isEmpty { items.append(.divider()) }
        items.append(AppMenuItem(title: turntable ? "Flat disc" : "Turntable mode",
                                 systemImage: turntable ? "circle" : "opticaldiscdrive") {
            withAnimation(.easeInOut(duration: 0.25)) {
                state.nowPlayingStyle = turntable ? .flat : .turntable
            }
        })
        if player.djMode && !turntable {
            if !items.isEmpty { items.append(.divider()) }
            items.append(AppMenuItem(title: pitchVisible ? "Hide pitch fader" : "Show pitch fader",
                                     systemImage: pitchVisible ? "eye.slash" : "eye") {
                withAnimation(.easeInOut(duration: 0.15)) { pitchVisible.toggle() }
            })
        }

        return items
    }

    private func supportOnBandcamp() {
        // Wishlist / friend items link straight to their album page; imported files only have a name.
        if let url = buyURL { NSWorkspace.shared.open(url); return }
        let query = artist.trimmingCharacters(in: .whitespaces)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://bandcamp.com/search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        GeometryReader { geo in
            // On a tight window the full bottom utility bar reads stretched and stranded, so below
            // this height we drop it and move volume to a vertical fader beside the disc.
            let compact = geo.size.height < 1000
            // Short laptop screens (small MacBooks, or the window dragged short): tighten the
            // vertical rhythm so the disc keeps a usable size instead of being starved by big gaps.
            let tight = geo.size.height < 780
            let gap: CGFloat = tight ? Space.s3 : Space.s5     // spacing between the cluster's rows
            let vpad: CGFloat = tight ? Space.s4 : Space.s6    // outer top/bottom padding
            let titlePad: CGFloat = tight ? Space.s2 : Space.s4 // breathing room below the cover
            // Size the disc from the height that's left after the fixed column chrome (header,
            // title, scrubber, transport, gaps & padding). Part of that chrome — the transport
            // buttons and title — scales with `ui`, and `ui` scales with the disc, so the disc's
            // own growth costs height: solving disc + 28(ring) + fixed + ~0.4·disc ≤ height gives
            // the ÷1.4 below. The 0.4 covers the scaled transport + title *including* their line-
            // height overhead (a plain 0.32 undershot and clipped the play button off a wide, short
            // window), plus a little safety margin. Everything shrinks together as the window
            // shrinks, while still capping at a comfortable 520 on a large one.
            // Clear the window's title-bar / traffic-light strip (full-bleed content sits under it).
            let topReserve = max(geo.safeAreaInsets.top, 28)
            // 40 header + 35 title + 34 for the always-present FX pill (+ support nudge) + gaps/pad.
            let fixedChrome = 40 + 35 + 34 + titlePad + 6 + vpad * 2 + gap * 3
            let discCapH = max(140, (geo.size.height - topReserve - fixedChrome) / 1.4)
            let disc = min(min(geo.size.width * 0.52, discCapH), 520)
            // Scale the title/transport with the hero disc so the screen stays balanced
            // from the smallest window up to a wide desktop.
            let ui = min(max(disc / 300, 0.82), 1.5)
            // Shrink the window far enough and there's no room for the header/title/scrubber/
            // transport without clipping — so below this drop all the chrome and show just the
            // flat disc, filling the window. Drag the window bigger to get the controls back.
            // The disc scales down with height, so a wide-but-short window still fits the
            // controls; only drop them when genuinely short (or too narrow for the transport row).
            let mini = geo.size.height < 380 || geo.size.width < 420
            // Wide-but-short: pivot to two columns (disc left, controls right) instead of a tall
            // stack that clips the transport and strands the disc in whitespace.
            let landscape = geo.size.width >= 640 && geo.size.height < 520 && !mini
            if mini {
                miniDisc(size: geo.size)
            } else if landscape {
                turntableLandscape(geo)
                    .offset(y: dragOffset)
                    .gesture(dismissGesture)
            } else {
            ZStack {
                VStack(spacing: 0) {
                    header

                    Spacer(minLength: 0)

                    // Centred player cluster — disc, metadata, scrubber and transport move as one
                    // group. The flexible spacers above and below keep it vertically centred at any
                    // window size (they collapse on short windows and grow on tall ones), so the
                    // rhythm reads the same from the smallest window up to a wide desktop.
                    VStack(spacing: gap) {
                    // Hero disc — or the synced-lyrics list when it's toggled on. Turntable mode
                    // shows the record-speed switch beside it; the flat disc keeps the DJ pitch fader.
                    if showLyrics, let ly = lyrics {
                        // Tidal-style: the disc (cover inside) on the left, synced lyrics on the right.
                        // The disc morphs from the centre via `matchedGeometryEffect`.
                        HStack(alignment: .center, spacing: Space.s7) {
                            heroDisc(disc)
                                .matchedGeometryEffect(id: "heroDisc", in: heroNS)
                            LyricsPanel(lyrics: ly) { secs in
                                player.seek(fraction: min(1, max(0, secs / max(1, player.duration))))
                            }
                            .frame(maxWidth: 560)
                            .frame(height: disc + 40)
                            .transition(.opacity)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                    HStack(spacing: Space.s5) {
                        let showFader = !turntable && player.djMode && pitchVisible
                        // LEFT of the disc: on compact windows volume lives here as a vertical fader
                        // (the bottom bar is hidden); otherwise a spacer balances any right-hand fader
                        // so the disc stays centred.
                        if compact {
                            volumeFader(height: disc * 0.82).frame(width: 34)
                        } else if showFader {
                            Color.clear.frame(width: 34, height: 1)
                        } else if turntable {
                            Color.clear.frame(width: 52, height: 1)
                        }
                        heroDisc(disc)
                            .matchedGeometryEffect(id: "heroDisc", in: heroNS)
                        // RIGHT of the disc: DJ pitch fader, else a spacer to balance the left-hand
                        // fader / gutter so the disc stays centred.
                        if showFader { djFader(height: disc * 0.82).frame(width: 34) }
                        else if turntable { Color.clear.frame(width: 52, height: 1) }
                        else if compact { Color.clear.frame(width: 34, height: 1) }
                    }
                    }

                    // Title / artist.
                    nowPlayingTitle(ui)
                    .frame(maxWidth: disc + 120)
                    .padding(.top, titlePad)   // a little breathing room below the cover / lyrics

                    scrubber.frame(maxWidth: disc + 120)

                    transport(ui)
                    }

                    Spacer(minLength: 0)

                    // The full utility bar only when there's room; compact windows show just the
                    // vertical volume fader beside the disc instead.
                    if !compact { bottomBar.frame(maxWidth: disc + 120) }
                }
                .padding(.horizontal, Space.s7)
                .padding(.top, vpad + topReserve).padding(.bottom, vpad)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                // Right-click anywhere on the screen opens the track / DJ menu.
                .appContextMenu { screenMenuItems() }
                .task(id: lyricsFetchKey) { await loadLyrics() }
                // Keep the lyrics panel open across track changes. The layout guards on
                // `let ly = lyrics`, so a track with no synced lyrics falls back to the disc on its
                // own and the panel reappears once the new track's lyrics load.
            }
            .offset(y: dragOffset)
            .gesture(dismissGesture)
            }
        }
        // Page fill + ambient blurred-cover backdrop, both full-bleed so no bare
        // strip shows at the window's bottom edge (the backdrop must cover the same
        // area as the page, safe areas included).
        .background {
            ZStack {
                if ambientTheming && AlbumTheme.hasBackground(album) {
                    // Bespoke skin (e.g. "Forever Alone" → animated black ocean).
                    AlbumTheme.background(for: album, colors: state.ambientPalette)
                    p.page.opacity(0.22)   // light scrim; the skins are dark enough to stay legible
                } else if reduceTransparency {
                    // Reduce Transparency: skip the blurred-cover wash, keep a solid page.
                    p.page
                } else {
                    p.page
                    cover
                        .scaledToFill()
                        .blur(radius: 80)
                        .opacity(0.35)
                        .overlay(p.page.opacity(0.78))
                    // Cover-derived ambient glow (all albums, when theming is on).
                    if ambientTheming, let a = state.ambient {
                        Circle().fill(a.opacity(0.34)).frame(width: 680, height: 680).blur(radius: 150)
                            .offset(x: -200, y: -240)
                        Circle().fill(a.opacity(0.24)).frame(width: 600, height: 600).blur(radius: 150)
                            .offset(x: 240, y: 260)
                    }
                }
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
                baseAngle += Date().timeIntervalSince(s) * spinDegPerSecond
                spinStart = nil
            }
            syncCrackle()
        }
        // DJ pitch fader → visible turn rate: bake the angle spun so far at the OLD rate, then
        // restart the clock so the new speed takes over without the record jumping.
        .onChange(of: player.speed) { old, _ in
            guard let s = spinStart else { return }
            baseAngle += Date().timeIntervalSince(s) * degPerSecond * (player.djMode ? old : 1)
            spinStart = Date()
        }
        .onChange(of: turntable) { _, isTurntable in
            // Leaving turntable mode: a 45/78 selection repitched the audio via djMode; don't let
            // that (or the persisted djMode flag) bleed into the flat disc.
            if !isTurntable { resetRPMToStandard() }
            syncCrackle()
        }
        .onChange(of: vinylCrackle) { _, _ in syncCrackle() }
        .onChange(of: player.volume) { _, v in crackle.setVolume(v) }
        .onChange(of: album.id) { _, _ in
            crackle.setIntensity(VinylPatina.wear(forCount: state.playCount(forAlbum: album.id)))
            refreshHeroImage()
        }
        .onChange(of: player.current?.id) { _, _ in
            // A new record starts at 33 — don't carry a previous single's 45/78 repitch into it.
            if turntable { resetRPMToStandard() }
            refreshHeroImage()
        }
        .onAppear { rpm = currentRPM(); refreshHeroImage() }
        .onDisappear { crackle.stop() }
        .overlay {
            if let tab = infoTab {
                TrackInfoSheet(tab: tab, artist: album.artist,
                               artistBio: npBio, albumNotes: liveAlbum.about,
                               bcCredits: liveAlbum.bcCredits, geniusCredits: npGenius,
                               onClose: { withAnimation(.easeInOut(duration: 0.25)) { infoTab = nil } })
                    .zIndex(50)
            }
        }
        .task(id: album.artist) { await loadNpBio() }
        .task(id: player.current?.id) { await loadNpCredits() }
        .task(id: album.id) { state.loadNotes(for: album.id) }
    }

    /// Bring the crackle loop in line with the current state: on whenever a track is playing and
    /// the surface-noise setting is on (any display style). Thickness tracks play-count wear.
    private func syncCrackle() {
        if vinylCrackle, player.isPlaying {
            crackle.start(volume: player.volume,
                          wear: VinylPatina.wear(forCount: state.playCount(forAlbum: album.id)))
        } else {
            crackle.stop()
        }
    }

    /// Album disc that turns slowly while playing, driven by a clock so the
    /// progress ticks (every 0.2s) don't stutter or reset the rotation.
    ///
    /// The rotating layer is an `Equatable` child (`SpinningArtwork`) so the ~5–10 Hz `currentTime`
    /// ticks — which invalidate this whole view via `@EnvironmentObject player` — don't tear down and
    /// re-schedule its `TimelineView` every tick, which had pinned the spin to the tick rate.
    /// The hero disc — turntable record or flat progress-ring disc (cover inside) — shared between
    /// the centred layout and the lyrics two-column layout via `matchedGeometryEffect`, so it morphs
    /// smoothly to the left when lyrics are toggled on.
    /// Disc-only layout for a very small window: the flat cover disc, as big as fits, and nothing
    /// else. Forced flat even in turntable mode. Drag down to collapse, same as the full screen.
    private func miniDisc(size: CGSize) -> some View {
        let disc = max(120, min(size.width, size.height) - 36 - 28)   // 18pt inset each side + ring
        return flatHeroDisc(disc)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .appContextMenu { screenMenuItems() }
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

    @ViewBuilder private func heroDisc(_ disc: CGFloat) -> some View {
        if turntable {
            turntableRecord(disc)
        } else {
            flatHeroDisc(disc)
        }
    }

    /// The flat progress-ring disc (cover inside). Used by the normal centred layout and, forced
    /// flat regardless of turntable mode, by the disc-only mini window.
    private func flatHeroDisc(_ disc: CGFloat) -> some View {
        ZStack {
            DiscProgressRing()
            spinningDisc(disc)
        }
        .frame(width: disc + 28, height: disc + 28)
        .onScrollWheel { dx, dy, precise, _ in
            guard player.duration > 0 else { return }
            let raw = abs(dx) >= abs(dy) ? dx : -dy
            player.seek(fraction: PlayerControls.scrollNudge(base: player.progress, raw: raw, precise: precise, divisor: PlayerControls.seekDivisor))
        }
    }

    private func spinningDisc(_ size: CGFloat) -> some View {
        SpinningArtwork(
            image: heroImage, fallback: album.cover, diameter: size,
            wear: VinylPatina.wear(forCount: state.playCount(forAlbum: album.id)),
            full: true, spindleColor: p.page,
            paused: !player.isPlaying || scrubbing || reduceMotion,
            baseAngle: baseAngle, spinStart: spinStart, degPerSecond: spinDegPerSecond
        )
        .equatable()
        .contentShape(Circle())
        .modifier(LinkCursor())
        .highPriorityGesture(scrubGesture(size))
    }

    /// The record + progress ring as one reusable unit (RPM scale, spin, jog-scrub, wheel-seek).
    private func turntableRecord(_ disc: CGFloat) -> some View {
        let scale: CGFloat = rpm == 33 ? 1 : (rpm == 45 ? 0.8 : 0.64)
        return ZStack {
            DiscProgressRing()
            turntableDisc(disc, single: rpm != 33)
        }
        .scaleEffect(scale)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82), value: rpm)
        .frame(width: disc + 28, height: disc + 28)
        .onScrollWheel { dx, dy, precise, _ in
            guard player.duration > 0 else { return }
            let raw = abs(dx) >= abs(dy) ? dx : -dy
            player.seek(fraction: PlayerControls.scrollNudge(base: player.progress, raw: raw, precise: precise, divisor: PlayerControls.seekDivisor))
        }
    }

    /// Turntable look: the cover pressed into the centre label of a black record — grooved
    /// platter, play-count wear, analog crackle warmth. Spins (pitch-coupled) and jog-scrubs
    /// exactly like the flat disc; the surrounding ring carries the progress.
    private func turntableDisc(_ size: CGFloat, single: Bool = false) -> some View {
        let wear = VinylPatina.wear(forCount: state.playCount(forAlbum: album.id))
        // Singles (45/78) have a bigger centre label and the classic wide "dinked" hole.
        let labelRatio: CGFloat = single ? 0.5 : 0.42
        let holeRatio: CGFloat = single ? 0.05 : 0.02
        return ZStack {
            // Static shadow caster (a plain black disc) so the drop-shadow isn't recomputed from
            // the spinning content every frame.
            Circle().fill(.black).frame(width: size, height: size)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)

            // STATIC record art — grooves, wear and crackle are rotationally symmetric, so
            // spinning them is invisible. Flattened to a Metal texture (`drawingGroup`) and, via
            // `Equatable`, skipped entirely on the ~5 Hz progress tick that re-evaluates `body`
            // (its inputs — size, wear — don't change with playback), so it isn't re-rasterised.
            if AlbumTheme.usesCD(album) {
                CDArt(size: size)
            } else {
                RecordArt(size: size, wear: wear)
            }

            // Static specular sheen — a fixed light source.
            Circle().fill(
                RadialGradient(colors: [.white.opacity(0.05), .clear],
                               center: UnitPoint(x: 0.34, y: 0.24), startRadius: 0, endRadius: size * 0.62)
            )
            .frame(width: size, height: size)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)

            // Drifting dust motes + a slow travelling glint — analog "warmth".
            if !reduceMotion { VinylAtmosphere(size: size, playing: player.isPlaying).equatable() }

            // Only the centre label actually spins — the one cheap layer (a single clipped image).
            // Isolated as an `Equatable` child so the progress tick doesn't re-schedule its spin
            // clock every ~0.1s (which made the record visibly step at ~10 fps instead of turning).
            SpinningArtwork(
                image: heroImage, fallback: album.cover, diameter: size * labelRatio,
                wear: wear, full: false, spindleColor: p.page,
                paused: !player.isPlaying || scrubbing || reduceMotion,
                baseAngle: baseAngle, spinStart: spinStart, degPerSecond: spinDegPerSecond
            )
            .equatable()

            // Spindle hole, static and on top.
            Circle().fill(Color(white: 0.5)).frame(width: size * holeRatio, height: size * holeRatio)
            Circle().fill(p.page).frame(width: size * holeRatio * 0.6, height: size * holeRatio * 0.6)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .modifier(LinkCursor())
        .highPriorityGesture(scrubGesture(size))
    }

    /// Return to 33⅓ and undo any 45/78 repitch (speed + the djMode flag it set). No-op if already
    /// at 33, so it won't disturb a genuine DJ-fader session in flat mode.
    private func resetRPMToStandard() {
        guard rpm != 33 else { return }
        rpm = 33
        player.speed = 1.0
        player.djMode = false
    }

    /// Derive the current rpm from the engine state (so the switch is right when the screen opens).
    private func currentRPM() -> Int {
        guard player.djMode else { return 33 }
        if player.speed > 1.8 { return 78 }
        if player.speed > 1.15 { return 45 }
        return 33
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

    /// Title · artist · support nudge · FX pill — shared by the centred and landscape layouts.
    private func nowPlayingTitle(_ ui: CGFloat) -> some View {
        VStack(spacing: 6) {
            Button { openAlbum() } label: {
                Group {
                    if let style = AlbumTheme.titleStyle(for: album) {
                        Text(title).foregroundStyle(style)
                    } else {
                        Text(title)
                    }
                }
                .font(.system(size: 24 * ui, weight: .bold)).kerning(-0.4)
                .lineLimit(1).truncationMode(.tail)
                .id(title)
                .transition(.blurReplace)
                .animation(.easeInOut(duration: 0.3), value: title)
            }.buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
            Button { openAlbum() } label: {
                Text(artist).font(.system(size: 15 * ui)).foregroundStyle(p.muted).lineLimit(1)
                    .id(artist)
                    .transition(.blurReplace)
                    .animation(.easeInOut(duration: 0.3), value: artist)
            }.buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
            if notOwned { supportNudge }
            fxPill
        }
    }

    /// Drag-down-to-dismiss, shared by every layout branch.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in dragOffset = max(0, v.translation.height) }
            .onEnded { v in
                if v.translation.height > 120 { collapse() }
                else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragOffset = 0 } }
            }
    }

    /// Wide-but-short window: two columns — the spinning disc (+ its fader) on the left, the
    /// metadata / scrubber / transport centred on the right — so nothing clips and the wide space
    /// isn't wasted. Mirrors First Listen's landscape mode.
    private func turntableLandscape(_ geo: GeometryProxy) -> some View {
        let w = geo.size.width, h = geo.size.height
        let topReserve = max(geo.safeAreaInsets.top, 28)
        let pad: CGFloat = Space.s5
        let disc = max(120, min((h - topReserve - pad * 2) * 0.9, w * 0.4, 440))
        let ui = min(max(disc / 300, 0.82), 1.3)
        let showFader = !turntable && player.djMode && pitchVisible
        return VStack(spacing: 0) {
            header
            HStack(spacing: Space.s6) {
                HStack(spacing: Space.s4) {
                    heroDisc(disc).matchedGeometryEffect(id: "heroDisc", in: heroNS)
                    if showFader { djFader(height: disc * 0.82).frame(width: 34) }
                    else { volumeFader(height: disc * 0.82).frame(width: 34) }
                }
                VStack(spacing: Space.s4) {
                    if showLyrics, let ly = lyrics {
                        // Lyrics take the right column so the toggle still works in this layout.
                        nowPlayingTitle(ui).frame(maxWidth: .infinity)
                        LyricsPanel(lyrics: ly) { secs in
                            player.seek(fraction: min(1, max(0, secs / max(1, player.duration))))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        scrubber
                        transport(ui)
                    } else {
                        Spacer(minLength: 0)
                        nowPlayingTitle(ui).frame(maxWidth: .infinity)
                        scrubber
                        transport(ui)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, topReserve).padding(.bottom, pad).padding(.horizontal, pad)
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .appContextMenu { screenMenuItems() }
        .task(id: lyricsFetchKey) { await loadLyrics() }
    }

    private var header: some View {
        HStack {
            Button { collapse() } label: {
                Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(p.text)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(p.glassFill))
                    .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            }.buttonStyle(.soft)
            .tip("Collapse now playing")
            Spacer()
            NowPlayingMenuButton()
        }
    }

    /// The stable key that drives a lyrics fetch: refetch when the track changes, or when the
    /// feature is toggled on/off in Settings while this screen is open.
    private var lyricsFetchKey: String {
        "\(player.current?.id.uuidString ?? "none")|\(lyricsEnabled)"
    }

    /// Fetch synced lyrics for the current track (LRCLIB, disk-cached). Applied only if the track
    /// hasn't changed by the time the request returns.
    private func loadLyrics() async {
        lyrics = nil
        guard lyricsEnabled, let track = player.current else { return }
        let result = await LyricsService.synced(artist: track.artist, title: track.title,
                                                album: album.title, durationSec: player.duration)
        if player.current?.id == track.id { lyrics = result }
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

    /// Vertical volume fader shown to the left of the disc on compact windows (where the bottom
    /// utility bar is hidden). Drag to set volume; top = full, bottom = mute.
    private func volumeFader(height: CGFloat) -> some View {
        VStack(spacing: 8) {
            Image(systemName: volumeGlyph).font(.system(size: 11)).foregroundStyle(p.muted)
                .frame(height: 12).contentTransition(.symbolEffect(.replace))
            GeometryReader { g in
                let h = g.size.height
                ZStack {
                    Capsule().fill(p.text.opacity(0.15)).frame(width: 4)
                    Capsule().fill(p.text).frame(width: 4, height: max(0, h * player.volume))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    Circle().fill(p.text).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .offset(y: (0.5 - player.volume) * (h - 16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.volume = min(1, max(0, 1 - v.location.y / h))
                })
                .modifier(LinkCursor())
            }
            .frame(height: height)
            .onScrollWheel { dx, dy, precise, _ in
                let raw = abs(dx) >= abs(dy) ? dx : -dy
                player.volume = PlayerControls.scrollNudge(base: player.volume, raw: raw, precise: precise, divisor: PlayerControls.volumeDivisor)
            }
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(player.volume * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.volume = min(1, player.volume + 0.05)
                case .decrement: player.volume = max(0, player.volume - 0.05)
                @unknown default: break
                }
            }
            Text("VOL").font(.system(size: 9, weight: .bold)).kerning(1.2).foregroundStyle(p.muted2)
        }
    }

    private var volumeGlyph: String { PlayerControls.volumeGlyph(player.volume) }

    // A leaf view (see `NowPlayingScrubber`) so the ~10 Hz clock tick re-renders only the bar +
    // time labels, not the whole Now Playing body.
    private var scrubber: some View { NowPlayingScrubber() }

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

    private func transport(_ ui: CGFloat) -> some View {
        HStack(spacing: Space.s7 * ui) {
            Button { player.prev() } label: {
                Image(systemName: "backward.fill").font(.system(size: 17 * ui))
                    .foregroundStyle(player.current == nil ? p.muted2 : p.text)
                    .frame(width: 44 * ui, height: 44 * ui)
                    .contentShape(Circle())
            }.buttonStyle(.soft).disabled(player.current == nil)
            .tip("Previous track")

            Button { playOrToggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 19 * ui))
                    .foregroundStyle(p.accentInk)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: player.isPlaying)
                    .frame(width: 58 * ui, height: 58 * ui)
                    .background(Circle().fill(p.accent))
            }.buttonStyle(.soft)
            .tip(player.isPlaying ? "Pause" : "Play")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 17 * ui))
                    .foregroundStyle(player.hasNext ? p.text : p.muted2)
                    .frame(width: 44 * ui, height: 44 * ui)
                    .contentShape(Circle())
            }.buttonStyle(.soft).disabled(!player.hasNext)
            .tip("Next track")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: Space.s5) {
            Button { if let t = player.current { state.toggleLikedSong(t) } } label: {
                let liked = player.current.map { state.isLiked($0) } ?? false
                Image(systemName: liked ? "heart.fill" : "heart").font(.system(size: 16))
                    .foregroundStyle(liked ? p.text : p.muted)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: liked)
            }.buttonStyle(.soft).disabled(player.current == nil).tip("Favourite song")
            .accessibilityLabel((player.current.map { state.isLiked($0) } ?? false) ? "Remove from favourites" : "Favourite song")
            .accessibilityAddTraits((player.current.map { state.isLiked($0) } ?? false) ? [.isSelected] : [])

            Image(systemName: "speaker.fill").font(.system(size: 12)).foregroundStyle(p.muted2)
                .accessibilityHidden(true)
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
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(player.volume * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.volume = min(1, player.volume + 0.05)
                case .decrement: player.volume = max(0, player.volume - 0.05)
                @unknown default: break
                }
            }
            .onScrollWheel { dx, dy, precise, _ in
                let raw = abs(dx) >= abs(dy) ? dx : -dy
                player.volume = PlayerControls.scrollNudge(base: player.volume, raw: raw, precise: precise, divisor: PlayerControls.volumeDivisor)
            }
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12)).foregroundStyle(p.muted2)
                .accessibilityHidden(true)

            // Share a "now playing" card.
            Button { shareNowPlaying() } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 14)).foregroundStyle(p.muted)
            }
            .buttonStyle(.soft)
            .disabled(player.current == nil)
            .tip("Share now playing")
            .background(NSViewAnchorRep(anchor: shareAnchor))

            // Toggle the synced-lyrics panel (only when this track has synced lyrics).
            // Art mode moved to the right-click menu.
            if lyricsEnabled && lyrics != nil {
                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { showLyrics.toggle() }
                } label: {
                    Image(systemName: "quote.bubble").font(.system(size: 14))
                        .foregroundStyle(showLyrics ? p.text : p.muted)
                }
                .buttonStyle(.soft)
                .accessibilityLabel(showLyrics ? "Hide lyrics" : "Show lyrics")
                .accessibilityAddTraits(showLyrics ? [.isSelected] : [])
                .tip(showLyrics ? "Hide lyrics" : "Show lyrics")
            }

            // About / Credits — the record's story and who made it (same as First Listen).
            if npHasAbout {
                Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { infoTab = .about } } label: {
                    Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(p.muted)
                }
                .buttonStyle(.soft).tip("About")
            }
            if npHasCredits {
                Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { infoTab = .credits } } label: {
                    Image(systemName: "person.2").font(.system(size: 14)).foregroundStyle(p.muted)
                }
                .buttonStyle(.soft).tip("Credits")
            }

            // AirPlay / audio output. (The DJ pitch-fader show/hide moved to the right-click menu.)
            AirPlayButton(color: NSColor(p.muted), activeColor: NSColor(p.text))
                .frame(width: 18, height: 18)
                .help("AirPlay / output device")
        }
    }

    // MARK: About / Credits data

    /// The album with its notes/credits filled in (state.loadNotes populates this in `state.albums`).
    private var liveAlbum: Album { state.album(id: album.id) ?? album }
    private var npHasAbout: Bool { npBio?.text.isEmpty == false || liveAlbum.about?.isEmpty == false }
    private var npHasCredits: Bool { liveAlbum.bcCredits?.isEmpty == false || npGenius?.isEmpty == false }

    private func loadNpBio() async {
        guard npBioArtist != album.artist else { return }
        npBioArtist = album.artist
        npBio = nil
        let titles = state.libraryAlbums(byArtist: album.artist).map(\.title)
        let a = album.artist
        let bio = await ArtistBioService.bio(artist: a, ownedAlbumTitles: titles)
        if album.artist == a { npBio = bio }
    }

    private func loadNpCredits() async {
        npGenius = nil
        guard let track = player.current else { return }
        let c = await GeniusService.credits(artist: track.artist, title: track.title, album: album.title)
        if player.current?.id == track.id { npGenius = c }
    }

    // MARK: Cover

    @ViewBuilder private var cover: some View {
        if let img = heroImage {
            Image(nsImage: img).resizable()
        } else {
            // Static placeholder ONLY — never a per-frame view (e.g. CachedRemoteImage) here,
            // because `cover` renders inside the spinning TimelineView. refreshHeroImage() resolves
            // the real art (embedded or remote, via ArtworkCache) into `heroImage`; until it lands
            // we show the album's gradient rather than re-instantiating a loader 60–120×/s.
            Rectangle().fill(album.cover)
        }
    }

    /// Resolve the hero artwork to a single cached `NSImage` for the current track/album, so the
    /// spinning label reuses one stable image instead of rebuilding a view every frame. Covers
    /// BOTH sources: embedded bytes (local imports) and — crucially for streamed Bandcamp tracks —
    /// the remote `artworkURL`, which otherwise fell through to a `CachedRemoteImage` that the
    /// per-frame TimelineView re-instantiated 60–120×/s (the real turntable-lag culprit).
    private func refreshHeroImage() {
        // 1. Embedded bytes, via the shared decode cache.
        if let d = player.current?.artworkData { heroImage = ArtworkCache.image(for: album.id, data: d); return }
        if let d = album.artworkData { heroImage = ArtworkCache.image(for: album.id, data: d); return }
        // 2. Remote URL: use the already-decoded image if the grid/mini-player cached it (the common
        //    case → set synchronously, no churn); otherwise fetch once and apply if still current.
        guard let url = coverURL else { heroImage = nil; return }
        if let hit = ArtworkCache.remote(url) { heroImage = hit; return }
        heroImage = nil
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else { return }
            ArtworkCache.store(img, for: url)
            if coverURL == url { heroImage = img }   // ignore if the track changed mid-flight
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
        // Owned → open its library detail page. Not owned but with a Bandcamp page → open that page
        // to buy it (a friend/wishlist item has no local detail page to show).
        if let owned = state.libraryAlbum(forBandcampURL: album.bandcampItemURL) {
            state.openedAlbumID = owned.id
            collapse()
        } else if let url = buyURL {
            NSWorkspace.shared.open(url)
        } else {
            state.openedAlbumID = album.id
            collapse()
        }
    }

    /// Render a shareable "now playing" card and open the macOS share sheet. Resolves the cover
    /// to real image data first (ImageRenderer can't wait on async remote loads).
    private func shareNowPlaying() {
        Task { @MainActor in
            let img = await resolvedCoverImage()
            let bcURL = album.bandcampItemURL.flatMap { URL(string: $0) }
            let card = NowPlayingCard(title: title, artist: artist, cover: img,
                                      coverFallback: album.cover, palette: p,
                                      ambient: state.ambient,
                                      ambientBackground: shareCardAmbient,
                                      skin: shareCardAmbient ? AlbumTheme.cardSkin(for: album) : .none,
                                      skinColors: state.ambientPalette,
                                      link: bcURL?.host)
            if let image = ShareCard.render(card) {
                ShareCard.present(image, anchorView: shareAnchor.view, url: bcURL)
            } else {
                state.showNotice("Couldn't create the share image.")
            }
        }
    }

    private func resolvedCoverImage() async -> NSImage? {
        if let img = heroImage { return img }
        if let url = coverURL, let (data, _) = try? await URLSession.shared.data(from: url) {
            return NSImage(data: data)
        }
        return nil
    }

    private func timeString(_ t: Double) -> String { PlayerControls.timeString(t) }
}

/// The "•••" button in the Now Playing header — opens the current track's actions menu
/// (add to playlist, favourite, go to album), anchored beneath the button.
private struct NowPlayingMenuButton: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var frame: CGRect = .zero

    var body: some View {
        Button { open() } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(p.text)
                .frame(width: 40, height: 40)
                .background(Circle().fill(p.glassFill))
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .disabled(player.current == nil)
        .opacity(player.current == nil ? 0.4 : 1)
        .tip("Track actions")
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            }
        )
    }

    private func open() {
        guard let track = player.current else { return }
        let items = nowPlayingTrackMenuItems(for: track, state: state, player: player, includeEffects: true)
        state.showMenu(items, at: CGPoint(x: frame.minX, y: frame.maxY + 6))
    }
}

/// The single rotating layer of the hero disc — the flat cover, or the turntable's centre label.
///
/// Pulled out of `NowPlayingView` and made `Equatable` for one reason: that screen observes
/// `PlayerEngine` (`@EnvironmentObject`), whose `currentTime` republishes 5–10×/s, so its whole
/// `body` re-evaluates on every progress tick. When the spinning `TimelineView` lived inline, each
/// re-eval rebuilt it and coalesced its display-link tick into the parent's, pinning the spin to
/// ~10 fps (a visible step, not a turn). None of this view's inputs change on a progress tick, so
/// `.equatable()` lets SwiftUI skip it entirely — its clock keeps ticking at full frame rate.
private struct SpinningArtwork: View, Equatable {
    var image: NSImage?
    var fallback: LinearGradient
    var diameter: CGFloat      // the rotating image's frame
    var wear: Double
    var full: Bool             // flat disc (patina + spindle + rim + shadow) vs. turntable centre label
    var spindleColor: Color
    var paused: Bool
    var baseAngle: Double
    var spinStart: Date?
    var degPerSecond: Double

    var body: some View {
        TimelineView(.animation(paused: paused)) { tl in
            // Auto-spin freezes while paused (scrub / not playing / Reduce Motion); the finger or a
            // baked-in `baseAngle` still positions the disc.
            let live = paused ? 0 : (spinStart.map { tl.date.timeIntervalSince($0) * degPerSecond } ?? 0)
            art.rotationEffect(.degrees(baseAngle + live))
        }
    }

    @ViewBuilder private var cover: some View {
        if let img = image { Image(nsImage: img).resizable() }
        else { Rectangle().fill(fallback) }
    }

    @ViewBuilder private var art: some View {
        if full {
            cover
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                // Play-count "patina": the more you spin this album, the more the record wears.
                .overlay(VinylPatina(wear: wear).clipShape(Circle()))
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .overlay(Circle().fill(spindleColor).frame(width: diameter * 0.06)) // spindle
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
        } else {
            cover
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 2))
        }
    }

    // `fallback` (a LinearGradient) isn't Equatable and only shows transiently before the image
    // loads — an album change flips `image`/`wear` anyway — so it's left out of the comparison.
    nonisolated static func == (l: SpinningArtwork, r: SpinningArtwork) -> Bool {
        l.image === r.image && l.diameter == r.diameter &&
        l.wear == r.wear && l.full == r.full && l.spindleColor == r.spindleColor &&
        l.paused == r.paused && l.baseAngle == r.baseAngle && l.spinStart == r.spinStart &&
        l.degPerSecond == r.degPerSecond
    }
}

/// Drifting dust specks + one slow travelling glint, clipped to the record. Deterministic positions
/// eased by a slow clock; cheap (a dozen circles) and paused when not playing. `Equatable` for the
/// same reason as `SpinningArtwork` — so the progress tick doesn't re-schedule its drift clock.
private struct VinylAtmosphere: View, Equatable {
    var size: CGFloat
    var playing: Bool

    var body: some View {
        // Drift is slow enough that ~20 fps is indistinguishable from 60 — a third of the
        // per-frame cost for this gradient + 12-mote plusLighter layer.
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let r = size / 2
            ZStack {
                // Slow travelling glint — soft and small so it doesn't read as a halo ring.
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.05), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.22))
                    .frame(width: size * 0.44, height: size * 0.44)
                    .offset(x: CGFloat(cos(t * 0.25)) * r * 0.3, y: CGFloat(sin(t * 0.25)) * r * 0.3)
                // Dust motes.
                ForEach(0..<12, id: \.self) { i in
                    let seed = Double(i)
                    let baseA = (seed * 2.399963).truncatingRemainder(dividingBy: 2 * .pi)
                    let rad = r * (0.3 + 0.62 * ((sin(seed * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1) + 1) / 2)
                    let drift = sin(t * 0.3 + seed) * 0.06
                    let a = baseA + drift
                    Circle().fill(.white.opacity(0.10))
                        .frame(width: max(1, size * 0.006), height: max(1, size * 0.006))
                        .offset(x: CGFloat(cos(a)) * rad, y: CGFloat(sin(a)) * rad)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Clock-driven leaves (isolated so the ~10 Hz playhead tick only re-renders these)

/// The hero disc's progress ring. Owns the clock so the tick re-renders only the ring, not the
/// whole Now Playing surface.
private struct DiscProgressRing: View {
    @EnvironmentObject var clock: PlaybackClock
    @Environment(\.palette) private var p

    var body: some View {
        ZStack {
            Circle().stroke(p.text.opacity(0.12), lineWidth: 4)
            Circle()
                .trim(from: 0, to: clock.progress)
                .stroke(p.text, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// The scrubber bar + time labels. Owns the clock (display) and player (seek) so the tick
/// re-renders only this strip.
private struct NowPlayingScrubber: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var clock: PlaybackClock
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.text.opacity(0.15)).frame(height: 4)
                    Capsule().fill(p.text).frame(width: g.size.width * clock.progress, height: 4)
                    Circle().fill(p.text).frame(width: 12, height: 12)
                        .offset(x: max(0, g.size.width * clock.progress - 6))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.seek(fraction: v.location.x / g.size.width)
                })
            }
            .frame(height: 16)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(PlayerControls.timeString(clock.time))
            .accessibilityAdjustableAction { direction in
                guard player.duration > 0 else { return }
                let step = 5.0 / player.duration
                switch direction {
                case .increment: player.seek(fraction: min(1, player.progress + step))
                case .decrement: player.seek(fraction: max(0, player.progress - step))
                @unknown default: break
                }
            }
            .onScrollWheel { dx, dy, precise, _ in
                guard player.duration > 0 else { return }
                let raw = abs(dx) >= abs(dy) ? dx : -dy
                player.seek(fraction: PlayerControls.scrollNudge(base: player.progress, raw: raw, precise: precise, divisor: PlayerControls.seekDivisor))
            }
            HStack {
                Text(PlayerControls.timeString(clock.time))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: Int(clock.time))
                Spacer()
                Text(PlayerControls.timeString(clock.duration))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: Int(clock.duration))
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
        }
    }
}
