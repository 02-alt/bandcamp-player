import AVFoundation
import os

/// Real turntable scratch audio. While the user drags the disc we play the decoded
/// PCM through an `AVAudioSourceNode` whose read-head follows the disc position — so
/// moving forward/back (and fast/slow) produces the authentic pitch-bending scratch,
/// including reverse. Local files only; remote streams fall back to the silent jog.
///
/// The render block runs on the real-time audio thread, so all state it touches lives
/// in `ScratchCore` (hand-synchronised, `@unchecked Sendable`) rather than the main actor.
final class ScratchCore: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?           // retained so the sample pointers stay valid
    private var channelData: UnsafePointer<UnsafeMutablePointer<Float>>?
    private var frames = 0
    private var channels = 0
    private(set) var sampleRate: Double = 44_100

    /// Per-sample smoothing coefficients (one-pole). Set from the sample rate.
    private var posCoeff = 0.005
    private var gainCoeff = 0.008

    /// Shared with the audio thread. `target` = where the disc wants the head; `gainTarget`
    /// ramps 0→1 on begin and 1→0 on release; `seedPos`/`needsSeed` jump the head on begin.
    private struct Shared { var playhead = 0.0; var target = 0.0; var seedPos = 0.0; var needsSeed = false; var gainTarget = 0.0 }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    // Audio-thread-only state, persisted across callbacks.
    private var playhead = 0.0
    private var gain = 0.0

    func setBuffer(_ buf: AVAudioPCMBuffer) {
        buffer = buf
        frames = Int(buf.frameLength)
        channels = Int(buf.format.channelCount)
        channelData = buf.floatChannelData.map { UnsafePointer($0) }
        sampleRate = buf.format.sampleRate
        // ~6 ms position smoothing, ~4 ms gain smoothing.
        posCoeff = 1 - exp(-1.0 / (0.006 * sampleRate))
        gainCoeff = 1 - exp(-1.0 / (0.004 * sampleRate))
    }

    func seed(seconds t: Double) {
        let f = t * sampleRate
        shared.withLock { $0.target = f; $0.seedPos = f; $0.needsSeed = true; $0.gainTarget = 1 }
    }
    func setTarget(seconds t: Double) { shared.withLock { $0.target = t * sampleRate } }
    func fadeOut() { shared.withLock { $0.gainTarget = 0 } }
    func currentSeconds() -> Double { shared.withLock { $0.playhead } / sampleRate }

    /// Move the read-head smoothly toward the disc position, one sample at a time, and gate
    /// the level by how fast it's moving — so fast drags scratch, slow settles fade to silence,
    /// and there are no per-callback discontinuities (the source of the harsh clicks).
    func render(frameCount n: Int, into abl: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        let (target, gainTarget, seedPos, doSeed): (Double, Double, Double, Bool) = shared.withLock {
            let v = ($0.target, $0.gainTarget, $0.seedPos, $0.needsSeed)
            $0.needsSeed = false
            return v
        }
        guard let data = channelData, frames > 1, n > 0 else {
            for b in abl { memset(b.mData, 0, Int(b.mDataByteSize)) }
            return noErr
        }
        if doSeed { playhead = seedPos; gain = 0 }

        // Cap the pitch so a fast drag plays the track (up to ~1.6×) forward/reverse
        // instead of chirping like a scratch — the music just goes the way you drag.
        let maxRate = 1.6
        // Don't let the disc position run more than ~0.3s ahead of what's playing, so the
        // audio tracks your finger and settles quickly when you stop (no long tail).
        let maxGap = 0.30 * sampleRate
        let goal = max(playhead - maxGap, min(playhead + maxGap, target))

        for i in 0..<n {
            let rate = max(-maxRate, min(maxRate, (goal - playhead) * posCoeff))
            playhead += rate
            gain += (gainTarget - gain) * gainCoeff
            // Fade out only when essentially stopped, so slow drags stay continuous.
            let motion = min(1.0, abs(rate) / 0.05)
            let level = Float(gain * motion)
            for ch in 0..<abl.count {
                guard let out = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                out[i] = Self.sample(data, min(ch, channels - 1), playhead, frames) * level
            }
        }
        shared.withLock { $0.playhead = playhead }
        return noErr
    }

    /// Linear interpolation between the two nearest samples (the resampling that makes the pitch).
    private static func sample(_ data: UnsafePointer<UnsafeMutablePointer<Float>>,
                               _ ch: Int, _ p: Double, _ frames: Int) -> Float {
        if p < 0 || p >= Double(frames - 1) { return 0 }
        let i = Int(p); let f = Float(p - Double(i))
        let a = data[ch][i], b = data[ch][i + 1]
        return a + (b - a) * f
    }
}

