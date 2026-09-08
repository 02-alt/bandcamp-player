import AVFoundation

/// Plays a local audio file through AVAudioEngine for the "Slowed + Reverb" (DJ) mode.
/// The signal chain is: player → varispeed → time-pitch → reverb → mixer, so three things
/// can be bent live, smoothly and with no dropouts (unlike `AVPlayer.rate`):
///   • `rate` — tape-style speed: tempo *and* pitch move together (resampling).
///   • `pitchSemitones` — an *extra*, independent pitch shift on top (deeper "screwed" feel).
///   • `reverbMix` — a wet/dry reverb tail for the dreamy "+ reverb" sound.
/// Streams from disk (no full decode).
@MainActor
final class VarispeedPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let vari = AVAudioUnitVarispeed()
    private let pitchUnit = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()
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
        engine.attach(vari)
        engine.attach(pitchUnit)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 0            // start dry; the user dials it in
        engine.connect(node, to: vari, format: nil)
        engine.connect(vari, to: pitchUnit, format: nil)
        engine.connect(pitchUnit, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
    }

    /// Point at a local file. Returns false if it can't be opened.
    func load(_ url: URL) -> Bool {
        guard url.isFileURL, let f = try? AVAudioFile(forReading: url) else { return false }
        file = f
        sampleRate = f.processingFormat.sampleRate
        duration = sampleRate > 0 ? Double(f.length) / sampleRate : 0
        engine.connect(node, to: vari, format: f.processingFormat)
        return true
    }

    /// Start (or restart) playback from a position in seconds.
    func play(fromSeconds t: Double) {
        guard let f = file else { return }
        scheduleToken += 1
        let token = scheduleToken
        node.stop()

        let total = f.length
        let start = max(0, min(total, AVAudioFramePosition(max(0, t) * sampleRate)))
        guard start < total else { onFinish?(); return }
        segmentStartFrame = start
        let count = AVAudioFrameCount(total - start)

        if !engine.isRunning { engine.prepare(); try? engine.start() }
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
    }

    func pause() { node.pause() }
    func resume() { if !engine.isRunning { try? engine.start() }; node.play() }

    func stop() {
        scheduleToken += 1
        node.stop()
        engine.stop()
    }

    /// Current source position in seconds (accounts for the varispeed rate).
    var currentSeconds: Double {
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return Double(segmentStartFrame) / sampleRate
        }
        let played = max(0, Double(playerTime.sampleTime) / sampleRate)
        return Double(segmentStartFrame) / sampleRate + played
    }
}
