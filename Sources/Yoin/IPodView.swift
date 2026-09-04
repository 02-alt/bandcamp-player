import SwiftUI

/// The iPod tab — appears only while a click-wheel iPod is connected. Covers-first: albums as a
/// grid of tiles (tap to see tracks), the way iTunes/iMazing present a device. Phase 2 is
/// read-only browse; adding songs is Phase 3.
struct IPodView: View {
    @EnvironmentObject var ipod: IPodWatcher
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var albums: [IPodAlbum] = []
    @State private var loading = true
    @State private var openAlbum: IPodAlbum?
    @State private var artDB: IPodArtworkDB?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var splitView = false
    @State private var libTargeted = false
    @State private var podTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: Space.s6)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let device = ipod.device {
                deviceHeader(device)
                content(device)
            } else {
                Text("No iPod connected.")
                    .font(.system(size: 14)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) { if selecting, ipod.device != nil { selectionBar } }
        .task(id: ipod.device?.volumeURL) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .ipodDBChanged)) { _ in
            Task { await load() }
        }
        .sheet(item: $openAlbum) { album in
            IPodAlbumSheet(album: album) { openAlbum = nil }
                .environment(\.palette, p)
        }
    }

    private var songCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }

    // MARK: Header

    private func deviceHeader(_ device: IPodDevice) -> some View {
        HStack(spacing: Space.s4) {
            Image(systemName: "ipod")
                .font(.system(size: 30)).foregroundStyle(p.text)
                .frame(width: 54, height: 54)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.glassFill))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s2) {
                Text(device.name).font(.system(size: 18, weight: .bold)).kerning(-0.3)
                    .foregroundStyle(p.text).lineLimit(1)
                Text("\(songCount) song\(songCount == 1 ? "" : "s") · \(albums.count) album\(albums.count == 1 ? "" : "s") · \(bytes(device.freeBytes)) free of \(bytes(device.totalBytes))")
                    .font(.system(size: 12)).foregroundStyle(p.muted)
                capacityBar(device).frame(height: 5).frame(maxWidth: 320)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    splitView.toggle()
                    if splitView { selecting = false; selection.removeAll() }
                }
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 12, weight: .semibold))
                    Text(splitView ? "Done" : "Sync").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(splitView ? p.accentInk : p.muted)
                .padding(.vertical, Space.s2).padding(.horizontal, Space.s3)
                .background(Capsule().fill(splitView ? p.accent : p.glassFill))
                .overlay(Capsule().strokeBorder(splitView ? .clear : p.edgeSoft, lineWidth: 1))
            }
            .buttonStyle(.soft)
            .help("Split the view to drag albums between your library and the iPod")
            .accessibilityLabel(splitView ? "Close sync view" : "Open sync view")
            if !albums.isEmpty && !splitView {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selecting.toggle(); if !selecting { selection.removeAll() }
                    }
                } label: {
                    Text(selecting ? "Done" : "Select").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selecting ? p.text : p.muted)
                        .padding(.vertical, Space.s2).padding(.horizontal, Space.s3)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                }.buttonStyle(.soft)
            }
            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.muted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(p.glassFill))
                    .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            }
            .buttonStyle(.soft)
            .tip("Re-read the iPod's library")
        }
        .padding(.bottom, Space.s2)
    }

    private func capacityBar(_ device: IPodDevice) -> some View {
        GeometryReader { g in
            let frac = device.totalBytes > 0 ? Double(device.usedBytes) / Double(device.totalBytes) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(p.text.opacity(0.15))
                Capsule().fill(p.text).frame(width: max(0, g.size.width * frac))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("iPod capacity")
        .accessibilityValue("\(bytes(device.usedBytes)) used of \(bytes(device.totalBytes))")
    }

    // MARK: Content

    @ViewBuilder private func content(_ device: IPodDevice) -> some View {
        if splitView {
            splitContent(device)
        } else if loading {
            OrbLoadingRow(text: "Reading iPod library…", size: 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if albums.isEmpty {
            VStack(spacing: Space.s3) {
                Image(systemName: "music.note.list").font(.system(size: 26)).foregroundStyle(p.muted2)
                    .accessibilityHidden(true)
                Text("Couldn't read this iPod's library.")
                    .font(.system(size: 14)).foregroundStyle(p.muted)
                Text("It may be empty, or use a database format Yoin can't read yet.")
                    .font(.system(size: 12)).foregroundStyle(p.muted2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack {
                Text("ALBUMS ON THIS IPOD").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                Spacer()
                Text("Tap Sync to drag albums on & off").font(.system(size: 11)).foregroundStyle(p.muted2)
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s6) {
                    ForEach(albums) { album in
                        IPodAlbumTile(album: album, artDB: artDB,
                                      selecting: selecting,
                                      selected: selection.contains(album.id),
                                      menu: { albumMenu(album) },
                                      onTap: {
                                          if selecting { toggle(album) } else { openAlbum = album }
                                      })
                    }
                }
                .padding(.top, Space.s2)
                .padding(.bottom, selecting ? Space.s8 : 0)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Sync (split view)

    /// Two side-by-side panes — your library and the iPod — so albums can be dragged between them:
    /// library → iPod transcodes + copies the album onto the device; iPod → library imports it
    /// back. Both directions reuse the existing sync engine.
    private func splitContent(_ device: IPodDevice) -> some View {
        HStack(alignment: .top, spacing: Space.s4) {
            syncPane(title: "YOUR LIBRARY", subtitle: "Drag an album onto the iPod  →", targeted: libTargeted) {
                libraryGrid(device)
            }
            .dropDestination(for: String.self) { items, _ in dropToLibrary(items, device: device) }
                isTargeted: { libTargeted = $0 }

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.muted2)
                .frame(width: 18).padding(.top, 44).accessibilityHidden(true)

            syncPane(title: "ON THIS IPOD", subtitle: "←  Drag an album to your library", targeted: podTargeted) {
                ipodGrid(device)
            }
            .dropDestination(for: String.self) { items, _ in dropToIPod(items, device: device) }
                isTargeted: { podTargeted = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func syncPane<Content: View>(title: String, subtitle: String, targeted: Bool,
                                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(p.muted2)
            }
            ScrollView { content().padding(.bottom, Space.s4) }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(p.glassFill.opacity(targeted ? 1 : 0.45)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(targeted ? p.accent : p.edgeSoft, lineWidth: targeted ? 2 : 1))
        .animation(.easeInOut(duration: 0.12), value: targeted)
    }

    private var syncColumns: [GridItem] { [GridItem(.adaptive(minimum: 96), spacing: Space.s3)] }

    private func libraryGrid(_ device: IPodDevice) -> some View {
        let items = state.albums.filter { $0.source == .bandcamp || $0.localTracks != nil || $0.url != nil }
        return LazyVGrid(columns: syncColumns, alignment: .leading, spacing: Space.s4) {
            ForEach(items) { album in
                let canCopy = album.hasLocalFiles || album.url != nil
                SyncTile(title: album.title, artist: album.artist,
                         cover: AnyView(AlbumArt(album: album)),
                         dimmed: !canCopy,
                         // Keyboard/VoiceOver path — the drag isn't reachable without a pointer.
                         actionName: canCopy ? "Copy to iPod" : nil,
                         action: { state.addToIPod([album.id], device: device) })
                    .draggable("app:\(album.id.uuidString)")
            }
        }
    }

    @ViewBuilder private func ipodGrid(_ device: IPodDevice) -> some View {
        if loading {
            OrbLoadingRow(text: "Reading iPod…", size: 40)
        } else if albums.isEmpty {
            Text("No albums on the iPod yet.").font(.system(size: 12)).foregroundStyle(p.muted2)
        } else {
            LazyVGrid(columns: syncColumns, alignment: .leading, spacing: Space.s4) {
                ForEach(albums) { album in
                    SyncTile(title: album.title, artist: album.artist,
                             cover: AnyView(IPodMiniCover(album: album, artDB: artDB)),
                             dimmed: false,
                             actionName: "Import to library",
                             action: { state.downloadFromIPod([(album.title, album.artist, album.tracks)], device: device) })
                        .draggable("ipod:\(album.id.uuidString)")
                }
            }
        }
    }

    /// Accept "app:<uuid>" payloads dropped on the iPod pane → copy those albums to the device.
    private func dropToIPod(_ items: [String], device: IPodDevice) -> Bool {
        let ids = items.filter { $0.hasPrefix("app:") }.compactMap { UUID(uuidString: String($0.dropFirst(4))) }
        guard !ids.isEmpty else { return false }
        state.addToIPod(Set(ids), device: device)
        return true
    }

    /// Accept "ipod:<uuid>" payloads dropped on the library pane → import those albums.
    private func dropToLibrary(_ items: [String], device: IPodDevice) -> Bool {
        let ids = Set(items.filter { $0.hasPrefix("ipod:") }.compactMap { UUID(uuidString: String($0.dropFirst(5))) })
        let groups = albums.filter { ids.contains($0.id) }.map { (title: $0.title, artist: $0.artist, tracks: $0.tracks) }
        guard !groups.isEmpty else { return false }
        state.downloadFromIPod(groups, device: device)
        return true
    }

    private func toggle(_ album: IPodAlbum) {
        if selection.contains(album.id) { selection.remove(album.id) } else { selection.insert(album.id) }
    }

    private var selectedAlbums: [IPodAlbum] { albums.filter { selection.contains($0.id) } }

    /// Right-click actions for one iPod album.
    private func albumMenu(_ album: IPodAlbum) -> [AppMenuItem] {
        guard let dev = ipod.device else { return [] }
        return [
            AppMenuItem(title: "Download to library", systemImage: "square.and.arrow.down") {
                state.downloadFromIPod([(album.title, album.artist, album.tracks)], device: dev)
            },
            AppMenuItem(title: "Remove from iPod", systemImage: "trash", role: .destructive, holdToConfirm: true) {
                state.removeFromIPod(album.tracks, device: dev)
            },
        ]
    }

    /// Floating bar with bulk actions while selecting.
    private var selectionBar: some View {
        HStack(spacing: Space.s3) {
            Text("\(selection.count) selected").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
            Spacer()
            Button("Select all") { selection = Set(albums.map(\.id)) }
                .buttonStyle(.soft).foregroundStyle(p.muted).font(.system(size: 12, weight: .semibold))
            Button { downloadSelected() } label: {
                Label("Download", systemImage: "square.and.arrow.down").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.text).padding(.vertical, Space.s2).padding(.horizontal, Space.s4)
                    .background(Capsule().fill(p.glassFill)).overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
            }.buttonStyle(.soft).disabled(selection.isEmpty)
            .accessibilityLabel("Download \(selection.count) selected to library")
            Button { removeSelected() } label: {
                HStack(spacing: Space.s1) {
                    Image(systemName: "trash").font(.system(size: 12)).accessibilityHidden(true)
                    Text("Remove").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white).padding(.vertical, Space.s2).padding(.horizontal, Space.s4)
                .background(Capsule().fill(Color.red.opacity(selection.isEmpty ? 0.35 : 0.9)))
            }.buttonStyle(.soft).disabled(selection.isEmpty)
            .accessibilityLabel("Remove \(selection.count) selected from iPod")
        }
        .padding(.vertical, Space.s3).padding(.horizontal, Space.s5)
        .background {
            if reduceTransparency { Capsule().fill(p.page) }
            else { Capsule().fill(.ultraThinMaterial) }
        }
        .overlay(Capsule().strokeBorder(p.edge, lineWidth: 1))
        .padding(.bottom, Space.s4)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private func downloadSelected() {
        guard let dev = ipod.device else { return }
        state.downloadFromIPod(selectedAlbums.map { ($0.title, $0.artist, $0.tracks) }, device: dev)
        withAnimation { selecting = false; selection.removeAll() }
    }
    private func removeSelected() {
        guard let dev = ipod.device else { return }
        state.removeFromIPod(selectedAlbums.flatMap { $0.tracks }, device: dev)
        withAnimation { selecting = false; selection.removeAll() }
    }

    // MARK: Load

    private func load() async {
        guard let url = ipod.device?.volumeURL else { albums = []; loading = false; return }
        loading = true
        artDB = IPodArtworkDB(volume: url)
        let grouped = await Task.detached(priority: .userInitiated) {
            IPodAlbum.group(IPodDB.tracks(atVolume: url))
        }.value
        albums = grouped
        loading = false
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - Album grouping

/// Tracks from the iPod grouped into albums for the covers-first grid.
struct IPodAlbum: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let artist: String
    let tracks: [IPodTrack]
    /// A representative track dbid for looking up the album's cover in the iPod ArtworkDB.
    var artDBID: UInt64 { tracks.first(where: { $0.dbid != 0 })?.dbid ?? 0 }

    /// Group a flat track list into albums (by album title, then artist), sorted alphabetically.
    /// Tracks with no album fall under a single "Singles" tile per artist.
    static func group(_ tracks: [IPodTrack]) -> [IPodAlbum] {
        var order: [String] = []
        var buckets: [String: [IPodTrack]] = [:]
        for t in tracks {
            let name = t.album.isEmpty ? "Singles" : t.album
            let key = "\(name)\u{1}\(t.artist)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(t)
        }
        return order.map { key in
            let parts = key.components(separatedBy: "\u{1}")
            return IPodAlbum(title: parts.first ?? "Album",
                             artist: parts.count > 1 ? parts[1] : "",
                             tracks: buckets[key] ?? [])
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// A monochrome-plus-hint-of-colour placeholder cover derived deterministically from the album
/// name (the iPod's own artwork lives in a proprietary thumbnail DB we don't read yet).
func iPodPlaceholderCover(_ seed: String) -> LinearGradient {
    var h: UInt64 = 5381
    for b in seed.utf8 { h = (h &* 33) &+ UInt64(b) }        // stable across launches
    let hue = Double(h % 360) / 360.0
    return LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.52),
                                   Color(hue: hue, saturation: 0.55, brightness: 0.30)],
                          startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Sync tiles (split view)

/// A compact, draggable album tile used in the sync split view (either library or iPod side).
private struct SyncTile: View {
    let title: String
    let artist: String
    let cover: AnyView
    var dimmed: Bool = false
    /// Name of the sync action exposed to VoiceOver / keyboard (drag isn't reachable without a
    /// pointer). `nil` disables it (e.g. a not-yet-downloaded album that can't be copied).
    var actionName: String? = nil
    var action: () -> Void = {}
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            cover
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
                .shadow(color: .black.opacity(hovering ? 0.4 : 0.25), radius: hovering ? 12 : 7, y: 5)
                .animation(reduceMotion ? nil : Motion.lift, value: hovering)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
            Text(artist).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1)
        }
        .opacity(dimmed ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(dimmed ? "Download this album first to copy it to the iPod" : "Drag to the other side to sync")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(artist.isEmpty ? "" : " by \(artist)")")
        .accessibilityValue(dimmed ? "Download this album first to copy it to the iPod" : "")
        .modifier(SyncTileAction(name: actionName, action: action))
    }
}

/// Adds a named accessibility action only when one is provided.
private struct SyncTileAction: ViewModifier {
    let name: String?
    let action: () -> Void
    func body(content: Content) -> some View {
        if let name {
            content.accessibilityAction(named: Text(name), action)
        } else {
            content
        }
    }
}

/// Small cover loader for an iPod album (iPod's own art if present, else an iTunes cover).
private struct IPodMiniCover: View {
    let album: IPodAlbum
    let artDB: IPodArtworkDB?
    @State private var coverImage: NSImage?
    @State private var coverURL: URL?

    var body: some View {
        Group {
            if let coverImage {
                Image(nsImage: coverImage).resizable().scaledToFill()
            } else if let coverURL {
                CachedRemoteImage(url: coverURL) { placeholder }
            } else {
                placeholder
            }
        }
        .task {
            if let px = await artDB?.cover(forDBID: album.artDBID) {
                coverImage = iPodCoverImage(px)
            } else {
                coverURL = await IPodArt.shared.coverURL(artist: album.artist, album: album.title)
            }
        }
    }

    private var placeholder: some View {
        iPodPlaceholderCover(album.title + album.artist)
            .overlay(Image(systemName: "music.note").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85)))
    }
}

// MARK: - Tiles & sheet

private struct IPodAlbumTile: View {
    let album: IPodAlbum
    let artDB: IPodArtworkDB?
    var selecting: Bool = false
    var selected: Bool = false
    let menu: () -> [AppMenuItem]
    let onTap: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false
    @State private var coverURL: URL?
    @State private var coverImage: NSImage?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Space.s3) {
                cover
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if selecting {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20)).foregroundStyle(selected ? p.accent : .white.opacity(0.9))
                                .background(Circle().fill(selected ? .white : .black.opacity(0.4)).padding(3))
                                .padding(Space.s2)
                        }
                    }
                    .overlay {
                        if selecting && selected {
                            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                .strokeBorder(p.accent, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Text("\(album.tracks.count)")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .padding(.vertical, 3).padding(.horizontal, 7)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .padding(Space.s2)
                    }
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    .scaleEffect(hovering ? 1.035 : 1)
                    .shadow(color: .black.opacity(hovering ? 0.5 : 0.3),
                            radius: hovering ? 22 : 14, y: hovering ? 16 : 10)
                    .animation(Motion.lift, value: hovering)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text).lineLimit(1)
                    Text(album.artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.98, brighten: 0))
        .onHover { hovering = $0 }
        .appContextMenu(menu)
        .accessibilityLabel("\(album.title)\(album.artist.isEmpty ? "" : " by \(album.artist)"), \(album.tracks.count) songs")
        .accessibilityAddTraits(selecting && selected ? [.isSelected] : [])
        .task {
            // Prefer the iPod's own artwork (decoded off-main), else a crisp iTunes cover.
            if let px = await artDB?.cover(forDBID: album.artDBID) {
                coverImage = iPodCoverImage(px)
            } else {
                coverURL = await IPodArt.shared.coverURL(artist: album.artist, album: album.title)
            }
        }
    }

    /// iPod's own art if present, else a crisp iTunes cover, else the colored placeholder.
    @ViewBuilder private var cover: some View {
        if let coverImage {
            Image(nsImage: coverImage).resizable().scaledToFill()
        } else if let coverURL {
            CachedRemoteImage(url: coverURL) { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        iPodPlaceholderCover(album.title + album.artist)
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(Space.s3)
            }
    }
}

/// A sheet listing one album's tracks — reached by tapping a cover tile.
private struct IPodAlbumSheet: View {
    let album: IPodAlbum
    let onClose: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iPodPlaceholderCover(album.title + album.artist))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "music.note").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.system(size: 17, weight: .bold)).kerning(-0.3)
                        .foregroundStyle(p.text).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(album.artist.isEmpty ? "" : album.artist + " · ")\(album.tracks.count) song\(album.tracks.count == 1 ? "" : "s")")
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                }
                Spacer()
                IconButton(system: "xmark", tip: "Close album", action: onClose)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, track in
                        HStack(spacing: Space.s3) {
                            Text("\(i + 1)").font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(p.muted2).frame(width: 26, alignment: .trailing)
                            Text(track.title).font(.system(size: 13)).foregroundStyle(p.text).lineLimit(1)
                            Spacer()
                            if track.durationMs > 0 {
                                Text(duration(track.durationMs)).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(p.muted2)
                            }
                        }
                        .padding(.vertical, Space.s2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(Space.s6)
        .frame(width: 440, height: 560)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(p.page))
    }

    private func duration(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
