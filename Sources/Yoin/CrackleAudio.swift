import AVFoundation
import os

/// Analog-modelled vinyl surface noise, synthesised live on the real-time audio thread. Unlike a
/// naive white-noise hiss, this layers what a real record actually sounds like:
///   • a warm **pink-noise bed** (−3 dB/oct, via Paul Kellet's economy filter), not flat white;
///   • sparse **crackles** — high-passed micro-clicks, Poisson-scattered;
///   • rarer, louder **pops** — low-passed thumps with a longer tail;
///   • a faint sub-bass **rumble** for body.
/// Two independent channels give it stereo width. `intensity` (0…1) scales the crackle/pop density
/// so a well-played record (high wear) crackles more than a mint one.
///
/// State the render block touches lives here (hand-synchronised, `@unchecked Sendable`), never the
/// main actor — the block runs on the real-time thread.
final class CrackleCore: @unchecked Sendable {
    let sampleRate: Double

    private struct Shared { var intensity = 0.5; var gainTarget = 0.0 }
    private let shared: OSAllocatedUnfairLock<Shared>

    private var rng: UInt64 = 0x2545F4914F6CDD1D
    private var gain = 0.0

    /// One noise voice per output channel.
    private struct Chan {
        // Pink-noise filter memory (Kellet).
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var rumble = 0.0                 // sub-bass one-pole
        // Crackle voices (fast, high-passed) and pop voices (slow, low-passed).
        var crAmp = [Double](repeating: 0, count: 8), crDec = [Double](repeating: 0, count: 8)
        var popAmp = [Double](repeating: 0, count: 4), popDec = [Double](repeating: 0, count: 4)
        var crHPy = 0.0, crHPx = 0.0     // crackle high-pass state
        var popLP = 0.0                  // pop low-pass state
    }
    private var chL = Chan(), chR = Chan()

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.shared = OSAllocatedUnfairLock(initialState: Shared())
    }

    func setIntensity(_ v: Double) { shared.withLock { $0.intensity = max(0, min(1, v)) } }
    func fadeIn()  { shared.withLock { $0.gainTarget = 1 } }
    func fadeOut() { shared.withLock { $0.gainTarget = 0 } }

    /// xorshift64 → uniform Double in [-1, 1). Allocation-free for the RT thread.
    private func noise() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53) * 2 - 1
    }
    private func uni() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53)
    }

    func render(frameCount n: Int, into abl: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        let (gainTarget, intensity) = shared.withLock { ($0.gainTarget, $0.intensity) }
        let gainCoeff = 1 - exp(-1.0 / (0.040 * sampleRate))       // ~40 ms in/out fade
        let crackleP = (24.0 + intensity * 120.0) / sampleRate     // crackles / sec → per-sample prob
        let popP = (0.8 + intensity * 4.5) / sampleRate            // pops / sec
        let bedLevel = 0.05 + intensity * 0.06

        let chCount = abl.count
        for i in 0..<n {
            gain += (gainTarget - gain) * gainCoeff
            // Two decorrelated voices; channel 0 uses the left voice, all others the right, so a
            // mono output still sounds right and stereo gets width.
            let l = sampleOne(&chL, crackleP: crackleP, popP: popP, bedLevel: bedLevel, intensity: intensity)
            let r = chCount > 1 ? sampleOne(&chR, crackleP: crackleP, popP: popP, bedLevel: bedLevel, intensity: intensity) : 0
            for ch in 0..<chCount {
                guard let p = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                p[i] = Float((ch == 0 ? l : r) * gain)
            }
        }
        return noErr
    }

    private func sampleOne(_ c: inout Chan, crackleP: Double, popP: Double, bedLevel: Double, intensity: Double) -> Double {
        let w = noise()

        // Pink-noise bed.
        c.b0 = 0.99886 * c.b0 + w * 0.0555179
        c.b1 = 0.99332 * c.b1 + w * 0.0750759
        c.b2 = 0.96900 * c.b2 + w * 0.1538520
        c.b3 = 0.86650 * c.b3 + w * 0.3104856
        c.b4 = 0.55000 * c.b4 + w * 0.5329522
        c.b5 = -0.7616 * c.b5 - w * 0.0168980
        let pink = (c.b0 + c.b1 + c.b2 + c.b3 + c.b4 + c.b5 + c.b6 + w * 0.5362) * 0.11
        c.b6 = w * 0.115926

        // Sub-bass rumble.
        c.rumble += (noise() - c.rumble) * 0.0022

        // Spawn crackles / pops.
        if uni() < crackleP, let j = c.crAmp.firstIndex(where: { $0 < 0.0008 }) {
            c.crAmp[j] = (0.15 + 0.55 * uni()) * (0.5 + 0.5 * intensity)
            c.crDec[j] = exp(-1.0 / ((0.0004 + 0.0016 * uni()) * sampleRate))   // 0.4–2 ms
        }
        if uni() < popP, let j = c.popAmp.firstIndex(where: { $0 < 0.0008 }) {
            c.popAmp[j] = (0.5 + 0.5 * uni()) * (0.5 + 0.5 * intensity)
            c.popDec[j] = exp(-1.0 / ((0.006 + 0.020 * uni()) * sampleRate))    // 6–26 ms
        }

        // Crackle sum → high-pass (turns the noise bursts into sharp ticks).
        var crSum = 0.0
        for j in 0..<c.crAmp.count where c.crAmp[j] > 0.0008 { crSum += noise() * c.crAmp[j]; c.crAmp[j] *= c.crDec[j] }
        let hp = 0.90 * (c.crHPy + crSum - c.crHPx)
        c.crHPy = hp; c.crHPx = crSum

        // Pop sum → low-pass (rounds them into soft thumps).
        var popSum = 0.0
        for j in 0..<c.popAmp.count where c.popAmp[j] > 0.0008 { popSum += noise() * c.popAmp[j]; c.popAmp[j] *= c.popDec[j] }
        c.popLP += (popSum - c.popLP) * 0.25

        return pink * bedLevel + c.rumble * 0.06 + hp * 0.85 + c.popLP * 0.7
    }
}

