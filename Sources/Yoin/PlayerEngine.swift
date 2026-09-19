import SwiftUI
import AVFoundation

private let volumeKey = "yoin.volume"
private let djModeKey = "yoin.djMode"
private let djPitchKey = "yoin.djPitch"
private let djReverbKey = "yoin.djReverb"
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
/// Holds just the moving playhead (position + track length). Split out of `PlayerEngine` so the
/// ~5–10 Hz position updates only invalidate views that actually show progress — not `RootView`
/// (the top of the tree) or the whole collection subtree, which observe `PlayerEngine` for other
/// reasons and used to re-render on every tick.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
    var progress: Double { duration > 0 ? min(1, time / duration) : 0 }
}

@MainActor
final class PlayerEngine: ObservableObject {
    @Published var queue: [Track] = []
    @Published var index = 0
    @Published var isPlaying = false
    /// The playhead lives on a separate observable (see `PlaybackClock`). `currentTime`/`duration`
    /// proxy to it so all existing call sites are unchanged, but the engine itself no longer
    /// republishes at the position-update rate.
    let clock = PlaybackClock()
    var currentTime: Double { get { clock.time } set { clock.time = newValue } }
    var duration: Double { get { clock.duration } set { clock.duration = newValue } }
    // Restored from the last session (0.8 on first launch). Audio updates apply live on every
    // change; the UserDefaults write is debounced so a slider drag doesn't fire dozens of
    // synchronous main-thread persists per second (it only needs to survive to next launch).
    @Published var volume: Double = UserDefaults.standard.object(forKey: volumeKey) as? Double ?? 0.8 {
        didSet {
            vari.volume = Float(volume)
            // During a crossfade the fade timer owns both decks' volumes (it ramps toward
            // `volume`); setting them here would fight the ramp.
            if !crossfading { player?.volume = Float(volume) }
            persistVolumeDebounced()
        }
    }
    private var volumePersistWork: DispatchWorkItem?
    private func persistVolumeDebounced() {
        volumePersistWork?.cancel()
        let v = volume
        let work = DispatchWorkItem { UserDefaults.standard.set(v, forKey: volumeKey) }
        volumePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    /// Whether the full-window Now Playing screen is showing.
    @Published var expanded = false
    /// Whether the fullscreen "art mode" (screensaver-style cover display) is showing.
    @Published var artMode = false

    // MARK: Slowed + Reverb (DJ mode — varispeed speed + separate pitch shift + reverb tail)
    /// When on, local tracks play via the varispeed engine so `speed` bends tempo *and*
    /// pitch (chopped-&-screwed when slowed), plus an optional independent `pitch` shift and
    /// a `reverbMix` tail, all live. Persisted across launches.
    @Published var djMode: Bool = UserDefaults.standard.bool(forKey: djModeKey) {
        didSet {
            UserDefaults.standard.set(djMode, forKey: djModeKey)
            if !djMode { speed = 1.0 }
            switchEngineForDJChange()
        }
    }
    /// Playback speed multiplier (1.0 = normal). Only meaningful in DJ mode.
    @Published var speed: Double = 1.0 { didSet { switchEngineForDJChange() } }
    /// Extra pitch shift in semitones on top of the speed-coupled drop (0 = none). Applies to
    /// the varispeed engine only (downloaded files); AVPlayer streams get the speed drop alone.
    @Published var pitch: Double = UserDefaults.standard.double(forKey: djPitchKey) {
        didSet { UserDefaults.standard.set(pitch, forKey: djPitchKey); vari.pitchSemitones = pitch; switchEngineForDJChange() }
    }
    /// Reverb wet/dry mix, 0 (dry) … 100 (fully wet). Varispeed engine only.
    @Published var reverbMix: Double = UserDefaults.standard.double(forKey: djReverbKey) {
        didSet { UserDefaults.standard.set(reverbMix, forKey: djReverbKey); vari.reverbMix = reverbMix; switchEngineForDJChange() }
    }

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
        didSet { UserDefaults.standard.set(eqEnabled, forKey: "yoin.eqEnabled"); refreshDSP() }
    }
    @Published var eqPresetName: String = UserDefaults.standard.string(forKey: "yoin.eqPreset") ?? EQ.flat.name {
        didSet { UserDefaults.standard.set(eqPresetName, forKey: "yoin.eqPreset"); refreshDSP() }
    }

