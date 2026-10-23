import SwiftUI
import AppKit
import CabinCore

// MARK: - Model

/// One row in a custom right-click menu.
struct AppMenuItem: Identifiable {
    enum Role { case normal, destructive }
    let id = UUID()
    var title: String
    var systemImage: String
    var role: Role = .normal
    /// Destructive rows ask for confirmation (a native alert) before firing.
    var holdToConfirm: Bool = false
    /// The confirmation alert's title and detail; default to "<title>?" / "This can't be undone."
    var confirmMessage: String? = nil
    var confirmDetail: String? = nil
    var action: () -> Void
    /// When set, this row is a parent: it opens a submenu with these children, and its own
    /// `action` is ignored.
    var submenu: [AppMenuItem]? = nil
    /// Optional live-preview hook: called with `true` when the pointer enters the row and `false`
    /// when it leaves — used to audition an effect on hover before committing it with a click.
    var onHover: ((Bool) -> Void)? = nil
    /// Marks a row as the currently-active choice (e.g. the selected FX preset) so VoiceOver
    /// announces it — the checkmark icon alone isn't exposed to assistive tech.
    var selected: Bool = false

    static func divider() -> AppMenuItem {
        AppMenuItem(title: "—divider—", systemImage: "", action: {})
    }
    var isDivider: Bool { title == "—divider—" }
}

extension Notification.Name {
    /// Opens the Slowed + Reverb sliders sheet (right-click ▸ Slowed + Reverb ▸ Customise…).
    static let openSlowedReverbFX = Notification.Name("cabin.openSlowedReverbFX")
}

/// Builds an "Add to playlist…" row whose flyout lists "New playlist…" + every playlist.
@MainActor
func addToPlaylistMenuItem(state: AppState,
                           add: @escaping (UUID) -> Void,
                           createNew: @escaping () -> Void) -> AppMenuItem {
    var sub: [AppMenuItem] = [AppMenuItem(title: "New Playlist…", systemImage: "plus") { createNew() }]
    // Smart playlists rebuild themselves — you can't hand-add to them. Sets take whole albums.
    let editable = state.playlists.filter { !$0.isSmart && $0.kind == .playlist }
    if !editable.isEmpty {
        sub.append(.divider())
        for pl in editable {
            sub.append(AppMenuItem(title: pl.name, systemImage: "music.note.list") { add(pl.id) })
        }
    }
    var item = AppMenuItem(title: "Add to Playlist…", systemImage: "music.note.list") {}
    item.submenu = sub
    return item
}

/// Builds an "Add to set…" row whose flyout lists "New set…" + every set.
@MainActor
func addToSetMenuItem(state: AppState, album: Album) -> AppMenuItem {
    var sub: [AppMenuItem] = [AppMenuItem(title: "New Set…", systemImage: "plus") { state.createSetAndAdd(album) }]
    let sets = state.playlists.filter { $0.kind == .set }
    if !sets.isEmpty {
        sub.append(.divider())
        for s in sets {
            sub.append(AppMenuItem(title: s.name, systemImage: "square.stack.3d.up") { state.addAlbum(album, toSet: s.id) })
        }
    }
    var item = AppMenuItem(title: "Add to Set…", systemImage: "square.stack.3d.up") {}
    item.submenu = sub
    return item
}

// MARK: - Shared album menu

