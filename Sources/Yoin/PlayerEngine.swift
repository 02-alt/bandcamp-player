import SwiftUI
import AVFoundation

private let djModeKey = "yoin.djMode"
private let transitionModeKey = "yoin.transitionMode"

/// How one track flows into the next.
enum TransitionMode: String, CaseIterable, Identifiable {
    case off, crossfade, beatmatch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:        "Off"
        case .crossfade:  "Crossfade"
        case .beatmatch:  "Beat-match"
        }
    }
    var blurb: String {
        switch self {
        case .off:        "Hard cut between tracks"
        case .crossfade:  "Equal-power overlap between tracks"
        case .beatmatch:  "Overlap, nudging tempos together (owned files)"
        }
    }
}

/// Audio playback over a track queue. Normal playback uses AVPlayer (handles local files
/// and remote streams). In DJ mode, local tracks play through `VarispeedPlayer`
/// (AVAudioEngine) so the speed/pitch can be bent live with no dropouts.
///
/// When a transition mode is on, the end of each track overlaps the next via a second
/// AVPlayer deck (`deckB`) with an equal-power volume ramp — and, for beat-match, a
/// pitch-preserved tempo nudge on the outgoing deck when both BPMs are known and close.
@MainActor
final class PlayerEngine: ObservableObject {
    @Published var queue: [Track] = []
    @Published var index = 0
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.8 {
        didSet {
            vari.volume = Float(volume)
            // During a crossfade the fade timer owns both decks' volumes (it ramps toward
            // `volume`); setting them here would fight the ramp.
            if !crossfading { player?.volume = Float(volume) }
        }
    }
    /// Whether the full-window Now Playing screen is showing.
    @Published var expanded = false
    /// Whether the fullscreen "art mode" (screensaver-style cover display) is showing.
    @Published var artMode = false

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

    // MARK: Transitions (crossfade / beat-match)
    @Published var transitionMode: TransitionMode =
        TransitionMode(rawValue: UserDefaults.standard.string(forKey: transitionModeKey) ?? "") ?? .off {
        didSet { UserDefaults.standard.set(transitionMode.rawValue, forKey: transitionModeKey) }
    }
    /// Overlap length when crossfading, in seconds.
    var crossfadeSeconds: Double = 6
    /// Radio's "Auto-DJ continuous mix" — forces a beat-matched crossfade while a station plays,
    /// without changing the user's saved `transitionMode`. Set by AppState on start/stop radio.
    @Published var autoDJ = false

    /// The transition mode actually applied — Auto-DJ (radio) overrides to beat-match.
    private var effectiveTransition: TransitionMode { autoDJ ? .beatmatch : transitionMode }

    // MARK: Equalizer (10-band, applied via an MTAudioProcessingTap on the AVPlayer path)
    @Published var eqEnabled: Bool = UserDefaults.standard.bool(forKey: "yoin.eqEnabled") {
        didSet { UserDefaults.standard.set(eqEnabled, forKey: "yoin.eqEnabled"); refreshEQ() }
    }
    @Published var eqPresetName: String = UserDefaults.standard.string(forKey: "yoin.eqPreset") ?? EQ.flat.name {
        didSet { UserDefaults.standard.set(eqPresetName, forKey: "yoin.eqPreset"); refreshEQ() }
    }
    /// The user's hand-tuned band gains (dB), used when the preset is "Custom".
    @Published var eqCustomGains: [Float] = PlayerEngine.loadCustomGains()
    /// Supplies the now-playing album's genre for the "Auto" EQ preset.
    var currentGenre: (@MainActor () -> String?)?

    /// Whether the current primary item currently carries our EQ tap.
    private var eqAttached = false
    private final class WeakEQ { weak var eq: AudioEQ?; init(_ e: AudioEQ) { eq = e } }
    private var activeEQs: [WeakEQ] = []

    private static func loadCustomGains() -> [Float] {
        let saved = (UserDefaults.standard.string(forKey: "yoin.eqCustom") ?? "")
            .split(separator: ",").compactMap { Float($0) }
        return saved.count == EQ.bands.count ? saved : EQ.flat.gains
    }

    /// The band gains actually in effect for the current preset.
    var eqGains: [Float] {
        switch eqPresetName {
        case "Auto":   return EQ.auto(forGenre: currentGenre?() ?? "").gains
        case "Custom": return eqCustomGains
        default:       return EQ.preset(named: eqPresetName).gains
        }
    }

