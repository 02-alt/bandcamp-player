import AVFoundation
import CoreGraphics

/// Computes a real amplitude waveform (peak bins, 0…1) from a local audio file, cached per
/// path. Remote streams aren't analysed — callers fall back to the placeholder `Waveform.bars`.
enum WaveformAnalyzer {
    nonisolated(unsafe) private static var cache: [String: [CGFloat]] = [:]
    private static let lock = NSLock()

    static func cached(_ url: URL) -> [CGFloat]? {
        lock.lock(); defer { lock.unlock() }
        return cache[url.path]
    }

    private static func store(_ peaks: [CGFloat], for url: URL) {
        lock.lock(); defer { lock.unlock() }
        cache[url.path] = peaks
    }

    /// Peaks for `url` (cached). Nil for remote/unreadable files.
    static func peaks(url: URL, bins: Int = 100) async -> [CGFloat]? {
        guard url.isFileURL else { return nil }
        if let c = cached(url) { return c }
        guard let result = await compute(url: url, bins: bins) else { return nil }
        store(result, for: url)
        return result
    }

    private static func compute(url: URL, bins: Int) async -> [CGFloat]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let rate = 8_000.0   // plenty for an envelope, keeps memory small
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
        guard reader.startReading() else { return nil }

        var samples: [Float] = []
        if let dur = try? await asset.load(.duration) {
            samples.reserveCapacity(Int(CMTimeGetSeconds(dur) * rate))
        }
        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let base = ptr else { continue }
            let count = length / MemoryLayout<Float>.size
            base.withMemoryRebound(to: Float.self, capacity: count) { fp in
                samples.append(contentsOf: UnsafeBufferPointer(start: fp, count: count))
            }
        }
        guard reader.status != .failed, !samples.isEmpty else { return nil }

        // Max absolute amplitude per bin, then normalise to 0…1.
        let binSize = max(1, samples.count / bins)
        var peaks: [CGFloat] = []
        peaks.reserveCapacity(bins)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + binSize)
            var m: Float = 0
            for j in i..<end { m = max(m, abs(samples[j])) }
            peaks.append(CGFloat(m))
            i = end
        }
        let mx = peaks.max() ?? 1
        if mx > 0 { for k in peaks.indices { peaks[k] = peaks[k] / mx } }
        return peaks
    }
}
