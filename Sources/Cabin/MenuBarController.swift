import AppKit
import SwiftUI

/// Owns the menu-bar status item and the now-playing dropdown it shows.
///
/// We manage this in AppKit rather than via SwiftUI's `MenuBarExtra(.window)` because that
/// style does not reliably centre a wide (360pt) popover under its icon — it drifts to the
/// right. Here we compute the status button's screen frame and centre the panel under it
/// ourselves, keeping the clean full-bleed card look (no popover arrow / system chrome).
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var panel: KeyableDropdownPanel?
    private weak var player: PlayerEngine?
    private weak var state: AppState?
    /// When the dropdown last closed — lets a click on the status button (which first resigns
    /// the panel's key state, closing it) read as "toggle off" instead of immediately reopening.
    private var closedAt = Date.distantPast

    private let side: CGFloat = 360
    /// Gap between the menu bar and the top of the card.
    private let gap: CGFloat = 6

    /// Wire up the live engine/state (call once from the app's onAppear).
    func configure(player: PlayerEngine, state: AppState) {
        self.player = player
        self.state = state
    }

    /// Add or remove the status item to match the Settings toggle.
    func setInstalled(_ installed: Bool) {
        installed ? install() : remove()
    }

    // MARK: - Status item

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Cabin")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        statusItem = item
    }

    private func remove() {
        closePanel()
        panel = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    // MARK: - Dropdown panel

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if let panel, panel.isVisible {
            closePanel()
            return
        }
        // If the panel just closed (because clicking the button resigned its key state),
        // treat this click as the "off" half of a toggle and don't reopen.
        if Date().timeIntervalSince(closedAt) < 0.25 { return }
        showPanel(from: sender)
    }

    private func showPanel(from button: NSStatusBarButton) {
        guard let player, let state, let buttonWindow = button.window else { return }

        // Rebuild the content each time so the palette / now-playing snapshot is current.
        let content = MiniPlayerView(onExpand: { [weak self] in
            self?.closePanel()
            Self.openMainWindow()
        })
        .fixedSize()
        .environmentObject(state)
        .environmentObject(player)
        .environmentObject(player.clock)
        .environment(\.palette, Palette(scheme: state.scheme))

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: side, height: side)

        let panel = KeyableDropdownPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel

        // Centre the card horizontally under the status button, clamped to the screen.
        let buttonRect = button.convert(button.bounds, to: nil)
        let onScreen = buttonWindow.convertToScreen(buttonRect)
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = onScreen.midX - side / 2
        if let vf = screen?.visibleFrame {
            x = min(max(x, vf.minX + 8), vf.maxX - side - 8)
        }
        let y = onScreen.minY - gap - side
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        closedAt = Date()
    }

    /// Close when the user clicks outside the dropdown (it resigns key), mirroring a popover.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        closePanel()
    }

    /// Bring the main window back to the front (it may be hidden while the mini player is up).
    static func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// A borderless panel that can still become key, so its transport controls stay clickable
/// and clicking away resigns key (which we use to auto-close the dropdown).
private final class KeyableDropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
