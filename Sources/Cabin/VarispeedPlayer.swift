import AVFoundation

/// Plays a local audio file through AVAudioEngine for the "Slowed + Reverb" (DJ) mode.
/// The signal chain is: player → adapter → varispeed → time-pitch → reverb → mixer, so three
/// things can be bent live, smoothly and with no dropouts (unlike `AVPlayer.rate`):
///   • `rate` — tape-style speed: tempo *and* pitch move together (resampling).
///   • `pitchSemitones` — an *extra*, independent pitch shift on top (deeper "screwed" feel).
///   • `reverbMix` — a wet/dry reverb tail for the dreamy "+ reverb" sound.
/// Streams from disk (no full decode).
///
/// The adapter is a plain mixer node that converts whatever the file is (mono, 48 kHz, …) to the
/// fixed stereo format the effect units run at. Without it a mono file leaves the varispeed unit
/// with mismatched bus formats and the engine silently refuses to start.
@MainActor
final class VarispeedPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let adapter = AVAudioMixerNode()
    private let vari = AVAudioUnitVarispeed()
    private let pitchUnit = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()
    /// EQ + Room & vinyl DSP (same `AudioEQ` the AVPlayer tap uses), hosted as an in-process unit.
    private let room: AVAudioUnitEffect = {
        _ = RoomEffectAU.register
        return AVAudioUnitEffect(audioComponentDescription: RoomEffectAU.componentDescription)
    }()
    /// Push EQ gains / room profile / amount here, exactly like the AVPlayer taps.
    var dsp: AudioEQ? { (room.auAudioUnit as? RoomEffectAU)?.eq }
    private var file: AVAudioFile?

    private(set) var duration: Double = 0
    private var sampleRate: Double = 44_100
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var scheduleToken = 0

    /// Called on the main actor when the current segment finishes playing to the end.
    var onFinish: (@MainActor () -> Void)?

    var rate: Double = 1.0 { didSet { vari.rate = Float(min(4, max(0.25, rate))) } }
    /// Extra pitch shift in semitones (independent of `rate`). `pitch` on the unit is in cents.
    var pitchSemitones: Double = 0 { didSet { pitchUnit.pitch = Float(min(24, max(-24, pitchSemitones)) * 100) } }
    /// Reverb wet/dry mix, 0 (fully dry — bypassed) … 100 (fully wet).
    var reverbMix: Double = 0 { didSet { reverb.wetDryMix = Float(min(100, max(0, reverbMix))) } }
    var volume: Float = 0.8 { didSet { engine.mainMixerNode.outputVolume = volume } }

    init() {
        engine.attach(node)
        engine.attach(adapter)
        engine.attach(vari)
        engine.attach(pitchUnit)
        engine.attach(reverb)
        engine.attach(room)
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 0            // start dry; the user dials it in
        // The effect chain runs at one fixed stereo format; the adapter converts every file to it
        // and the main mixer converts to whatever the output device wants. Room/EQ sits last,
        // mirroring the AVPlayer tap (post-effects).
        let chain = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.connect(node, to: adapter, format: nil)
        engine.connect(adapter, to: vari, format: chain)
        engine.connect(vari, to: pitchUnit, format: chain)
        engine.connect(pitchUnit, to: reverb, format: chain)
        engine.connect(reverb, to: room, format: chain)
        engine.connect(room, to: engine.mainMixerNode, format: chain)
    }

    /// Point at a local file. Returns false if it can't be opened.
    func load(_ url: URL) -> Bool {
        guard url.isFileURL, let f = try? AVAudioFile(forReading: url) else { return false }
        file = f
        sampleRate = f.processingFormat.sampleRate
        duration = sampleRate > 0 ? Double(f.length) / sampleRate : 0
        engine.connect(node, to: adapter, format: f.processingFormat)
        return true
    }

    /// Spin the engine up ahead of `play(fromSeconds:)`. Starting the engine takes a moment; doing
    /// it while the previous engine is still sounding turns a hand-off gap into a near-seamless cut.
    @discardableResult
    func prepare() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do { try engine.start(); return true } catch { return false }
    }

    /// Start (or restart) playback from a position in seconds. Returns false when the engine
    /// couldn't start (unsupported format / device trouble) so the caller can fall back.
    @discardableResult
    func play(fromSeconds t: Double) -> Bool {
        guard let f = file else { return false }
        scheduleToken += 1
        let token = scheduleToken
        node.stop()

        let total = f.length
        let start = max(0, min(total, AVAudioFramePosition(max(0, t) * sampleRate)))
        guard start < total else { onFinish?(); return true }
        segmentStartFrame = start
        let count = AVAudioFrameCount(total - start)

        guard prepare() else { return false }
        engine.mainMixerNode.outputVolume = volume
        vari.rate = Float(min(4, max(0.25, rate)))

        node.scheduleSegment(f, startingFrame: start, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, token == self.scheduleToken else { return }
                self.onFinish?()
            }
        }
        node.play()
        return true
    }

    func pause() { node.pause() }
    func resume() { if !engine.isRunning { try? engine.start() }; node.play() }

    func stop() {
        scheduleToken += 1
        node.stop()
        engine.stop()
    }

    /// Current source position in seconds. The player node counts the frames it has handed
    /// downstream, so this is already in file time — the varispeed rate is accounted for.
    var currentSeconds: Double {
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return Double(segmentStartFrame) / sampleRate
        }
        let played = max(0, Double(playerTime.sampleTime) / sampleRate)
        return Double(segmentStartFrame) / sampleRate + played
    }
}
