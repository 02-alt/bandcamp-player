import SwiftUI

/// The "breathing" thinking-orb from the `thinking-orbs` library (`state="breathing"`),
/// ported to a SwiftUI Canvas. It's the library's "ring" mode: a monochrome ring of dots
/// (bands × segments) at a fixed tilt that slowly *morphs* via a gentle wobble — it does
/// not spin. Constants are the library's resolved `breathing @ 64` preset.
struct OrbLoader: View {
    var size: CGFloat = 28
    /// Multiplier on the preset's baked speed (the library's `speed` prop).
    var breathSpeed: Double = 0.45
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Resolved "breathing @ 64" (ring mode) preset.
    private let pitch = 0.3
    private let bands = 11          // round(lanes 3 × bandMul 3.627)
    private let segs = 44           // segs 88 × √(count 0.25)
    private let wobMul = 0.368
    private let rBase = 1.0516      // 1.1 × size-tune 0.956
    private let rDepth = 1.6252     // 1.7 × 0.956
    private let rMin = 0.3
    private let presetSpeed = 3.24

    var body: some View {
        Group {
            if reduceMotion {
                // Honour Reduce Motion: render a single static frame instead of the breathing loop.
                orb(phase: 0)
            } else {
                TimelineView(.animation) { tl in
                    orb(phase: tl.date.timeIntervalSinceReferenceDate * presetSpeed * breathSpeed)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // decorative; loading state is announced by the surrounding caption
    }

    @ViewBuilder private func orb(phase s: Double) -> some View {
        Canvas { ctx, sz in
                let dim = Double(min(sz.width, sz.height))
                let cx = sz.width / 2, cy = sz.height / 2
                let o = dim / 2 * 0.78
                let rScale = pow(dim / 300, 0.6)
                let sinP = sin(pitch), cosP = cos(pitch)
                let g = 0.23 * wobMul
                let d = o / (1 + 0.85 * g)
                let half = Double(bands - 1) / 2
                let dark = p.scheme == .dark

                // Build the dots, then draw back-to-front so nearer dots sit on top.
                var dots: [(x: CGFloat, y: CGFloat, z: Double, r: Double, white: Double, a: Double)] = []
                dots.reserveCapacity(bands * segs)
                for z in 0..<bands {
                    let lane = (Double(z) - half) * 0.075          // band offset across the ring's width
                    let b = abs(Double(z) - half) / half           // 0 (centre band) … 1 (edge band)
                    for iSeg in 0..<segs {
                        let ang = Double(iSeg) / Double(segs) * 2 * .pi
                        // The morph: a travelling undulation of the ring radius.
                        let wob = (0.16 * sin(ang * 3 - s * 1.7 + Double(z) * 0.22)
                                 + 0.07 * sin(ang * 5 + s * 1.1)) * wobMul
                        let radius = d * (1 + wob)
                        // Direction on the tilted ring (yaw 0, faceOn profile).
                        let q = cos(ang)
                        let f = cosP * sin(ang) + sinP * lane
                        let j = -sinP * sin(ang) + cosP * lane
                        let w = (q * q + f * f + j * j).squareRoot()
                        let mx = q / w * radius, my = f / w * radius, mz = j / w * radius
                        // Project (rotate by pitch about X), depth = zp.
                        let rp = my * cosP - mz * sinP
                        let zp = my * sinP + mz * cosP
                        let px = cx + CGFloat(mx)
                        let py = cy - CGFloat(rp)
                        let k = (zp / o + 1) / 2                    // 0 (far) … 1 (near)
                        let alpha = 0.4 + 0.6 * k
                        if alpha < 0.02 { continue }
                        let dotR = max(rMin, (rBase + rDepth * k) * (1 - 0.25 * b) * rScale)
                        let white = 0.52 - 0.44 * k + 0.18 * b
                        dots.append((px, py, zp, dotR, white, alpha))
                    }
                }
                dots.sort { $0.z < $1.z }
                for dot in dots {
                    let c = min(1, max(0, dot.white))
                    let lum = dark ? 1 - c : c                      // library's light/dark ink mapping
                    let r = CGFloat(dot.r)
                    let rect = CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Color(white: lum).opacity(dot.a)))
                }
            }
        }
    }

/// Orb + a caption, for full-width loading rows.
struct OrbLoadingRow: View {
    var text: String
    var size: CGFloat = 22
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: Space.s3) {
            OrbLoader(size: size)
            Text(text).font(.system(size: 13)).foregroundStyle(p.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}
