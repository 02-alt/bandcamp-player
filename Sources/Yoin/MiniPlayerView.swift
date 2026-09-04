import SwiftUI
import AppKit

/// A compact, art-forward player styled after TIDAL's floating mini player: full-bleed
/// album artwork with the title, artist, progress and transport controls over a dark
/// scrim, in a rounded square. Lives in a floating panel (see MiniPlayerController).
struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var state: AppState
    var onExpand: () -> Void

    private let side: CGFloat = 360

    private var album: Album { state.nowPlayingAlbum ?? state.current }
    private var title: String { player.current?.title ?? album.title }
    private var artist: String { player.current?.artist ?? album.artist }
    private var coverImage: NSImage? {
        if let d = player.current?.artworkData { return NSImage(data: d) }
        return album.artwork
    }
    private var coverURL: URL? { player.current?.artworkURL ?? album.artworkURL }

    var body: some View {
        ZStack {
            background
            scrim
            content
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .colorScheme(.dark)
    }

    @ViewBuilder private var background: some View {
        Group {
            if let img = coverImage {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if let url = coverURL {
                CachedRemoteImage(url: url) { album.cover }
            } else {
                album.cover
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }

    /// Darkens the top (for the expand button) and bottom (for text/controls).
    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.45), location: 0.0),
            .init(color: .black.opacity(0.0), location: 0.30),
            .init(color: .black.opacity(0.0), location: 0.45),
            .init(color: .black.opacity(0.88), location: 1.0),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onExpand) { glyph("arrow.up.forward") }
                    .buttonStyle(.plain).tip("Expand").accessibilityLabel("Expand player")
                Spacer()
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                    Text(artist).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                progressBar
                controls
            }
            .foregroundStyle(.white)
        }
        .padding(16)
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
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
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            MiniControl(system: "shuffle", size: 15, dim: true, active: player.shuffle, label: "Shuffle") { player.shuffle.toggle() }
            MiniControl(system: "backward.fill", size: 19, label: "Previous track") { player.prev() }
            Button { playOrToggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.white))
                    .contentTransition(.symbolEffect(.replace))
            }.buttonStyle(.plain).tip(player.isPlaying ? "Pause" : "Play")
            MiniControl(system: "forward.fill", size: 19, label: "Next track") { player.next() }
            MiniControl(system: "repeat", size: 15, dim: true, active: player.repeatOne, label: "Repeat") { player.repeatOne.toggle() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private func glyph(_ system: String) -> some View {
        Image(systemName: system).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 28, height: 28).background(.black.opacity(0.35), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)).contentShape(Circle())
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

/// A transport glyph that dims when off, lifts on hover, and marks active toggles.
private struct MiniControl: View {
    let system: String
    let size: CGFloat
    var dim: Bool = false
    var active: Bool = false
    var label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : (dim ? (hovering ? 0.9 : 0.6) : 1)))
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                .frame(width: size + 14, height: size + 14)
                .overlay(alignment: .bottom) {
                    if active { Circle().fill(.white).frame(width: 3, height: 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.12 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
