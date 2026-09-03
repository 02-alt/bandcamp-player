import SwiftUI
import AppKit

/// The "Friends" drawer: slides in from the right (like Up Next) over a scrim. Lists the fans
/// you follow on Bandcamp, and — once you pick one — their collection and wishlist with the
/// "why I love this" note they wrote on each owned album. Everything streams as a preview.
struct FriendsView: View {
    @EnvironmentObject var state: AppState
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

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let friend = state.openedFriend {
                FriendDetail(friend: friend)
            } else {
                friendsList
            }
        }
        .padding(Space.s5)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(glow: true)
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) { state.friendsOpen = false }
    }

    // MARK: Friends list

    private var friendsList: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Friends").font(.system(size: 17, weight: .bold)).kerning(-0.3)
                if case .loaded = state.friendsLoad, !state.friends.isEmpty {
                    Text("\(state.friends.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.muted2)
                }
                Spacer()
                IconButton(system: "xmark", label: "Close friends") { close() }
            }

            switch state.friendsLoad {
            case .loading where state.friends.isEmpty:
                OrbLoadingRow(text: "Loading the fans you follow…", size: 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                note(msg, systemImage: "exclamationmark.triangle")
            case .loaded where state.friends.isEmpty:
                note("You're not following any Bandcamp fans yet.", systemImage: "person.2")
            default:
                ScrollView {
                    VStack(spacing: Space.s2) {
                        ForEach(state.friends) { friend in
                            FriendRow(friend: friend) { state.openFriend(friend) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage).font(.system(size: 24)).foregroundStyle(p.muted2).accessibilityHidden(true)
            Text(text).font(.system(size: 13)).foregroundStyle(p.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One friend row in the drawer: avatar + name + location.
private struct FriendRow: View {
    let friend: Friend
    let open: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s3) {
                Avatar(friend: friend, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(friend.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(p.text)
                    if let loc = friend.location {
                        Text(loc).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted2)
            }
            .padding(.vertical, Space.s2).padding(.horizontal, Space.s3)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(hovering ? p.glassFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.97, brighten: 0))
        .onHover { hovering = $0 }
    }
}

/// A circular Bandcamp fan avatar, falling back to a monogram when there's no photo.
struct Avatar: View {
    let friend: Friend
    var size: CGFloat = 44
    @Environment(\.palette) private var p

    var body: some View {
        Circle()
            .fill(p.glassFill)
            .overlay {
                if let url = friend.avatarURL {
                    CachedRemoteImage(url: url) { monogram }
                } else {
                    monogram
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    private var monogram: some View {
        Text(String(friend.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(p.muted)
    }
}

/// The "macaron": overlapping circular avatars of followed friends who own an album —
/// "people you follow own this." Shows up to 3, then "+N".
struct OwnersMacaron: View {
    let owners: [Friend]
    var size: CGFloat = 24

    var body: some View {
        let shown = Array(owners.prefix(3))
        let extra = owners.count - shown.count
        HStack(spacing: -size * 0.42) {
            ForEach(shown) { f in
                Avatar(friend: f, size: size)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(.black.opacity(0.7)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        let names = owners.map(\.name)
        let list: String
        switch names.count {
        case 0: return ""
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + ", and \(names.last!)"
        }
        return "People you follow own this: \(list)"
    }
}

// MARK: - Friend detail (collection / wishlist tabs)

private struct FriendDetail: View {
    let friend: Friend
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @State private var tab: Tab = .collection

    private enum Tab { case collection, wishlist }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            header
            tabs
            content
        }
        .task(id: friend.id) { await state.startFriendList(friend, wishlist: false) }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { state.openedFriend = nil } } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.text)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(p.glassFill))
                    .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            }
            .buttonStyle(.soft)
            .accessibilityLabel("Back to friends")

            Avatar(friend: friend, size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(friend.name).font(.system(size: 15, weight: .bold)).foregroundStyle(p.text).lineLimit(1)
                if let loc = friend.location {
                    Text(loc).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            IconButton(system: "xmark", label: "Close friends") {
                withAnimation(.easeInOut(duration: 0.2)) { state.friendsOpen = false }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 3) {
            tabButton("Collection", .collection)
            tabButton("Wishlist", .wishlist)
        }
        .padding(3)
        .background(Capsule().fill(p.glassFill))
        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    private func tabButton(_ label: String, _ t: Tab) -> some View {
        let on = tab == t
        return Button {
            withAnimation(Motion.glide) { tab = t }
            Task { await state.startFriendList(friend, wishlist: t == .wishlist) }
        } label: {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? p.text : p.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.s2)
                .background { if on { Capsule().fill(p.glassFill).overlay(Capsule().strokeBorder(p.edge, lineWidth: 1)) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
    }

    @ViewBuilder private var content: some View {
        let wishlist = tab == .wishlist
        let items = state.friendItems(friend.id, wishlist: wishlist)

        if let msg = items.failed, items.albums.isEmpty {
            centered(msg, systemImage: "exclamationmark.triangle")
        } else if items.albums.isEmpty && (items.loading || !items.started) {
            OrbLoadingRow(text: wishlist ? "Loading their wishlist…" : "Loading their collection…", size: 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.albums.isEmpty {
            centered(wishlist ? "Their wishlist is empty." : "Nothing in their collection.",
                     systemImage: wishlist ? "heart" : "square.stack")
        } else {
            ScrollView {
                LazyVStack(spacing: Space.s2) {
                    ForEach(items.albums) { album in
                        FriendAlbumRow(album: album)
                    }

                    if !items.reachedEnd {
                        Button {
                            Task { await state.loadMoreFriend(friend, wishlist: wishlist) }
                        } label: {
                            HStack(spacing: Space.s2) {
                                if items.loading { OrbLoader(size: 40) }
                                Text(items.loading ? "Loading…" : "Load more")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                            }
                            .padding(.vertical, Space.s3).frame(maxWidth: .infinity)
                            .background(Capsule().fill(p.glassFill))
                            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                        }
                        .buttonStyle(.soft)
                        .disabled(items.loading)
                        .padding(.top, Space.s3)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func centered(_ text: String, systemImage: String) -> some View {
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage).font(.system(size: 24)).foregroundStyle(p.muted2).accessibilityHidden(true)
            Text(text).font(.system(size: 13)).foregroundStyle(p.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A friend's album as a compact row: cover + title/artist, their "why" note, tap to preview.
private struct FriendAlbumRow: View {
    let album: Album
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var hovering = false
    @State private var noteExpanded = false

    /// The user's own copy of this album, if they own it too.
    private var owned: Album? { state.libraryAlbum(forBandcampURL: album.bandcampItemURL) }

    private var ownedBadge: some View {
        Text("OWNED")
            .font(.system(size: 8, weight: .bold)).kerning(0.5)
            .foregroundStyle(p.accentInk)
            .padding(.vertical, 2).padding(.horizontal, 5)
            .background(Capsule().fill(p.accent))
            .fixedSize()
            .accessibilityLabel("You own this album")
    }

    var body: some View {
        Button { if album.isPlayable { state.play(album, on: player) } } label: {
            HStack(alignment: .top, spacing: Space.s3) {
                AlbumArt(album: album, corner: 8)
                    .frame(width: 52, height: 52)
                    .overlay { if hovering && album.isPlayable { playOverlay } }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s2) {
                        Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(p.text)
                        if owned != nil { ownedBadge }
                    }
                    Text(album.artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                    if let why = album.friendReview, !why.isEmpty {
                        Text("“\(why)”")
                            .font(.system(size: 11).italic()).foregroundStyle(p.muted)
                            .lineLimit(noteExpanded ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                            .help(why)
                    }
                }
                Spacer(minLength: 0)
                if album.bandcampItemURL != nil {
                    Button { buy() } label: {
                        Image(systemName: "bag").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(p.glassFill))
                            .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                    }
                    .buttonStyle(.soft)
                    .accessibilityLabel("Open on Bandcamp")
                    .help("Open on Bandcamp")
                }
            }
            .padding(Space.s2)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(hovering ? p.glassFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .onHover { hovering = $0 }
        .appContextMenu { menu }
    }

    private var playOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35))
            Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white)
        }
    }

    private var menu: [AppMenuItem] {
        var items: [AppMenuItem] = []
        if album.isPlayable {
            items.append(AppMenuItem(title: "Play preview", systemImage: "play.fill") { state.play(album, on: player) })
        }
        if let mine = owned {
            items.append(AppMenuItem(title: "Go to album in library", systemImage: "square.stack") {
                state.goToLibraryAlbum(mine.id)
            })
        }
        if let why = album.friendReview, !why.isEmpty {
            items.append(AppMenuItem(title: noteExpanded ? "Collapse note" : "Read full note",
                                     systemImage: "text.quote") { noteExpanded.toggle() })
            items.append(AppMenuItem(title: "Copy note", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(why, forType: .string)
            })
        }
        if album.bandcampItemURL != nil {
            items.append(AppMenuItem(title: "Open on Bandcamp", systemImage: "safari") { buy() })
        }
        return items
    }

    private func buy() {
        guard let s = album.bandcampItemURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}
