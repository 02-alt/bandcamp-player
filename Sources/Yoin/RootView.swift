import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var ipod: IPodWatcher
    @AppStorage("ambientTheming") private var ambientTheming = true
    @State private var dropTargeted = false

    var body: some View {
        let p = Palette(scheme: state.scheme)
        // Cover-derived glow, when enabled and something is playing.
        let ambient = ambientTheming ? state.ambient : nil
        // Bespoke per-album skin (e.g. "Forever Alone" → animated black ocean).
        let special = ambientTheming && AlbumTheme.hasBackground(state.nowPlayingAlbum)
        ZStack {
            if special {
                AlbumTheme.background(for: state.nowPlayingAlbum, colors: state.ambientPalette).ignoresSafeArea()
            } else {
                // Page + soft blobs so the glass reads. The blobs pick up the now-playing
                // cover's colour when ambient theming is on, else stay monochrome.
                p.page.ignoresSafeArea()
                // A full-bleed wash so the tint reads even where the glass panel covers the blobs.
                if let ambient {
                    ambient.opacity(0.16).blendMode(.plusLighter).ignoresSafeArea()
                }
                Circle().fill(ambient?.opacity(0.55) ?? p.blob1).frame(width: 640, height: 640).blur(radius: 110)
                    .offset(x: -200, y: -360).ignoresSafeArea()
                Circle().fill(ambient?.opacity(0.40) ?? p.blob2).frame(width: 560, height: 560).blur(radius: 110)
                    .offset(x: 420, y: 380).ignoresSafeArea()
            }

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
            // Mirror the connected iPod for context menus. `onChange(initial:)` runs after the
            // view is instantiated — mutating state here (unlike in onReceive, which replays during
            // graph instantiation and aborts) is safe.
            .onChange(of: ipod.device, initial: true) { _, dev in state.connectedIPod = dev }

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

            // Friends drawer (slides in from the right like Up Next).
            if state.friendsOpen {
                FriendsView()
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

            // Fullscreen art mode — sits above Now Playing.
            if player.artMode {
                ArtModeView()
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(250)
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

            // Monthly listening receipt (full-window reveal).
            if let month = state.receiptMonth {
                ReceiptView(month: month)
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(280)
            }

            // ⌘K command palette.
            if state.paletteOpen {
                CommandPalette()
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(275)
            }

            // Custom right-click menus render above everything.
            ContextMenuLayer().zIndex(200)

            // First-launch loading screen while the collection is still being fetched.
            if state.isInitialLoading {
                LaunchLoadingView()
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(400)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state.isInitialLoading)
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
