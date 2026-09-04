import AVFoundation
import Accelerate
import os
import SwiftUI

/// A named 10-band graphic-EQ curve (gains in dB at ISO octave centres).
struct EQPreset: Equatable, Identifiable, Sendable {
    let name: String
    let gains: [Float]
    var id: String { name }
    var isFlat: Bool { gains.allSatisfy { abs($0) < 0.01 } }
}

/// EQ presets + the ISO band centres. Values are conservative starting points drawn from the
/// common genre-EQ guides (rock = V-curve, loudness = bass+treble, etc.).
enum EQ {
    static let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static let flat = EQPreset(name: "Flat", gains: Array(repeating: 0, count: 10))
    static let presets: [EQPreset] = [
        flat,
        EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble",     gains: [0, 0, 0, 0, 0, 0, 1, 2, 3, 4]),
        EQPreset(name: "Vocal",      gains: [-2, -1, 0, 1, 3, 3, 2, 1, 0, -1]),
        EQPreset(name: "Rock",       gains: [4, 3, 1, -1, -1, 0, 1, 2, 3, 3]),
        EQPreset(name: "Pop",        gains: [2, 1, 0, 1, 2, 2, 1, 0, 1, 2]),
        EQPreset(name: "Jazz",       gains: [3, 2, 1, 1, -1, -1, 0, 1, 2, 2]),
        EQPreset(name: "Loudness",   gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
    ]

    static func preset(named name: String) -> EQPreset { presets.first { $0.name == name } ?? flat }

    /// Pick a preset from an album's genre tag (the "Auto" mode).
    static func auto(forGenre genre: String) -> EQPreset {
        let g = genre.lowercased()
        if g.contains("rock") || g.contains("metal") || g.contains("punk") { return preset(named: "Rock") }
        if g.contains("jazz") || g.contains("blues") || g.contains("soul") { return preset(named: "Jazz") }
        if g.contains("pop") { return preset(named: "Pop") }
        if g.contains("hip") || g.contains("rap") || g.contains("bass") || g.contains("electronic") || g.contains("techno") || g.contains("house") { return preset(named: "Bass Boost") }
        if g.contains("class") || g.contains("acoustic") || g.contains("folk") || g.contains("ambient") { return preset(named: "Vocal") }
        return flat
    }
}

/// Real-time 10-band EQ implemented as a cascade of peaking biquads, driven by an
/// `MTAudioProcessingTap` on an `AVPlayerItem`. One instance per deck; gains can be updated
/// live from the main thread and are picked up by the render callback under a fast lock.
///
/// The tap is only attached when the EQ is enabled (see `PlayerEngine`), so a Flat/off EQ
/// leaves the normal AVPlayer path completely untouched.
final class AudioEQ: @unchecked Sendable {
    private var gains: [Float]
    private var lock = os_unfair_lock_s()
    private var coeffsDirty = true

    // Set in prepare(), used in process().
    private var sampleRate: Double = 44_100
    private var channels: Int = 2
    private var setup: vDSP_biquad_Setup?
    private var delays: [[Float]] = []            // per-channel delay state (length 2*M+2)
    private let sections = EQ.bands.count

    init(gains: [Float]) { self.gains = gains }