/// The standard right-click actions for an album, used everywhere covers appear.
@MainActor
/// The album right-click menu, grouped by intent so it stays scannable: playback, then
/// queue/playlist, then library, then a "Manage" flyout that hides the rare maintenance
/// actions, and finally Select + an isolated destructive Delete.
/// - `sourceActions`: visible source rows (e.g. "Open on Bandcamp"), shown in the library group.
/// - `manageExtras`: rows to prepend into the "Manage" flyout (e.g. "Re-download", "Refresh").
/// - `trailingActions`: rows placed just before Select (e.g. "Share album…").
func albumMenuItems(for album: Album, state: AppState, player: PlayerEngine,
                    sourceActions: [AppMenuItem] = [],
                    manageExtras: [AppMenuItem] = [],
                    trailingActions: [AppMenuItem] = []) -> [AppMenuItem] {
    // Right-clicking one of several selected albums acts on the whole selection.
    let sel = state.selection
    if state.selecting, sel.count > 1, sel.contains(album.id) {
        return selectionMenuItems(sel, state: state)
    }

    var items: [AppMenuItem] = []

    // Playback.
    if album.isPlayable {
        items.append(AppMenuItem(title: "Play", systemImage: "play.fill") { state.play(album, on: player) })
        if state.playCount(for: album) <= 1 {   // the ceremony is for a record you haven't really heard yet; hide it once it's been played more than once
            items.append(AppMenuItem(title: "First Listen", systemImage: "record.circle") { state.firstListenAlbum = album })
        }
        items.append(.divider())
        items.append(AppMenuItem(title: "Play Next", systemImage: "text.insert") { state.playNextAlbum(album, on: player) })
        items.append(AppMenuItem(title: "Add to Queue", systemImage: "text.append") { state.addAlbumToQueue(album, on: player) })
        items.append(addToPlaylistMenuItem(state: state,
                                            add: { state.addAlbum(album, toPlaylist: $0) },
                                            createNew: { state.beginPlaylistDraft(album: album) }))
        items.append(addToSetMenuItem(state: state, album: album))
        items.append(.divider())
    }

    // Library.
    items.append(AppMenuItem(title: album.isFavourite ? "Remove Favourite" : "Add to Favourites",
                             systemImage: album.isFavourite ? "heart.slash" : "heart") { state.toggleFavourite(album.id) })
    if album.isPlayable {
        items.append(AppMenuItem(title: "Start Radio", systemImage: "dot.radiowaves.left.and.right") { state.startRadio(album: album, on: player) })
    }
    items.append(contentsOf: sourceActions)
    if album.canDownload {   // a real first download stays visible; re-download lives in Manage
        items.append(AppMenuItem(title: "Download in FLAC", systemImage: "arrow.down") { state.download(album) })
    }

    // Manage — the rarely-used maintenance actions, tucked into a flyout to keep the menu short.
    var manage = manageExtras
    if album.canResetToOriginal {
        manage.append(AppMenuItem(title: "Reset to Original", systemImage: "arrow.uturn.backward") { state.resetToOriginal(albumID: album.id) })
    }
    if album.source == .local && (album.hasLocalFiles || album.url != nil) {
        manage.append(AppMenuItem(title: "Re-scan Artwork", systemImage: "photo") { state.rescanArtwork([album.id]) })
    }
    if let ipod = state.connectedIPod, album.hasLocalFiles || album.url != nil {
        manage.append(AppMenuItem(title: "Add to iPod", systemImage: "arrow.down.to.line") {
            state.addToIPod([album.id], device: ipod)
        })
    }
    if !manage.isEmpty {
        var manageItem = AppMenuItem(title: "Manage", systemImage: "slider.horizontal.3") {}
        manageItem.submenu = manage
        items.append(manageItem)
    }

    // Album-level extras (e.g. Share) + Select, then Delete on its own.
    items.append(.divider())
    items.append(contentsOf: trailingActions)
    items.append(AppMenuItem(title: "Select", systemImage: "checkmark.circle") {
        state.screen = .grid
        state.enterSelection(true); state.selection.insert(album.id)
    })
    items.append(.divider())
    items.append(AppMenuItem(title: "Delete", systemImage: "trash", role: .destructive, holdToConfirm: true,
                             confirmMessage: "Delete “\(album.title)”?",
                             confirmDetail: "It’s removed from Cabin. Your files and your Bandcamp purchase aren’t touched.") {
        state.deleteAlbums([album.id])
    })
    return items
}

/// Backs the hover-to-audition behaviour of the Room & vinyl menu: it snapshots the room state
/// when the menu opens, applies a preset live on hover, and — if the pointer leaves every preset
/// row without a click committing one — restores the snapshot. A hover counter makes travelling
/// between rows safe: it only reverts once nothing in the flyout is hovered.
@MainActor final class RoomPreview {
    private let player: PlayerEngine
    private let baseEnabled: Bool
    private let basePreset: String
    private var committed = false
    private var hovers = 0

