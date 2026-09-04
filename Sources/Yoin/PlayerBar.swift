import SwiftUI
import AppKit
import AVKit

/// AirPlay / audio-output picker, wrapping AppKit's `AVRoutePickerView`. It routes the system's
/// AVPlayer audio (the normal streaming/local path) to AirPlay devices. Note: DJ varispeed mode
/// uses a separate AVAudioEngine that renders to the default device and won't follow this route.
struct AirPlayButton: NSViewRepresentable {
    var color: NSColor
    var activeColor: NSColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(color, for: .normal)
        v.setRoutePickerButtonColor(activeColor, for: .activeHighlighted)
        return v
    }

    func updateNSView(_ v: AVRoutePickerView, context: Context) {
        v.setRoutePickerButtonColor(color, for: .normal)
        v.setRoutePickerButtonColor(activeColor, for: .activeHighlighted)
    }
}

struct PlayerBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @AppStorage("ambientTheming") private var ambientTheming = true

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
                }.buttonStyle(.soft).tip("Open now playing")
                Button { openNowPlayingAlbum() } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        if state.radioActive {
                            HStack(spacing: 3) {
                                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 8, weight: .bold))
                                Text("RADIO · \(state.currentRadioLabel ?? "")").font(.system(size: 8, weight: .bold)).kerning(0.5).lineLimit(1)
                            }
                            .foregroundStyle(p.accent)
                        }
                        Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Text(artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
                .appContextMenu {
                    player.current.map { nowPlayingTrackMenuItems(for: $0, state: state, player: player) } ?? []
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Center: controls + waveform
            VStack(spacing: Space.s2) {
                HStack(spacing: Space.s5) {
                    Button { player.prev() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 15))
                            .foregroundStyle(player.current == nil ? p.muted2 : p.muted)
                    }.buttonStyle(.soft).disabled(player.current == nil).tip("Previous track")
                    Button { playOrToggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13))
                            .foregroundStyle(p.accentInk)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: player.isPlaying)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(p.accent))
                    }.buttonStyle(.soft).tip(player.isPlaying ? "Pause" : "Play")
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 15))
                            .foregroundStyle(player.hasNext ? p.muted : p.muted2)
                    }.buttonStyle(.soft).disabled(!player.hasNext).tip("Next track")
                }
                WaveformView()
            }
            .frame(maxWidth: .infinity)

            // Right
            HStack(spacing: Space.s4) {
                Button { if let t = player.current { state.toggleLikedSong(t) } } label: {
                    let liked = player.current.map { state.isLiked($0) } ?? false
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundStyle(liked ? p.text : p.muted)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: liked)
                }.buttonStyle(.soft).disabled(player.current == nil).tip("Favourite song")
                    .accessibilityValue((player.current.map { state.isLiked($0) } ?? false) ? "On" : "Off")

                VolumeControl()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { state.queueOpen.toggle() }
                } label: {
                    Image(systemName: "list.bullet").font(.system(size: 13))
                        .foregroundStyle(state.queueOpen ? p.text : p.muted)
                }.buttonStyle(.soft).tip("Up Next")
                    .accessibilityValue(state.queueOpen ? "Shown" : "Hidden")

                AirPlayButton(color: NSColor(p.muted), activeColor: NSColor(p.text))
                    .frame(width: 18, height: 18)
                    .help("AirPlay / output device")
                    .accessibilityLabel("AirPlay and output device")

                Button { MiniPlayerController.shared.toggle() } label: {
                    Image(systemName: "pip").font(.system(size: 13))
                        .foregroundStyle(p.muted)
                }.buttonStyle(.soft).tip("Mini player").accessibilityLabel("Toggle mini player")

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13))
                        .foregroundStyle(p.muted)
                }.buttonStyle(.soft).accessibilityLabel("Toggle full screen").tip("Full screen")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, Space.s3).padding(.horizontal, Space.s5)
        .glass(glow: true, tint: ambientTheming ? state.ambient : nil)
    }

    /// Open the album of the track shown in the bar.
    private func openNowPlayingAlbum() {
        withAnimation(.easeInOut(duration: 0.2)) {
            state.openedAlbumID = (state.nowPlayingAlbum ?? state.current).id
        }
    }

    private func playOrToggle() {
        if player.current == nil, let first = state.albums.first(where: { $0.isPlayable }) {
            state.play(first, on: player)
        } else {
            player.toggle()
        }
    }
}

/// Spinning record with the album label in the middle. Spins only while playing.
private struct Vinyl: View {
    let cover: LinearGradient
    let artwork: NSImage?
    let artworkURL: URL?
    let spinning: Bool
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            guard !reduceMotion else { return }   // honour Reduce Motion — no continuous spin
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
                .tip(player.volume <= 0.001 ? "Unmute" : "Mute")

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
                player.volume = min(1, max(0, player.volume + (precise ? raw : raw * 8) / 600))
            }
        }
    }
}

private struct WaveformView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            Text(timeString(player.currentTime))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                .frame(width: 34)
            GeometryReader { geo in
                // Real per-track waveform when we've analysed it (local files); else placeholder.
                let src = state.nowPlayingWaveform ?? Waveform.bars
                // Fit the bar count to the available width so bars never collapse to nothing.
                let count = max(20, min(src.count, Int(geo.size.width / 4)))
                let bars = (0..<count).map { src[$0 * src.count / count] }
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
                .accessibilityHidden(true)
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { v in
                        player.seek(fraction: v.location.x / geo.size.width)
                    }
                )
            }
            .frame(minWidth: 120, maxWidth: 340)
            .frame(height: 26)
            .task(id: player.current?.id) { state.ensureWaveform(for: player.current) }
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(timeString(player.currentTime))
            .accessibilityAdjustableAction { direction in
                guard player.current != nil, player.duration > 0 else { return }
                let step = 5.0 / player.duration
                switch direction {
                case .increment: player.seek(fraction: min(1, player.progress + step))
                case .decrement: player.seek(fraction: max(0, player.progress - step))
                @unknown default: break
                }
            }
            .onScrollWheel { dx, dy, precise, _ in
                guard player.current != nil, player.duration > 0 else { return }
                let raw = abs(dx) >= abs(dy) ? dx : -dy
                player.seek(fraction: min(1, max(0, player.progress + (precise ? raw : raw * 8) / 900)))
            }
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
