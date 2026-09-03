import SwiftUI
import AppKit

/// A horizontal "turntable" mini player: a long dark info/control bar with the spinning
/// vinyl protruding off its right end. Tap the disc to collapse the bar (disc-only mode);
/// the ✕ returns to the full window. Panel is transparent so the record silhouette shows.
struct VinylMiniPlayerView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onExpand: () -> Void
    /// Ask the host panel to resize (used by the collapse-to-disc toggle).
    var onResize: (CGSize) -> Void

    // Layout. Extra transparent margin keeps the bar/disc shadows off the window edges.
    private static let margin: CGFloat = 40
    private static let barW: CGFloat = 470
    private static let barH: CGFloat = 92
    private static let discD: CGFloat = 168
    private static let overlap: CGFloat = 92   // how much the disc covers the bar's right end
    static let panelSize = CGSize(width: 2 * margin + barW + (discD - overlap),
                                  height: 2 * margin + discD)
    private static let collapsedSize = CGSize(width: discD + 2 * margin, height: discD + 2 * margin)
    private let degPerSecond = 22.0

    @State private var baseAngle = 0.0
    @State private var spinStart: Date? = nil
    @State private var collapsed = false
    @State private var showVolume = false
    @State private var discHover = false

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
            let m = Self.margin
            ZStack {
                if !collapsed {
                    // Right-anchor the bar (its right edge stays fixed near the disc) so on
                    // resize it unfurls leftward from behind the disc instead of popping in
                    // on the right (the window grows leftward, keeping its right edge fixed).
                    bar
                        .frame(width: Self.barW, height: Self.barH)
                        .position(x: geo.size.width - (m + Self.discD - Self.overlap) - Self.barW / 2,
                                  y: geo.size.height / 2)
                        .transition(.opacity)
                }
                vinyl
                    .frame(width: Self.discD, height: Self.discD)
                    .position(x: geo.size.width - m - Self.discD / 2, y: geo.size.height / 2)

                // Disc-only mode: reveal the track title below the record on hover.
                if collapsed {
                    Text(title)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: Self.discD)
                        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                        .position(x: geo.size.width - m - Self.discD / 2,
                                  y: geo.size.height / 2 + Self.discD / 2 + 10)
                        .opacity(discHover ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .colorScheme(.dark)
    }

    private func toggleCollapsed() {
        // Match the window-resize timing (see MiniPlayerController.collapseCurve) so the
        // bar fade and the panel resize move together as one smooth motion.
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: MiniPlayerController.collapseDuration)) {
            collapsed.toggle()
        }
        onResize(collapsed ? Self.collapsedSize : Self.panelSize)
    }

    // MARK: Info / control bar

    private var bar: some View {
        HStack(spacing: 12) {
            iconButton("xmark", action: onExpand, help: "Back to window")
            volumeButton
            transport
            ZStack {
                if showVolume { volumeRow } else { info }
            }
            .frame(width: 148, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.leading, 16).padding(.trailing, 100)   // keep content clear of the disc
        .frame(width: Self.barW, height: Self.barH, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1)
            Text(artist).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            progress
        }
        .transition(.opacity)
    }

    /// Inline volume control that swaps in for the track info when the speaker is tapped.
    /// A dark pill "well" with a white circular thumb, plus a speaker on the right.
    private var volumeRow: some View {
        HStack(spacing: 10) {
            volumeSlider
            Image(systemName: volumeIcon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75)).frame(width: 16)
        }
        .transition(.opacity)
    }

    private var volumeButton: some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { showVolume.toggle() } } label: {
            Image(systemName: showVolume ? "xmark" : volumeIcon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(showVolume ? .black : .white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(showVolume ? Color.white.opacity(0.9) : .white.opacity(0.08), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Volume")
        .accessibilityLabel(showVolume ? "Hide volume" : "Volume")
    }

    private var volumeIcon: String {
        if player.volume <= 0.001 { return "speaker.slash.fill" }
        if player.volume < 0.34 { return "speaker.wave.1.fill" }
        if player.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var volumeSlider: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumb: CGFloat = 16
            let x = max(thumb / 2, min(w - thumb / 2, w * player.volume))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))                       // the well
                Capsule().fill(.white.opacity(0.4))                        // filled portion
                    .frame(width: max(0, x))
                    .padding(3)
                Circle().fill(.white).frame(width: thumb, height: thumb)   // thumb
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: x - thumb / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                player.volume = min(1, max(0, v.location.x / w))
            })
        }
        .frame(height: 22)
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

    private var transport: some View {
        HStack(spacing: 12) {
            ctrl("backward.fill", 14, label: "Previous track") { player.prev() }
            Button { playOrToggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white))
                    .contentTransition(.symbolEffect(.replace))
            }.buttonStyle(.plain).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            ctrl("forward.fill", 14, label: "Next track") { player.next() }
        }
    }

    private var progress: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white).frame(width: max(0, geo.size.width * player.progress))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.seek(fraction: v.location.x / geo.size.width)
                })
            }
            .frame(height: 3)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(timeString(player.currentTime))
            .accessibilityAdjustableAction { direction in
                guard player.duration > 0 else { return }
                let step = 5.0 / player.duration
                switch direction {
                case .increment: player.seek(fraction: min(1, player.progress + step))
                case .decrement: player.seek(fraction: max(0, player.progress - step))
                @unknown default: break
                }
            }
            HStack {
                Text(timeString(player.currentTime))
                Spacer()
                Text(timeString(player.duration))
            }
            .font(.system(size: 8, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: 140)
    }

    // MARK: Vinyl

    private var vinyl: some View {
        ZStack {
            // Static shadow circle → clean circular shadow (not re-rasterised while spinning).
            Circle().fill(.black)
                .frame(width: Self.discD, height: Self.discD)
                .shadow(color: .black.opacity(0.5), radius: 22, y: 9)

            TimelineView(.animation(paused: !player.isPlaying || reduceMotion)) { tl in
                let live = reduceMotion ? 0 : (spinStart.map { tl.date.timeIntervalSince($0) * degPerSecond } ?? 0)
                ZStack {
                    Circle().fill(RadialGradient(colors: [Color(white: 0.11), .black],
                                                 center: .center, startRadius: 6, endRadius: Self.discD / 2))
                    ForEach(0..<12) { i in
                        Circle().strokeBorder(.white.opacity(0.05), lineWidth: 0.8)
                            .padding(CGFloat(i) * 6 + 8)
                    }
                    Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    coverLabel
                        .frame(width: Self.discD * 0.42, height: Self.discD * 0.42)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 2))
                    Circle().fill(.black).frame(width: 11, height: 11)
                    Circle().fill(Color(white: 0.55)).frame(width: 4, height: 4)
                }
                .rotationEffect(.degrees(baseAngle + live))
            }
            // Scale only the content, never the shadow circle (scaling a shadowed view
            // rasterises a square buffer and clips the shadow into a hard border).
            .scaleEffect(collapsed && discHover ? 1.035 : 1)
            .animation(.easeOut(duration: 0.18), value: discHover)
        }
        .modifier(LinkCursor())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { discHover = h } }
        .onTapGesture { toggleCollapsed() }
        .help(collapsed ? "Show controls" : "Hide controls")
        .onChange(of: player.isPlaying, initial: true) { _, playing in
            if playing {
                if spinStart == nil { spinStart = Date() }
            } else if let s = spinStart {
                baseAngle += Date().timeIntervalSince(s) * degPerSecond
                spinStart = nil
            }
        }
    }

    @ViewBuilder private var coverLabel: some View {
        if let img = coverImage {
            Image(nsImage: img).resizable().scaledToFill()
        } else if let url = coverURL {
            CachedRemoteImage(url: url) { Circle().fill(album.cover) }
        } else {
            Circle().fill(album.cover)
        }
    }

    // MARK: Bits

    private func iconButton(_ system: String, action: @escaping () -> Void, help: String) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: Circle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func ctrl(_ system: String, _ size: CGFloat, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private func playOrToggle() {
        if player.current == nil, let first = state.albums.first(where: { $0.isPlayable }) {
            state.play(first, on: player)
        } else {
            player.toggle()
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