    init(_ p: PlayerEngine) { player = p; baseEnabled = p.roomEnabled; basePreset = p.roomPresetName }

    func hover(_ entering: Bool, apply: @escaping () -> Void) {
        if entering { hovers += 1; apply() }
        else {
            hovers = max(0, hovers - 1)
            // Defer so moving between two rows (leave A, enter B) never dips to a revert.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.committed, self.hovers == 0 else { return }
                self.player.roomEnabled = self.baseEnabled
                self.player.roomPresetName = self.basePreset
            }
        }
    }

    func commit(_ apply: () -> Void) { committed = true; apply() }
}

/// The Room/vinyl + crackle FX rows, shared by every Now Playing surface (the screen right-click,
/// the ••• button, the player bar) so the effects are reachable from any of them. Reads/writes the
/// same `PlayerEngine` room state and the `vinylCrackle` preference the FX card uses.
@MainActor
func effectsMenuItems(player: PlayerEngine) -> [AppMenuItem] {
    let roomOn = player.roomEnabled && player.roomPresetName != Room.off.name

    // Live auditioning: hovering a preset applies it so the change is heard immediately; a click
    // commits it, and leaving the flyout without clicking restores whatever was set on open.
    let preview = RoomPreview(player)
    func previewRow(title: String, icon: String, selected: Bool, apply: @escaping () -> Void) -> AppMenuItem {
        var item = AppMenuItem(title: title, systemImage: icon) { preview.commit(apply) }
        item.onHover = { entering in preview.hover(entering, apply: apply) }
        item.selected = selected
        return item
    }

    // Room & vinyl presets (checkmark on the active one; "Off" disables the DSP).
    var presetSub: [AppMenuItem] = [
        previewRow(title: "Off", icon: roomOn ? "circle" : "checkmark", selected: !roomOn) { player.roomEnabled = false },
        .divider()
    ]
    for preset in Room.presets {
        let on = player.roomEnabled && player.roomPresetName == preset.name
        presetSub.append(previewRow(title: preset.name, icon: on ? "checkmark" : "speaker.wave.2", selected: on) {
            player.roomPresetName = preset.name; player.roomEnabled = true
        })
    }
    var presetItem = AppMenuItem(title: "Room & Vinyl", systemImage: "speaker.wave.2") {}
    presetItem.submenu = presetSub

    // Effect strength in steps (the menu equivalent of the Amount bar).
    let curPct = Int((player.roomAmount * 100).rounded())
    var amountSub: [AppMenuItem] = []
    for pct in [0, 25, 50, 75, 100] {
        var row = AppMenuItem(title: "\(pct)%",
                              systemImage: curPct == pct ? "checkmark" : "dial.medium") {
            player.roomAmount = Double(pct) / 100
        }
        row.selected = curPct == pct
        amountSub.append(row)
    }
    var amountItem = AppMenuItem(title: "Effect Amount", systemImage: "dial.medium") {}
    amountItem.submenu = amountSub

    // Vinyl crackle toggle (the @AppStorage("vinylCrackle") pill on Now Playing, default on).
    let crackleOn = UserDefaults.standard.object(forKey: "vinylCrackle") as? Bool ?? true
    var crackleItem = AppMenuItem(title: crackleOn ? "Vinyl Crackle: On" : "Vinyl Crackle: Off",
                                  systemImage: crackleOn ? "checkmark" : "waveform.path") {
        UserDefaults.standard.set(!crackleOn, forKey: "vinylCrackle")
    }
    crackleItem.selected = crackleOn

    return [presetItem, amountItem, crackleItem, slowedReverbMenuItem(player: player)]
}

/// Snapshot of the Slowed + Reverb settings, so hovering a row can audition it and leaving the
/// flyout without clicking puts everything back (same idea as `RoomPreview`).
@MainActor private final class DJPreview {
    private let player: PlayerEngine
    private let base: (dj: Bool, speed: Double, pitch: Double, reverb: Double)
    private var committed = false
    private var hovers = 0

