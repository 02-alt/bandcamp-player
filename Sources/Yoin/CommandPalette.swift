import SwiftUI

/// One runnable entry in the ⌘K palette.
private struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    /// Extra words to match against (so "dark", "pause", etc. find the right action).
    let keywords: String
    let run: () -> Void
}

/// ⌘K command palette: fuzzy-search over app actions and your albums, run with a click or ⏎.
struct CommandPalette: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @FocusState private var focused: Bool
    @State private var query = ""

    var body: some View {
        ZStack(alignment: .top) {
            // Dim + click-out to dismiss.
            Rectangle().fill(.black.opacity(0.35)).ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: Space.s3) {
                    Image(systemName: "command").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.muted)
                    TextField("Search actions and albums…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { runTop() }
                }
                .padding(.vertical, Space.s4).padding(.horizontal, Space.s5)

                Divider().overlay(p.edgeSoft)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, item in
                            row(item, first: i == 0)
                        }
                        ForEach(albumResults) { album in albumRow(album) }
                        if filtered.isEmpty && albumResults.isEmpty {
                            Text("No matches").font(.system(size: 13)).foregroundStyle(p.muted2)
                                .frame(maxWidth: .infinity).padding(.vertical, Space.s5)
                        }
                    }
                    .padding(Space.s2)
                }
                .frame(maxHeight: 380)
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .background {
            Button("") { close() }.keyboardShortcut(.escape, modifiers: []).hidden()
        }
    }

    // MARK: Rows

    private func row(_ item: PaletteItem, first: Bool) -> some View {
        Button { item.run(); close() } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: item.systemImage).font(.system(size: 13)).foregroundStyle(p.muted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.system(size: 11)).foregroundStyle(p.muted2)
                    }
                }
                Spacer()
                if first { Text("⏎").font(.system(size: 12)).foregroundStyle(p.muted2) }
            }
            .padding(.vertical, 7).padding(.horizontal, Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
    }

    private func albumRow(_ album: Album) -> some View {
        Button { state.openedAlbumID = album.id; close() } label: {
            HStack(spacing: Space.s3) {
                AlbumArt(album: album, corner: 6).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text(album.artist).font(.system(size: 11)).foregroundStyle(p.muted2).lineLimit(1)
                }
                Spacer()
                Text("Album").font(.system(size: 10)).foregroundStyle(p.muted2)
            }
            .padding(.vertical, 5).padding(.horizontal, Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
    }

    // MARK: Filtering

    private var filtered: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return actions }
        return actions.filter { ($0.title + " " + $0.keywords).lowercased().contains(q) }
    }

    private var albumResults: [Album] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var seen = Set<String>()
        return state.albums
            .filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
            .filter { seen.insert($0.dedupeKey).inserted }
            .prefix(6).map { $0 }
    }

    private func runTop() {
        if let first = filtered.first { first.run(); close() }
        else if let a = albumResults.first { state.openedAlbumID = a.id; close() }
    }

    private func close() { withAnimation(.easeInOut(duration: 0.12)) { state.paletteOpen = false } }

    // MARK: Actions

    private var actions: [PaletteItem] {
        func go(_ s: AppState.Screen) { withAnimation(Motion.glide) { state.screen = s } }
        var items: [PaletteItem] = [
            PaletteItem(title: player.isPlaying ? "Pause" : "Play", subtitle: "", systemImage: player.isPlaying ? "pause.fill" : "play.fill", keywords: "play pause toggle") { player.toggle() },
            PaletteItem(title: "Next track", subtitle: "", systemImage: "forward.fill", keywords: "skip next") { player.next() },
            PaletteItem(title: "Previous track", subtitle: "", systemImage: "backward.fill", keywords: "back previous") { player.prev() },
            PaletteItem(title: player.shuffle ? "Shuffle: off" : "Shuffle: on", subtitle: "", systemImage: "shuffle", keywords: "shuffle random") { player.shuffle.toggle() },
            PaletteItem(title: player.repeatOne ? "Repeat one: off" : "Repeat one: on", subtitle: "", systemImage: "repeat.1", keywords: "repeat loop") { player.repeatOne.toggle() },
            PaletteItem(title: "Open Now Playing", subtitle: "", systemImage: "chevron.up", keywords: "now playing expand full") { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { player.expanded = true } },
            PaletteItem(title: "Art mode", subtitle: "Fullscreen cover", systemImage: "photo.artframe", keywords: "art fullscreen cover screensaver") { withAnimation(.easeInOut(duration: 0.3)) { player.artMode = true } },
            PaletteItem(title: "Mini player", subtitle: "", systemImage: "pip", keywords: "mini pip float") { MiniPlayerController.shared.toggle() },
            PaletteItem(title: player.djMode ? "DJ mode: off" : "DJ mode: on", subtitle: "Turntable speed control", systemImage: "dial.medium", keywords: "dj turntable speed pitch") { player.djMode.toggle() },
            PaletteItem(title: "Up Next", subtitle: "", systemImage: "list.bullet", keywords: "queue up next") { withAnimation(.easeInOut(duration: 0.2)) { state.queueOpen.toggle() } },
            PaletteItem(title: "Search music", subtitle: "", systemImage: "magnifyingglass", keywords: "search find") { withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = true } },
            PaletteItem(title: "Sync Bandcamp", subtitle: "", systemImage: "arrow.clockwise", keywords: "sync refresh bandcamp") { Task { await state.syncBandcamp(announce: true) } },
        ]
        // Transitions.
        for m in TransitionMode.allCases where m != player.transitionMode {
            items.append(PaletteItem(title: "Transitions: \(m.label)", subtitle: m.blurb, systemImage: "shuffle", keywords: "transition crossfade beatmatch fade") { player.transitionMode = m })
        }
        // Screen navigation.
        let screens: [(String, String, AppState.Screen)] = [
            ("Crate", "square.stack", .crate), ("Library", "square.grid.2x2", .grid),
            ("Playlists", "music.note.list", .playlists), ("Wishlist", "heart", .wishlist),
            ("Recap", "sparkles.rectangle.stack", .recap), ("Settings", "gearshape", .settings),
        ]
        for (name, icon, screen) in screens {
            items.append(PaletteItem(title: "Go to \(name)", subtitle: "", systemImage: icon, keywords: "open go screen tab \(name)") { go(screen) })
        }
        return items
    }
}