    func setGains(_ g: [Float]) {
        os_unfair_lock_lock(&lock)
        gains = g
        coeffsDirty = true
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Tap

    /// Build an `AVAudioMix` that runs this EQ over the item's first audio track.
    func audioMix(for item: AVPlayerItem) -> AVAudioMix? {
        guard let track = item.asset.tracks(withMediaType: .audio).first else { return nil }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare,
            unprepare: tapUnprepare, process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<AudioEQ>.fromOpaque(callbacks.clientInfo!).release()   // balance passRetained
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: Called from the tap callbacks (fromOpaque)

    fileprivate func prepare(sampleRate sr: Double, channels ch: Int) {
        sampleRate = sr
        channels = max(1, ch)
        delays = Array(repeating: [Float](repeating: 0, count: 2 * sections + 2), count: channels)
        coeffsDirty = true
        rebuildSetupIfNeeded()
    }

    fileprivate func unprepareTap() {
        if let s = setup { vDSP_biquad_DestroySetup(s); setup = nil }
        delays = []
    }

    private func rebuildSetupIfNeeded() {
        os_unfair_lock_lock(&lock)
        let dirty = coeffsDirty
        let g = gains
        coeffsDirty = false
        os_unfair_lock_unlock(&lock)
        guard dirty else { return }

        // 5 coefficients per section: b0, b1, b2, a1, a2 (a0 normalised to 1).
        var coeffs = [Double](); coeffs.reserveCapacity(sections * 5)
        let q = 1.41   // ~1 octave bandwidth
        for (i, f0) in EQ.bands.enumerated() {
            let gain = Double(g.indices.contains(i) ? g[i] : 0)
            let A = pow(10, gain / 40)
            let w0 = 2 * Double.pi * f0 / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let b0 = 1 + alpha * A
            let b1 = -2 * cosw
            let b2 = 1 - alpha * A
            let a0 = 1 + alpha / A
            let a1 = -2 * cosw
            let a2 = 1 - alpha / A
            coeffs.append(b0 / a0); coeffs.append(b1 / a0); coeffs.append(b2 / a0)
            coeffs.append(a1 / a0); coeffs.append(a2 / a0)
        }
        if let old = setup { vDSP_biquad_DestroySetup(old) }
        setup = vDSP_biquad_CreateSetup(coeffs, vDSP_Length(sections))
    }

    fileprivate func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        rebuildSetupIfNeeded()
        guard let setup else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        let n = vDSP_Length(frames)
        // Handles both non-interleaved (one buffer per channel) and interleaved (one buffer,
        // mNumberChannels > 1) float32 layouts.
        var channelIndex = 0
        for buffer in abl {
            let ch = Int(buffer.mNumberChannels)
            guard let data = buffer.mData else { continue }
            let floats = data.assumingMemoryBound(to: Float.self)
            for c in 0..<ch {
                guard channelIndex < delays.count else { break }
                delays[channelIndex].withUnsafeMutableBufferPointer { d in
                    vDSP_biquad(setup, d.baseAddress!,
                                floats + c, vDSP_Stride(ch),
                                floats + c, vDSP_Stride(ch), n)
                }
                channelIndex += 1
            }
        }
    }

    deinit { if let s = setup { vDSP_biquad_DestroySetup(s) } }
}

// MARK: - C tap callbacks (no context capture; state travels via the tap storage pointer)

private func tapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                     _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo   // the retained AudioEQ passed in clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioEQ>.fromOpaque(storage).release()   // balance passRetained
}

private func tapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                        _ format: UnsafePointer<AudioStreamBasicDescription>) {
    let eq = Unmanaged<AudioEQ>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    eq.prepare(sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame))
}

private func tapUnprepare(_ tap: MTAudioProcessingTap) {
    let eq = Unmanaged<AudioEQ>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    eq.unprepareTap()
}

private func tapProcess(_ tap: MTAudioProcessingTap, _ numberFrames: CMItemCount,
                        _ flags: MTAudioProcessingTapFlags,
                        _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    var frames = numberFrames
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                    flagsOut, nil, &frames)
    guard status == noErr else { return }
    numberFramesOut.pointee = frames
    let eq = Unmanaged<AudioEQ>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    eq.process(bufferListInOut, frames: frames)
}

/// An interactive 10-band graphic EQ: drag each vertical fader to set that band's gain, with
/// the frequency labelled under each column. Drives `onChange(band, dB)`.
struct EQEditor: View {
    let gains: [Float]
    let onChange: (Int, Float) -> Void
    @Environment(\.palette) private var p

    private let range: Float = 12   // ±12 dB

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(Array(EQ.bands.enumerated()), id: \.offset) { i, f in
                VStack(spacing: 5) {
                    fader(i).frame(maxWidth: .infinity)
                    Text(label(f)).font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(p.muted2)
                }
            }
        }
        .accessibilityLabel("Equalizer")
    }

    private func fader(_ i: Int) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let mid = h / 2
            let g = gains.indices.contains(i) ? gains[i] : 0
            let frac = CGFloat(max(-range, min(range, g)) / range)   // -1 … +1
            let handleY = mid - frac * mid
            ZStack {
                Capsule().fill(p.glassFill).frame(width: 4)                    // track
                Rectangle().fill(p.edgeSoft).frame(height: 1).position(x: w / 2, y: mid)  // 0 dB
                // Fill from centre to the handle.
                Capsule().fill(p.text.opacity(0.55))
                    .frame(width: 4, height: abs(frac) * mid)
                    .position(x: w / 2, y: (mid + handleY) / 2)
                Circle().fill(p.text).frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .position(x: w / 2, y: handleY)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .modifier(LinkCursor())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = Float((mid - v.location.y) / mid)                       // +1 top … -1 bottom
                onChange(i, max(-range, min(range, f * range)))
            })
        }
        .frame(height: 104)
    }

    private func label(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}