@MainActor
final class ScratchAudio {
    private let engine = AVAudioEngine()
    private let core = ScratchCore()
    private var node: AVAudioSourceNode?
    private(set) var loadedURL: URL?
    private var running = false
    private var tempFile: URL?
    private var stopToken = 0

    /// Carries the decoded buffer out of the background decode (AVAudioPCMBuffer isn't Sendable).
    private struct BufferBox: @unchecked Sendable { let buffer: AVAudioPCMBuffer; let format: AVAudioFormat }

    func isLoaded(_ url: URL?) -> Bool { url != nil && url == loadedURL }

    /// Decode a track into memory and wire up the source node. Local files decode directly;
    /// remote streams (Bandcamp) are downloaded to a temp file first so they can be scratched too.
    func preload(_ url: URL) async {
        guard url != loadedURL else { return }

        // Resolve to a locally-decodable file.
        let localURL: URL
        if url.isFileURL {
            localURL = url
        } else if let tmp = try? await Self.downloadToTemp(url) {
            localURL = tmp
        } else {
            return
        }
        // Only clean up a temp file WE downloaded — never the user's own local file.
        if Task.isCancelled {
            if localURL != url { try? FileManager.default.removeItem(at: localURL) }
            return
        }

        let box: BufferBox? = await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: localURL) else { return nil }
            let fmt = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
            do { try file.read(into: buf) } catch { return nil }
            return BufferBox(buffer: buf, format: fmt)
        }.value
        guard let box else { return }
        configure(box)
        loadedURL = url
        // Drop the previous stream's temp file, keep the current one alive.
        if let old = tempFile { try? FileManager.default.removeItem(at: old) }
        tempFile = (localURL == url) ? nil : localURL
    }

    /// Download a remote audio stream to a temp file so `AVAudioFile` can decode it.
    private static func downloadToTemp(_ url: URL) async throws -> URL {
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("yoin-scratch-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func configure(_ box: BufferBox) {
        if let n = node { engine.detach(n); node = nil }
        core.setBuffer(box.buffer)
        let n = Self.makeNode(format: box.format, core: core)
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: box.format)
        node = n
        engine.prepare()
    }

    /// Build the source node in a nonisolated context so its render block does NOT
    /// inherit `@MainActor`. The block runs on the real-time audio thread; if it were
    /// main-actor-isolated, Swift's executor check would trap (SIGTRAP) on every call.
    private nonisolated static func makeNode(format: AVAudioFormat, core: ScratchCore) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            core.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(abl))
        }
    }

    /// Start scratching from `t` seconds at the given output volume.
    func begin(atSeconds t: Double, volume: Double) {
        guard node != nil else { return }
        stopToken += 1                       // cancel any pending fade-out stop
        core.seed(seconds: t)
        engine.mainMixerNode.outputVolume = Float(volume)
        if !running { try? engine.start(); running = true }
    }

    /// Point the read-head at `t` seconds (called continuously while dragging).
    func update(toSeconds t: Double) { core.setTarget(seconds: t) }

    /// Fade the scratch out, then stop the engine a moment later (no cut-off click).
    /// Returns where the read-head ended up (seconds) so the player can resume there.
    @discardableResult
    func end() -> Double {
        let pos = core.currentSeconds()
        core.fadeOut()
        stopToken += 1
        let token = stopToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)   // let the gain ramp to 0
            guard token == stopToken else { return }          // a new scratch re-engaged
            engine.stop()
            running = false
        }
        return pos
    }
}
