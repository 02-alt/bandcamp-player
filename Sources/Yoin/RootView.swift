import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @State private var dropTargeted = false

    var body: some View {
        let p = Palette(scheme: state.scheme)
        ZStack {
            // Page + soft blobs so the glass reads.
            p.page.ignoresSafeArea()
            Circle().fill(p.blob1).frame(width: 520, height: 520).blur(radius: 90)
                .offset(x: -120, y: -320).ignoresSafeArea()
            Circle().fill(p.blob2).frame(width: 460, height: 460).blur(radius: 90)
                .offset(x: 360, y: 340).ignoresSafeArea()

            VStack(spacing: Space.s5) {
                MainPanel()
                // Hidden while the full-window Now Playing screen is up — it replaces the bar.
                if !player.expanded { PlayerBar() }
            }
            .padding(Space.s5)
            .sheet(isPresented: $state.showWhatsNew) {
                WhatsNewView { state.showWhatsNew = false }
                    .environment(\.palette, p)
            }

            // Drag & drop hint
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(p.text.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(p.text.opacity(0.04))
                    .overlay(
                        Text("Drop music or a folder to import")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.text)
                    )
                    .padding(Space.s4)
                    .allowsHitTesting(false)
            }

            // Up Next queue panel (slides in over the collection).
            if state.queueOpen {
                QueueView()
                    .environment(\.palette, p)
                    .zIndex(150)
            }

            // Full-window Now Playing screen.
            if player.expanded {
                NowPlayingView()
                    .environment(\.palette, p)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }

            // Transient error/status banner.
            if let notice = state.notice {
                VStack {
                    Text(notice)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text)
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(p.text.opacity(0.12)))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                        .padding(.top, Space.s5)
                        .onTapGesture { withAnimation { state.notice = nil } }
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(300)
            }

            // Custom right-click menus render above everything.
            ContextMenuLayer().zIndex(200)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.notice)
        .environment(\.palette, p)
        .tint(p.text)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            state.handleDrop(providers)
        }
        .sheet(isPresented: $state.showLogin) {
            BandcampLoginSheet()
                .environment(\.palette, p)
        }
    }
}
