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
    /// When set, this row is a parent: hovering it opens a flyout with these children,
    /// and its own `action` is ignored.
    var submenu: [AppMenuItem]? = nil

    static func divider() -> AppMenuItem {
        AppMenuItem(title: "—divider—", systemImage: "", action: {})
    }
    var isDivider: Bool { title == "—divider—" }
}

/// Width of the menu host (the window), so a flyout can flip to the left near the right edge.
private struct MenuHostWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var menuHostWidth: CGFloat {
        get { self[MenuHostWidthKey.self] }
        set { self[MenuHostWidthKey.self] = newValue }
    }
}

/// Builds an "Add to playlist…" row whose flyout lists "New playlist…" + every playlist.
@MainActor
func addToPlaylistMenuItem(state: AppState,
                           add: @escaping (UUID) -> Void,
                           createNew: @escaping () -> Void) -> AppMenuItem {
    var sub: [AppMenuItem] = [AppMenuItem(title: "New playlist…", systemImage: "plus") { createNew() }]
    // Smart playlists rebuild themselves — you can't hand-add to them.
    let editable = state.playlists.filter { !$0.isSmart }
    if !editable.isEmpty {
        sub.append(.divider())
        for pl in editable {
            sub.append(AppMenuItem(title: pl.name, systemImage: "music.note.list") { add(pl.id) })
        }
    }
    var item = AppMenuItem(title: "Add to playlist…", systemImage: "music.note.list") {}
    item.submenu = sub
    return item
}

