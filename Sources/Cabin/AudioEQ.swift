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

/// A "room / vinyl" tone-shaping profile: a low-pass "muffle" + high-pass rolloff (like hearing
/// music through a wall or a cheap speaker) plus a `tanh` tube-saturation drive. Applied on the
/// same processing tap as the EQ, so it stacks with any EQ curve. `trim` makes up the perceived
/// loudness lost when a band is squeezed. All-zero = neutral (leaves the audio untouched).
struct RoomProfile: Equatable, Identifiable, Sendable {
    let name: String
    let lowpassHz: Double   // 0 = no low-pass (keep the highs)
    let highpassHz: Double  // 0 = no high-pass (keep the lows)
    let drive: Float        // tube saturation, 0 = clean; ~1–2.5 is musical
    let trim: Float         // linear output gain to recover lost energy
    /// Tape wow & flutter depth, 0 = off … ~1 = heavily warped. Drives a modulated delay line that
    /// wobbles the pitch (slow "wow" + fast "flutter"), like a worn cassette or a warped record.
    let wow: Float
    var id: String { name }
    var isNeutral: Bool {
        lowpassHz == 0 && highpassHz == 0 && drive == 0 && wow == 0 && abs(trim - 1) < 0.001
    }

    init(name: String, lowpassHz: Double, highpassHz: Double, drive: Float, trim: Float, wow: Float = 0) {
        self.name = name; self.lowpassHz = lowpassHz; self.highpassHz = highpassHz
        self.drive = drive; self.trim = trim; self.wow = wow
    }
}

/// The vinyl / room presets. Cutoffs and drives are deliberately gentle so music stays listenable;
/// the point is character, not destruction.
enum Room {
    static let off = RoomProfile(name: "Off", lowpassHz: 0, highpassHz: 0, drive: 0, trim: 1)
    static let presets: [RoomProfile] = [
        RoomProfile(name: "Tube Warmth",    lowpassHz: 0,    highpassHz: 0,   drive: 2.2, trim: 0.92),
        RoomProfile(name: "Living Room",    lowpassHz: 9000, highpassHz: 0,   drive: 1.0, trim: 1.0),
        RoomProfile(name: "Boombox",        lowpassHz: 6000, highpassHz: 220, drive: 1.6, trim: 1.25),
        RoomProfile(name: "Old Radio",      lowpassHz: 3200, highpassHz: 400, drive: 1.2, trim: 1.4),
        RoomProfile(name: "Through a Wall", lowpassHz: 1500, highpassHz: 120, drive: 0,   trim: 1.7),
        RoomProfile(name: "Basement Show",  lowpassHz: 5000, highpassHz: 90,  drive: 1.8, trim: 1.1),
        RoomProfile(name: "Worn Tape",      lowpassHz: 12000, highpassHz: 0,  drive: 1.2, trim: 1.0, wow: 0.5),
        RoomProfile(name: "Warped Cassette", lowpassHz: 7000, highpassHz: 60, drive: 1.5, trim: 1.1, wow: 1.0),
    ]

