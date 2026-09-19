import Foundation

/// What a player surface should show *right now*. The precedence rule — the playing track's own
/// title/artist/artwork win over the album's, and `nowPlayingAlbum` wins over the browsing
/// `current` — is an app invariant that was previously re-derived by hand in five views
/// (NowPlaying, PlayerBar, the two mini players, Art mode), which had already drifted apart
/// (PlayerBar dropped the `nowPlayingAlbum` layer). Deriving it once here removes that divergence
/// and makes the rule unit-testable without SwiftUI.
struct NowPlayingSubject {
    let album: Album
    let title: String
    let artist: String
    let coverURL: URL?

    init(nowPlayingAlbum: Album?, current: Album, track: Track?) {
        let a = nowPlayingAlbum ?? current
        album = a
        title = track?.title ?? a.title
        artist = track?.artist ?? a.artist
        coverURL = track?.artworkURL ?? a.artworkURL
    }
}

extension AppState {
    /// The now-playing subject for the given transport track (`player.current`), applying the
    /// standard precedence over this state's `nowPlayingAlbum` / `current`.
    func nowPlaying(_ track: Track?) -> NowPlayingSubject {
        NowPlayingSubject(nowPlayingAlbum: nowPlayingAlbum, current: current, track: track)
    }
}
