import SwiftUI
import AVFoundation

private let djModeKey = "yoin.djMode"

/// Audio playback over a track queue. Normal playback uses AVPlayer (handles local files
/// and remote streams). In DJ mode, local tracks play through `VarispeedPlayer`
/// (AVAudioEngine) so the speed/pitch can be bent live with no dropouts.
@MainActor
final class PlayerEngine: ObservableObject {
    @Published var queue: [Track] = []
    @Published var index = 0
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.8 {
        didSet { player?.volume = Float(volume); vari.volume = Float(volume) }
    }
    /// Whether the full-window Now Playing screen is showing.
    @Published var expanded = false

    // MARK: DJ mode (varispeed — slow/speed the track, pitch follows like a turntable)
    /// When on, local tracks play via the varispeed engine so `speed` bends tempo *and*
    /// pitch (chopped-&-screwed when slowed), live. Persisted across launches.
    @Published var djMode: Bool = UserDefaults.standard.bool(forKey: djModeKey) {
        didSet {
            UserDefaults.standard.set(djMode, forKey: djModeKey)
            if !djMode { speed = 1.0 }
            switchEngineForDJChange()
        }
    }
    /// Playback speed multiplier (1.0 = normal). Only meaningful in DJ mode.
    @Published var speed: Double = 1.0 { didSet { applyRate() } }

    /// Shuffle picks a random next track; repeat-one replays the current track on end.
    @Published var shuffle = false
    @Published var repeatOne = false

    /// Fired when a track stops being the active one (skipped, advanced, or played out),
    /// reporting how long it actually ran. Wired to listening-history logging in AppState.
    var trackFinished: (@MainActor (Track, _ elapsed: Double, _ duration: Double) -> Void)?

    /// Fired whenever the active track / play state / position changes materially, so the
    /// system Now Playing panel + media keys (see NowPlayingCenter) can be refreshed.
    var nowPlayingChanged: (@MainActor () -> Void)?
    private func pushNowPlaying() { nowPlayingChanged?() }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var activeTrack: Track?

    // DJ playback (local files only).
    private let vari = VarispeedPlayer()
    private var djActive = false
    private var positionTimer: Timer?
    private var scrubbing = false
    private var lastAppliedRate: Float = -1
    /// Target of an in-flight AVPlayer seek. While set, the periodic time observer must not
    /// overwrite `currentTime` — a remote seek is async, so the player still reports the OLD
    /// position for a moment, which would snap a just-scrubbed position back.
    private var pendingSeek: Double?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var hasPrev: Bool { index > 0 }
    var hasNext: Bool { index + 1 < queue.count }
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    /// DJ engine applies to this track (local file we can stream through AVAudioEngine).
    private func wantsDJ(_ track: Track) -> Bool { djMode && track.streamURL.isFileURL }

    // MARK: Transport

