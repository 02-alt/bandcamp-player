import AppKit
import MediaPlayer

/// Bridges the player to macOS's system Now Playing panel and the media keys
/// (F7–F9 / Control Center / AirPods). Registering `MPRemoteCommandCenter`
/// handlers and keeping `MPNowPlayingInfoCenter` up to date is all macOS needs to
/// route those controls here and show the current track system-wide.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private weak var player: PlayerEngine?
    private weak var state: AppState?
    /// Remote artwork is fetched once per URL and reused (the panel asks repeatedly).
    private var artworkCache: [URL: NSImage] = [:]
    private var pendingArtworkURL: URL?

    private init() {}

    func configure(player: PlayerEngine, state: AppState) {
        self.player = player
        self.state = state
        setupCommands()
        player.nowPlayingChanged = { [weak self] in self?.update() }
        update()
    }

    // MARK: Remote commands (media keys, Control Center, headphones)

    private func setupCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            if !p.isPlaying { p.toggle() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            if p.isPlaying { p.toggle() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.player?.toggle(); return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.player?.next(); return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            self?.player?.prev(); return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let p = self?.player, p.duration > 0,
                  let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            p.seek(fraction: e.positionTime / p.duration)
            return .success
        }
        // We drive next/prev, so disable seek-by-interval (avoids a confusing extra control).
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    // MARK: Now Playing info

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let p = player, let track = p.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        if let album = albumTitle(for: track) { info[MPMediaItemPropertyAlbumTitle] = album }
        if p.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = p.duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = p.isPlaying ? (p.djMode ? p.speed : 1.0) : 0.0

        if let img = artwork(for: track) {
            let size = img.size
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in img }
        }

        center.nowPlayingInfo = info
        center.playbackState = p.isPlaying ? .playing : .paused
    }

    private func albumTitle(for track: Track) -> String? {
        if let id = track.albumID, let a = state?.albums.first(where: { $0.id == id }) { return a.title }
        return state?.nowPlayingAlbum?.title
    }

    /// Local artwork is instant; remote covers are fetched lazily then pushed on the next update.
    private func artwork(for track: Track) -> NSImage? {
        if let data = track.artworkData, let img = NSImage(data: data) { return img }
        if let id = track.albumID, let a = state?.albums.first(where: { $0.id == id }),
           let data = a.artworkData, let img = NSImage(data: data) { return img }
        guard let url = track.artworkURL else { return nil }
        if let cached = artworkCache[url] { return cached }
        fetchArtwork(url)
        return nil
    }

    private func fetchArtwork(_ url: URL) {
        guard pendingArtworkURL != url else { return }
        pendingArtworkURL = url
        Task { [weak self] in
            let img: NSImage? = await Task.detached {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return NSImage(data: data)
            }.value
            await MainActor.run {
                guard let self else { return }
                self.pendingArtworkURL = nil
                if let img { self.artworkCache[url] = img; self.update() }
            }
        }
    }
}
