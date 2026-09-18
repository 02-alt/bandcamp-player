import SwiftUI
import AppKit

/// A read-only detail page for an album you don't own — a wishlist item (or a friend's pick):
/// cover, Play + Buy buttons, a streamable (muted) tracklist, album/artist info, who of your
/// friends owns it, and more by the artist. Reuses the same Bandcamp/track/bio services the owned
/// album page uses. Opened via `state.openExternalAlbum(_:)` and shown from `MainPanel`.
struct ExternalAlbumDetailView: View {
    let album: Album
    /// Small pill under the title, e.g. "In your wishlist" or "In Alice's collection".
    var note: String = "In your wishlist"
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    @State private var tracks: [Track] = []
    @State private var loadingTracks = true
    @State private var about: String?
    @State private var bio: ArtistBio?

    private var moreByArtist: [Album] {
        state.albums.filter {
            $0.artist.caseInsensitiveCompare(album.artist) == .orderedSame && $0.id != album.id
        }
    }
    private var buyURL: URL? { album.bandcampItemURL.flatMap(URL.init(string:)) }
    private var owners: [Friend] { state.owners(forBandcampURL: album.bandcampItemURL) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                IconButton(system: "chevron.left", tip: "Back") { state.openedExternalAlbum = nil }
                Spacer()
            }
            .padding(.horizontal, Space.s5).padding(.top, Space.s5)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    header
                    buyRow
                    trackSection
                    infoSection
                    if let bio, !bio.text.isEmpty { bioSection(bio) }
                    if !moreByArtist.isEmpty { moreSection }
                }
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.s7)
                .padding(.top, Space.s4)
                .padding(.bottom, Space.s7)
            }
            .scrollIndicators(.hidden)
        }
        .task(id: album.id) { await load() }
    }

    /// Start playback from a track, making sure Now Playing can resolve this album — for a friend's
    /// pick it's in neither your library nor wishlist, so we hand it over as the external album
    /// (mirrors `state.play`), otherwise the player bar / Now Playing show nothing.
    private func play(at index: Int) {
        guard !tracks.isEmpty else { state.play(album, on: player); return }
        let known = state.albums.contains { $0.id == album.id } || state.wishlist.contains { $0.id == album.id }
        state.nowPlayingExternalAlbum = known ? nil : album
        state.nowPlayingAlbumID = album.id
        player.play(tracks, startAt: index)
    }

    private func load() async {
        loadingTracks = true
        tracks = await state.resolveTracks(for: album)
        loadingTracks = false
        if let id = state.identity, let itemURL = album.bandcampItemURL {
            about = try? await BandcampClient(identity: id).notes(forItemURL: itemURL).about
        }
        if about == nil { about = album.about }
        bio = await ArtistBioService.bio(artist: album.artist, ownedAlbumTitles: moreByArtist.map(\.title))
    }

    private var header: some View {
        VStack(spacing: Space.s4) {
            AlbumArt(album: album, corner: Radius.card)
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                .overlay(alignment: .bottomTrailing) {
                    if !owners.isEmpty { OwnersMacaron(owners: owners, size: 34).padding(Space.s3) }
                }
            VStack(spacing: 5) {
                Text(album.title).font(.system(size: 24, weight: .bold)).kerning(-0.4)
                    .multilineTextAlignment(.center).foregroundStyle(p.text)
                Button { state.openArtist(album.artist) } label: {
                    Text(album.artist).font(.system(size: 15)).foregroundStyle(p.muted)
                }
                .buttonStyle(.soft)
                .tip("Go to artist")
                Text(note.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.8)
                    .foregroundStyle(p.muted2)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(p.glassFill))
                    .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var buyRow: some View {
        HStack(spacing: Space.s3) {
            Button { play(at: 0) } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(p.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Capsule().fill(p.glassFill))
                    .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
            }
            .buttonStyle(.soft)
            .disabled(!album.isPlayable)
            if let url = buyURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Buy on Bandcamp", systemImage: "bag.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(p.accentInk)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.soft)
                .tip("Support the artist on Bandcamp")
            }
        }
    }

    @ViewBuilder private var trackSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("TRACKS").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            if loadingTracks {
                OrbLoadingRow(text: "Loading tracks…", size: 48)
            } else if tracks.isEmpty {
                Text("No preview available for this album.").font(.system(size: 13)).foregroundStyle(p.muted2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        ExternalTrackRow(index: i, track: t,
                                         playing: player.current?.albumID == album.id && player.current?.trackIndex == i) {
                            play(at: i)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var infoSection: some View {
        let meta = [album.year, album.genre, album.label]
            .compactMap { ($0?.isEmpty == false) ? $0 : nil }
        if !meta.isEmpty || (about?.isEmpty == false) {
            VStack(alignment: .leading, spacing: Space.s2) {
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(p.muted)
                }
                if let about, !about.isEmpty {
                    Text(about).font(.system(size: 13)).foregroundStyle(p.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bioSection(_ bio: ArtistBio) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(album.artist.uppercased()).font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            Text(bio.text).font(.system(size: 13)).foregroundStyle(p.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("MORE BY \(album.artist.uppercased())")
                .font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2).lineLimit(1)
            ScrollView(.horizontal) {
                HStack(spacing: Space.s4) {
                    ForEach(moreByArtist) { a in
                        Button {
                            state.openedExternalAlbum = nil
                            state.openedAlbumID = a.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AlbumArt(album: a, corner: 10).frame(width: 128, height: 128)
                                Text(a.title).font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1).frame(width: 128, alignment: .leading).foregroundStyle(p.text)
                            }
                        }
                        .buttonStyle(.soft)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A streamable track row on the external album page — styled like the owned album's `AlbumTrackRow`
/// (number ↔ play cross-fade, accent + bars when playing), minus the owned-only like/more actions.
private struct ExternalTrackRow: View {
    let index: Int
    let track: Track
    let playing: Bool
    let onPlay: () -> Void
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: Space.s4) {
                ZStack {
                    if playing && player.isPlaying {
                        NowPlayingBars(color: p.accent)
                    } else if playing {
                        Image(systemName: "pause.fill").font(.system(size: 11)).foregroundStyle(p.accent)
                    } else {
                        Text("\(index + 1)").font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(p.muted2).opacity(hovering ? 0 : 1)
                        Image(systemName: "play.fill").font(.system(size: 11))
                            .foregroundStyle(p.text).opacity(hovering ? 1 : 0)
                    }
                }
                .frame(width: 26)
                .animation(.easeInOut(duration: 0.12), value: hovering)

                Text(track.title).font(.system(size: 14, weight: playing ? .semibold : .regular))
                    .foregroundStyle(playing ? p.accent : p.text.opacity(0.85)).lineLimit(1)
                Spacer(minLength: Space.s3)
            }
            .padding(.vertical, Space.s3).padding(.horizontal, Space.s3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(playing ? p.glassFill : .clear))
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 10, active: playing)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.995, brighten: 0))
        .onHover { hovering = $0 }
    }
}