/// The currently open menu: its anchor point (SwiftUI global coords) and its rows.
struct AppMenuState: Identifiable {
    let id = UUID()
    var location: CGPoint
    var items: [AppMenuItem]
    /// True only if there's a real (non-divider) row — a menu of only dividers must never
    /// render its full-screen scrim, or it would silently swallow every click.
    var hasActionableItems: Bool { items.contains { !$0.isDivider } }
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
        items.append(AppMenuItem(title: "Start radio", systemImage: "dot.radiowaves.left.and.right") { state.startRadio(album: album, on: player) })
        items.append(addToPlaylistMenuItem(state: state,
                                            add: { state.addAlbum(album, toPlaylist: $0) },
                                            createNew: { state.createPlaylistAndAdd(album) }))
    }
    items.append(AppMenuItem(title: album.isFavourite ? "Remove favourite" : "Add to favourites",
                             systemImage: album.isFavourite ? "heart.slash" : "heart") { state.toggleFavourite(album.id) })
    if album.canDownload {
        items.append(AppMenuItem(title: "Download in FLAC", systemImage: "arrow.down") { state.download(album) })
    }
    if album.canResetToOriginal {
        items.append(AppMenuItem(title: "Reset to original", systemImage: "arrow.uturn.backward") { state.resetToOriginal(albumID: album.id) })
    }
    if album.source == .local && (album.hasLocalFiles || album.url != nil) {
        items.append(AppMenuItem(title: "Re-scan artwork", systemImage: "photo") { state.rescanArtwork([album.id]) })
    }
    // Add to a connected iPod (only for albums with local audio to copy).
    if let ipod = state.connectedIPod, album.hasLocalFiles || album.url != nil {
        items.append(AppMenuItem(title: "Add to iPod", systemImage: "arrow.down.to.line") {
            state.addToIPod([album.id], device: ipod)
        })
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

/// Right-click actions for a single (usually now-playing) track — used by the player bar
/// and the full Now Playing screen.
@MainActor
func nowPlayingTrackMenuItems(for track: Track, state: AppState, player: PlayerEngine) -> [AppMenuItem] {
    let liked = state.isLiked(track)
    var items: [AppMenuItem] = [
        AppMenuItem(title: liked ? "Unfavourite song" : "Favourite song",
                    systemImage: liked ? "heart.slash" : "heart") { state.toggleLikedSong(track) },
        addToPlaylistMenuItem(state: state,
                              add: { state.addTrack(track, toPlaylist: $0) },
                              createNew: { state.createPlaylistAndAdd(track: track) })
    ]
    let album = track.albumID.flatMap { id in state.albums.first { $0.id == id } }
    if let album {
        items.append(AppMenuItem(title: "Start radio", systemImage: "dot.radiowaves.left.and.right") {
            state.startRadio(album: album, track: track, on: player)
        })
        items.append(AppMenuItem(title: album.isFavourite ? "Remove favourite" : "Add to favourites",
                                 systemImage: album.isFavourite ? "heart.slash" : "heart") { state.toggleFavourite(album.id) })
        items.append(.divider())
        items.append(AppMenuItem(title: "Go to album", systemImage: "square.stack") {
            if player.expanded { withAnimation(.easeInOut(duration: 0.2)) { player.expanded = false } }
            if state.queueOpen { withAnimation(.easeInOut(duration: 0.2)) { state.queueOpen = false } }
            withAnimation(.easeInOut(duration: 0.2)) { state.openedAlbumID = album.id }
        })
    } else if let np = state.nowPlayingAlbum, np.source == .bandcamp,
              state.libraryAlbum(forBandcampURL: np.bandcampItemURL) == nil,
              let s = np.bandcampItemURL, let url = URL(string: s) {
        // A track you don't own (a friend's / wishlist item) → link straight to buy it.
        items.append(.divider())
        items.append(AppMenuItem(title: "Buy on Bandcamp", systemImage: "bag") {
            NSWorkspace.shared.open(url)
        })
    }
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
    items.append(AppMenuItem(title: "Find credits for \(ids.count)", systemImage: "person.2") {
        state.enrichSelection(ids)
    })
    // Re-read embedded cover art — useful for imports that came in without a cover.
    if members.contains(where: { $0.source == .local && ($0.hasLocalFiles || $0.url != nil) }) {
        items.append(AppMenuItem(title: "Re-scan artwork", systemImage: "photo") {
            state.rescanArtwork(ids)
        })
    }
    // Add to a connected iPod — any selected albums that have local audio to copy.
    if let ipod = state.connectedIPod {
        let addable = members.filter { $0.hasLocalFiles || $0.url != nil }.map(\.id)
        if !addable.isEmpty {
            items.append(AppMenuItem(title: "Add \(addable.count) to iPod", systemImage: "arrow.down.to.line") {
                state.addToIPod(Set(addable), device: ipod)
            })
        }
    }
    items.append(.divider())
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
            if let menu = state.activeMenu, menu.hasActionableItems {
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
                        .environment(\.menuHostWidth, geo.size.width)
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
        // Safety net: never let a menu (and its input-blocking scrim) stay stuck open. Long
        // enough (45s) that it won't interrupt someone browsing a submenu — it only rescues a
        // genuinely stuck menu; tap-away, Escape, and losing focus are the normal closers.
        .task(id: state.activeMenu?.id) {
            guard state.activeMenu != nil else { return }
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if !Task.isCancelled { state.dismissMenu() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            state.dismissMenu()
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
                } else if let sub = item.submenu {
                    SubmenuRow(item: item, submenu: sub, fire: fire)
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

/// A parent row that reveals a flyout of child items on hover (e.g. "Add to playlist…").
private struct SubmenuRow: View {
    let item: AppMenuItem
    let submenu: [AppMenuItem]
    let fire: (AppMenuItem) -> Void
    @Environment(\.palette) private var p
    @Environment(\.menuHostWidth) private var hostWidth
    @State private var rowHover = false
    @State private var flyoutHover = false
    @State private var open = false
    @State private var rowFrame: CGRect = .zero
    @State private var closeTask: Task<Void, Never>?

    /// Flip the flyout to the left when it would overrun the window's right edge.
    private var flipLeft: Bool {
        hostWidth > 0 && rowFrame.maxX + 240 > hostWidth - 12
    }

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: item.systemImage).font(.system(size: 13)).frame(width: 18)
            Text(item.title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: Space.s4)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(p.muted2)
        }
        .foregroundStyle(p.text)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(p.glassFill).opacity(rowHover || open ? 1 : 0))
        .contentShape(Rectangle())
        .modifier(LinkCursor())
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { rowFrame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in rowFrame = f }
            }
        )
        .onHover { h in rowHover = h; schedule() }
        .overlay(alignment: flipLeft ? .topTrailing : .topLeading) {
            if open {
                MenuFlyout(items: submenu, fire: fire) { flyoutHover = $0; schedule() }
                    .fixedSize()
                    .offset(x: flipLeft ? -(rowFrame.width + 6) : (rowFrame.width + 6), y: -6)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: flipLeft ? .topTrailing : .topLeading)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: open)
        .zIndex(open ? 1 : 0)
    }

    /// Open while either the row or the flyout is hovered; close shortly after both leave,
    /// so the pointer can travel across the gap into the flyout.
    private func schedule() {
        closeTask?.cancel()
        if rowHover || flyoutHover {
            open = true
        } else {
            closeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !Task.isCancelled { open = false }
            }
        }
    }
}

/// The floating child list shown beside a `SubmenuRow`.
private struct MenuFlyout: View {
    let items: [AppMenuItem]
    let fire: (AppMenuItem) -> Void
    let onHover: (Bool) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                if item.isDivider {
                    Divider().overlay(p.edgeSoft).padding(.vertical, 4)
                } else {
                    MenuRow(item: item) { fire(item) }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.page))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
        .onHover { onHover($0) }
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