/// Carries the (non-Sendable) decoded loop buffer across the background-decode → main-actor hop.
private struct LoopBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
}

@MainActor
final class CrackleAudio {
    private let engine = AVAudioEngine()
    private let core = CrackleCore(sampleRate: 44_100)
    private var sourceNode: AVAudioSourceNode?      // synth path
    private var filePlayer: AVAudioPlayerNode?      // drop-in real-recording path
    private var fileBuffer: AVAudioPCMBuffer?
    private var configured = false                  // engine graph built lazily on first start
    private var running = false
    private var stopToken = 0
    private var targetVolume: Float = 0

    /// Fraction of the player volume the crackle plays at — faint on purpose.
    private static let ceiling: Float = 0.28

    /// True once configured with a user-supplied recording (vs. the synth).
    private(set) var usingRealRecording = false

    /// Trivial — SwiftUI recreates the owning view (and this `@State` default) on every body
    /// update, so the initializer must be cheap. The AVAudioEngine graph and the (potentially
    /// multi-second) audio decode happen once, lazily, on the first `start()`.
    init() {}

    /// Build the engine graph from the (already-decoded) loop buffer. Runs at most once, on the
    /// main actor — cheap graph wiring only; the expensive decode happens off-thread in `start()`.
    private func buildGraph(with buf: AVAudioPCMBuffer?) {
        guard !configured else { return }
        configured = true
        if let buf {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buf.format)
            filePlayer = node
            fileBuffer = buf
            usingRealRecording = true
        } else {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let n = Self.makeNode(format: format, core: core)
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            sourceNode = n
        }
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
    }

    /// Load an optional drop-in loop from `Resources/Audio/vinyl-crackle.*`, decoded to a buffer.
    /// `nonisolated` so `start()` can run it off the main thread (decoding a multi-MB MP3 to PCM
    /// on the main actor would hitch the UI right as playback begins).
    private nonisolated static func loadBundledLoop() -> AVAudioPCMBuffer? {
        let exts = ["wav", "caf", "m4a", "mp3", "aiff", "aif"]
        let url = exts.lazy.compactMap {
            Bundle.module.url(forResource: "vinyl-crackle", withExtension: $0, subdirectory: "Audio")
                ?? Bundle.module.url(forResource: "vinyl-crackle", withExtension: $0)
        }.first
        guard let url, let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        return buf
    }

    /// Build the source node in a nonisolated context so its render block does NOT inherit
    /// `@MainActor` (it runs on the real-time audio thread; a main-actor block would SIGTRAP).
    private nonisolated static func makeNode(format: AVAudioFormat, core: CrackleCore) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            core.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(abl))
        }
    }

    func setIntensity(_ wear: Double) { core.setIntensity(0.25 + 0.75 * wear) }

    func setVolume(_ volume: Double) {
        targetVolume = Float(volume) * Self.ceiling
        // Invalidate any in-flight fade ramp so it doesn't stomp this direct set over the next ~120 ms.
        if running { stopToken += 1; engine.mainMixerNode.outputVolume = targetVolume }
    }

    /// Fade the crackle in at the given player volume. On the very first call the bundled loop is
    /// decoded off the main thread; the graph is then built and playback begins on the main actor.
    func start(volume: Double, wear: Double) {
        stopToken += 1
        core.setIntensity(0.25 + 0.75 * wear)
        targetVolume = Float(volume) * Self.ceiling
        if configured { beginPlayback(); return }
        let token = stopToken
        Task { [weak self] in
            // AVAudioPCMBuffer isn't Sendable; the box carries it across the actor hop (safe — it's
            // created on the background thread and only read on the main actor afterwards).
            let box = await Task.detached(priority: .userInitiated) { LoopBox(CrackleAudio.loadBundledLoop()) }.value
            await MainActor.run {
                guard let self, token == self.stopToken else { return }   // stop() raced ahead of the decode
                self.buildGraph(with: box.buffer)
                self.beginPlayback()
            }
        }
    }

    /// Start the engine (if idle) and fade in. Requires the graph to already be built.
    private func beginPlayback() {
        guard configured else { return }
        if !running {
            do { try engine.start() } catch { return }
            running = true
            if let fp = filePlayer, let buf = fileBuffer {
                fp.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
                fp.play()
            }
        }
        core.fadeIn()
        rampVolume(to: targetVolume)          // the file path has no internal gain ramp
    }

    /// Fade out, then stop the engine a moment later (no cut-off click).
    func stop() {
        stopToken += 1                        // also cancels an in-flight first-start decode
        guard running else { return }
        core.fadeOut()
        rampVolume(to: 0)
        let token = stopToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard token == stopToken else { return }
            filePlayer?.stop()
            engine.stop()
            running = false
        }
    }

    /// Short mixer-volume ramp (~120 ms) so both paths fade smoothly.
    private func rampVolume(to target: Float) {
        let steps = 12
        let start = engine.mainMixerNode.outputVolume
        let token = stopToken
        for k in 1...steps {
            let t = Float(k) / Float(steps)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(k) * 10_000_000)
                guard token == stopToken else { return }
                engine.mainMixerNode.outputVolume = start + (target - start) * t
            }
        }
    }
}
