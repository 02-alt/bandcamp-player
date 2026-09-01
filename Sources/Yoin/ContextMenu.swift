import SwiftUI
import AppKit

// MARK: - Model

/// One row in a custom right-click menu.
struct AppMenuItem: Identifiable {
    enum Role { case normal, destructive }
    let id = UUID()
    var title: String
    var systemImage: String
    var role: Role = .normal
    /// Destructive rows require a press-and-hold before firing.
    var holdToConfirm: Bool = false
    var action: () -> Void

    static func divider() -> AppMenuItem {
        AppMenuItem(title: "—divider—", systemImage: "", action: {})
    }
    var isDivider: Bool { title == "—divider—" }
}

/// The currently open menu: its anchor point (SwiftUI global coords) and its rows.
struct AppMenuState: Identifiable {
    let id = UUID()
    var location: CGPoint
    var items: [AppMenuItem]
}

// MARK: - Shared album menu

/// The standard right-click actions for an album, used everywhere covers appear.
@MainActor
func albumMenuItems(for album: Album, state: AppState, player: PlayerEngine) -> [AppMenuItem] {
    // Right-clicking one of several selected albums acts on the whole selection.
    let sel = state.selection
    if state.selecting, sel.count > 1, sel.contains(album.id) {
        return selectionMenuItems(sel, state: state)
    }

    var items: [AppMenuItem] = []
    if album.isPlayable {
        items.append(AppMenuItem(title: "Play", systemImage: "play.fill") { state.play(album, on: player) })
        items.append(AppMenuItem(title: "Play next", systemImage: "text.insert") { state.playNextAlbum(album, on: player) })
        items.append(AppMenuItem(title: "Add to queue", systemImage: "text.append") { state.addAlbumToQueue(album, on: player) })
        items.append(AppMenuItem(title: "Add to playlist…", systemImage: "music.note.list") { state.showAddToPlaylistMenu(for: album) })
    }
    items.append(AppMenuItem(title: album.isFavourite ? "Remove favourite" : "Add to favourites",
                             systemImage: album.isFavourite ? "heart.slash" : "heart") { state.toggleFavourite(album.id) })
    if album.canDownload {
        items.append(AppMenuItem(title: "Download in FLAC", systemImage: "arrow.down") { state.download(album) })
    }
    if album.canResetToOriginal {
        items.append(AppMenuItem(title: "Reset to original", systemImage: "arrow.uturn.backward") { state.resetToOriginal(albumID: album.id) })
    }
    items.append(.divider())
    items.append(AppMenuItem(title: "Select", systemImage: "checkmark.circle") {
        state.screen = .grid
        state.enterSelection(true); state.selection.insert(album.id)
    })
    items.append(AppMenuItem(title: "Delete", systemImage: "trash", role: .destructive, holdToConfirm: true) {
        state.deleteAlbums([album.id])
    })
    return items
}

/// Actions when several albums are selected at once.
@MainActor
private func selectionMenuItems(_ ids: Set<UUID>, state: AppState) -> [AppMenuItem] {
    var items: [AppMenuItem] = []
    let members = state.albums.filter { ids.contains($0.id) }
    // Offer "combine" only when every pick is a plain single-file import.
    if members.count >= 2 && members.allSatisfy({ $0.isSingleLocalFile }) {
        items.append(AppMenuItem(title: "Combine into one album", systemImage: "square.stack") {
            state.combineIntoAlbum(ids)
        })
        items.append(.divider())
    }
    items.append(AppMenuItem(title: "Delete \(ids.count)", systemImage: "trash", role: .destructive, holdToConfirm: true) {
        state.deleteAlbums(ids); state.enterSelection(false)
    })
    return items
}

// MARK: - Right-click capture

/// A transparent overlay that reports right-clicks (in SwiftUI global coordinates)
/// while letting every other event fall through to the views behind it.
private struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (CGPoint) -> Void
    /// The view's frame in SwiftUI global space, so we can convert local → global.
    var globalFrame: CGRect

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onRightClick = onRightClick
        v.globalFrame = { globalFrame }
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.onRightClick = onRightClick
        v.globalFrame = { globalFrame }
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?
        var globalFrame: (() -> CGRect)?

        // Only claim right mouse events; pass everything else through to the button behind.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let type = NSApp.currentEvent?.type, type == .rightMouseDown || type == .rightMouseUp {
                return super.hitTest(point)
            }
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)          // bottom-left origin
            let flipped = CGPoint(x: local.x, y: bounds.height - local.y)   // → top-left origin
            let frame = globalFrame?() ?? .zero
            onRightClick?(CGPoint(x: frame.minX + flipped.x, y: frame.minY + flipped.y))
        }
    }
}

