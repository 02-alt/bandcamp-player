import SwiftUI
import MapKit
import AppKit

/// A place on the collection map: one artist location, its coordinate, and the albums from there.
/// For the Friends source, `friends` are the followed fans who bought music from this place.
struct MapPlace: Identifiable {
    let id: String            // normalised location string
    let name: String          // display string ("Berlin, Germany")
    let coordinate: CLLocationCoordinate2D
    let country: String?
    let albums: [Album]
    var friends: [Friend] = []
}

@MainActor
enum CollectionGeo {
    /// The distinct artist-origin strings across the collection (from the cache), for geocoding.
    static func locationStrings(albums: [Album], loc: ArtistLocationStore) -> [String] {
        Array(Set(albums.compactMap { loc.location(forArtist: $0.artist) }))
    }

    /// Group the collection's located albums into map places, largest first. Reads each album's
    /// location from the artist cache (survives re-syncs); only places already geocoded appear.
    static func places(albums: [Album], loc: ArtistLocationStore, geo: GeoStore) -> [MapPlace] {
        var byKey: [String: (name: String, albums: [Album])] = [:]
        for a in albums {
            guard let place = loc.location(forArtist: a.artist), geo.point(for: place) != nil else { continue }
            byKey[GeoStore.key(place), default: (place, [])].albums.append(a)
        }
        return byKey.compactMap { key, v in
            guard let pt = geo.point(for: v.name) else { return nil }
            return MapPlace(id: key, name: v.name, coordinate: pt.coordinate,
                            country: pt.country, albums: v.albums)
        }
        .sorted { $0.albums.count > $1.albums.count }
    }

    /// Group friends' bought albums into map places, recording which friends contribute to
    /// each — so the Friends map can show their avatars on the pins.
    static func friendPlaces(_ perFriend: [(friend: Friend, albums: [Album])],
                             loc: ArtistLocationStore, geo: GeoStore) -> [MapPlace] {
        var byKey: [String: (name: String, albums: [Album], friends: [Int: Friend])] = [:]
        for (friend, albums) in perFriend {
            for a in albums {
                guard let place = loc.location(forArtist: a.artist), geo.point(for: place) != nil else { continue }
                let k = GeoStore.key(place)
                byKey[k, default: (place, [], [:])].albums.append(a)
                byKey[k, default: (place, [], [:])].friends[friend.id] = friend
            }
        }
        return byKey.compactMap { key, v in
            guard let pt = geo.point(for: v.name) else { return nil }
            return MapPlace(id: key, name: v.name, coordinate: pt.coordinate, country: pt.country,
                            albums: v.albums, friends: Array(v.friends.values))
        }
        .sorted { $0.albums.count > $1.albums.count }
    }

