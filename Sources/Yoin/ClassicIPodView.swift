import SwiftUI
import AppKit

/// A pixel-faithful black iPod Classic replica whose *screen* is a live, working UI: a Cover Flow
/// of the albums actually on the connected iPod, a Now Playing screen that mirrors the real device,
/// and transfer-feedback screens driven by `IPodTransfer`. The click wheel below is functional —
/// rotate to flip covers, centre to select, MENU to go back, and the transport keys map to the app's
/// `PlayerEngine`, playing the iPod's own files.
struct ClassicIPodView: View {
    let albums: [IPodAlbum]
    let device: IPodDevice
    let artDB: IPodArtworkDB?
    var onExit: () -> Void

    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var clock: PlaybackClock
    @ObservedObject private var transfer = IPodTransfer.shared
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deviceTargeted = false
    @State private var libTargeted = false

    /// Which screen the iPod is showing.
    private enum Screen: Equatable {
        case menu
        case coverflow
        case tracklist(IPodAlbum)
        case nowPlaying
        case about
    }
    @State private var screen: Screen = .menu
    /// Fractional cover-flow position (whole number = a cover is centred). Kept as a Double so the
    /// rotational wheel drag can move it smoothly.
    @State private var position: Double = 0
    @State private var trackSel = 0
    @State private var playingAlbum: IPodAlbum?
    @State private var wheelAngle: Double?     // last angle during a rotational drag
    @State private var scrollAccum: Double = 0 // fractional wheel rotation for discrete lists

    // MARK: Menu OS navigation
    /// A hierarchical iPod-style menu, navigated with the wheel (scroll), centre (select) and
    /// MENU (back). `nav` is the breadcrumb stack, `selStack` remembers the highlight at each level.
    private enum MenuID: Equatable { case root, music, artists, albumsList, songs, artist(String), extras }
    private enum MenuAction { case push(MenuID), openAlbum(IPodAlbum), playFlat(Int), coverflow, nowPlaying, shuffleAll, about }
    private struct MenuRow: Identifiable {
        let id = UUID(); let label: String; var sub: String? = nil; var chevron = false; let action: MenuAction
    }
    @State private var nav: [MenuID] = [.root]
    @State private var menuSel = 0
    @State private var selStack: [Int] = []
    @State private var pageRows: [MenuRow] = []
    @AppStorage("ipodSkin") private var skinRaw = IPodSkin.black.rawValue
    private var skin: IPodSkin { IPodSkin(rawValue: skinRaw) ?? .black }

    private var selectedIndex: Int { max(0, min(albums.count - 1, Int(position.rounded()))) }

    var body: some View {
        HStack(spacing: Space.s4) {
            libraryPanel
                .frame(maxWidth: .infinity)
            deviceArea
                .frame(maxWidth: .infinity)
        }
        .onAppear { if pageRows.isEmpty { pageRows = rows(for: nav.last ?? .root) } }
        // Rows are ALWAYS derived from the nav stack, so the visible list can never drift out of
        // sync with the title / what the wheel is acting on.
        .onChange(of: nav) { _, n in
            pageRows = rows(for: n.last ?? .root)
        }
    }

    // MARK: - Your-library panel (drag onto the iPod ↔ drop iPod covers here)