// MARK: - Attach a menu to any view

extension View {
    /// Right-click this view to open a custom, app-styled menu. Empty items → no menu.
    func appContextMenu(_ items: @escaping () -> [AppMenuItem]) -> some View {
        modifier(AppContextMenu(items: items))
    }
}

private struct AppContextMenu: ViewModifier {
    let items: () -> [AppMenuItem]
    @EnvironmentObject private var state: AppState
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in frame = f }
                }
            )
            .overlay(
                RightClickCatcher(onRightClick: { point in
                    state.showMenu(items(), at: point)
                }, globalFrame: frame)
            )
    }
}

// MARK: - The rendered menu (lives once, in RootView)

struct ContextMenuLayer: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let menu = state.activeMenu {
                let g = geo.frame(in: .global)
                let cursor = CGPoint(x: menu.location.x - g.minX, y: menu.location.y - g.minY)
                // Flip/clamp so the card always stays fully on screen.
                let x = min(max(8, cursor.x), max(8, geo.size.width - size.width - 8))
                let y = min(max(8, cursor.y), max(8, geo.size.height - size.height - 8))

                ZStack(alignment: .topLeading) {
                    // Click-away scrim (also catches the mouse so the app doesn't react underneath).
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.dismissMenu() }

                    MenuCard(items: menu.items)
                        .fixedSize()
                        .background(
                            GeometryReader { g2 in
                                Color.clear
                                    .onAppear { size = g2.size }
                                    .onChange(of: g2.size) { _, s in size = s }
                            }
                        )
                        .offset(x: x, y: y)
                        .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
                }
                .ignoresSafeArea()
                .background(
                    // Escape closes the menu.
                    Button("") { state.dismissMenu() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .hidden()
                )
            }
        }
    }
}

/// The floating rounded card — matches the app's glass/colours.
private struct MenuCard: View {
    let items: [AppMenuItem]
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                if item.isDivider {
                    Divider().overlay(p.edgeSoft).padding(.vertical, 4)
                } else if item.role == .destructive && item.holdToConfirm {
                    HoldToConfirmRow(item: item) { fire(item) }
                } else {
                    MenuRow(item: item) { fire(item) }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 200, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.page))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
    }

    private func fire(_ item: AppMenuItem) {
        state.dismissMenu()
        item.action()
    }
}

/// A normal menu row: icon + label, soft hover fill, fires on click.
private struct MenuRow: View {
    let item: AppMenuItem
    let onTap: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.s3) {
                Image(systemName: item.systemImage).font(.system(size: 13)).frame(width: 18)
                Text(item.title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: Space.s5)
            }
            .foregroundStyle(p.text)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(p.glassFill).opacity(hovering ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .onHover { hovering = $0 }
    }
}

/// Destructive row: press and hold to confirm. A red fill sweeps across; releasing early cancels.
private struct HoldToConfirmRow: View {
    let item: AppMenuItem
    let onConfirm: () -> Void
    @Environment(\.palette) private var p
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var task: Task<Void, Never>?

    private let holdDuration: Double = 0.75
    private let danger = Color.red

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: item.systemImage).font(.system(size: 13)).frame(width: 18)
            Text(holding ? "Hold to confirm…" : item.title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: Space.s5)
        }
        .foregroundStyle(danger)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(danger.opacity(0.12))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(danger.opacity(0.30))
                        .frame(width: geo.size.width * progress)
                }
            }
        )
        .contentShape(Rectangle())
        .modifier(LinkCursor())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { start() } }
                .onEnded { _ in cancel() }
        )
    }

    private func start() {
        holding = true
        withAnimation(.linear(duration: holdDuration)) { progress = 1 }
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onConfirm()
        }
    }

    private func cancel() {
        task?.cancel(); task = nil
        holding = false
        withAnimation(.easeOut(duration: 0.18)) { progress = 0 }
    }
}
