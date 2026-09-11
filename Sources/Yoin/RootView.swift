import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Publishes the real NSWindow width (points) and lowers the window's minimum size so it can shrink
/// into the narrow "solo" layout. A SwiftUI GeometryReader can't do this: wide content overflows and
/// clips inside a smaller window, so it reports the content's intrinsic width, not the window's.
private struct WindowAccessor: NSViewRepresentable {
    let onSize: (CGSize) -> Void
    let onScreen: (CGFloat) -> Void

    final class Coordinator { var observed = false; var tokens: [NSObjectProtocol] = [] }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { attach(v, context.coordinator) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { attach(v, context.coordinator) }
    }

    private func attach(_ v: NSView, _ coord: Coordinator) {
        guard let w = v.window else { return }
        // Let the window shrink far past the content's natural minimum; the narrow layouts fit.
        w.minSize = NSSize(width: 300, height: 220)
        onSize(w.frame.size)
        reportScreen(w)
        guard !coord.observed else { return }
        coord.observed = true
        coord.tokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: w, queue: .main
        ) { _ in onSize(w.frame.size) })
        // The display can change when the window is dragged to another monitor — re-read then.
        coord.tokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: w, queue: .main
        ) { _ in reportScreen(w) })
    }

    private func reportScreen(_ w: NSWindow) {
        // visibleFrame excludes the menu bar / Dock — the height the window can actually use.
        if let h = (w.screen ?? NSScreen.main)?.visibleFrame.height { onScreen(h) }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var ipod: IPodWatcher
    @AppStorage("ambientTheming") private var ambientTheming = true
    @State private var dropTargeted = false

    /// Global UI zoom. The interface's absolute point sizes are tuned for a big display; on a
    /// laptop screen that reads as oversized, so we lay the whole thing out on a slightly larger
    /// logical canvas and scale it down to fit — crisp on Retina, and more content fits. Keyed to
    /// the display's usable height so external monitors stay at 1.0 and only laptops shrink.
    private var uiScale: CGFloat {
        switch state.screenHeight {
        case ..<900:  return 0.85   // 13" laptops
        case ..<1000: return 0.90   // 14"/small 4K
        case ..<1120: return 0.95   // 15"/16"
        default:      return 1.0    // desktop displays — unchanged
        }
    }

    var body: some View {
        let p = Palette(scheme: state.scheme)
        // The recap is its own full-screen moment — suppress the cover-derived tint so it can't
        // bleed through the uncovered titlebar strip behind the traffic lights.
        let onRecap = state.screen == .recap
        // Cover-derived glow, when enabled and something is playing.
        let ambient = (ambientTheming && !onRecap) ? state.ambient : nil
        // Bespoke per-album skin (e.g. "Forever Alone" → animated black ocean).
        let special = ambientTheming && !onRecap && AlbumTheme.hasBackground(state.nowPlayingAlbum)
        // Tiniest window: a very short Crate → show only the cover, no player bar. (The player bar
        // reduces to a single row first — see PlayerBar — then disappears here.)
        let tinyWindow = state.screen == .crate && state.windowHeight < 380
        ZStack {
            if special {
                AlbumTheme.background(for: state.nowPlayingAlbum, colors: state.ambientPalette).ignoresSafeArea()
            } else {
                // Page + soft blobs so the glass reads. The blobs pick up the now-playing
                // cover's colour when ambient theming is on, else stay monochrome.
                p.page.ignoresSafeArea()
                // A full-bleed wash so the tint reads. Kept low (0.08) because content now sits
                // directly on this ambient (the glass panels are gone): a heavier wash lifts the
                // background luminance and pulls muted text under the WCAG AA contrast floor,
                // especially for bright covers (measured: a teal cover ran the right edge to ~0.08
                // luminance, dropping muted2 to ~2.8:1 — well under 4.5:1).
                if let ambient {
                    ambient.opacity(0.08).blendMode(.plusLighter).ignoresSafeArea()
                }
                // The blobs are drawn as overlays on a flexible Color.clear so their fixed 640/560
                // sizes don't force the root ZStack's minimum height (which would center-clip the
                // header + player bar once the window is shorter than the blob — see the low height
                // floor in YoinApp). Color.clear takes the proposed size; overlays don't drive it.
                // Skipped on the recap so the background is one flat, continuous surface right up
                // to the top edge — no shade seam where the titlebar strip meets the recap page.
                if !onRecap {
                    Color.clear
                        .overlay {
                            Circle().fill(ambient?.opacity(0.38) ?? p.blob1).frame(width: 640, height: 640)
                                .blur(radius: 110).offset(x: -200, y: -360)
                        }
                        .overlay {
                            Circle().fill(ambient?.opacity(0.18) ?? p.blob2).frame(width: 560, height: 560)
                                .blur(radius: 110).offset(x: 420, y: 380)
                        }
                        .ignoresSafeArea()
                }
            }

            ZStack {
                MainPanel()
                // Full-page collection map — covers the content area but keeps the player bar.
                if state.mapOpen {
                    CollectionMapView()
                        .environment(\.palette, p)
                        .transition(.opacity)
                }
            }
            // Docked translucent player bar as a bottom safe-area inset (not a VStack sibling), so
            // the content fills the window and can scroll *behind* it — screens that opt in (the
            // album tracklist) show through the material instead of stopping at its top edge.
            // The covers + player bar are the two non-negotiable elements; the inset keeps the bar
            // pinned to the bottom edge no matter how short the window gets.
            // Hidden while the full-window Now Playing screen is up.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // At the very smallest size (narrow Crate + short) drop the player bar too — just the
                // cover. Covers are tap-to-play and the transport keys/media keys still work.
                if !player.expanded && !tinyWindow { PlayerBar() }
            }
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

            // Quick "New playlist…" prompt from a right-click menu.
            if let draft = state.playlistDraft {
                QuickPlaylistCreator(draft: draft)
                    .environment(\.palette, p)
                    .transition(.opacity)
                    .zIndex(276)
            }

            // Custom right-click menus render above everything.
            ContextMenuLayer().zIndex(200)

            // First-launch loading screen while the collection is still being fetched.
            if state.isInitialLoading {
                LaunchLoadingView()
                    .environment(\.palette, p)
                    .environmentObject(state.syncProgress)
                    .transition(.opacity)
                    .zIndex(400)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state.isInitialLoading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.notice)
        .environment(\.palette, p)
        .tint(p.text)
        .background(WindowAccessor(onSize: { size in
            if abs(state.windowWidth - size.width) > 0.5 { state.windowWidth = size.width }
            if abs(state.windowHeight - size.height) > 0.5 { state.windowHeight = size.height }
        }, onScreen: { h in
            if abs(state.screenHeight - h) > 0.5 { state.screenHeight = h }
        }))
        .uiZoom(scale: uiScale, size: CGSize(width: state.windowWidth, height: state.windowHeight))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            state.handleDrop(providers)
        }
        .sheet(isPresented: $state.showLogin) {
            BandcampLoginSheet()
                .environment(\.palette, p)
        }
    }
}

private extension View {
    /// Lay this view out on a `1/scale` larger canvas, then scale it down to `size` — a non-blurry
    /// "zoom out" that makes the whole UI read smaller while still filling the window. A no-op at
    /// scale 1 (desktop displays) or before the real window size is known.
    @ViewBuilder func uiZoom(scale: CGFloat, size: CGSize) -> some View {
        if scale >= 0.999 || size.width < 1 || size.height < 1 {
            self
        } else {
            frame(width: size.width / scale, height: size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                // `size` is the full window frame (titlebar included). Without this, the zoom
                // container is inset below the hidden titlebar's top safe area while still sized to
                // the full height — leaving the titlebar region uncovered (a grey bar) and pushing
                // the bottom off-screen, where `.clipped()` cuts the player bar. Fill edge-to-edge.
                .ignoresSafeArea()
        }
    }
}
