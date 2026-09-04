import SwiftUI
import AppKit

/// Compact now-playing controls shown from the menu-bar item (`MenuBarExtra`).
struct MenuBarPlayer: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    private var title: String { player.current?.title ?? state.nowPlayingAlbum?.title ?? "Nothing playing" }
    private var artist: String { player.current?.artist ?? state.nowPlayingAlbum?.artist ?? "" }

    var body: some View {
        VStack(spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                cover.frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    if !artist.isEmpty {
                        Text(artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Space.s5) {
                button("backward.fill", size: 15) { player.prev() }
                    .disabled(player.current == nil)
                    .tip("Previous")
                button(player.isPlaying ? "pause.fill" : "play.fill", size: 18) { player.toggle() }
                    .tip(player.isPlaying ? "Pause" : "Play")
                button("forward.fill", size: 15) { player.next() }
                    .disabled(!player.hasNext)
                    .tip("Next")
            }

            HStack(spacing: Space.s3) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(p.muted2)
                Slider(value: $player.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(p.muted2)
            }

            Divider().overlay(p.edgeSoft)

            HStack {
                Button("Open Yoin") { openMainWindow() }
                    .buttonStyle(.soft).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.soft).font(.system(size: 12)).foregroundStyle(p.muted)
            }
        }
        .padding(Space.s4)
        .frame(width: 260)
        .environment(\.palette, p)
    }

    @ViewBuilder private var cover: some View {
        if let d = player.current?.artworkData, let img = NSImage(data: d) {
            Image(nsImage: img).resizable().scaledToFill()
        } else if let a = state.nowPlayingAlbum {
            AlbumArt(album: a, corner: 8)
        } else {
            RoundedRectangle(cornerRadius: 8).fill(p.glassFill)
                .overlay(Image(systemName: "music.note").foregroundStyle(p.muted2))
        }
    }

    private func button(_ system: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: size, weight: .medium)).foregroundStyle(p.text)
                .frame(width: 34, height: 34)
        }.buttonStyle(.soft)
    }

    /// Bring the main window back to the front (it may be hidden while the mini player is up).
    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
