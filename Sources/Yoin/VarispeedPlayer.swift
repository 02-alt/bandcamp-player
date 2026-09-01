import AVFoundation

/// Plays a local audio file through AVAudioEngine with a varispeed unit, so its rate
/// (tempo *and* pitch, tape-style) can be changed live — smoothly, with no dropouts,
/// unlike `AVPlayer.rate`. Used for DJ mode. Streams from disk (no full decode).
@MainActor
final class VarispeedPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let vari = AVAudioUnitVarispeed()
    private var file: AVAudioFile?

    private(set) var loadedURL: URL?
    private(set) var duration: Double = 0
    private var sampleRate: Double = 44_100
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var scheduleToken = 0

    /// Called on the main actor when the current segment finishes playing to the end.
    var onFinish: (@MainActor () -> Void)?

    var rate: Double = 1.0 { didSet { vari.rate = Float(min(4, max(0.25, rate))) } }
    var volume: Float = 0.8 { didSet { engine.mainMixerNode.outputVolume = volume } }

    init() {
        engine.attach(node)
        engine.attach(vari)
        engine.connect(node, to: vari, format: nil)
        engine.connect(vari, to: engine.mainMixerNode, format: nil)
    }

    /// Point at a local file. Returns false if it can't be opened.
    func load(_ url: URL) -> Bool {
        guard url.isFileURL, let f = try? AVAudioFile(forReading: url) else { return false }
        file = f
        sampleRate = f.processingFormat.sampleRate
        duration = sampleRate > 0 ? Double(f.length) / sampleRate : 0
        loadedURL = url
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
