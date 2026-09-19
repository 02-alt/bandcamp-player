import AVFoundation

/// The classic iPod click-wheel "tick" — the dry mechanical click the device plays through its
/// speaker as you scrub the wheel. Synthesised (a ~6 ms burst of fast-decaying noise) rather than
/// shipped as an audio file, and played on its own tiny audio engine so it mixes over whatever the
/// main player is doing without touching it. Call `click()` once per item the selection moves past.
@MainActor
final class IPodClick {
    static let shared = IPodClick()

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var started = false

    private init() {
        engine.attach(node)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        buffer = Self.makeClick(format: format)
    }

    /// Play one click. Starts the engine lazily on first use; `.interrupts` replaces any in-flight
    /// click so fast scrubbing ticks crisply instead of queueing up.
    func click() {
        guard let buffer else { return }
        if !started {
            do { try engine.start(); node.play(); started = true }
            catch { return }
        }
        node.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
    }

    private static func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(sr * 0.006)          // ~6 ms
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        var seed: UInt32 = 0x9E3779B9
        // One shared mono waveform copied to every channel.
        for c in 0..<Int(format.channelCount) {
            guard let p = buf.floatChannelData?[c] else { continue }
            var s = seed
            for i in 0..<Int(frames) {
                let t = Double(i) / sr
                s = s &* 1664525 &+ 1013904223                // cheap LCG noise
                let noise = Double(Int32(bitPattern: s)) / Double(Int32.max)
                let env = exp(-t * 1300)                      // sharp decay → a dry tick
                p[i] = Float(noise * env * 0.35)
            }
        }
        seed &+= 1
        return buf
    }
}
