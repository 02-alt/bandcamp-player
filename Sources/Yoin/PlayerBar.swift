import SwiftUI
import AppKit

struct PlayerBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    /// The album the transport actions (favourite) apply to.
    private var activeAlbum: Album { state.nowPlayingAlbum ?? state.current }

    // What the bar displays: the playing track, else the crate's front album.
    private var title: String { player.current?.title ?? state.current.title }
    private var artist: String { player.current?.artist ?? state.current.artist }
    private var coverGradient: LinearGradient { state.current.cover }
    private var coverImage: NSImage? {
        if let d = player.current?.artworkData { return NSImage(data: d) }
        return state.current.artwork
    }
    private var coverURL: URL? { player.current?.artworkURL ?? state.current.artworkURL }

    var body: some View {
        HStack(spacing: Space.s5) {
            // Now playing — click the title/artist to open its album.
            HStack(spacing: Space.s4) {
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { player.expanded = true }
                } label: {
                    Vinyl(cover: coverGradient, artwork: coverImage, artworkURL: coverURL, spinning: player.isPlaying)
                }.buttonStyle(.soft)
                Button { openNowPlayingAlbum() } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Text(artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Center: controls + waveform
            VStack(spacing: Space.s2) {
                HStack(spacing: Space.s5) {
                    Button { player.prev() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 15))
                            .foregroundStyle(player.current == nil ? p.muted2 : p.muted)
                    }.buttonStyle(.soft).disabled(player.current == nil)
                    Button { playOrToggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13))
                            .foregroundStyle(p.accentInk)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: player.isPlaying)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(p.accent))
                    }.buttonStyle(.soft)
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 15))
                            .foregroundStyle(player.hasNext ? p.muted : p.muted2)
                    }.buttonStyle(.soft).disabled(!player.hasNext)
                }
                WaveformView()
            }

            // Right
            HStack(spacing: Space.s4) {
                Button { state.toggleFavourite(activeAlbum.id) } label: {
                    Image(systemName: activeAlbum.isFavourite ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundStyle(activeAlbum.isFavourite ? p.text : p.muted)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: activeAlbum.isFavourite)
                }.buttonStyle(.soft)

                VolumeControl()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { state.queueOpen.toggle() }
                } label: {
                    Image(systemName: "list.bullet").font(.system(size: 13))
                        .foregroundStyle(state.queueOpen ? p.text : p.muted)
                }.buttonStyle(.soft).help("Up Next")

                Button { MiniPlayerController.shared.toggle() } label: {
                    Image(systemName: "pip").font(.system(size: 13))
                        .foregroundStyle(p.muted)
                }.buttonStyle(.soft).help("Mini player")

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13))
                        .foregroundStyle(p.muted)
                }.buttonStyle(.soft)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, Space.s3).padding(.horizontal, Space.s5)
        .glass(glow: true)
    }

    /// Open the album of the track shown in the bar.
    private func openNowPlayingAlbum() {
        withAnimation(.easeInOut(duration: 0.2)) {
            state.openedAlbumID = activeAlbum.id
        }
    }

    private func playOrToggle() {
        if player.current == nil, let first = state.albums.first(where: { $0.isPlayable }) {
            state.play(first, on: player)
        } else {
            player.toggle()
        }
    }

    private func ctrl(_ system: String, size: CGFloat) -> some View {
        Button {} label: {
            Image(systemName: system).font(.system(size: size)).foregroundStyle(p.muted)
        }.buttonStyle(.plain)
    }
}

/// Spinning record with the album label in the middle. Spins only while playing.
private struct Vinyl: View {
    let cover: LinearGradient
    let artwork: NSImage?
    let artworkURL: URL?
    let spinning: Bool
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.10), Color(white: 0.04)],
                                     center: .center, startRadius: 2, endRadius: 24))
                .overlay(
                    ForEach(0..<6) { i in
                        Circle().strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                            .padding(CGFloat(i) * 4 + 3)
                    }
                )
            Circle().fill(cover).frame(width: 26, height: 26)
                .overlay {
                    if let art = artwork {
                        Image(nsImage: art).resizable().scaledToFill()
                            .frame(width: 26, height: 26).clipShape(Circle())
                    } else if let url = artworkURL {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { Color.clear }
                        .frame(width: 26, height: 26).clipShape(Circle())
                    }
                }
                .overlay(Circle().fill(Color(white: 0.05)).frame(width: 6, height: 6))
        }
        .frame(width: 48, height: 48)
        .rotationEffect(.degrees(angle))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        .onChange(of: spinning, initial: true) { _, playing in
            if playing {
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { angle += 360 }
            } else {
                withAnimation(.default) { }   // stop accumulating
            }
        }
    }
}

/// Speaker icon (level-aware) + a thin draggable volume bar.
private struct VolumeControl: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    private var icon: String {
        if player.volume <= 0.001 { return "speaker.slash.fill" }
        if player.volume < 0.34 { return "speaker.wave.1.fill" }
        if player.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: Space.s2) {
            Button {
                player.volume = player.volume > 0 ? 0 : 0.8
            } label: {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(p.muted)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, alignment: .leading)
            }.buttonStyle(.soft)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.edgeSoft).frame(height: 4)
                    Capsule().fill(p.text).frame(width: geo.size.width * player.volume, height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { v in
                        player.volume = min(1, max(0, v.location.x / geo.size.width))
                    }
                )
            }
            .frame(width: 72, height: 20)
        }
    }
}

private struct WaveformView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            Text(timeString(player.currentTime))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                .frame(width: 34)
            GeometryReader { geo in
                // Fit the bar count to the available width so bars never collapse to nothing.
                let count = max(20, min(Waveform.bars.count, Int(geo.size.width / 4)))
                let bars = (0..<count).map { Waveform.bars[$0 * Waveform.bars.count / count] }
                let prog = player.current != nil ? player.progress : Waveform.progress
                let onCount = Int(Double(count) * prog)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(i < onCount ? p.text : p.text.opacity(0.22))
                            .frame(height: max(2, bars[i] * geo.size.height))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { v in
                        player.seek(fraction: v.location.x / geo.size.width)
                    }
                )
            }
            .frame(minWidth: 120, maxWidth: 340)
            .frame(height: 26)
            Text(player.current != nil ? timeString(player.duration) : "2:26")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                .frame(width: 34)
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
