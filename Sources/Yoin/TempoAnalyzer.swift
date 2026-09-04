import AVFoundation

/// Best-effort BPM estimation for local audio files, used to beat-match crossfades.
/// Analysis is coarse (energy-flux onset envelope + autocorrelation) and cached per file.
/// Remote streams aren't analysed — AVAssetReader can't reliably read them — so those
/// transitions fall back to a plain crossfade.
@MainActor
final class TempoAnalyzer {
    static let shared = TempoAnalyzer()

    private var cache: [String: Double] = [:]
    private var inFlight: Set<String> = []

    /// The detected BPM if it's already been computed, else nil (kick off `prefetch` first).
    func cachedBPM(for url: URL) -> Double? { url.isFileURL ? cache[url.path] : nil }

    /// Cached BPM, computing (and caching) it now if needed. Nil for remote/unreadable files.
    /// The analysis runs off the main actor; only the cache read/write is main-isolated.
    func bpm(for url: URL) async -> Double? {
        guard url.isFileURL else { return nil }
        if let c = cache[url.path] { return c }
        let bpm = await Self.detectBPM(url: url)
        if let bpm { cache[url.path] = bpm }
        return bpm
    }

    /// Analyse `url` in the background (once) so its BPM is ready by the time we crossfade.
    func prefetch(_ url: URL) {
        guard url.isFileURL else { return }
        let key = url.path
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let bpm = await Self.detectBPM(url: url)
            await MainActor.run {
                if let bpm { self.cache[key] = bpm }
                self.inFlight.remove(key)
            }
        }
    }

    // MARK: Analysis

    /// Read up to the first 90s as mono PCM, build a coarse onset envelope, and pick the
    /// tempo (70–180 BPM) whose lag maximises the envelope's autocorrelation.
    nonisolated static func detectBPM(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let rate = 11_025.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: rate,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 90, preferredTimescale: 600))
        guard reader.startReading() else { return nil }

        // RMS energy per hop → an envelope sampled at rate/hop (~21.5 Hz).
        let hop = 512
        var envelope: [Float] = []
        var sumSq: Float = 0
        var n = 0
        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let base = ptr else { continue }
            let count = length / MemoryLayout<Float>.size
            base.withMemoryRebound(to: Float.self, capacity: count) { fp in
                for i in 0..<count {
                    let s = fp[i]
                    sumSq += s * s
                    n += 1
                    if n == hop {
                        envelope.append((sumSq / Float(hop)).squareRoot())
                        sumSq = 0; n = 0
                    }
                }
            }
        }
        guard reader.status != .failed, envelope.count > 40 else { return nil }

        // Half-wave-rectified difference = onset flux.
        var flux = [Float](repeating: 0, count: envelope.count)
        for i in 1..<envelope.count { flux[i] = max(0, envelope[i] - envelope[i - 1]) }
        let mean = flux.reduce(0, +) / Float(flux.count)
        for i in flux.indices { flux[i] -= mean }

        let envRate = rate / Double(hop)
        var bestBPM = 0.0
        var bestScore: Float = -.greatestFiniteMagnitude
        var bpm = 70.0
        while bpm <= 180.0 {
            let lag = Int((60.0 / bpm) * envRate)
            if lag > 0, lag < flux.count - 8 {
                var s: Float = 0
                var i = lag
                while i < flux.count { s += flux[i] * flux[i - lag]; i += 1 }
                if s > bestScore { bestScore = s; bestBPM = bpm }
            }
            bpm += 0.5
        }
        return bestBPM > 0 ? bestBPM : nil
    }
}