    /// The country with the most albums, and how many, across geocoded albums.
    static func topCountry(albums: [Album], loc: ArtistLocationStore, geo: GeoStore) -> (name: String, count: Int)? {
        var counts: [String: Int] = [:]
        for a in albums {
            guard let place = loc.location(forArtist: a.artist), let c = geo.point(for: place)?.country else { continue }
            counts[c, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

// MARK: - Settings stat card

/// A compact "top country" tile in the listening-stats card that opens the full collection map.
struct MapStatCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var geo = GeoStore.shared
    @ObservedObject private var loc = ArtistLocationStore.shared
    @Environment(\.palette) private var p

    private var located: [Album] { state.albums.filter { loc.location(forArtist: $0.artist) != nil } }

    var body: some View {
        let top = CollectionGeo.topCountry(albums: state.albums, loc: loc, geo: geo)
        let placeCount = CollectionGeo.places(albums: state.albums, loc: loc, geo: geo).count

        Button { withAnimation(.easeInOut(duration: 0.25)) { state.mapOpen = true } } label: {
            HStack(spacing: Space.s4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.page.opacity(0.5))
                    Image(systemName: "globe.europe.africa.fill").font(.system(size: 22))
                        .foregroundStyle(p.muted)
                }
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text("TOP COUNTRY").font(.system(size: 10, weight: .bold)).kerning(1.2)
                        .foregroundStyle(p.muted2)
                    Text(top?.name ?? (located.isEmpty ? "—" : "Mapping…"))
                        .font(.system(size: 22, weight: .bold, design: .rounded)).kerning(-0.4)
                        .foregroundStyle(p.text).lineLimit(1).minimumScaleFactor(0.7)
                    Text(subtitle(top: top, places: placeCount))
                        .font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(p.muted2)
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.page.opacity(0.5)))
            .hoverHighlight(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
        .help("See where your collection comes from")
        // Geocode any not-yet-resolved locations so the card + map fill in.
        .task(id: loc.map.count) { await geo.resolve(CollectionGeo.locationStrings(albums: state.albums, loc: loc)) }
    }

    private func subtitle(top: (name: String, count: Int)?, places: Int) -> String {
        guard top != nil else {
            return located.isEmpty ? "No locations yet — sync your collection" : "Locating artists…"
        }
        return "\(top!.count) album\(top!.count == 1 ? "" : "s") · \(places) place\(places == 1 ? "" : "s")"
    }
}

// MARK: - Full map

/// Which slice of music the collection map plots: your owned library, your wishlist, or the
/// combined collections of the friends you follow.
enum MapSource: String, CaseIterable, Identifiable {
    case owned, wishlist, friends
    var id: String { rawValue }
    var label: String {
        switch self {
        case .owned: return "Owned"
        case .wishlist: return "Wishlist"
        case .friends: return "Friends"
        }
    }
}

/// A world map with a marker per artist location; tap one to see the albums from there.
struct CollectionMapView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var geo = GeoStore.shared
    @ObservedObject private var loc = ArtistLocationStore.shared
    @Environment(\.palette) private var p

    @State private var selected: MapPlace?
    @State private var expandedAlbum: UUID?
    @State private var source: MapSource = .owned
    @State private var listExpanded = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var collapsedFriends: Set<Int> = []
    @State private var resolving = false
    // The visible map's vertical span (degrees), used to size the clustering grid. Starts at a
    // world-ish value so the first paint clusters heavily; updated as the camera settles.
    @State private var zoomSpan: Double = 120
    @Namespace private var seg

    // Building the map places (dictionary over every album) is too heavy to redo on every render —
    // the map re-renders constantly during camera moves, hover, selection springs, and each ~1.3s
    // geocoding publish. Compute once into these caches, refreshed only when the data changes.
    @State private var cachedPlaces: [MapPlace] = []
    @State private var cachedFriendGroups: [FriendGroup] = []
    @State private var cachedFriendsByAlbum: [UUID: [Friend]] = [:]
    @State private var cachedSourceCount = 0

    typealias FriendGroup = (friend: Friend, rows: [(album: Album, place: MapPlace)])

    /// The albums feeding the map for the chosen source. Friends are the union of every loaded
    /// friend collection *and* wishlist, deduped by id.
    private func albums(for source: MapSource) -> [Album] {
        switch source {
        case .owned: return state.albums
        case .wishlist: return state.wishlist
        case .friends:
            // Only what friends actually bought (their collection) — not their wishlist.
            var seen = Set<UUID>(); var out: [Album] = []
            for items in state.friendColl.values {
                for a in items.albums where seen.insert(a.id).inserted { out.append(a) }
            }
            return out
        }
    }

    /// Each followed friend paired with the albums they bought (their collection, deduped).
    private var perFriendAlbums: [(friend: Friend, albums: [Album])] {
        state.friends.compactMap { f in
            let owned = state.friendColl[f.id]?.albums ?? []
            var seen = Set<UUID>(); var albs: [Album] = []
            for a in owned where seen.insert(a.id).inserted { albs.append(a) }
            return albs.isEmpty ? nil : (f, albs)
        }
    }

    private var sourceAlbums: [Album] { albums(for: source) }
    private var places: [MapPlace] { cachedPlaces }

    /// A cheap fingerprint of everything the caches depend on. Rebuild only when it changes, so
    /// renders during animation don't rebuild the (expensive) place dictionaries.
    private var dataSignature: String {
        let friendItems = state.friendColl.reduce(0) { $0 + $1.value.albums.count }
        return "\(source.rawValue)|\(loc.map.count)|\(geo.map.count)|\(state.albums.count)|\(state.wishlist.count)|\(friendItems)"
    }

    /// Recompute the place/group caches from the current source. Runs only when `dataSignature`
    /// changes (source switch, new geocode, page load), never mid-animation.
    private func rebuildCaches() {
        let ps = source == .friends
            ? CollectionGeo.friendPlaces(perFriendAlbums, loc: loc, geo: geo)
            : CollectionGeo.places(albums: sourceAlbums, loc: loc, geo: geo)
        cachedPlaces = ps
        cachedSourceCount = sourceAlbums.count
        guard source == .friends else { cachedFriendGroups = []; cachedFriendsByAlbum = [:]; return }
        let placeByKey = Dictionary(ps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Who bought each album — so a place panel can label every row with its owner(s).
        var byAlbum: [UUID: [Friend]] = [:]
        for (friend, albums) in perFriendAlbums {
            for a in albums where !(byAlbum[a.id]?.contains { $0.id == friend.id } ?? false) {
                byAlbum[a.id, default: []].append(friend)
            }
        }
        cachedFriendsByAlbum = byAlbum
        cachedFriendGroups = perFriendAlbums.compactMap { friend, albums in
            let rows: [(album: Album, place: MapPlace)] = albums.compactMap { a in
                guard let s = loc.location(forArtist: a.artist), let pl = placeByKey[GeoStore.key(s)] else { return nil }
                return (a, pl)
            }
            return rows.isEmpty ? nil : (friend, rows)
        }
        .sorted { $0.friend.name.localizedCaseInsensitiveCompare($1.friend.name) == .orderedAscending }
    }

    var body: some View {
        // Group nearby places into clusters sized to the current zoom, so ~200 city pins don't
        // pile up at world view. Zooming in shrinks the grid, splitting clusters into finer places.
        let clustered = clusters(places, cellDeg: max(0.02, zoomSpan / 6))
        let maxCount = max(1, clustered.map(\.albumCount).max() ?? 1)
        // Full-window page: the map fills everything, edge to edge; the header + place panel float
        // over it in liquid glass.
        ZStack(alignment: .top) {
            Map(position: $camera) {
                ForEach(clustered) { cluster in
                    if let place = cluster.single {
                        Annotation(place.name, coordinate: place.coordinate) {
                            Button { fly(to: place) } label: { marker(place, peak: maxCount) }
                                .buttonStyle(.soft(hover: 1.18, press: 0.92, brighten: 0.08))
                        }
                    } else {
                        Annotation("", coordinate: cluster.coordinate) {
                            Button { openCluster(cluster) } label: { clusterMarker(cluster, peak: maxCount) }
                                .buttonStyle(.soft(hover: 1.18, press: 0.92, brighten: 0.08))
                        }
                    }
                }
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                let d = ctx.region.span.latitudeDelta
                if d.isFinite, d > 0 { zoomSpan = d }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            // Force the map dark + palette-tinted so it reads as part of the app, not Apple Maps.
            .preferredColorScheme(.dark)
            .tint(p.accent)
            .overlay(p.page.opacity(0.18).allowsHitTesting(false))
            .ignoresSafeArea()

            header
                .padding(.horizontal, Space.s4)
                .padding(.top, 40)          // clear the window's traffic-light controls
                .frame(maxWidth: .infinity, alignment: .leading)

            if let place = selected {
                placePanel(place)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, Space.s5)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(p.page)
        .background(   // Escape closes the map.
            Button("") { close() }.keyboardShortcut(.escape, modifiers: []).hidden()
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selected?.id)
        .onChange(of: selected?.id) { _, _ in expandedAlbum = nil }
        // Switching source clears the old selection and reframes the map on the new pins.
        .onChange(of: source) { _, _ in
            selected = nil
            withAnimation(.easeInOut(duration: 0.5)) { camera = .automatic }
        }
        // Load the chosen source (wishlist / friend collections), resolve any new artist origins,
        // and geocode them. Re-runs — and cancels the previous — whenever the source changes.
        .task(id: source) { await prepare(source) }
        // Rebuild the place caches only when the underlying data changes — not on every render.
        .onAppear { rebuildCaches(); applyMapFocus() }
        .onChange(of: dataSignature) { _, _ in rebuildCaches(); applyMapFocus() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Button { close() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                        .frame(width: 36, height: 36).background(Circle().fill(p.glassFill))
                        .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                }.buttonStyle(.soft).tip("Back")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collection map").font(.system(size: 18, weight: .bold)).foregroundStyle(p.text)
                    HStack(spacing: Space.s2) {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(p.muted)
                        if resolving { OrbLoader(size: 12) }
                    }
                }
                Spacer(minLength: Space.s4)
                // Deploy the full album list; tapping an album flies the map to its place.
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { listExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(p.text)
                        .rotationEffect(.degrees(listExpanded ? 180 : 0))
                        .frame(width: 36, height: 36).background(Circle().fill(p.glassFill))
                        .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                }.buttonStyle(.soft).tip(listExpanded ? "Hide albums" : "Show all albums")
            }
            sourcePicker
            if listExpanded { albumList }
        }
        .padding(Space.s4)
        .frame(width: 340, alignment: .leading)
        // Liquid-glass floating bar over the map.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    /// The chevron-deployed list. For Owned/Wishlist it's a flat list of located albums; for
    /// Friends it's grouped under each friend (avatar + name + collapse chevron). Tapping an album
    /// flies the map to its place; the Friends list ends with a 20-at-a-time "Load more" spinner.
    private var albumList: some View {
        VStack(spacing: Space.s2) {
            Divider().overlay(p.edgeSoft)
            if source == .friends {
                if friendGroups.isEmpty { emptyListLabel } else { friendGroupedList }
            } else {
                if locatedAlbums.isEmpty { emptyListLabel } else { flatAlbumList }
            }
        }
    }

    private var emptyListLabel: some View {
        Text("No located albums yet").font(.system(size: 12)).foregroundStyle(p.muted2)
            .frame(maxWidth: .infinity).padding(.vertical, Space.s3)
    }

    private var flatAlbumList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(locatedAlbums, id: \.album.id) { row in albumListRow(row.album, place: row.place) }
            }
        }
        .frame(maxHeight: 340)
        .scrollIndicators(.hidden)
    }