    init(_ p: PlayerEngine) { player = p; base = (p.djMode, p.speed, p.pitch, p.reverbMix) }

    func hover(_ entering: Bool, apply: @escaping () -> Void) {
        if entering { hovers += 1; apply() }
        else {
            hovers = max(0, hovers - 1)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.committed, self.hovers == 0 else { return }
                self.player.djMode = self.base.dj
                self.player.speed = self.base.speed
                self.player.pitch = self.base.pitch
                self.player.reverbMix = self.base.reverb
            }
        }
    }

    func commit(_ apply: () -> Void) { committed = true; apply() }
}

/// "Slowed + Reverb" parent row → a submenu with two one-click presets (back to normal, the
/// classic slowed-and-reverb sound) and Customise… (the sliders sheet). Hovering a preset
/// auditions it live (NativeMenu's highlight → onHover); clicking keeps it.
@MainActor
func slowedReverbMenuItem(player: PlayerEngine) -> AppMenuItem {
    let preview = DJPreview(player)
    func row(_ title: String, icon: String, selected: Bool, apply: @escaping () -> Void) -> AppMenuItem {
        var item = AppMenuItem(title: title, systemImage: selected ? "checkmark" : icon) { preview.commit(apply) }
        item.onHover = { entering in preview.hover(entering, apply: apply) }
        item.selected = selected
        return item
    }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }

    let on = player.djMode
    let normal = !on || (near(player.speed, 1) && near(player.pitch, 0) && near(player.reverbMix, 0))
    let classic = on && near(player.speed, 0.80) && near(player.pitch, 0) && near(player.reverbMix, 40)

    // Custom = engine on with values that match neither preset (set from the sliders).
    let custom = on && !normal && !classic
    var sub: [AppMenuItem] = [
        row("Normal", icon: "waveform", selected: normal) {
            player.djMode = false            // also resets speed to 1.0×
            player.pitch = 0; player.reverbMix = 0
        },
        row("Slowed + Reverb", icon: "moon.stars", selected: classic) {
            player.djMode = true
            player.speed = 0.80; player.pitch = 0; player.reverbMix = 40
        },
        .divider()
    ]
    // Fine control lives in the FX panel's sliders — open it rather than listing every step here.
    var customise = AppMenuItem(title: custom ? "Custom (Edit)…" : "Customise…",
                                systemImage: custom ? "checkmark" : "slider.horizontal.3") {
        player.djMode = true
        // Let the menu's dismiss animation finish before the sheet comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .openSlowedReverbFX, object: nil)
        }
    }
    customise.selected = custom
    sub.append(customise)

    var item = AppMenuItem(title: on && !normal ? "Slowed + Reverb: On" : "Slowed + Reverb",
                           systemImage: on && !normal ? "checkmark" : "dial.medium") {}
    item.selected = on && !normal
    item.submenu = sub
    return item
}