    func play(_ tracks: [Track], startAt i: Int = 0) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        index = min(max(0, i), tracks.count - 1)
        startCurrent()
    }

    func toggle() {
        if djActive {
            if isPlaying { vari.pause(); isPlaying = false }
            else { isPlaying = true; vari.resume() }
            pushNowPlaying()
            return
        }
        guard let p = player else { if let t = current { play([t]) }; return }
        if isPlaying { p.pause(); isPlaying = false; lastAppliedRate = 0 }
        else { isPlaying = true; applyRate() }
        pushNowPlaying()
    }

    // MARK: Queue editing (Up Next, play-next, drag-to-reorder)

    /// Insert tracks right after the current one — they play next. Starts fresh if idle.
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty || current == nil { play(tracks); return }
        queue.insert(contentsOf: tracks, at: min(index + 1, queue.count))
    }

    /// Append tracks to the end of the queue. Starts fresh if idle.
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty || current == nil { play(tracks); return }
        queue.append(contentsOf: tracks)
    }

    /// Jump straight to a queue position and start it.
    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        startCurrent()
    }

    /// Remove a queued track, keeping playback stable. Removing the current track advances.
    func removeFromQueue(at i: Int) {
        guard queue.indices.contains(i) else { return }
        if i == index {
            queue.remove(at: i)
            if queue.isEmpty { clearQueue() }
            else { index = min(index, queue.count - 1); startCurrent() }
        } else {
            queue.remove(at: i)
            if i < index { index -= 1 }
        }
    }

    /// Drag-to-reorder support: move rows and keep the current track pinned under the playhead.
    func moveInQueue(from source: IndexSet, to destination: Int) {
        let currentID = current?.id
        queue.move(fromOffsets: source, toOffset: destination)
        if let currentID, let ni = queue.firstIndex(where: { $0.id == currentID }) { index = ni }
    }

    /// Stop and empty the queue.
    func clearQueue() {
        finalizeActive()
        teardownAV(); vari.stop(); stopPositionTimer(); djActive = false
        queue = []; index = 0
        isPlaying = false; currentTime = 0; duration = 0
        pushNowPlaying()
    }

    func next() {
        if shuffle, queue.count > 1 {
            var n = index
            while n == index { n = Int.random(in: 0..<queue.count) }
            index = n; startCurrent(); return
        }
        if hasNext { index += 1; startCurrent() }
        else { stopPlayback() }
    }

    /// A track finished on its own: repeat-one replays it, otherwise advance.
    private func trackEnded() {
        if repeatOne { startCurrent() } else { next() }
    }

    func prev() {
        if currentTime > 3 { seek(fraction: 0) }
        else if hasPrev { index -= 1; startCurrent() }
        else { seek(fraction: 0) }
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(1, fraction)) * duration
        currentTime = t
        if djActive {
            vari.play(fromSeconds: t)
            if !isPlaying { vari.pause() }
        } else {
            player?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        }
        pushNowPlaying()
    }

    // MARK: Rate (DJ speed / play-pause)

    /// The AVPlayer rate: DJ speed when playing (else 1.0), 0 when paused. Only ever pushed
    /// once the item is buffered (see `startAV`) — setting a non-1.0 rate on an *unbuffered*
    /// remote stream is what stalls it at 0:00.
    private var activeRate: Float { isPlaying ? Float(djMode ? speed : 1.0) : 0 }

    /// Push the current speed to whichever engine is active. The varispeed engine bends
    /// pitch live and smoothly; AVPlayer's rate is a best-effort fallback.
    private func applyRate() {
        if djActive { vari.rate = speed; return }
        guard let p = player else { return }
        let target = activeRate
        guard abs(target - lastAppliedRate) > 0.0005 else { return }
        lastAppliedRate = target
        if isPlaying { p.rate = target } else { p.pause() }
    }

    // MARK: Jog-wheel scrub (drag the disc to rewind / fast-forward)

    /// Silence the active engine while the user drags the disc (the scratch engine makes
    /// the sound). `isPlaying` is left unchanged so playback resumes cleanly on release.
    func beginScrub() {
        scrubbing = true
        if djActive { vari.pause() } else { player?.pause(); lastAppliedRate = -1 }
    }

    /// Update the playback position during a scrub (UI + engines follow on release).
    func scrub(to time: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(duration, time))
        currentTime = t
        if !djActive, let p = player {
            pendingSeek = t
            p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
                Task { @MainActor in
                    // Only the latest seek clears the guard; earlier (cancelled) ones don't.
                    guard let self, done, let ps = self.pendingSeek, abs(ps - t) < 0.05 else { return }
                    self.pendingSeek = nil
                }
            }
        }
    }

    /// Resume (only if it was playing) once the disc is released.
    func endScrub(resumePlaying: Bool) {
        scrubbing = false
        if djActive {
            if resumePlaying { vari.play(fromSeconds: currentTime) } else { vari.play(fromSeconds: currentTime); vari.pause() }
        } else if resumePlaying {
            applyRate()
        }
    }

    // MARK: Engine setup / switching

    private func startCurrent() {
        finalizeActive()
        teardownAV()
        vari.stop()
        stopPositionTimer()
        djActive = false

        guard let track = current else { return }
        activeTrack = track
        currentTime = 0
        duration = 0
        isPlaying = true

        if wantsDJ(track), vari.load(track.streamURL) {
            startVari(at: 0)
        } else {
            startAV(track, at: 0, playing: true)
        }
        pushNowPlaying()
    }

    /// Play the current track through the varispeed (DJ) engine.
    private func startVari(at t: Double) {
        djActive = true
        duration = vari.duration
        pushNowPlaying()
        vari.volume = Float(volume)
        vari.rate = speed
        vari.onFinish = { [weak self] in self?.trackEnded() }
        vari.play(fromSeconds: t)
        if !isPlaying { vari.pause() }
        startPositionTimer()
    }

    /// Play the current track through AVPlayer (normal path / streams).
    private func startAV(_ track: Track, at t: Double, playing: Bool) {
        let item = AVPlayerItem(url: track.streamURL)
        // DJ mode bends pitch with tempo (turntable feel); otherwise keep audio natural.
        item.audioTimePitchAlgorithm = djMode ? .varispeed : .timeDomain
        let p = player ?? AVPlayer()
        // Remote streams need to buffer before a rate is applied; local files start instantly.
        p.automaticallyWaitsToMinimizeStalling = !track.streamURL.isFileURL
        p.replaceCurrentItem(with: item)
        p.volume = Float(volume)
        player = p

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.djActive else { return }
                if !self.scrubbing && self.pendingSeek == nil { self.currentTime = time.seconds.isFinite ? time.seconds : 0 }
                if self.duration == 0, let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                    // Item is ready now — safe to push the DJ speed (doing it earlier stalls streams).
                    self.applyRate()
                    self.pushNowPlaying()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trackEnded() }
        }

        if t > 0 { p.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }
        isPlaying = playing
        lastAppliedRate = 1.0
        if playing {
            if track.streamURL.isFileURL {
                applyRate()          // local files are ready instantly — apply DJ speed now
            } else {
                p.play()             // stream: start at 1.0× and buffer; DJ speed applied when ready
            }
        } else {
            p.pause()
        }
    }

    /// Toggling DJ mode mid-track: hand playback between engines at the current position.
    private func switchEngineForDJChange() {
        guard let track = activeTrack ?? current, activeTrack != nil else { return }
        let shouldDJ = wantsDJ(track)
        if shouldDJ == djActive {
            applyRate()                       // same engine — just push the new speed
            if !djActive { player?.currentItem?.audioTimePitchAlgorithm = djMode ? .varispeed : .timeDomain }
            return
        }
        let pos = currentTime
        let wasPlaying = isPlaying
        if shouldDJ {
            guard vari.load(track.streamURL) else { applyRate(); return }
            teardownAV()
            player?.replaceCurrentItem(with: nil)
            startVari(at: pos)
        } else {
            stopPositionTimer()
            vari.stop()
            djActive = false
            startAV(track, at: pos, playing: wasPlaying)
        }
    }

    private func stopPlayback() {
        finalizeActive()
        if djActive { vari.pause() } else { player?.pause(); lastAppliedRate = 0 }
        isPlaying = false
        pushNowPlaying()
    }

    // MARK: Position timer (varispeed engine has no periodic observer)

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.djActive, self.isPlaying, !self.scrubbing else { return }
                self.currentTime = min(self.duration, self.vari.currentSeconds)
            }
        }
    }

    private func stopPositionTimer() { positionTimer?.invalidate(); positionTimer = nil }

    // MARK: Housekeeping

    private func finalizeActive() {
        guard let t = activeTrack else { return }
        trackFinished?(t, currentTime, duration)
        activeTrack = nil
    }

    private func teardownAV() {
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        // Silence the AVPlayer so a stream doesn't keep playing under a new varispeed (DJ)
        // track. startAV re-attaches an item on the normal path, so clearing here is safe.
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }
}