    private var friendGroupedList: some View {
        ScrollView {
            LazyVStack(spacing: Space.s2, pinnedViews: []) {
                ForEach(friendGroups, id: \.friend.id) { group in
                    let collapsed = collapsedFriends.contains(group.friend.id)
                    friendHeader(group.friend, count: group.rows.count, collapsed: collapsed)
                    if !collapsed {
                        ForEach(group.rows, id: \.album.id) { row in albumListRow(row.album, place: row.place) }
                    }
                }
                if anyFriendHasMore { loadMoreButton }
            }
        }
        .frame(maxHeight: 360)
        .scrollIndicators(.hidden)
    }

    /// A friend's section header: avatar + name + album count, tap the chevron to collapse.
    private func friendHeader(_ friend: Friend, count: Int, collapsed: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if collapsed { collapsedFriends.remove(friend.id) } else { collapsedFriends.insert(friend.id) }
            }
        } label: {
            HStack(spacing: Space.s3) {
                Avatar(friend: friend, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(friend.name).font(.system(size: 12, weight: .bold)).foregroundStyle(p.text).lineLimit(1)
                    Text("\(count) album\(count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(p.muted2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(p.muted)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .padding(.vertical, Space.s2).padding(.horizontal, Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
        .padding(.top, Space.s1)
    }

    private var loadMoreButton: some View {
        Button { loadMoreAllFriends() } label: {
            HStack(spacing: Space.s2) {
                if anyFriendLoading { OrbLoader(size: 16) }
                else { Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)) }
                Text(anyFriendLoading ? "Loading…" : "Load more")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(p.text)
            .padding(.vertical, Space.s3).frame(maxWidth: .infinity)
            .background(Capsule().fill(p.glassFill))
            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .disabled(anyFriendLoading)
        .padding(.top, Space.s2)
    }

    /// Located albums grouped under each friend (owned + wishlist), alphabetical by friend name.
    private var friendGroups: [FriendGroup] { cachedFriendGroups }

    /// One album row in the deployed list: cover + title/artist + place, flies the map on tap.
    private func albumListRow(_ album: Album, place: MapPlace) -> some View {
        Button { fly(to: place) } label: {
            HStack(spacing: Space.s3) {
                artwork(album)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text(album.artist).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: Space.s2)
                HStack(spacing: 3) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 10)).foregroundStyle(p.muted2)
                    Text(place.name).font(.system(size: 10, weight: .medium)).foregroundStyle(p.muted2).lineLimit(1)
                }
                .frame(maxWidth: 96, alignment: .trailing)
            }
            .padding(Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
    }

    /// Every located album across the map, paired with its place, largest places first.
    private var locatedAlbums: [(album: Album, place: MapPlace)] {
        places.flatMap { place in place.albums.map { (album: $0, place: place) } }
    }

    /// A per-source line: progress while a source loads, otherwise how much of it is on the map.
    private var subtitle: String {
        let n = places.count
        let mapped = places.reduce(0) { $0 + $1.albums.count }
        let total = cachedSourceCount
        if total == 0 {
            switch source {
            case .owned: return "No albums yet — sync your collection"
            case .wishlist:
                return state.wishlistLoad == .loading ? "Loading your wishlist…" : "Nothing on your wishlist yet"
            case .friends:
                return state.friendsLoad == .loading ? "Loading your friends…" : "Follow some fans to map their music"
            }
        }
        return "\(n) place\(n == 1 ? "" : "s") · \(mapped) of \(total) albums located"
    }

    /// Owned · Wishlist · Friends segmented control (matches the main nav's gliding pill).
    private var sourcePicker: some View {
        HStack(spacing: 3) {
            ForEach(MapSource.allCases) { s in
                let on = source == s
                Button {
                    withAnimation(Motion.glide) { source = s }
                } label: {
                    Text(s.label)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        .foregroundStyle(on ? p.text : p.muted)
                        .padding(.vertical, Space.s2).padding(.horizontal, Space.s4)
                        .background {
                            if on {
                                Capsule().fill(p.glassFill)
                                    .overlay(Capsule().strokeBorder(p.edge, lineWidth: 1))
                                    .matchedGeometryEffect(id: "mapSourcePill", in: seg)
                            }
                        }
                        .contentShape(Capsule())
                        .hoverHighlight(active: on)
                }
                .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(p.glassFill))
        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    /// Fetch the source's albums if needed, then resolve + geocode their artist origins. Geocodes
    /// already-known artists first (instant pins), then backfills any new artists and geocodes those.
    private func prepare(_ source: MapSource) async {
        switch source {
        case .owned:
            break
        case .wishlist:
            await state.syncWishlist()
        case .friends:
            await state.syncFriends()
            // Pull the first page of each friend's collection — the map shows purchases only.
            await withTaskGroup(of: Void.self) { group in
                for f in state.friends {
                    group.addTask { await state.startFriendList(f, wishlist: false) }
                }
            }
        }
        if Task.isCancelled { return }
        let list = albums(for: source)
        // Instant: geocode the artists we already know (cached from a previous run / the owned map).
        await geo.resolve(CollectionGeo.locationStrings(albums: list, loc: loc))
        // Progressive: look up any new artists and geocode each the moment it resolves, so pins
        // trickle onto the map right away instead of after the whole rate-limited batch.
        resolving = true
        await state.resolveArtistLocations(for: list) { place in
            await geo.resolve([place])
        }
        resolving = false
    }

    /// If the user opened the map by tapping an album's origin, fly to + select that place once it's
    /// on the map (its pin may only appear after geocoding lands, so this retries as caches rebuild).
    private func applyMapFocus() {
        guard let target = state.mapFocusLocation else { return }
        guard let place = cachedPlaces.first(where: { $0.id == GeoStore.key(target) }) else { return }
        state.mapFocusLocation = nil
        fly(to: place)
    }

    // MARK: Clustering

    /// A group of nearby places rendered as one bubble at low zoom. A single-member cluster is
    /// just a normal place pin; multi-member clusters show the combined album count.
    private struct MapCluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let places: [MapPlace]
        var albumCount: Int { places.reduce(0) { $0 + $1.albums.count } }
        var single: MapPlace? { places.count == 1 ? places[0] : nil }
    }

    /// Bucket places onto a lat/lon grid whose cell is `cellDeg` wide, merging everything in a cell
    /// into one cluster at its album-weighted centroid. Bigger cells (low zoom) → fewer, larger
    /// bubbles; smaller cells (zoomed in) → they split back into individual places.
    private func clusters(_ places: [MapPlace], cellDeg: Double) -> [MapCluster] {
        guard cellDeg > 0 else {
            return places.map { MapCluster(id: $0.id, coordinate: $0.coordinate, places: [$0]) }
        }
        var buckets: [String: [MapPlace]] = [:]
        for pl in places {
            let gx = (pl.coordinate.longitude / cellDeg).rounded(.down)
            let gy = (pl.coordinate.latitude / cellDeg).rounded(.down)
            buckets["\(Int(gx))|\(Int(gy))", default: []].append(pl)
        }
        return buckets.map { key, ps in
            let total = max(1, ps.reduce(0) { $0 + $1.albums.count })
            let lat = ps.reduce(0.0) { $0 + $1.coordinate.latitude * Double($1.albums.count) } / Double(total)
            let lon = ps.reduce(0.0) { $0 + $1.coordinate.longitude * Double($1.albums.count) } / Double(total)
            return MapCluster(id: key, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                              places: ps.sorted { $0.albums.count > $1.albums.count })
        }
    }

    /// Tapping a cluster opens a combined card of every album it groups (scroll/pinch the map to
    /// zoom in and it re-clusters into finer places on its own). If the cluster is really spread out,
    /// nudge the camera to fit its members too, so it visibly splits behind the card.
    private func openCluster(_ cluster: MapCluster) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selected = combinedPlace(cluster) }
        let lats = cluster.places.map(\.coordinate.latitude)
        let lons = cluster.places.map(\.coordinate.longitude)
        guard let latMin = lats.min(), let latMax = lats.max(),
              let lonMin = lons.min(), let lonMax = lons.max() else { return }
        let spread = max(latMax - latMin, lonMax - lonMin)
        // Only reframe when members actually span a meaningful area (else the card alone is enough).
        guard spread > 0.5 else { return }
        let center = CLLocationCoordinate2D(latitude: (latMin + latMax) / 2, longitude: (lonMin + lonMax) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(1.5, (latMax - latMin) * 1.8),
                                    longitudeDelta: max(1.5, (lonMax - lonMin) * 1.8))
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    /// Fold a cluster's member places into one synthetic place — combined albums + owners — so the
    /// place card can present them together.
    private func combinedPlace(_ cluster: MapCluster) -> MapPlace {
        let top = cluster.places.max { $0.albums.count < $1.albums.count } ?? cluster.places[0]
        let name = cluster.places.count == 1
            ? top.name : "\(top.name) + \(cluster.places.count - 1) nearby"
        var seen = Set<Int>(); var friends: [Friend] = []
        for pl in cluster.places {
            for f in pl.friends where seen.insert(f.id).inserted { friends.append(f) }
        }
        let albums = cluster.places.flatMap(\.albums)
        return MapPlace(id: cluster.id, name: name, coordinate: cluster.coordinate,
                        country: top.country, albums: albums, friends: friends)
    }

    /// A region bubble: the combined album count across the places it groups, sized by that count.
    private func clusterMarker(_ cluster: MapCluster, peak: Int) -> some View {
        let side = 26 + CGFloat(min(1, Double(cluster.albumCount) / Double(peak))) * 26
        return ZStack {
            Circle().fill(p.accent.opacity(0.28)).frame(width: side + 12, height: side + 12)
            Circle().fill(p.accent).frame(width: side, height: side)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2).frame(width: side, height: side)
            Text("\(cluster.albumCount)").font(.system(size: 12, weight: .bold)).foregroundStyle(p.accentInk)
        }
    }

    /// Move the map camera to a place (and select it, opening its panel).
    private func fly(to place: MapPlace) {
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6)))
            selected = place
        }
    }

    /// Any followed friend still has un-loaded collection pages (the map shows purchases only).
    private var anyFriendHasMore: Bool {
        state.friends.contains { f in !(state.friendColl[f.id]?.reachedEnd ?? false) }
    }

    /// Any followed friend is mid-fetch, so the load-more control shows the orb spinner.
    private var anyFriendLoading: Bool {
        state.friends.contains { f in state.friendColl[f.id]?.loading ?? false }
    }

    /// Pull the next page (20) of every friend's collection, then resolve + geocode any
    /// newly-revealed artist origins so fresh albums and pins appear. (Wishlist isn't mapped.)
    private func loadMoreAllFriends() {
        let friends = state.friends
        Task {
            await withTaskGroup(of: Void.self) { group in
                for f in friends {
                    group.addTask { await state.loadMoreFriend(f, wishlist: false) }
                }
            }
            let list = albums(for: .friends)
            await state.resolveArtistLocations(for: list)
            await geo.resolve(CollectionGeo.locationStrings(albums: list, loc: loc))
        }
    }

    /// "Alice", "Alice & Bob", or "Alice, Bob & 3 others" — the friends behind a place.
    private func friendsSummary(_ friends: [Friend]) -> String {
        let names = friends.map(\.name)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) & \(names.count - 2) other\(names.count - 2 == 1 ? "" : "s")"
        }
    }

    private func close() { withAnimation(.easeInOut(duration: 0.25)) { state.mapOpen = false } }

    /// The pin for a place: an accent circle sized by album count, or — on the Friends map — the
    /// overlapping avatars of the friends whose music comes from there.
    @ViewBuilder
    private func marker(_ place: MapPlace, peak: Int) -> some View {
        Group {
            if place.friends.isEmpty {
                countMarker(place, peak: peak)
            } else {
                friendMarker(place)
            }
        }
        .scaleEffect(selected?.id == place.id ? 1.25 : 1)
    }

    /// A pin sized by how many albums come from the place.
    private func countMarker(_ place: MapPlace, peak: Int) -> some View {
        let side = 22 + CGFloat(min(1, Double(place.albums.count) / Double(peak))) * 20
        return ZStack {
            Circle().fill(p.accent).frame(width: side, height: side)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2).frame(width: side, height: side)
            Text("\(place.albums.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(p.accentInk)
        }
    }

    /// Up to three friend avatars overlapped, then "+N", with the album count as a small badge.
    private func friendMarker(_ place: MapPlace) -> some View {
        let shown = Array(place.friends.prefix(3))
        let extra = place.friends.count - shown.count
        return HStack(spacing: -10) {
            ForEach(shown) { f in
                Avatar(friend: f, size: 30)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            }
            if extra > 0 {
                Text("+\(extra)").font(.system(size: 10, weight: .bold)).foregroundStyle(p.accentInk)
                    .frame(width: 26, height: 26).background(Circle().fill(p.accent))
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
            }
        }
    }

    private func placePanel(_ place: MapPlace) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name).font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                    Text("\(place.albums.count) album\(place.albums.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(p.muted)
                }
                Spacer()
                Button { selected = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                        .frame(width: 26, height: 26).background(Circle().fill(p.glassFill))
                        .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                }.buttonStyle(.soft).tip("Close")
            }
            // On the Friends map: who from here — avatars + names of the contributing friends.
            if !place.friends.isEmpty {
                HStack(spacing: Space.s2) {
                    OwnersMacaron(owners: place.friends, size: 22)
                    Text(friendsSummary(place.friends))
                        .font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            ScrollView {
                VStack(spacing: Space.s2) {
                    ForEach(place.albums) { album in albumRow(album) }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(Space.s4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        .frame(maxWidth: 420)
        .padding(Space.s5)
    }

    private func albumRow(_ album: Album) -> some View {
        let open = expandedAlbum == album.id
        return VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expandedAlbum = open ? nil : album.id }
                } label: {
                    HStack(spacing: Space.s3) {
                        artwork(album)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(album.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                            Text(album.artist).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                            // On the Friends map: who bought this exact album.
                            if let owners = cachedFriendsByAlbum[album.id], !owners.isEmpty {
                                HStack(spacing: 5) {
                                    OwnersMacaron(owners: owners, size: 14)
                                    Text(friendsSummary(owners))
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(p.muted2).lineLimit(1)
                                }
                                .padding(.top, 1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(p.muted2).rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
                .help(open ? "Hide details" : "Show details")

                Button { state.play(album, on: player) } label: {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .foregroundStyle(p.accentInk)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(p.accent))
                }
                .buttonStyle(.soft)
                .tip("Play album")
            }

            if open { albumInfo(album).padding(.top, Space.s3).transition(.opacity) }
        }
        .padding(Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.glassFill))
        .hoverHighlight(cornerRadius: 8)
        // Right-click: go to album, add to playlist, play, favourite, share…
        .appContextMenu { albumMenuItems(for: album, state: state, player: player) }
    }

    private func artwork(_ album: Album) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(album.cover)
            .frame(width: 40, height: 40)
            .overlay {
                if let img = album.artwork {
                    Image(nsImage: img).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if let url = album.artworkURL {
                    CachedRemoteImage(url: url) { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
    }

    /// The expanded detail shown when a row is tapped: quick metadata, plus an action that depends
    /// on ownership — "Go to album" for items in your library, "Buy on Bandcamp" for anything else
    /// (wishlist items and friends' records you don't own).
    private func albumInfo(_ album: Album) -> some View {
        // Owned = this very album on the Owned map, or a library album with the same Bandcamp page.
        let owned = source == .owned ? album : state.libraryAlbum(forBandcampURL: album.bandcampItemURL)
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: 6) {
                if !album.year.isEmpty { metaPill(album.year) }
                if !album.format.isEmpty { metaPill(album.format) }
                if album.lossless { metaPill("Lossless") }
            }
            if let g = album.genre, !g.isEmpty {
                Text(g).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(2)
            }
            if let owned {
                actionPill("square.stack", "Go to album", tint: false) { open(owned) }
            } else if let s = album.bandcampItemURL, let url = URL(string: s) {
                actionPill("bag", "Buy on Bandcamp", tint: true) { NSWorkspace.shared.open(url) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A small capsule action; `tint` fills it in the accent colour (used for the buy CTA).
    private func actionPill(_ symbol: String, _ title: String, tint: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tint ? p.accentInk : p.text)
            .padding(.vertical, 5).padding(.horizontal, Space.s3)
            .background(Capsule().fill(tint ? p.accent : p.page.opacity(0.6)))
            .overlay(Capsule().strokeBorder(tint ? .clear : p.edgeSoft, lineWidth: 1))
        }.buttonStyle(.soft)
    }

    private func metaPill(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .bold)).kerning(0.5)
            .foregroundStyle(p.muted2)
            .padding(.vertical, 3).padding(.horizontal, 7)
            .background(Capsule().fill(p.page.opacity(0.6)))
            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    private func open(_ album: Album) {
        state.openedAlbumID = album.id
        state.screen = .crate       // leave Settings so the album detail is visible
        close()
    }
}