    private var libraryItems: [Album] {
        state.albums.filter { $0.source == .bandcamp || $0.localTracks != nil || $0.url != nil }
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("YOUR LIBRARY").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                Text("Drag an album onto the iPod  →").font(.system(size: 10)).foregroundStyle(p.muted2)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Space.s4)],
                          alignment: .leading, spacing: Space.s5) {
                    ForEach(libraryItems) { album in
                        let canCopy = album.hasLocalFiles || album.url != nil
                        VStack(alignment: .leading, spacing: 4) {
                            AlbumArt(album: album)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                            Text(album.title).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(p.text).lineLimit(1)
                            Text(album.artist).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1)
                        }
                        .opacity(canCopy ? 1 : 0.45)
                        .help(canCopy ? "Drag onto the iPod to add it" : "Download this album first to copy it")
                        .draggable("app:\(album.id.uuidString)")
                        .appContextMenu { libraryMenu(album) }
                    }
                }
                .padding(.bottom, Space.s4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(Space.s4)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(p.glassFill.opacity(libTargeted ? 1 : 0.45)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(libTargeted ? p.accent : p.edgeSoft, lineWidth: libTargeted ? 2 : 1))
        .animation(.easeInOut(duration: 0.12), value: libTargeted)
        // Drop an iPod cover here → import it into the library.
        .dropDestination(for: String.self) { items, _ in
            let ids = Set(items.filter { $0.hasPrefix("ipod:") }
                .compactMap { UUID(uuidString: String($0.dropFirst(5))) })
            let groups = albums.filter { ids.contains($0.id) }
                .map { (title: $0.title, artist: $0.artist, tracks: $0.tracks) }
            guard !groups.isEmpty else { return false }
            state.downloadFromIPod(groups, device: device)
            return true
        } isTargeted: { libTargeted = $0 }
    }

    /// Right-click actions on a "Your Library" album.
    private func libraryMenu(_ album: Album) -> [AppMenuItem] {
        var items: [AppMenuItem] = []
        if album.canDownload {
            items.append(AppMenuItem(title: "Download", systemImage: "square.and.arrow.down") {
                state.download(album)
            })
        }
        if album.hasLocalFiles || album.url != nil {
            items.append(AppMenuItem(title: "Add to iPod", systemImage: "arrow.down.circle") {
                state.addToIPod([album.id], device: device)
            })
        }
        return items
    }

    // MARK: - Device area (drop an album here → add to iPod)

    private var deviceArea: some View {
        GeometryReader { geo in
            // Fill the right half; capped so it never gets huge on a big display.
            let w = min(geo.size.width * 0.62, geo.size.height * 0.56, 500)
            device(width: w)
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .center) {
                    if deviceTargeted {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(p.accent, lineWidth: 2)
                            .frame(width: w + 16, height: w * 1.7 + 16)
                            .allowsHitTesting(false)
                    }
                }
        }
        .dropDestination(for: String.self) { items, _ in
            let ids = Set(items.filter { $0.hasPrefix("app:") }
                .compactMap { UUID(uuidString: String($0.dropFirst(4))) })
            guard !ids.isEmpty else { return false }
            state.addToIPod(ids, device: device)
            return true
        } isTargeted: { deviceTargeted = $0 }
    }

    // MARK: - Device shell

    private func device(width w: CGFloat) -> some View {
        let h = w * 1.7
        let screenW = w * 0.82
        let screenH = screenW * 0.75
        let wheelD = w * 0.6
        return VStack(spacing: 0) {
            screenBezel(width: screenW, height: screenH)
                .padding(.top, w * 0.09)
            Spacer(minLength: 0)
            clickWheel(diameter: wheelD)
                .padding(.bottom, w * 0.1)
        }
        .frame(width: w, height: h)
        .background(deviceBody(width: w))
        .clipShape(RoundedRectangle(cornerRadius: w * 0.11, style: .continuous))
        // A single thin edge line so the metal has a crisp border — no bright top-to-bottom
        // chamfer, which is what made the slab read as a pillow rather than a flat face.
        .overlay(
            RoundedRectangle(cornerRadius: w * 0.11, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        // Layered shadow: a soft ambient one + a tight contact one → the slab sits above the surface.
        .shadow(color: .black.opacity(0.5), radius: 46, y: 28)
        .shadow(color: .black.opacity(0.35), radius: 9, y: 5)
    }

    private func deviceBody(width w: CGFloat) -> some View {
        // Anodised aluminium in the chosen colour, shaded as a FLAT face under diffuse light: a
        // gentle top→bottom base gradient and only a whisper of edge shading. Deliberately no strong
        // specular bands or side roll — those made the slab look like a rounded pillow.
        ZStack {
            LinearGradient(colors: skin.body, startPoint: .top, endPoint: .bottom)
            // Faint edge darkening at the very sides so the flat face still has a defined border,
            // without the bright catch-light that curved it.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.16), location: 0.0),
                .init(color: .clear,               location: 0.10),
                .init(color: .clear,               location: 0.90),
                .init(color: .black.opacity(0.16), location: 1.0),
            ], startPoint: .leading, endPoint: .trailing)
        }
    }

    private func screenBezel(width: CGFloat, height: CGFloat) -> some View {
        screenContent(size: CGSize(width: width, height: height))
            .frame(width: width, height: height)
            .background(Color(white: 0.97))
            // Glass sheen across the top of the display + a faint inner shadow at its edge.
            .overlay(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04), .clear],
                               startPoint: .top, endPoint: .center)
                    .allowsHitTesting(false)
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.black.opacity(0.18), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(7)
            // Recessed black bezel: dark fill with a highlighted lower lip so the glass sits inset.
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.black.opacity(0.6), .white.opacity(0.10)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.55), radius: 7, y: 2)
    }

    // MARK: - Screen content router

    @ViewBuilder
    private func screenContent(size: CGSize) -> some View {
        if transfer.active {
            transferScreen(size: size)
        } else {
            switch screen {
            case .menu: menuScreen(size: size)
            case .coverflow: coverflowScreen(size: size)
            case .tracklist(let album): tracklistScreen(album, size: size)
            case .nowPlaying: nowPlayingScreen(size: size)
            case .about: aboutScreen(size: size)
            }
        }
    }

    // MARK: Menu OS

    private func menuScreen(size: CGSize) -> some View {
        VStack(spacing: 0) {
            statusBar(title: menuTitle(nav.last ?? .root), size: size)
            if pageRows.isEmpty {
                Spacer()
                Text("Nothing here").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Identify rows by position, not by MenuRow.id (a fresh UUID each
                            // rebuild) — otherwise every navigation looks like a full remove+insert
                            // and briefly shows the old page concatenated with the new one.
                            ForEach(Array(pageRows.enumerated()), id: \.offset) { i, row in
                                menuRow(row, selected: i == menuSel).id(i)
                            }
                        }
                    }
                    .onChange(of: menuSel) { _, v in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(v, anchor: .center) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menuRow(_ row: MenuRow, selected: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.label).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                if let sub = row.sub, !sub.isEmpty {
                    Text(sub).font(.system(size: 9)).opacity(0.7).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if row.chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
        }
        .foregroundStyle(selected ? Color.white : navy)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background { if selected { highlight } else { Color.clear } }
    }

    // MARK: About (Extras ▸ About)

    private func aboutScreen(size: CGSize) -> some View {
        let songs = albums.reduce(0) { $0 + $1.tracks.count }
        let artists = Set(albums.map(\.artist).filter { !$0.isEmpty }).count
        let plays = albums.flatMap { $0.tracks }.reduce(0) { $0 + $1.playCount }
        return VStack(spacing: 0) {
            statusBar(title: "About", size: size)
            ScrollView {
                VStack(spacing: 0) {
                    aboutRow("Capacity", byteString(device.totalBytes))
                    aboutRow("Available", byteString(device.freeBytes))
                    aboutRow("Songs", "\(songs)")
                    aboutRow("Albums", "\(albums.count)")
                    aboutRow("Artists", "\(artists)")
                    aboutRow("Plays", "\(plays)")
                    if let s = device.serial { aboutRow("Serial Number", s) }
                    aboutRow("Model", "iPod")
                    aboutRow("Format", "Mac (HFS+)")
                }
                .padding(.vertical, 3)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func aboutRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(navy.opacity(0.55))
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(navy)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(navy.opacity(0.12)), alignment: .bottom)
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func menuTitle(_ id: MenuID) -> String {
        switch id {
        case .root: return device.name
        case .music: return "Music"
        case .artists: return "Artists"
        case .albumsList: return "Albums"
        case .songs: return "Songs"
        case .artist(let n): return n
        case .extras: return "Extras"
        }
    }

    private func rows(for id: MenuID) -> [MenuRow] {
        switch id {
        case .root:
            var r = [MenuRow(label: "Music", chevron: true, action: .push(.music)),
                     MenuRow(label: "Cover Flow", chevron: true, action: .coverflow)]
            r.append(MenuRow(label: "Extras", chevron: true, action: .push(.extras)))
            if player.current != nil { r.append(MenuRow(label: "Now Playing", chevron: true, action: .nowPlaying)) }
            r.append(MenuRow(label: "Shuffle Songs", action: .shuffleAll))
            return r
        case .music:
            return [MenuRow(label: "Artists", chevron: true, action: .push(.artists)),
                    MenuRow(label: "Albums", chevron: true, action: .push(.albumsList)),
                    MenuRow(label: "Songs", chevron: true, action: .push(.songs))]
        case .extras:
            return [MenuRow(label: "About", chevron: true, action: .about)]
        case .artists:
            let names = Array(Set(albums.map(\.artist))).filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return names.map { MenuRow(label: $0, chevron: true, action: .push(.artist($0))) }
        case .artist(let name):
            return albums.filter { $0.artist == name }
                .map { MenuRow(label: $0.title, chevron: true, action: .openAlbum($0)) }
        case .albumsList:
            return albums.map { MenuRow(label: $0.title, sub: $0.artist, chevron: true, action: .openAlbum($0)) }
        case .songs:
            return albums.flatMap { $0.tracks }.enumerated()
                .map { i, t in MenuRow(label: t.title, sub: t.artist, action: .playFlat(i)) }
        }
    }

    // MARK: Cover Flow

    private func coverflowScreen(size: CGSize) -> some View {
        VStack(spacing: 0) {
            statusBar(title: "Cover Flow", size: size)
            if albums.isEmpty {
                Spacer()
                Text("No albums on this iPod.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                GeometryReader { g in
                    ZStack {
                        // Farthest covers first so nearer ones paint on top (the overlap look).
                        ForEach(Array(albums.enumerated()), id: \.element.id) { i, album in
                            let o = Double(i) - position
                            if abs(o) <= 4.5 {
                                coverflowCover(album, offset: o, area: g.size)
                            }
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
                }
                VStack(spacing: 1) {
                    Text(albums[selectedIndex].title)
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(navy).lineLimit(1)
                    Text(albums[selectedIndex].artist)
                        .font(.system(size: 11)).foregroundStyle(navy.opacity(0.8)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
    }

    private func coverflowCover(_ album: IPodAlbum, offset o: Double, area: CGSize) -> some View {
        // Flat center cover with breathing room top/bottom; siblings tilt ~64° (center-anchored so
        // each stays a distinct sliver) and step OUT with real spacing so they fan to the screen
        // edges instead of piling up in the middle.
        let side = min(area.height * 0.6, area.width * 0.4)
        let a = abs(o)
        let sign: CGFloat = o == 0 ? 0 : (o > 0 ? 1 : -1)
        let rot: Double = o == 0 ? 0 : -Double(sign) * 64
        let x = area.width / 2 + sign * (side * 0.52 + CGFloat(max(0, a - 1)) * side * 0.34)
        let scale = o == 0 ? 1.0 : max(0.74, 0.9 - CGFloat(a - 1) * 0.05)
        return CoverFlowArt(album: album, artDB: artDB, side: side)
            .draggable("ipod:\(album.id.uuidString)") { dragPreview(album) }
            .appContextMenu { coverMenu(album) }
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(rot), axis: (x: 0, y: 1, z: 0),
                              perspective: 0.7)
            .position(x: x, y: area.height * 0.43)
            .zIndex(2 - a)
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: position)
    }

    /// Right-click actions on a Cover Flow album.
    private func coverMenu(_ album: IPodAlbum) -> [AppMenuItem] {
        [
            AppMenuItem(title: "Play", systemImage: "play.fill") { playAlbum(album, from: 0) },
            AppMenuItem(title: "Download to library", systemImage: "square.and.arrow.down") {
                state.downloadFromIPod([(album.title, album.artist, album.tracks)], device: device)
            },
            AppMenuItem(title: "Remove from iPod", systemImage: "trash", role: .destructive, holdToConfirm: true) {
                state.removeFromIPod(album.tracks, device: device)
            },
        ]
    }

    /// The drag image while pulling a cover off the iPod — the album's REAL cover (read straight
    /// from the shared cache so it's the actual art, not a placeholder), flat.
    @ViewBuilder private func dragPreview(_ album: IPodAlbum) -> some View {
        if let img = IPodCoverCache.shared.cached(album) {
            Image(nsImage: img).resizable().scaledToFill()
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            iPodPlaceholderCover(album.title + album.artist)
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // MARK: Track list

    private func tracklistScreen(_ album: IPodAlbum, size: CGSize) -> some View {
        VStack(spacing: 0) {
            statusBar(title: album.title, size: size)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                            trackRow(index: i, title: t.title).id(i)
                        }
                    }
                }
                .onChange(of: trackSel) { _, v in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(v, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private func trackRow(index i: Int, title: String) -> some View {
        let on = i == trackSel
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
            Spacer()
            if on { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
        }
        .foregroundStyle(on ? Color.white : navy)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background { if on { highlight } else { Color.clear } }
    }

    // MARK: Now Playing (mirrors the real device)

    private func nowPlayingScreen(size: CGSize) -> some View {
        let t = player.current
        let n = player.queue.count
        return VStack(spacing: 0) {
            statusBar(title: "Now Playing", size: size, playing: true)
            HStack(alignment: .top, spacing: 10) {
                NowPlayingArt(album: playingAlbum, artDB: artDB, side: size.height * 0.34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t?.title ?? "—").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(navy).lineLimit(2)
                    Text(t?.artist ?? "").font(.system(size: 11)).foregroundStyle(navy.opacity(0.75)).lineLimit(1)
                    Text(playingAlbum?.title ?? "").font(.system(size: 11)).foregroundStyle(navy.opacity(0.75)).lineLimit(1)
                    Spacer().frame(height: 8)
                    Text("\(player.index + 1) of \(max(n, 1))")
                        .font(.system(size: 11)).foregroundStyle(navy.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 10)
            Spacer()
            progressPill(size: size).padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private func progressPill(size: CGSize) -> some View {
        let frac: Double = clock.duration > 0 ? clock.time / clock.duration : 0
        return VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.82))
                        .overlay(Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    filledPill.frame(width: max(6, g.size.width * CGFloat(frac)))
                }
            }
            .frame(height: 11)
            HStack {
                Text(clock.time.mmss).font(.system(size: 10, design: .rounded)).foregroundStyle(navy.opacity(0.8))
                Spacer()
                Text("-" + max(0, clock.duration - clock.time).mmss)
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(navy.opacity(0.8))
            }
        }
    }

    /// The glossy blue fill of the progress capsule (its own view so the type-checker stays fast).
    private var filledPill: some View {
        let gloss = LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
        return Capsule()
            .fill(highlight)
            .overlay(Capsule().fill(gloss).padding(0.5))
    }

    // MARK: Transfer feedback

    private func transferScreen(size: CGSize) -> some View {
        VStack(spacing: 0) {
            statusBar(title: transfer.kind.verb, size: size)
            Spacer()
            if let outcome = transfer.outcome {
                VStack(spacing: 10) {
                    Image(systemName: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(outcome.ok ? Color(red: 0.16, green: 0.6, blue: 0.24) : .orange)
                    Text(outcome.message).font(.system(size: 11)).foregroundStyle(navy)
                        .multilineTextAlignment(.center).padding(.horizontal, 18)
                    Text("Press the centre button").font(.system(size: 9)).foregroundStyle(navy.opacity(0.5))
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: transfer.kind == .importing ? "square.and.arrow.down" : "arrow.down.to.line")
                        .font(.system(size: 26)).foregroundStyle(navy.opacity(0.8))
                    if !transfer.title.isEmpty {
                        Text(transfer.title).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(navy).lineLimit(1).padding(.horizontal, 18)
                    }
                    if let frac = transfer.fraction {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(white: 0.82))
                                Capsule().fill(highlight).frame(width: max(4, g.size.width * frac))
                            }
                        }
                        .frame(height: 8).padding(.horizontal, 30)
                        Text("\(transfer.loaded) of \(transfer.total)")
                            .font(.system(size: 10)).foregroundStyle(navy.opacity(0.7))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: Status bar

    private func statusBar(title: String, size: CGSize, playing: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(navy).lineLimit(1)
            Spacer()
            if playing {
                Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 9)).foregroundStyle(navy.opacity(0.7))
            }
            batteryGlyph
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            LinearGradient(colors: [Color(white: 1.0), Color(white: 0.85)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.black.opacity(0.25)), alignment: .bottom)
    }

    private var batteryGlyph: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(navy.opacity(0.75), lineWidth: 1)
                .frame(width: 16, height: 9)
                .overlay(
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color(red: 0.3, green: 0.78, blue: 0.35))
                        .padding(1.5)
                )
            RoundedRectangle(cornerRadius: 0.5).fill(navy.opacity(0.75)).frame(width: 1.5, height: 4)
        }
    }

    // MARK: - Click wheel

    private func clickWheel(diameter d: CGFloat) -> some View {
        ZStack {
            // Flat, matte wheel: a barely-there top→bottom gradient (diffuse light on a flat disc),
            // NOT a radial dome, and no drop shadow — the wheel sits flush in the face, it doesn't
            // float above it. A thin inner line reads as the recessed groove around the wheel.
            Circle()
                .fill(LinearGradient(colors: skin.wheel.reversed(),
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(skin.ink.opacity(0.10), lineWidth: 1))
                .overlay(Circle().strokeBorder(.black.opacity(0.22), lineWidth: 1).padding(0.5))
            // Rotational scrub over the ring (below the buttons).
            Circle().fill(Color.white.opacity(0.001))
                .gesture(ringDrag(diameter: d))
            // Edge buttons — the glyph IS the button, so pressing lights it up + depresses it.
            wheelEdge(menuAction, size: CGSize(width: d * 0.42, height: d * 0.26))
                { Text("MENU").font(.system(size: 11, weight: .bold)).kerning(1) }
                .offset(y: -d * 0.36)
            wheelEdge(prevAction, size: CGSize(width: d * 0.26, height: d * 0.42))
                { Image(systemName: "backward.end.fill").font(.system(size: d * 0.07)) }
                .offset(x: -d * 0.36)
            wheelEdge(nextAction, size: CGSize(width: d * 0.26, height: d * 0.42))
                { Image(systemName: "forward.end.fill").font(.system(size: d * 0.07)) }
                .offset(x: d * 0.36)
            wheelEdge({ IPodClick.shared.click(); player.toggle() }, size: CGSize(width: d * 0.42, height: d * 0.26))
                { Image(systemName: "playpause.fill").font(.system(size: d * 0.07)) }
                .offset(y: d * 0.36)
            // Centre button — sinks in on press.
            Button(action: centerAction) {
                // Flat centre button, a hair darker than the ring, ringed by a thin groove — flush,
                // not a raised dome.
                Circle()
                    .fill(LinearGradient(colors: skin.wheel.reversed(),
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().fill(.black.opacity(0.10)))
                    .overlay(Circle().strokeBorder(.black.opacity(0.28), lineWidth: 1))
                    .frame(width: d * 0.38, height: d * 0.38)
                    .contentShape(Circle())
            }
            .buttonStyle(WheelCenterStyle(reduceMotion: reduceMotion))
        }
        .frame(width: d, height: d)
    }

    private func wheelEdge<L: View>(_ action: @escaping () -> Void, size: CGSize,
                                    @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(skin.ink.opacity(0.6))
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(WheelButtonStyle(reduceMotion: reduceMotion))
    }

    private func ringDrag(diameter d: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                let c = CGPoint(x: d / 2, y: d / 2)
                let a = atan2(Double(v.location.y - c.y), Double(v.location.x - c.x))
                if let last = wheelAngle {
                    var delta = a - last
                    if delta > .pi { delta -= 2 * .pi }
                    if delta < -.pi { delta += 2 * .pi }
                    scroll(by: delta / (.pi / 6))   // ~30° per step
                }
                wheelAngle = a
            }
            .onEnded { _ in
                wheelAngle = nil
                scrollAccum = 0
                if screen == .coverflow {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                        position = Double(selectedIndex)
                    }
                }
            }
    }

    // MARK: - Actions

    private func scroll(by steps: Double) {
        switch screen {
        case .menu:
            // The list is discrete, so accumulate the small per-event rotation and step by whole
            // rows as it crosses each threshold — otherwise tiny deltas round to 0 and never move.
            let d = steppedDelta(steps)
            if d != 0 {
                let before = menuSel
                menuSel = max(0, min(pageRows.count - 1, menuSel + d))
                if menuSel != before { IPodClick.shared.click() }
            }
        case .coverflow:
            let before = selectedIndex
            position = max(0, min(Double(albums.count - 1), position + steps))
            if selectedIndex != before { IPodClick.shared.click() }
        case .tracklist(let album):
            let d = steppedDelta(steps)
            if d != 0 {
                let before = trackSel
                trackSel = max(0, min(album.tracks.count - 1, trackSel + d))
                if trackSel != before { IPodClick.shared.click() }
            }
        case .nowPlaying, .about:
            break
        }
    }

    /// Accumulates fractional wheel rotation and yields whole-row steps once |accum| ≥ 1, so the
    /// rotational drag scrolls discrete lists (menus, tracklists) the same way it flips covers.
    private func steppedDelta(_ steps: Double) -> Int {
        scrollAccum += steps
        var d = 0
        while scrollAccum >= 1 { d += 1; scrollAccum -= 1 }
        while scrollAccum <= -1 { d -= 1; scrollAccum += 1 }
        return d
    }

    private func centerAction() {
        IPodClick.shared.click()
        switch screen {
        case .menu:
            if pageRows.indices.contains(menuSel) { activate(pageRows[menuSel].action) }
        case .coverflow:
            guard albums.indices.contains(selectedIndex) else { return }
            trackSel = 0
            withScreen(.tracklist(albums[selectedIndex]))
        case .tracklist(let album):
            playAlbum(album, from: trackSel)
        case .nowPlaying:
            if transfer.outcome != nil { transfer.dismiss() } else { player.toggle() }
        case .about:
            withScreen(.menu)
        }
        // The transfer result screen dismisses on centre regardless of the underlying screen.
        if transfer.outcome != nil { transfer.dismiss() }
    }

    private func menuAction() {
        IPodClick.shared.click()
        if transfer.active { return }
        switch screen {
        case .menu: menuBack()
        case .coverflow: withScreen(.menu)
        case .tracklist: withScreen(.menu)
        case .about: withScreen(.menu)
        case .nowPlaying:
            if let a = playingAlbum { withScreen(.tracklist(a)) } else { withScreen(.menu) }
        }
    }

    private func prevAction() {
        IPodClick.shared.click()
        switch screen {
        case .menu: menuSel = max(0, menuSel - 1)
        case .coverflow:
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
                position = max(0, Double(selectedIndex - 1))
            }
        case .tracklist: trackSel = max(0, trackSel - 1)
        case .nowPlaying: player.prev()
        case .about: break
        }
    }

    private func nextAction() {
        IPodClick.shared.click()
        switch screen {
        case .menu: menuSel = min(pageRows.count - 1, menuSel + 1)
        case .coverflow:
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
                position = min(Double(albums.count - 1), Double(selectedIndex + 1))
            }
        case .tracklist(let album): trackSel = min(album.tracks.count - 1, trackSel + 1)
        case .nowPlaying: player.next()
        case .about: break
        }
    }

    // MARK: Menu navigation

    private func activate(_ action: MenuAction) {
        switch action {
        case .push(let id):
            scrollAccum = 0
            selStack.append(menuSel); menuSel = 0; nav.append(id)   // onChange(nav) rebuilds pageRows
        case .openAlbum(let a):
            trackSel = 0; withScreen(.tracklist(a))
        case .playFlat(let i):
            playAll(startAt: i, shuffle: false)
        case .coverflow:
            withScreen(.coverflow)
        case .nowPlaying:
            if player.current != nil { withScreen(.nowPlaying) }
        case .about:
            withScreen(.about)
        case .shuffleAll:
            playAll(startAt: 0, shuffle: true)
        }
    }

    private func menuBack() {
        scrollAccum = 0
        // At the root menu, MENU does nothing (like a real iPod). Leaving Classic is done with the
        // header's Albums/Sync/Classic toggle, so MENU never yanks you back to the grid.
        guard nav.count > 1 else { return }
        menuSel = selStack.popLast() ?? 0
        nav.removeLast()   // onChange(nav) rebuilds pageRows
    }

    private func playAll(startAt: Int, shuffle: Bool) {
        var flat = albums.flatMap { $0.tracks }
        guard !flat.isEmpty else { return }
        var start = max(0, min(startAt, flat.count - 1))
        let startTrack = flat[start]
        if shuffle { flat.shuffle(); start = 0 }
        let ts = tracks(from: flat)
        guard !ts.isEmpty else { return }
        playingAlbum = albums.first { $0.tracks.contains { $0.id == startTrack.id } }
        player.play(ts, startAt: min(start, ts.count - 1))
        withScreen(.nowPlaying)
    }

    private func tracks(from list: [IPodTrack]) -> [Track] {
        list.compactMap { t in
            guard let url = fileURL(t.location) else { return nil }
            return Track(title: t.title, artist: t.artist, streamURL: url)
        }
    }

    private func playAlbum(_ album: IPodAlbum, from start: Int) {
        let ts = tracks(from: album.tracks)
        guard !ts.isEmpty else { return }
        playingAlbum = album
        player.play(ts, startAt: min(start, ts.count - 1))
        withScreen(.nowPlaying)
    }

    private func withScreen(_ s: Screen) {
        scrollAccum = 0
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { screen = s }
    }

    /// ":iPod_Control:Music:F09:DVSI.mp3" → <volume>/iPod_Control/Music/F09/DVSI.mp3, guarded to the
    /// iPod's music tree so an odd DB entry can never resolve to an arbitrary host file.
    private func fileURL(_ location: String) -> URL? {
        let rel = String(location.drop(while: { $0 == ":" })).replacingOccurrences(of: ":", with: "/")
        guard rel.hasPrefix("iPod_Control/Music/") else { return nil }
        return device.volumeURL.appendingPathComponent(rel)
    }

    private let navy = Color(red: 0.16, green: 0.20, blue: 0.36)
    private let highlight = LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 0.98),
                                                    Color(red: 0.15, green: 0.42, blue: 0.90)],
                                           startPoint: .top, endPoint: .bottom)
}

// MARK: - Cover images (with reflection)

/// A single Cover Flow cover plus its mirrored reflection, loading the iPod's own art (else an
/// iTunes cover) once via `IPodCoverCache`.
private struct CoverFlowArt: View {
    let album: IPodAlbum
    let artDB: IPodArtworkDB?
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        face
            .overlay(alignment: .bottom) {
                // A mirrored reflection hanging just below the cover (a non-layout overlay so it
                // doesn't push the cover up).
                face
                    .scaleEffect(y: -1)
                    .mask(LinearGradient(colors: [.white.opacity(0.45), .clear],
                                         startPoint: .top, endPoint: .center))
                    .opacity(0.5)
                    .offset(y: side + 2)
            }
            .task {
                if let hit = IPodCoverCache.shared.cached(album) { image = hit }
                else { image = await IPodCoverCache.shared.image(album: album, artDB: artDB) }
            }
    }

    @ViewBuilder private var face: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                iPodPlaceholderCover(album.title + album.artist)
                    .overlay(Image(systemName: "music.note").font(.system(size: side * 0.22))
                        .foregroundStyle(.white.opacity(0.85)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

/// The album cover shown on the Now Playing screen.
private struct NowPlayingArt: View {
    let album: IPodAlbum?
    let artDB: IPodArtworkDB?
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                (album.map { iPodPlaceholderCover($0.title + $0.artist) }
                    ?? iPodPlaceholderCover("iPod"))
                    .overlay(Image(systemName: "music.note").font(.system(size: side * 0.24))
                        .foregroundStyle(.white.opacity(0.85)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
        .task {
            guard let album else { return }
            if let hit = IPodCoverCache.shared.cached(album) { image = hit }
            else { image = await IPodCoverCache.shared.image(album: album, artDB: artDB) }
        }
    }
}

/// Memoized cover loader shared across the iPod screens (replica *and* the normal grid / sync
/// panes) — the iPod's own artwork if present, else a crisp iTunes cover downloaded to an
/// `NSImage`. Caching the decoded image app-wide is the key Sync-mode perf fix: cells no longer
/// re-decode the `ithmb` thumbnail or re-download/re-allocate the cover every time they scroll
/// back into view. Keyed by album title+artist so the same album shares one image across the
/// grid, the sync panes, and the replica (whose `IPodAlbum` ids differ per reload).
@MainActor
final class IPodCoverCache {
    static let shared = IPodCoverCache()
    private var cache: [String: NSImage] = [:]
    private var misses: Set<String> = []          // albums we've looked up and found no art for

    private func key(_ album: IPodAlbum) -> String { "\(album.title)\u{1}\(album.artist)" }

    /// The already-decoded cover, if we have it — lets a cell show it instantly with no flash.
    func cached(_ album: IPodAlbum) -> NSImage? { cache[key(album)] }

    func image(album: IPodAlbum, artDB: IPodArtworkDB?) async -> NSImage? {
        let k = key(album)
        if let hit = cache[k] { return hit }
        if misses.contains(k) { return nil }      // don't re-hit the network for a known miss
        var img: NSImage?
        // Try EVERY track's own thumbnail (not just the first) — art often isn't stored for every
        // track, so checking only one misses covers the iPod actually has. First hit wins.
        if let artDB {
            for dbid in album.tracks.prefix(60).map(\.dbid) where dbid != 0 {
                if let px = await artDB.cover(forDBID: dbid) { img = iPodCoverImage(px); break }
            }
        }
        // Only then fall back to a (validated) iTunes cover; a bad match returns nil → placeholder.
        if img == nil, let u = await IPodArt.shared.coverURL(artist: album.artist, album: album.title),
           let (data, _) = try? await URLSession.shared.data(from: u) {
            img = NSImage(data: data)
        }
        if let img { cache[k] = img } else { misses.insert(k) }
        return img
    }
}

private extension Double {
    /// mm:ss for a time in seconds (safe for NaN/negatives).
    var mmss: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let s = Int(self)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Device skins

/// A colour finish for the replica iPod — body + click-wheel gradients and the ink colour used for
/// the wheel labels/glyphs (dark on light finishes, white on dark ones). Persisted per user.
enum IPodSkin: String, CaseIterable, Identifiable {
    case black, silver, blue, red
    var id: String { rawValue }

    var name: String {
        switch self {
        case .black: return "Black"
        case .silver: return "Silver"
        case .blue: return "Blue"
        case .red: return "(PRODUCT)RED"
        }
    }

    /// Body gradient, top → bottom.
    var body: [Color] {
        switch self {
        case .black:  return [Color(white: 0.18), Color(white: 0.10), Color(white: 0.05)]
        case .silver: return [Color(white: 0.93), Color(white: 0.82), Color(white: 0.70)]
        case .blue:   return [Color(red: 0.36, green: 0.60, blue: 0.90), Color(red: 0.20, green: 0.42, blue: 0.74), Color(red: 0.12, green: 0.27, blue: 0.52)]
        case .red:    return [Color(red: 0.86, green: 0.22, blue: 0.22), Color(red: 0.70, green: 0.13, blue: 0.13), Color(red: 0.50, green: 0.08, blue: 0.08)]
        }
    }

    /// Click-wheel radial gradient, inner → outer.
    var wheel: [Color] {
        switch self {
        case .black:  return [Color(white: 0.16), Color(white: 0.08)]
        case .silver: return [Color(white: 0.96), Color(white: 0.84)]
        case .blue:   return [Color(red: 0.52, green: 0.72, blue: 0.95), Color(red: 0.30, green: 0.50, blue: 0.80)]
        case .red:    return [Color(red: 0.92, green: 0.40, blue: 0.40), Color(red: 0.72, green: 0.20, blue: 0.20)]
        }
    }

    /// Ink for the wheel labels/glyphs — dark on light finishes, white on dark ones.
    var ink: Color {
        switch self {
        case .silver: return Color(white: 0.18)
        case .black, .blue, .red: return .white
        }
    }

    /// A representative solid colour for the picker swatch.
    var swatch: Color {
        switch self {
        case .black:  return Color(white: 0.12)
        case .silver: return Color(white: 0.85)
        case .blue:   return Color(red: 0.26, green: 0.50, blue: 0.84)
        case .red:    return Color(red: 0.80, green: 0.16, blue: 0.16)
        }
    }
}

// MARK: - Click-wheel press feedback

/// An edge wheel button: on press the glyph brightens, shrinks, and a soft glow blooms under it —
/// the tactile "click" feedback of a real wheel.
private struct WheelButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.6 : 0)
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .background {
                if configuration.isPressed {
                    Circle().fill(.white.opacity(0.14)).blur(radius: 9).scaleEffect(1.6)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.5),
                       value: configuration.isPressed)
    }
}

/// The centre button: sinks in (scales down + darkens) while held.
private struct WheelCenterStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .overlay {
                if configuration.isPressed {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 1).scaleEffect(0.96)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.5),
                       value: configuration.isPressed)
    }
}