    /// Drag a single band — switches to the "Custom" preset (seeded from the current curve),
    /// enables the EQ, and updates the sound live without re-cueing.
    func setEQBand(_ index: Int, _ db: Float) {
        if eqPresetName != "Custom" { eqCustomGains = eqGains }   // seed from the shown curve
        guard eqCustomGains.indices.contains(index) else { return }
        eqCustomGains[index] = max(-12, min(12, db))
        UserDefaults.standard.set(eqCustomGains.map { String($0) }.joined(separator: ","), forKey: "yoin.eqCustom")
        if !eqEnabled { eqEnabled = true }                       // hear it immediately
        if eqPresetName != "Custom" { eqPresetName = "Custom" }  // didSet → refreshEQ
        else { refreshEQ() }
    }

    /// A fresh EQ audio mix for `item`, or nil when EQ is off / flat (leave the item untouched).
    private func makeEQMix(for item: AVPlayerItem) -> AVAudioMix? {
        guard eqEnabled, eqGains.contains(where: { abs($0) > 0.01 }) else { return nil }
        let eq = AudioEQ(gains: eqGains)
        activeEQs.removeAll { $0.eq == nil }   // drop drained decks so this can't grow unbounded
        activeEQs.append(WeakEQ(eq))
        return eq.audioMix(for: item)
    }

    /// Apply an EQ change: push new gains live if the tap is already (un)attached as needed,
    /// otherwise re-cue the current track to attach/detach the tap.
    private func refreshEQ() {
        let want = eqEnabled && eqGains.contains { abs($0) > 0.01 }
        if want == eqAttached {
            let g = eqGains
            activeEQs.removeAll { $0.eq == nil }
            for box in activeEQs { box.eq?.setGains(g) }
        } else if !djActive, let track = activeTrack, player != nil {
            let pos = currentTime, was = isPlaying
            cancelCrossfade()
            teardownAV()
            startAV(track, at: pos, playing: was)
        } else {
            eqAttached = want
        }
    }

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

    /// Fired when the playhead moves to a new track, so radio mode can top up the queue
    /// before it runs dry (see AppState.radioTopUpIfNeeded).
    var queueAdvanced: (@MainActor () -> Void)?

    /// Surfaces a user-facing playback problem (dead/stalled stream) — wired to a notice.
    var onError: (@MainActor (String) -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var stallWatchdog: Task<Void, Never>?
    /// The track we've already retried once, so a persistently-dead stream is skipped
    /// (rather than retried forever) on the second failure.
    private var retriedTrackID: UUID?
    private var activeTrack: Track?

    // Second deck + fade state for track-to-track transitions.
    private var deckB: AVPlayer?
    private var fadeTimer: Timer?
    private var fadeStart: Date?
    private var crossfading = false
    private var crossfadeTargetIndex: Int?
    /// Outgoing-deck rate target during a beat-matched fade (1 = no tempo change).
    private var beatmatchRatio: Double = 1

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
        cancelCrossfade()
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
        cancelCrossfade()
        finalizeActive()
        teardownAV(); vari.stop(); stopPositionTimer(); djActive = false
        queue = []; index = 0
        isPlaying = false; currentTime = 0; duration = 0
        pushNowPlaying()
    }

    func next() {
        cancelCrossfade()
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
        cancelCrossfade()
        if currentTime > 3 { seek(fraction: 0) }
        else if hasPrev { index -= 1; startCurrent() }
        else { seek(fraction: 0) }
    }

    func seek(fraction: Double) {
        cancelCrossfade()
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
        guard let p = player, !crossfading else { return }   // fade timer owns the rate mid-crossfade
        let target = activeRate
        guard abs(target - lastAppliedRate) > 0.0005 else { return }
        lastAppliedRate = target
        if isPlaying { p.rate = target } else { p.pause() }
    }

    // MARK: Jog-wheel scrub (drag the disc to rewind / fast-forward)

