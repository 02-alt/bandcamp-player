import SwiftUI
import MapKit

/// A place on the collection map: one artist location, its coordinate, and the albums from there.
struct MapPlace: Identifiable {
    let id: String            // normalised location string
    let name: String          // display string ("Berlin, Germany")
    let coordinate: CLLocationCoordinate2D
    let country: String?
    let albums: [Album]
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
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// A world map with a marker per artist location; tap one to see the albums from there.
struct CollectionMapView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var geo = GeoStore.shared
    @ObservedObject private var loc = ArtistLocationStore.shared
    @Environment(\.palette) private var p

    @State private var selected: MapPlace?
    @State private var expandedAlbum: UUID?

    private var places: [MapPlace] { CollectionGeo.places(albums: state.albums, loc: loc, geo: geo) }

    var body: some View {
        let maxCount = max(1, places.map(\.albums.count).max() ?? 1)
        // Full-window page: the map fills everything, edge to edge; the header + place panel float
        // over it in liquid glass.
        ZStack(alignment: .top) {
            Map(initialPosition: .automatic) {
                ForEach(places) { place in
                    Annotation(place.name, coordinate: place.coordinate) {
                        Button { selected = place } label: { marker(place, peak: maxCount) }
                            .buttonStyle(.plain)
                    }
                }
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
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Button { close() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                    .frame(width: 36, height: 36).background(Circle().fill(p.glassFill))
                    .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            }.buttonStyle(.plain).help("Back")
            VStack(alignment: .leading, spacing: 2) {
                Text("Collection map").font(.system(size: 18, weight: .bold)).foregroundStyle(p.text)
                let mapped = places.reduce(0) { $0 + $1.albums.count }
                Text("\(places.count) place\(places.count == 1 ? "" : "s") · \(mapped) of \(state.albums.count) albums located")
                    .font(.system(size: 12)).foregroundStyle(p.muted)
            }
        }
        .fixedSize()
        .padding(Space.s4)
        // Liquid-glass floating bar over the map.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private func close() { withAnimation(.easeInOut(duration: 0.25)) { state.mapOpen = false } }

    /// A pin sized by how many albums come from the place.
    private func marker(_ place: MapPlace, peak: Int) -> some View {
        let side = 22 + CGFloat(min(1, Double(place.albums.count) / Double(peak))) * 20
        return ZStack {
            Circle().fill(p.accent).frame(width: side, height: side)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2).frame(width: side, height: side)
            Text("\(place.albums.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(p.accentInk)
        }
        .scaleEffect(selected?.id == place.id ? 1.25 : 1)
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
                }.buttonStyle(.plain)
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
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(p.muted2).rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Hide details" : "Show details")

                Button { state.play(album, on: player) } label: {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .foregroundStyle(p.accentInk)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(p.accent))
                }
                .buttonStyle(.plain)
                .help("Play album")
            }

            if open { albumInfo(album).padding(.top, Space.s3).transition(.opacity) }
        }
        .padding(Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.glassFill))
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

    /// The expanded detail shown when a row is tapped: quick metadata + an open-album action.
    private func albumInfo(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: 6) {
                if !album.year.isEmpty { metaPill(album.year) }
                if !album.format.isEmpty { metaPill(album.format) }
                if album.lossless { metaPill("Lossless") }
            }
            if let g = album.genre, !g.isEmpty {
                Text(g).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(2)
            }
            Button { open(album) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack").font(.system(size: 10, weight: .semibold))
                    Text("Go to album").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(p.text)
                .padding(.vertical, 5).padding(.horizontal, Space.s3)
                .background(Capsule().fill(p.page.opacity(0.6)))
                .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