    static func preset(named name: String) -> RoomProfile {
        name == off.name ? off : (presets.first { $0.name == name } ?? off)
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

    // Set in prepare(), used in process().
    private var sampleRate: Double = 44_100
    private var channels: Int = 2
    // `setup` is only read/used by the render thread. New coefficient sets are built off the
    // render thread and published via `pendingSetup`; the render thread swaps the pointer under a
    // short lock (no allocation/free on the audio thread) and hands the superseded one back via
    // `retiredSetup` for the builder to free. This keeps the render callback allocation- and
    // free-free, avoiding the glitch/priority-inversion that live coeff rebuilds used to cause.
    private var setup: vDSP_biquad_Setup?
    private var pendingSetup: vDSP_biquad_Setup?
    private var retiredSetup: vDSP_biquad_Setup?
    private var delays: [[Float]] = []            // per-channel delay state (length 2*M+2)
    // 10 peaking EQ bands + 2 fixed "room" sections (low-pass muffle, high-pass rolloff). The room
    // sections are identity biquads when the room profile doesn't use them, so the cascade length —
    // and therefore the per-channel delay-state size — never changes at runtime.
    private let eqSections = EQ.bands.count
    private let sections = EQ.bands.count + 2

    /// Room/vinyl tone shaping applied after the EQ+filter cascade. `satDrive`/`satTrim` are the
    /// render-thread snapshot of it, updated (under `lock`) whenever a new setup is published.
    private var room: RoomProfile
    private var satDrive: Float = 0
    private var satTrim: Float = 1

    /// Wet/dry mix for the room effect, 0 = bypass … 1 = full strength — drives the FX "Amount"
    /// bar. `wetMix` is the render-thread snapshot; `scratch` holds the per-channel dry copy used
    /// only when the effect is dialled below full (allocated in prepare, never on the audio thread).
    private var wetMix: Float = 1
    private var scratch: [[Float]] = []
    private var maxFrames: Int = 4096

    // Tape wow & flutter: a per-channel delay line whose read head is modulated by a slow "wow"
    // LFO plus a faster "flutter" LFO, producing pitch wobble. Buffers/phases allocated in prepare;
    // `wowIntensity` is the render-thread snapshot (0 = bypassed).
    private var wowIntensity: Float = 0
    private var tapeBuf: [[Float]] = []       // per-channel ring buffer
    private var tapeWrite: [Int] = []         // per-channel write index
    private var tapeN = 0                      // ring length (samples)
    private var modBuf: [Double] = []          // per-frame delay (samples), shared across channels
    private var wowPhase = 0.0
    private var flutPhase = 0.0

    init(gains: [Float], room: RoomProfile = Room.off, amount: Float = 1) {
        self.gains = gains
        self.room = room
        satDrive = room.drive
        satTrim = room.trim
        wetMix = max(0, min(1, amount))
    }

    func setGains(_ g: [Float]) {
        os_unfair_lock_lock(&lock)
        gains = g
        let sr = sampleRate
        os_unfair_lock_unlock(&lock)
        buildSetup(sampleRate: sr)
    }

    func setRoom(_ r: RoomProfile) {
        os_unfair_lock_lock(&lock)
        room = r
        let sr = sampleRate
        os_unfair_lock_unlock(&lock)
        buildSetup(sampleRate: sr)
    }

    /// Live-update the wet/dry amount (0…1). Cheap — no coefficient rebuild.
    func setAmount(_ a: Float) {
        os_unfair_lock_lock(&lock)
        wetMix = max(0, min(1, a))
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Tap

    /// Build an `AVAudioMix` that runs this EQ over the item's first audio track. Returns nil when
    /// the track isn't available yet (remote streams load their tracks asynchronously — the caller
    /// should retry via `audioMix(for track:)` once they've loaded).
    func audioMix(for item: AVPlayerItem) -> AVAudioMix? {
        guard let track = item.asset.tracks(withMediaType: .audio).first else { return nil }
        return audioMix(for: track)
    }

    /// Build an `AVAudioMix` that runs this EQ over an already-loaded audio track.
    func audioMix(for track: AVAssetTrack) -> AVAudioMix? {
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

    fileprivate func prepare(sampleRate sr: Double, channels ch: Int, maxFrames mf: Int) {
        os_unfair_lock_lock(&lock)
        sampleRate = sr
        channels = max(1, ch)
        maxFrames = max(1, mf)
        delays = Array(repeating: [Float](repeating: 0, count: 2 * sections + 2), count: channels)
        // Pre-allocated dry-signal scratch (one contiguous buffer per channel) for the wet/dry mix.
        scratch = Array(repeating: [Float](repeating: 0, count: maxFrames), count: channels)
        // Tape delay line: ~30 ms is plenty for the wow/flutter centre (~6 ms) plus modulation.
        tapeN = max(1024, Int(0.03 * sr))
        tapeBuf = Array(repeating: [Float](repeating: 0, count: tapeN), count: channels)
        tapeWrite = Array(repeating: 0, count: channels)
        modBuf = [Double](repeating: 0, count: maxFrames)
        wowPhase = 0; flutPhase = 0
        os_unfair_lock_unlock(&lock)
        buildSetup(sampleRate: sr)
    }

    fileprivate func unprepareTap() {
        os_unfair_lock_lock(&lock)
        let s = setup, p = pendingSetup, r = retiredSetup
        setup = nil; pendingSetup = nil; retiredSetup = nil
        delays = []
        scratch = []
        tapeBuf = []; tapeWrite = []; tapeN = 0; modBuf = []
        os_unfair_lock_unlock(&lock)
        if let s { vDSP_biquad_DestroySetup(s) }
        if let p { vDSP_biquad_DestroySetup(p) }
        if let r { vDSP_biquad_DestroySetup(r) }
    }

    /// Compute coefficients and create a new biquad setup OFF the render thread, then publish it
    /// for the render thread to pick up. Any setup already superseded (an unconsumed pending, or
    /// one the render thread retired) is freed here — never on the audio thread.
    private func buildSetup(sampleRate sr: Double) {
        os_unfair_lock_lock(&lock)
        let g = gains
        let r = room
        os_unfair_lock_unlock(&lock)

        // 5 coefficients per section: b0, b1, b2, a1, a2 (a0 normalised to 1).
        var coeffs = [Double](); coeffs.reserveCapacity(sections * 5)
        let q = 1.41   // ~1 octave bandwidth
        for (i, f0) in EQ.bands.enumerated() {
            let gain = Double(g.indices.contains(i) ? g[i] : 0)
            let A = pow(10, gain / 40)
            let w0 = 2 * Double.pi * f0 / sr
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let b0 = 1 + alpha * A
            let b1 = -2 * cosw
            let b2 = 1 - alpha * A
            let a0 = 1 + alpha / A
            let a1 = -2 * cosw
            let a2 = 1 - alpha / A
            appendBiquad(&coeffs, b0, b1, b2, a0, a1, a2)
        }
        // Room low-pass "muffle", then high-pass rolloff (RBJ, Q≈0.707). Identity when unused so
        // the cascade always has `sections` sections and the delay buffers keep their size.
        appendLowpass(&coeffs, cutoff: r.lowpassHz, sampleRate: sr)
        appendHighpass(&coeffs, cutoff: r.highpassHz, sampleRate: sr)

        let newSetup = vDSP_biquad_CreateSetup(coeffs, vDSP_Length(sections))

        // Publish for the render thread, and reclaim anything already superseded (off-RT).
        os_unfair_lock_lock(&lock)
        satDrive = r.drive
        satTrim = r.trim
        wowIntensity = r.wow
        let stalePending = pendingSetup
        pendingSetup = newSetup
        let retired = retiredSetup
        retiredSetup = nil
        os_unfair_lock_unlock(&lock)
        if let stalePending { vDSP_biquad_DestroySetup(stalePending) }
        if let retired { vDSP_biquad_DestroySetup(retired) }
    }

    /// Append one normalised biquad section (a0 divided out).
    private func appendBiquad(_ c: inout [Double], _ b0: Double, _ b1: Double, _ b2: Double,
                              _ a0: Double, _ a1: Double, _ a2: Double) {
        c.append(b0 / a0); c.append(b1 / a0); c.append(b2 / a0)
        c.append(a1 / a0); c.append(a2 / a0)
    }

    private func appendLowpass(_ c: inout [Double], cutoff: Double, sampleRate sr: Double) {
        guard cutoff > 0 else { appendBiquad(&c, 1, 0, 0, 1, 0, 0); return }   // identity
        let f = min(cutoff, sr * 0.45)
        let w0 = 2 * Double.pi * f / sr, cosw = cos(w0), alpha = sin(w0) / (2 * 0.707)
        appendBiquad(&c, (1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha)
    }

    private func appendHighpass(_ c: inout [Double], cutoff: Double, sampleRate sr: Double) {
        guard cutoff > 0 else { appendBiquad(&c, 1, 0, 0, 1, 0, 0); return }   // identity
        let f = min(max(cutoff, 20), sr * 0.45)
        let w0 = 2 * Double.pi * f / sr, cosw = cos(w0), alpha = sin(w0) / (2 * 0.707)
        appendBiquad(&c, (1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha)
    }

    fileprivate func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        // Pointer-swap only — no allocation or free on the audio thread.
        os_unfair_lock_lock(&lock)
        if let np = pendingSetup {
            retiredSetup = setup   // hand the old one back for the builder to free off-RT
            setup = np
            pendingSetup = nil
        }
        let setup = self.setup
        let drive = satDrive
        let trim = satTrim
        let mix = wetMix
        let wow = wowIntensity
        let sr = sampleRate
        os_unfair_lock_unlock(&lock)
        guard let setup else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        let n = vDSP_Length(frames)
        let count = Int(frames)
        // Below full strength, keep a dry copy so the effect can be blended back (the "Amount" bar).
        let blend = mix < 0.999 && count <= maxFrames

        // Tape wow & flutter: precompute this frame's read-head delay (shared across channels) by
        // advancing a slow "wow" LFO plus a faster "flutter" LFO. Centre delay stays > modulation
        // so the read head never overruns the write head.
        let tape = wow > 0 && count <= maxFrames && tapeN > 2
        if tape {
            let twoPi = 2 * Double.pi
            let wInc = twoPi * 0.6 / sr           // wow ~0.6 Hz
            let fInc = twoPi * 6.5 / sr           // flutter ~6.5 Hz
            let center = 0.006 * sr               // 6 ms nominal delay
            let wAmp = Double(wow) * 0.004 * sr    // up to ±4 ms
            let fAmp = Double(wow) * 0.0009 * sr   // up to ±0.9 ms
            var wp = wowPhase, fp = flutPhase
            modBuf.withUnsafeMutableBufferPointer { m in
                for i in 0..<count {
                    m[i] = center + wAmp * sin(wp) + fAmp * sin(fp)
                    wp += wInc; fp += fInc
                }
            }
            wowPhase = wp.truncatingRemainder(dividingBy: twoPi)
            flutPhase = fp.truncatingRemainder(dividingBy: twoPi)
        }
        // Handles both non-interleaved (one buffer per channel) and interleaved (one buffer,
        // mNumberChannels > 1) float32 layouts.
        var channelIndex = 0
        for buffer in abl {
            let ch = Int(buffer.mNumberChannels)
            guard let data = buffer.mData else { continue }
            let floats = data.assumingMemoryBound(to: Float.self)
            for c in 0..<ch {
                guard channelIndex < delays.count else { break }
                let base = floats + c
                let stride = vDSP_Stride(ch)
                // Stash the dry (pre-effect) signal for the wet/dry blend below.
                if blend, channelIndex < scratch.count {
                    scratch[channelIndex].withUnsafeMutableBufferPointer { s in
                        cblas_scopy(Int32(count), base, Int32(ch), s.baseAddress!, 1)
                    }
                }
                delays[channelIndex].withUnsafeMutableBufferPointer { d in
                    vDSP_biquad(setup, d.baseAddress!, base, stride, base, stride, n)
                }
                // Room post-pass: tube saturation (soft-clip) and/or output trim. `tanh(d·x)/d`
                // is ≈ x for small signals (unity gain) and compresses peaks — a musical warmth.
                if drive > 0 {
                    let invD = 1 / drive
                    var i = 0
                    while i < count { base[i * ch] = tanhf(drive * base[i * ch]) * invD * trim; i += 1 }
                } else if trim != 1 {
                    var t = trim
                    vDSP_vsmul(base, stride, &t, base, stride, n)
                }
                // Tape wow & flutter: write each sample into the ring and read back a
                // fractionally-delayed one, so the modulated read head warps the pitch.
                if tape, channelIndex < tapeBuf.count {
                    let N = tapeN
                    tapeBuf[channelIndex].withUnsafeMutableBufferPointer { rb in
                        modBuf.withUnsafeBufferPointer { m in
                            var w = tapeWrite[channelIndex]
                            for i in 0..<count {
                                rb[w] = base[i * ch]
                                var r = Double(w) - m[i]
                                if r < 0 { r += Double(N) }
                                let i0 = Int(r)
                                let frac = Float(r - Double(i0))
                                let a = rb[i0]
                                let b = rb[i0 + 1 >= N ? 0 : i0 + 1]
                                base[i * ch] = a + (b - a) * frac
                                w += 1; if w >= N { w = 0 }
                            }
                            tapeWrite[channelIndex] = w
                        }
                    }
                }
                // Wet/dry blend: out = wet·mix + dry·(1−mix).
                if blend, channelIndex < scratch.count {
                    var wet = mix, dry = 1 - mix
                    vDSP_vsmul(base, stride, &wet, base, stride, n)
                    scratch[channelIndex].withUnsafeMutableBufferPointer { s in
                        vDSP_vsma(s.baseAddress!, 1, &dry, base, stride, base, stride, n)
                    }
                }
                channelIndex += 1
            }
        }
    }

    deinit {
        if let s = setup { vDSP_biquad_DestroySetup(s) }
        if let p = pendingSetup { vDSP_biquad_DestroySetup(p) }
        if let r = retiredSetup { vDSP_biquad_DestroySetup(r) }
    }
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
    eq.prepare(sampleRate: format.pointee.mSampleRate,
               channels: Int(format.pointee.mChannelsPerFrame), maxFrames: Int(maxFrames))
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