    /// Silence the active engine while the user drags the disc (the scratch engine makes
    /// the sound). `isPlaying` is left unchanged so playback resumes cleanly on release.
    func beginScrub() {
        cancelCrossfade()
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
        cancelCrossfade()
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
        queueAdvanced?()
        prefetchUpcomingTempo()
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

        if let mix = makeEQMix(for: item) { item.audioMix = mix }
        eqAttached = item.audioMix != nil
        installAVObservers(on: p, item: item, track: track)

        if t > 0 { p.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }
        isPlaying = playing
        if playing {
            if track.streamURL.isFileURL {
                // Local files are ready instantly — set the rate directly so playback starts.
                // (Routing through applyRate() here no-ops: its change guard sees the rate is
                // already 1.0 and returns without ever telling the player to move.)
                let rate = activeRate
                p.rate = rate
                lastAppliedRate = rate
            } else {
                p.play()             // stream: start at 1.0× and buffer; DJ speed applied when ready
                lastAppliedRate = 1.0
            }
        } else {
            p.pause()
            lastAppliedRate = 0
        }
    }

    /// Attach the position / end / failure observers to a deck's current item. Reused both when
    /// starting a track and when a crossfade promotes deck B to the primary deck.
    private func installAVObservers(on p: AVPlayer, item: AVPlayerItem, track: Track) {
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.djActive else { return }
                if !self.scrubbing && self.pendingSeek == nil { self.currentTime = time.seconds.isFinite ? time.seconds : 0 }
                if self.duration == 0, let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                    self.retriedTrackID = nil   // it loaded fine — allow a fresh retry if it fails again later
                    self.stallWatchdog?.cancel(); self.stallWatchdog = nil
                    // Item is ready now — safe to push the DJ speed (doing it earlier stalls streams).
                    self.applyRate()
                    self.pushNowPlaying()
                }
                self.maybeStartCrossfade()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // If the track reaches its end mid-fade (timing jitter), finish the handoff now.
                if self.crossfading { self.commitCrossfade() } else { self.trackEnded() }
            }
        }
        // A dead/blocked stream would otherwise sit silently at 0:00 forever. Catch an
        // explicit failure, and (for remote streams) a stall that never reaches ready.
        // `.initial` delivers an already-failed status set before we started observing — e.g. a
        // dead stream promoted from the crossfade deck (which had no observers during the fade).
        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
            if it.status == .failed {
                Task { @MainActor in self?.handlePlaybackFailure() }
            }
        }
        if !track.streamURL.isFileURL {
            let watched = track.id
            stallWatchdog?.cancel()
            stallWatchdog = Task { @MainActor [weak self] in
                // Generous — a slow connection can legitimately take a while to buffer; a truly
                // dead stream is caught immediately by the .failed observer above. This only
                // rescues a silent stall that never errors and never becomes ready.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.activeTrack?.id == watched, self.isPlaying, self.duration == 0, self.currentTime == 0 {
                    self.handlePlaybackFailure()
                }
            }
        }
    }

    /// Toggling DJ mode mid-track: hand playback between engines at the current position.
    private func switchEngineForDJChange() {
        cancelCrossfade()
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

    // MARK: Crossfade / beat-match

    /// Called from the periodic observer: begin overlapping the next track once we're within
    /// the fade window of the current one. Only for normal (non-DJ) AVPlayer playback.
    private func maybeStartCrossfade() {
        guard effectiveTransition != .off, !crossfading, !djActive, !djMode,
              !repeatOne, !shuffle, !scrubbing, pendingSeek == nil,
              isPlaying, hasNext, duration > crossfadeSeconds + 3 else { return }
        let remaining = duration - currentTime
        guard remaining > 0.25, remaining <= crossfadeSeconds else { return }
        beginCrossfade()
    }

    private func beginCrossfade() {
        guard let p = player, hasNext, let out = activeTrack else { return }
        let nextTrack = queue[index + 1]
        // If the next track would play through the varispeed (DJ) engine, don't crossfade —
        // the decks are AVPlayer-only.
        guard !wantsDJ(nextTrack) else { return }

        let item = AVPlayerItem(url: nextTrack.streamURL)
        item.audioTimePitchAlgorithm = .timeDomain
        if let mix = makeEQMix(for: item) { item.audioMix = mix }
        let b = deckB ?? AVPlayer()
        b.automaticallyWaitsToMinimizeStalling = !nextTrack.streamURL.isFileURL
        b.replaceCurrentItem(with: item)
        b.volume = 0
        deckB = b

        crossfading = true
        crossfadeTargetIndex = index + 1
        beatmatchRatio = 1

        // Beat-match: ease the outgoing tempo toward the incoming track's, pitch preserved —
        // but only when both BPMs are known and within ~8% (a bigger gap warps audibly).
        if effectiveTransition == .beatmatch,
           let outBPM = TempoAnalyzer.shared.cachedBPM(for: out.streamURL),
           let inBPM = TempoAnalyzer.shared.cachedBPM(for: nextTrack.streamURL),
           outBPM > 0, inBPM > 0 {
            let r = inBPM / outBPM
            if r >= 0.92, r <= 1.08 {
                beatmatchRatio = r
                p.currentItem?.audioTimePitchAlgorithm = .timeDomain
            }
        }

        b.play()
        startFadeTimer()
        pushNowPlaying()
    }

    private func startFadeTimer() {
        fadeStart = Date()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFade() }
        }
    }

    private func tickFade() {
        guard crossfading, let start = fadeStart else { return }
        let t = min(1, Date().timeIntervalSince(start) / max(0.5, crossfadeSeconds))
        // Equal-power curve: perceived loudness stays constant across the overlap.
        player?.volume = Float(cos(t * .pi / 2) * volume)
        deckB?.volume = Float(sin(t * .pi / 2) * volume)
        if beatmatchRatio != 1, isPlaying { player?.rate = Float(1 + (beatmatchRatio - 1) * t) }
        if t >= 1 { commitCrossfade() }
    }

    /// The fade finished (or the outgoing track hit its natural end): promote deck B to be the
    /// primary deck and advance to it — no re-seek, so the incoming audio never skips.
    private func commitCrossfade() {
        guard crossfading, let incoming = deckB, let target = crossfadeTargetIndex else {
            cancelCrossfade(); return
        }
        fadeTimer?.invalidate(); fadeTimer = nil
        fadeStart = nil

        finalizeActive()                 // log the outgoing track's play time
        teardownAVObservers()            // detach from the still-primary (outgoing) deck
        let outgoing = player
        outgoing?.pause()
        outgoing?.rate = 0
        outgoing?.replaceCurrentItem(with: nil)

        // Swap: deck B becomes primary, the drained deck is kept for the next transition.
        player = incoming
        deckB = outgoing
        crossfading = false
        beatmatchRatio = 1
        crossfadeTargetIndex = nil

        index = min(max(0, target), max(0, queue.count - 1))
        let track = current
        activeTrack = track
        isPlaying = true
        eqAttached = incoming.currentItem?.audioMix != nil
        incoming.volume = Float(volume)
        lastAppliedRate = 1.0
        duration = 0
        currentTime = incoming.currentTime().seconds.isFinite ? incoming.currentTime().seconds : 0
        if let item = incoming.currentItem, let track {
            installAVObservers(on: incoming, item: item, track: track)
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
        }
        pushNowPlaying()
        queueAdvanced?()
        prefetchUpcomingTempo()
    }

    /// Abort an in-progress crossfade and restore the outgoing (primary) deck to full volume /
    /// normal rate. Safe to call when not crossfading.
    private func cancelCrossfade() {
        guard crossfading else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        fadeStart = nil
        crossfading = false
        crossfadeTargetIndex = nil
        beatmatchRatio = 1
        deckB?.pause()
        deckB?.replaceCurrentItem(with: nil)
        player?.volume = Float(volume)
        lastAppliedRate = -1
        if isPlaying { applyRate() }
    }

    /// Warm the BPM cache for the current + next tracks so a beat-matched fade is ready in time.
    private func prefetchUpcomingTempo() {
        guard effectiveTransition == .beatmatch else { return }
        if let cur = current?.streamURL { TempoAnalyzer.shared.prefetch(cur) }
        if index + 1 < queue.count { TempoAnalyzer.shared.prefetch(queue[index + 1].streamURL) }
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

    /// A stream failed or never became playable. Retry the same track once (covers a transient
    /// network hiccup), then tell the user and skip past it instead of hanging silently at 0:00.
    private func handlePlaybackFailure() {
        stallWatchdog?.cancel(); stallWatchdog = nil
        guard let track = activeTrack else { return }
        if retriedTrackID != track.id {
            retriedTrackID = track.id
            startCurrent()          // rebuild the item + observers for a fresh attempt
            return
        }
        onError?("Couldn’t play “\(track.title)” — skipping.")
        if hasNext { next() } else { stopPlayback() }
    }

    private func teardownAVObservers() {
        statusObserver?.invalidate(); statusObserver = nil
        stallWatchdog?.cancel(); stallWatchdog = nil
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
    }

    private func teardownAV() {
        teardownAVObservers()
        // Silence the AVPlayer so a stream doesn't keep playing under a new varispeed (DJ)
        // track. startAV re-attaches an item on the normal path, so clearing here is safe.
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }
}