/// Right-click actions for a single (usually now-playing) track — used by the player bar
/// and the full Now Playing screen. `includeEffects` appends the shared FX rows (Room & vinyl,
/// amount, crackle) — on for the Now Playing surfaces, off for queue/list rows.
@MainActor
func nowPlayingTrackMenuItems(for track: Track, state: AppState, player: PlayerEngine,
                              includeEffects: Bool = false) -> [AppMenuItem] {
    let liked = state.isLiked(track)
    var items: [AppMenuItem] = [
        AppMenuItem(title: liked ? "Unfavourite Song" : "Favourite Song",
                    systemImage: liked ? "heart.slash" : "heart") { state.toggleLikedSong(track) },
        addToPlaylistMenuItem(state: state,
                              add: { state.addTrack(track, toPlaylist: $0) },
                              createNew: { state.beginPlaylistDraft(track: track) })
    ]
    let album = track.albumID.flatMap { id in state.albums.first { $0.id == id } }
    if let album {
        items.append(AppMenuItem(title: "Start Radio", systemImage: "dot.radiowaves.left.and.right") {
            state.startRadio(album: album, track: track, on: player)
        })
        items.append(AppMenuItem(title: album.isFavourite ? "Remove Favourite" : "Add to Favourites",
                                 systemImage: album.isFavourite ? "heart.slash" : "heart") { state.toggleFavourite(album.id) })
        items.append(.divider())
        items.append(AppMenuItem(title: "Go to Album", systemImage: "square.stack") {
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
    if includeEffects {
        items.append(.divider())
        items.append(contentsOf: effectsMenuItems(player: player))
    }
    return items
}

/// The full-screen player's right-click menu (Now Playing, First Listen): the playing track's
/// actions — or, before anything plays, the shown album's — plus the effects rows. Without the
/// album fallback, a not-yet-started player offered only "Art Mode".
@MainActor
func playerScreenMenuItems(track: Track?, album: Album?, state: AppState, player: PlayerEngine) -> [AppMenuItem] {
    if let track { return nowPlayingTrackMenuItems(for: track, state: state, player: player, includeEffects: true) }
    guard let album, state.album(id: album.id) != nil else { return effectsMenuItems(player: player) }
    return albumMenuItems(for: album, state: state, player: player) + [.divider()] + effectsMenuItems(player: player)
}

/// Actions when several albums are selected at once.
@MainActor
private func selectionMenuItems(_ ids: Set<UUID>, state: AppState) -> [AppMenuItem] {
    var items: [AppMenuItem] = []
    let members = state.albums.filter { ids.contains($0.id) }
    // Offer "combine" only when every pick is a plain single-file import.
    if members.count >= 2 && members.allSatisfy({ $0.isSingleLocalFile }) {
        items.append(AppMenuItem(title: "Combine Into One Album", systemImage: "square.stack") {
            state.combineIntoAlbum(ids)
        })
        items.append(.divider())
    }
    items.append(AppMenuItem(title: "Find Credits for \(ids.count)", systemImage: "person.2") {
        state.enrichSelection(ids)
    })
    // Re-read embedded cover art — useful for imports that came in without a cover.
    if members.contains(where: { $0.source == .local && ($0.hasLocalFiles || $0.url != nil) }) {
        items.append(AppMenuItem(title: "Re-scan Artwork", systemImage: "photo") {
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
    items.append(AppMenuItem(title: "Delete \(ids.count) Albums", systemImage: "trash", role: .destructive, holdToConfirm: true,
                             confirmMessage: "Delete \(ids.count) albums?",
                             confirmDetail: "They’re removed from Cabin. Your files and your Bandcamp purchases aren’t touched.") {
        state.deleteAlbums(ids); state.enterSelection(false)
    })
    return items
}

// MARK: - Native menu

/// Turns `[AppMenuItem]` into a real `NSMenu` — system look, keyboard navigation (arrows, type-
/// select, Return/Esc), VoiceOver, submenus — and runs the actions. Stays alive while its menu is
/// open (`live`) and doubles as the menus' delegate so a row's `onHover` still auditions effects as
/// the highlight moves (the Room & vinyl presets).
@MainActor
final class NativeMenu: NSObject, NSMenuDelegate {
    private static var live: NativeMenu?

    private final class Box { let item: AppMenuItem; init(_ i: AppMenuItem) { item = i } }
    private var highlighted: AppMenuItem?
    private let root = NSMenu()

    private init(_ items: [AppMenuItem]) {
        super.init()
        populate(root, with: items)
    }

    /// Nil when there's nothing actionable (a divider-only menu).
    static func make(_ items: [AppMenuItem]) -> NSMenu? {
        guard items.contains(where: { !$0.isDivider }) else { return nil }
        let m = NativeMenu(items)
        live = m
        return m.root
    }

    private func populate(_ menu: NSMenu, with items: [AppMenuItem]) {
        menu.autoenablesItems = false
        menu.delegate = self
        var lastWasDivider = true
        for item in items {
            if item.isDivider {
                if !lastWasDivider { menu.addItem(.separator()) }
                lastWasDivider = true
                continue
            }
            lastWasDivider = false
            let mi = NSMenuItem(title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = Box(item)
            if item.selected { mi.state = .on }
            // "checkmark"/"circle" were the custom menu's selection glyphs — native menus use state.
            if !["", "checkmark", "circle"].contains(item.systemImage) {
                mi.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)
            }
            if let sub = item.submenu {
                let sm = NSMenu(title: item.title)
                populate(sm, with: sub)
                mi.submenu = sm
                mi.action = nil
            }
            menu.addItem(mi)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let item = (sender.representedObject as? Box)?.item else { return }
        guard item.holdToConfirm else { item.action(); return }
        // Confirm after the menu has fully closed, as a sheet on the window it came from.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = item.confirmMessage ?? "\(item.title)?"
            alert.informativeText = item.confirmDetail ?? "This can’t be undone."
            alert.alertStyle = .warning
            let ok = alert.addButton(withTitle: item.title)
            ok.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            let run = { (r: NSApplication.ModalResponse) in if r == .alertFirstButtonReturn { item.action() } }
            if let w = NSApp.keyWindow ?? NSApp.mainWindow { alert.beginSheetModal(for: w, completionHandler: run) }
            else { run(alert.runModal()) }
        }
    }

    // Hover auditioning: report enter/leave as the highlight moves between rows.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let next = (item?.representedObject as? Box)?.item
        guard next?.id != highlighted?.id else { return }
        highlighted?.onHover?(false)
        highlighted = next
        next?.onHover?(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === root else { return }
        highlighted?.onHover?(false)
        highlighted = nil
    }

    /// Pop a menu with its top-left at `point` in SwiftUI global coordinates of the key window
    /// (what the "…" buttons measure).
    static func popUp(_ items: [AppMenuItem], atGlobal point: CGPoint) {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView,
              let menu = make(items) else { return }
        let p = NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        menu.popUp(positioning: nil, at: p, in: view)
    }
}

// MARK: - Right-click capture

/// Lets the SwiftUI side open the menu without a mouse (VoiceOver "Show menu").
@MainActor
final class MenuAnchor {
    weak var view: NSView?
    /// Pop `items` from the anchored view's centre.
    func show(_ items: [AppMenuItem]) {
        guard let v = view, let menu = NativeMenu.make(items) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: v.bounds.midX, y: v.bounds.midY), in: v)
    }
}

/// A transparent overlay that opens the native menu on right-click or Control-click while letting
/// every other event fall through to the views behind it.
private struct RightClickCatcher: NSViewRepresentable {
    var items: () -> [AppMenuItem]
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.items = items
        anchor.view = v
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.items = items
        anchor.view = v
    }

    final class CatcherView: NSView {
        var items: (() -> [AppMenuItem])?

        // Only claim right-clicks and Control-clicks; pass everything else through.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            switch e.type {
            case .rightMouseDown, .rightMouseUp: return super.hitTest(point)
            case .leftMouseDown where e.modifierFlags.contains(.control),
                 .leftMouseUp where e.modifierFlags.contains(.control): return super.hitTest(point)
            default: return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) { pop(event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { pop(event) } else { super.mouseDown(with: event) }
        }

        private func pop(_ event: NSEvent) {
            guard let items = items?(), let menu = NativeMenu.make(items) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

// MARK: - Attach a menu to any view

extension View {
    /// Right-click (or Control-click, or VoiceOver "Show menu") this view to open a native menu
    /// built from `items`. Empty items → no menu.
    func appContextMenu(_ items: @escaping () -> [AppMenuItem]) -> some View {
        modifier(AppContextMenu(items: items))
    }
}

private struct AppContextMenu: ViewModifier {
    let items: () -> [AppMenuItem]
    @State private var anchor = MenuAnchor()

    func body(content: Content) -> some View {
        content
            .overlay(RightClickCatcher(items: items, anchor: anchor))
            .accessibilityAction(.showMenu) { anchor.show(items()) }
    }
}
