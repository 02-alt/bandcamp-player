import AppKit
import SwiftUI

/// Which floating mini-player look to use.
enum MiniPlayerStyle: String, CaseIterable, Identifiable {
    case cover, turntable
    var id: String { rawValue }
    var label: String { self == .cover ? "Cover" : "Turntable" }
}

/// Owns the floating mini-player panel (TIDAL-style). A borderless, transparent,
/// always-on-top NSPanel hosting `MiniPlayerView`, draggable anywhere on screen.
@MainActor
final class MiniPlayerController {
    static let shared = MiniPlayerController()

    private var panel: NSPanel?
    private var positioned = false
    private weak var player: PlayerEngine?
    private weak var state: AppState?
    private weak var mainWindow: NSWindow?

    private let side: CGFloat = 360

    /// Wire up the live engine/state (call once from the app's onAppear).
    func configure(player: PlayerEngine, state: AppState) {
        self.player = player
        self.state = state
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() { isOpen ? hide() : show() }

    /// Enter mini-player mode: hide the main app window and show the floating panel.
    /// Deferred to the next runloop tick so we never order a window out from inside the
    /// click event that triggered this (the button lives in the window we're hiding).
    func show() {
        guard let player, let state else { return }
        if panel == nil { build(player: player, state: state) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Show the panel first so a visible window always exists, then hide the main
            // window — otherwise "last window closed" briefly holds and the app quits.
            self.positionIfNeeded()
            self.panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let main = NSApp.windows.first(where: { !($0 is KeyablePanel) && $0.canBecomeMain && $0.isVisible }) {
                self.mainWindow = main
                main.orderOut(nil)
            }
        }
    }

    /// Leave mini-player mode: hide the panel and bring the main window back.
    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.restoreMainWindow()
        }
    }

    private func restoreMainWindow() {
        let main = mainWindow ?? NSApp.windows.first(where: { !($0 is KeyablePanel) && $0.canBecomeMain })
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Panel

    /// Rebuild the panel when the chosen style changes (keeps it open if it was).
    func restyle() {
        let wasOpen = isOpen
        let origin = panel?.frame.origin
        panel?.orderOut(nil)
        panel = nil
        guard wasOpen, let player, let state else { return }
        build(player: player, state: state)
        if let origin { panel?.setFrameOrigin(origin) }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build(player: PlayerEngine, state: AppState) {
        let expand: () -> Void = { [weak self] in self?.expand() }
        let size: CGSize
        let root: AnyView
        switch state.miniPlayerStyle {
        case .turntable:
            size = VinylMiniPlayerView.panelSize
            let resize: (CGSize) -> Void = { [weak self] s in self?.resizeMini(to: s) }
            root = AnyView(VinylMiniPlayerView(onExpand: expand, onResize: resize)
                .environmentObject(player).environmentObject(state))
        case .cover:
            size = CGSize(width: side, height: side)
            root = AnyView(MiniPlayerView(onExpand: expand).environmentObject(player).environmentObject(state))
        }

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]   // relayout when the panel resizes
        hosting.wantsLayer = true   // needed to draw in a transparent window

        let panel = KeyablePanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window shadow traces the content's alpha; for the irregular turntable shape
        // that reads as a ragged halo, so let its in-view shadows do the work instead.
        panel.hasShadow = state.miniPlayerStyle == .cover
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
    }

    /// Resize the panel (collapse to disc / expand to full), keeping the disc anchored
    /// at the right edge and vertical centre so it doesn't jump. Animated with the same
    /// duration + easing curve the SwiftUI content uses, so the two move as one.
    static let collapseDuration: Double = 0.42
    static let collapseCurve = (c0: CGPoint(x: 0.65, y: 0), c1: CGPoint(x: 0.35, y: 1))

    func resizeMini(to size: CGSize) {
        guard let panel else { return }
        let f = panel.frame
        let origin = NSPoint(x: f.maxX - size.width, y: f.midY - size.height / 2)
        let target = NSRect(origin: origin, size: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.collapseDuration
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(Self.collapseCurve.c0.x), Float(Self.collapseCurve.c0.y),
                Float(Self.collapseCurve.c1.x), Float(Self.collapseCurve.c1.y))
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
    }

    private func positionIfNeeded() {
        guard let panel, !positioned, let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 24, y: v.minY + 24))
        positioned = true
    }

    /// Expand arrow → leave mini-player mode and return to the full app window.
    private func expand() {
        hide()
    }
}

/// A borderless panel that can still become key, so the transport controls stay clickable.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
