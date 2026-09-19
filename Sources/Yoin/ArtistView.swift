import SwiftUI
import AppKit

/// Artist page. The releases shown are derived from albums you already have (library +
/// wishlist); the bio is the same one First Listen fetches (`ArtistBioService`), shown inline
/// instead of only linking out to Bandcamp.
struct ArtistView: View {
    let name: String
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    @State private var bio: ArtistBio? = nil
    @State private var bioLoaded = false

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: Space.s6)]

    private var library: [Album] { state.libraryAlbums(byArtist: name) }
    private var wished: [Album] { state.wishlistAlbums(byArtist: name) }

    /// Best-effort band page URL, taken from the host of any owned Bandcamp item URL
    /// (e.g. `https://artist.bandcamp.com/album/…` → `https://artist.bandcamp.com`).
    private var bandcampURL: URL? {
        for a in library + wished {
            if let s = a.bandcampItemURL, let u = URL(string: s), let host = u.host {
                return URL(string: "https://\(host)")
            }
        }
        return nil
    }

    private var subtitle: String {
        var parts: [String] = []
        if !library.isEmpty { parts.append("\(library.count) album\(library.count == 1 ? "" : "s") in your library") }
        if !wished.isEmpty { parts.append("\(wished.count) on your wishlist") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Transparent so RootView's ambient shows through (no black block). MainPanel hides the
            // content below while this is up. RootView already provides the cover-tinted ambient, so
            // no second wash here (doubling it would wash out muted text below the WCAG AA floor).
            Color.clear.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Space.s6) {
                header
                Divider().overlay(p.edgeSoft)
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s6) {
                        if bio?.text.isEmpty == false { aboutSection }
                        TourDatesView(artist: name)
                        if !library.isEmpty { librarySection }
                        if !wished.isEmpty { wishlistSection }
                        if library.isEmpty && wished.isEmpty { empty }
                    }
                    .padding(.top, Space.s2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(Space.s7)
        }
        // Flat, full-bleed screen (see AlbumDetailView) — no rounded card corners.
        .clipShape(Rectangle())
        .task(id: name) { await loadBio() }
    }

    private func loadBio() async {
        guard !bioLoaded else { return }
        bioLoaded = true
        bio = await ArtistBioService.bio(artist: name, ownedAlbumTitles: library.map(\.title))
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeading("ABOUT")
            Text(bio?.text ?? "")
                .font(.system(size: 14)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let b = bio, !b.text.isEmpty {
                Button {
                    if let s = b.sourceURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }
                } label: {
                    Text("via \(b.sourceName)").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(p.muted2).underline(b.sourceURL != nil)
                }
                .buttonStyle(.plain).disabled(b.sourceURL == nil)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.s4) {
            IconButton(system: "chevron.left", tip: "Back") { state.openedArtist = nil }
            VStack(alignment: .leading, spacing: 2) {
                Text("ARTIST").font(.system(size: 11)).kerning(1).foregroundStyle(p.muted2)
                Text(name).font(.system(size: 30, weight: .bold)).kerning(-0.6)
                    .foregroundStyle(p.text).lineLimit(1).truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(p.muted)
                }
            }
            Spacer(minLength: Space.s3)
            HStack(spacing: Space.s2) {
                if !library.isEmpty {
                    pill("Start radio", systemImage: "dot.radiowaves.left.and.right") {
                        state.startRadioForArtist(name, on: player)
                    }
                }
                if let url = bandcampURL {
                    pill("Bandcamp", systemImage: "safari") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeading("IN YOUR LIBRARY")
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s6) {
                ForEach(library) { AlbumCard(album: $0) }
            }
        }
    }

    private var wishlistSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeading("ON YOUR WISHLIST")
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s6) {
                ForEach(wished) { WishlistCard(album: $0) }
            }
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
    }

    /// Only reachable if the artist's albums were removed after opening the page.
    private var empty: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "music.mic").font(.system(size: 26)).foregroundStyle(p.muted2)
            Text("No albums by \(name) in your library or wishlist.")
                .font(.system(size: 13)).foregroundStyle(p.muted).multilineTextAlignment(.center)
            if let url = bandcampURL {
                pill("Open on Bandcamp", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func pill(_ title: String, systemImage: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(p.text)
            .padding(.vertical, 9).padding(.horizontal, Space.s4)
            .background(Capsule().fill(p.glassFill))
            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
    }
}
