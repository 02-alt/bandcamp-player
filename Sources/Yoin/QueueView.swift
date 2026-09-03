import SwiftUI

/// The "Up Next" panel: the live playback queue. Slides in from the right over a scrim.
/// Tap a row to jump, drag to reorder, ⌫ / the ✕ on a row to remove.
struct QueueView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Scrim — tap to dismiss.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { close() }

            panel
                .frame(width: 360)
                .frame(maxHeight: .infinity)
                .padding(Space.s4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .ignoresSafeArea()
        .background(
            Button("") { close() }.keyboardShortcut(.escape, modifiers: []).hidden()
        )
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Up Next").font(.system(size: 17, weight: .bold)).kerning(-0.3)
                Spacer()
                if player.queue.count > 1 {
                    Button { player.clearQueue() } label: {
                        Text("Clear").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                    }.buttonStyle(.soft)
                }
                IconButton(system: "xmark", label: "Close queue") { close() }
            }

            if state.radioActive {
                HStack(spacing: Space.s2) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("RADIO").font(.system(size: 8, weight: .bold)).kerning(0.8).opacity(0.8)
                        Text(state.currentRadioLabel ?? "Playing").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    Spacer(minLength: Space.s2)
                    // Save the station (unless it's already saved).
                    if !state.isCurrentRadioSaved {
                        Button { state.saveCurrentRadio() } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(p.accent.opacity(0.18)))
                        }.buttonStyle(.soft).help("Save this station")
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).opacity(0.7)
                            .frame(width: 24, height: 24)
                    }
                    Button { state.stopRadio() } label: {
                        Text("Stop").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentInk)
                            .padding(.vertical, 4).padding(.horizontal, 10)
                            .background(Capsule().fill(p.accent))
                    }.buttonStyle(.soft)
                }
                .foregroundStyle(p.accent)
                .padding(.vertical, 6).padding(.horizontal, Space.s3)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(p.accent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(p.accent.opacity(0.3), lineWidth: 1))
            }

            if player.queue.isEmpty {
                Text("Nothing queued")
                    .font(.system(size: 13)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, track in
                        QueueRow(index: i, track: track, playing: i == player.index && player.isPlaying,
                                 isCurrent: i == player.index) {
                            player.jump(to: i)
                        } onRemove: {
                            player.removeFromQueue(at: i)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .onMove { from, to in player.moveInQueue(from: from, to: to) }
                    .onDelete { offsets in offsets.sorted(by: >).forEach { player.removeFromQueue(at: $0) } }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
            }
        }
        .padding(Space.s5)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(glow: true)
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) { state.queueOpen = false }
    }
}

private struct QueueRow: View {
    let index: Int
    let track: Track
    let playing: Bool
    let isCurrent: Bool
    let onTap: () -> Void
    let onRemove: () -> Void
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var hovering = false

    /// Right-click actions: play, favourite/add-to-playlist/go-to-album (shared), remove.
    private var menuItems: [AppMenuItem] {
        var items: [AppMenuItem] = [
            AppMenuItem(title: "Play", systemImage: "play.fill") { onTap() }
        ]
        items.append(contentsOf: nowPlayingTrackMenuItems(for: track, state: state, player: player))
        items.append(.divider())
        items.append(AppMenuItem(title: "Remove from queue", systemImage: "minus.circle") { onRemove() })
        return items
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.s3) {
                cover
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                        .foregroundStyle(isCurrent ? p.text : p.text.opacity(0.9)).lineLimit(1)
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if playing {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(p.muted)
                } else if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(p.muted)
                            .frame(width: 22, height: 22).background(Circle().fill(p.glassFill))
                    }.buttonStyle(.soft)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(p.glassFill).opacity(isCurrent ? 1 : (hovering ? 0.6 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .onHover { hovering = $0 }
        .appContextMenu { menuItems }
    }

    private var cover: some View {
        let gradient = LinearGradient(colors: [Color(white: track.g0), Color(white: track.g1)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        return RoundedRectangle(cornerRadius: 6, style: .continuous).fill(gradient)
            .frame(width: 34, height: 34)
            .overlay {
                if let data = track.artworkData, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if let url = track.artworkURL {
                    CachedRemoteImage(url: url) { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
    }
}
