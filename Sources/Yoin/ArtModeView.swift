import SwiftUI

/// Fullscreen "art mode": a screensaver-style display of the current cover with minimal,
/// auto-hiding controls. Exits on Escape, the close button, or the ⌄ chevron.
struct ArtModeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var clock: PlaybackClock
    @Environment(\.palette) private var p
    @AppStorage("ambientTheming") private var ambientTheming = true
    @AppStorage("animatedCover") private var animatedCover = false

    @State private var controlsShown = true
    @State private var hideTask: Task<Void, Never>?

    private var np: NowPlayingSubject { state.nowPlaying(player.current) }
    private var album: Album { np.album }
    private var title: String { np.title }
    private var artist: String { np.artist }
    private var coverImage: NSImage? {
        if let t = player.current, let d = t.artworkData { return ArtworkCache.image(for: t.id, data: d) }
        return album.artwork
    }
    private var coverURL: URL? { np.coverURL }

    var body: some View {
        GeometryReader { geo in
            // Cap the cover so it never crowds out the title/controls, and leave vertical
            // room for them on short/wide windows.
            let side = min(min(geo.size.width * 0.5, (geo.size.height - 260) * 0.9), 460)
            let contentWidth = min(geo.size.width - 96, side + 160)
            // Too small for the framed-cover + controls layout: switch to a mini-player style —
            // the cover fills the whole window and the controls appear only on hover.
            let compact = geo.size.height < 520 || geo.size.width < 440
            ZStack {
                // Clamp the (greedy, full-bleed) background to the window so it never
                // inflates the ZStack and pushes the content off-centre.
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                if compact {
                    compactLayout(geo.size)
                } else {
                    // Distinct sections (s6/s7): the hero art, then the metadata+controls
                    // cluster. Related blocks inside the cluster sit closer (s5), and the
                    // title/artist pair closest of all (s2) so it reads as one unit.
                    VStack(spacing: Space.s7) {
                        Spacer(minLength: Space.s6)
                        cover
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.55), radius: 40, y: 24)

                        VStack(spacing: Space.s5) {
                            VStack(spacing: Space.s2) {
                                titleText
                                    .font(.system(size: 28, weight: .bold)).kerning(-0.4)
                                    .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.7)
                                Text(artist).font(.system(size: 16)).foregroundStyle(p.muted).lineLimit(1)
                            }
                            .frame(maxWidth: contentWidth)

                            controls
                                .frame(maxWidth: contentWidth)
                                .opacity(controlsShown ? 1 : 0)
                                .animation(.easeInOut(duration: 0.4), value: controlsShown)
                        }
                        Spacer(minLength: Space.s6)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                // Close button (top-right), fades with the controls.
                VStack {
                    HStack {
                        Spacer()
                        Button { exit() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(p.text)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(p.glassFill))
                                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                        }.buttonStyle(.soft).tip("Close art mode")
                    }
                    Spacer()
                }
                .padding(Space.s6)
                .opacity(controlsShown ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: controlsShown)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { flashControls() }
            }
            .onTapGesture { flashControls() }
        }
        .ignoresSafeArea()
        .background(
            Button("") { exit() }.keyboardShortcut(.escape, modifiers: []).hidden()
        )
        .onAppear { flashControls() }
        .onDisappear { hideTask?.cancel() }
    }

    // MARK: Pieces

    @ViewBuilder private var background: some View {
        if animatedCover {
            ZStack {
                Color.black
                FlowingArtBackground(image: coverImage, tint: state.ambient ?? .black)
                // Darken so the title/controls and the crisp cover stay legible over the gradient.
                Color.black.opacity(0.28)
            }
        } else if ambientTheming && AlbumTheme.hasBackground(album) {
            ZStack { AlbumTheme.background(for: album, colors: state.ambientPalette); Color.black.opacity(0.35) }
        } else {
            ZStack {
                Color.black
                // Cover-derived ambient glow (all albums, when theming is on).
                if ambientTheming, let a = state.ambient {
                    Circle().fill(a.opacity(0.50)).frame(width: 720, height: 720).blur(radius: 140)
                        .offset(x: -180, y: -220)
                    Circle().fill(a.opacity(0.34)).frame(width: 640, height: 640).blur(radius: 140)
                        .offset(x: 220, y: 260)
                }
                cover.scaledToFill().blur(radius: 130).opacity(0.22)
                Color.black.opacity(0.42)
            }
        }
    }

    @ViewBuilder private var cover: some View {
        if let img = coverImage {
            Image(nsImage: img).resizable().scaledToFill()
        } else if let url = coverURL {
            CachedRemoteImage(url: url) { Rectangle().fill(album.cover) }
        } else {
            Rectangle().fill(album.cover)
        }
    }

    @ViewBuilder private var titleText: some View {
        if AlbumTheme.isForeverAlone(album) {
            Text(title).foregroundStyle(AlbumTheme.gold)
                .shadow(color: Color(red: 0.85, green: 0.65, blue: 0.25).opacity(0.55), radius: 8, y: 1)
        } else {
            Text(title).foregroundStyle(p.text)
        }
    }

    private var controls: some View {
        VStack(spacing: Space.s4) {
            // Slim progress bar.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.text.opacity(0.15)).frame(height: 4)
                    Capsule().fill(p.text).frame(width: g.size.width * clock.progress, height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.seek(fraction: min(1, max(0, v.location.x / g.size.width)))
                })
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Int(clock.progress * 100)) percent")
            .accessibilityAdjustableAction { direction in
                guard player.duration > 0 else { return }
                let step = 5.0 / player.duration
                switch direction {
                case .increment: player.seek(fraction: min(1, player.progress + step))
                case .decrement: player.seek(fraction: max(0, player.progress - step))
                @unknown default: break
                }
            }

            HStack(spacing: Space.s6) {
                transportButton("backward.fill", size: 20, label: "Previous track") { player.prev() }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(p.accentInk)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(p.accent))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }.buttonStyle(.soft).tip(player.isPlaying ? "Pause" : "Play")
                transportButton("forward.fill", size: 20, label: "Next track") { player.next() }
            }

            // Volume.
            HStack(spacing: Space.s3) {
                Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(p.muted2)
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
                .frame(height: 14)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(p.muted2)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: 260)
            .padding(.top, Space.s2)
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
        }
    }

    private func transportButton(_ system: String, size: CGFloat, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: size)).foregroundStyle(p.text)
                .frame(width: 44, height: 44)
        }.buttonStyle(.soft).tip(label)
    }

    // MARK: Compact (small window) — cover fills the window, controls on hover

    @ViewBuilder private func compactLayout(_ size: CGSize) -> some View {
        ZStack {
            cover
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()

            // Title + transport + progress over a bottom scrim; fades with `controlsShown`
            // (the shared hover/idle logic), so it behaves like the mini player.
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: Space.s3) {
                    VStack(spacing: 2) {
                        titleText.font(.system(size: 17, weight: .bold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                    }
                    HStack(spacing: Space.s5) {
                        transportButton("backward.fill", size: 15, label: "Previous track") { player.prev() }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16)).foregroundStyle(p.accentInk)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(p.accent))
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        }.buttonStyle(.soft).tip(player.isPlaying ? "Pause" : "Play")
                        transportButton("forward.fill", size: 15, label: "Next track") { player.next() }
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                            Capsule().fill(.white).frame(width: g.size.width * clock.progress, height: 4)
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            player.seek(fraction: min(1, max(0, v.location.x / g.size.width)))
                        })
                    }
                    .frame(height: 12)
                }
                .padding(Space.s5)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                          startPoint: .top, endPoint: .bottom))
            }
            .frame(width: size.width, height: size.height)
            .opacity(controlsShown ? 1 : 0)
            .animation(.easeInOut(duration: 0.35), value: controlsShown)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Behaviour

    /// Show the controls, then hide them again after a few idle seconds.
    private func flashControls() {
        hideTask?.cancel()
        if !controlsShown { withAnimation(.easeInOut(duration: 0.3)) { controlsShown = true } }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { controlsShown = false }
        }
    }

    private func exit() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { player.artMode = false }
    }
}