    // MARK: Room / vinyl DSP (muffle + tube warmth, on the same tap as the EQ)
    @Published var roomEnabled: Bool = UserDefaults.standard.bool(forKey: "yoin.roomEnabled") {
        didSet { UserDefaults.standard.set(roomEnabled, forKey: "yoin.roomEnabled"); refreshDSP() }
    }
    @Published var roomPresetName: String = UserDefaults.standard.string(forKey: "yoin.roomPreset") ?? Room.off.name {
        didSet { UserDefaults.standard.set(roomPresetName, forKey: "yoin.roomPreset"); refreshDSP() }
    }
    /// Effect strength for the room DSP, 0 (barely there) … 1 (full). Applied as a wet/dry mix.
    @Published var roomAmount: Double = PlayerEngine.loadRoomAmount() {
        didSet {
            let v = min(1, max(0, roomAmount))
            UserDefaults.standard.set(v, forKey: "yoin.roomAmount")
            let m = roomActive ? Float(v) : 1
            activeEQs.removeAll { $0.eq == nil }
            for box in activeEQs { box.eq?.setAmount(m) }
        }
    }
    private static func loadRoomAmount() -> Double {
        UserDefaults.standard.object(forKey: "yoin.roomAmount") == nil
            ? 1 : min(1, max(0, UserDefaults.standard.double(forKey: "yoin.roomAmount")))
    }
    /// The room profile actually in effect (Off when the feature is disabled).
    var currentRoom: RoomProfile { roomEnabled ? Room.preset(named: roomPresetName) : Room.off }
    private var roomActive: Bool { !currentRoom.isNeutral }
    private var roomMix: Float { roomActive ? Float(min(1, max(0, roomAmount))) : 1 }
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
        if eqPresetName != "Custom" { eqPresetName = "Custom" }  // didSet → refreshDSP
        else { refreshDSP() }
    }

    /// Whether the EQ contributes any non-flat gain right now.
    private var eqActive: Bool { eqEnabled && eqGains.contains { abs($0) > 0.01 } }

    /// Result of trying to attach the EQ/room DSP to an item: no FX wanted, attached synchronously,
    /// or the track wasn't ready so it must be loaded before the tap can go on.
    private enum DSPAttach { case none; case attached; case pending(AudioEQ, AVAsset) }

    /// Build the EQ/room tap and set it on `item` if possible. Returns `.pending` when the item's
    /// audio track hasn't loaded yet (the tap can't be built inline) — the caller must load the
    /// track and attach BEFORE playback starts, because a tap set after an item begins playing is
    /// ignored (this is why FX was silent on instant-start local/imported files).
    private func prepareDSP(for item: AVPlayerItem) -> DSPAttach {
        guard eqActive || roomActive else { return .none }
        let eq = AudioEQ(gains: eqActive ? eqGains : EQ.flat.gains,
                         room: roomActive ? currentRoom : Room.off, amount: roomMix)
        activeEQs.removeAll { $0.eq == nil }   // drop drained decks so this can't grow unbounded
        activeEQs.append(WeakEQ(eq))
        if let mix = eq.audioMix(for: item) {
            item.audioMix = mix
            return .attached
        }
        return .pending(eq, item.asset)
    }

    /// A fresh audio mix carrying the EQ/room DSP for `item`, attaching asynchronously if the track
    /// isn't ready. Used by the crossfade deck, which isn't audible until the fade starts.
    @discardableResult
    private func attachDSPAsync(to item: AVPlayerItem) -> Bool {
        switch prepareDSP(for: item) {
        case .none: return false
        case .attached: return true
        case .pending(let eq, let asset):
            Task { @MainActor [weak item] in
                guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
                      let track = tracks.first, let item, item.audioMix == nil else { return }
                if let mix = eq.audioMix(for: track) { item.audioMix = mix }
            }
            return true
        }
    }

    /// Apply an EQ or room change: push new coefficients live if the tap is already (un)attached as
    /// needed, otherwise re-cue the current track to attach/detach the tap.
    private func refreshDSP() {
        let want = eqActive || roomActive
        if want == eqAttached {
            let g = eqActive ? eqGains : EQ.flat.gains
            let r = roomActive ? currentRoom : Room.off
            let m = roomMix
            activeEQs.removeAll { $0.eq == nil }
            for box in activeEQs { box.eq?.setGains(g); box.eq?.setRoom(r); box.eq?.setAmount(m) }
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
    /// A DJ effect is actually engaged — not merely the engine toggled on. Only then is a local
    /// file routed through the varispeed engine; otherwise it stays on AVPlayer so the room/EQ FX
    /// tap still applies. (Leaving "Slowed + reverb engine" on used to silently disable FX on every
    /// downloaded/imported track.)
    private var djEngaged: Bool { djMode && (speed != 1.0 || pitch != 0 || reverbMix > 0) }
    private func wantsDJ(_ track: Track) -> Bool { djEngaged && track.streamURL.isFileURL }

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

        // DJ mode plays local files through the varispeed engine — but only if it can actually
        // run with the file's format. `vari.load` now validates that and returns false otherwise,
        // so an unsupported format falls back to AVPlayer instead of stalling silently.
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
        vari.pitchSemitones = pitch
        vari.reverbMix = reverbMix
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

        let attach = prepareDSP(for: item)
        // Intent, not `item.audioMix != nil`: a pending tap attaches after the track loads.
        eqAttached = eqActive || roomActive
        installAVObservers(on: p, item: item, track: track)

        if t > 0 { p.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }
        isPlaying = playing

        // Starting playback is deferred until any pending tap is on, because a tap set after an
        // item begins playing is ignored — the reason FX did nothing on instant-start local files.
        let begin = { [weak self] in
            guard let self, self.player === p, p.currentItem === item else { return }
            if playing {
                if track.streamURL.isFileURL {
                    // Local files are ready instantly — set the rate directly so playback starts.
                    // (applyRate() would no-op here: its guard sees the rate is already 1.0.)
                    let rate = self.activeRate
                    p.rate = rate
                    self.lastAppliedRate = rate
                } else {
                    p.play()         // stream: start at 1.0× and buffer; DJ speed applied when ready
                    self.lastAppliedRate = 1.0
                }
            } else {
                p.pause()
                self.lastAppliedRate = 0
            }
        }

        switch attach {
        case .none, .attached:
            begin()
        case .pending(let eq, let asset):
            Task { @MainActor [weak item] in
                if let tracks = try? await asset.loadTracks(withMediaType: .audio),
                   let atrack = tracks.first, let item, item.audioMix == nil,
                   let mix = eq.audioMix(for: atrack) {
                    item.audioMix = mix
                }
                begin()   // start playback even if the tap couldn't be built, so audio never stalls
            }
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
                    // Item is ready now — safe to push the DJ speed (doing it earlier stalls streams).
                    self.applyRate()
                    self.pushNowPlaying()
                }
                // Actual playback progress — not merely a reported duration — is what proves the
                // asset is playable. Only then disarm the stall watchdog. A dead/blocked asset that
                // reports a bogus tiny duration but never advances stays armed and gets skipped.
                if self.isPlaying, self.currentTime > 0.35, self.stallWatchdog != nil {
                    self.retriedTrackID = nil   // it played — allow a fresh retry if it fails later
                    self.stallWatchdog?.cancel(); self.stallWatchdog = nil
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
        let watched = track.id
        let isFile = track.streamURL.isFileURL
        stallWatchdog?.cancel()
        stallWatchdog = Task { @MainActor [weak self] in
            // A working track advances within a few seconds (local) or after buffering (remote).
            // If it's still parked at 0:00 while "playing", the asset is dead/blocked/truncated —
            // even if it reported a (bogus) duration, so we no longer gate on duration == 0.
            // Generous for streams (slow connections buffer); a truly dead stream is also caught
            // immediately by the .failed observer above.
            try? await Task.sleep(nanoseconds: isFile ? 6_000_000_000 : 30_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.activeTrack?.id == watched, self.isPlaying, !self.scrubbing,
               self.pendingSeek == nil, self.currentTime < 0.35 {
                self.handlePlaybackFailure()
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
        attachDSPAsync(to: item)
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
