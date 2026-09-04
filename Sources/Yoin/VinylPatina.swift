import SwiftUI

/// Play-count "wear" drawn onto a record: hairline surface scuffs plus a faint dust haze
/// toward the rim that both thicken the more an album has been played. Deterministic per
/// wear level, decorative, and non-interactive. Layer it inside a disc's ZStack (clipped to
/// a circle) so it rotates with the record.
struct VinylPatina: View {
    /// 0 = mint, 1 = well-loved. Map a play count with `VinylPatina.wear(forCount:)`.
    var wear: Double

    /// Ease a play count into a 0…1 wear amount that saturates around ~60 plays.
    static func wear(forCount count: Int) -> Double {
        guard count > 0 else { return 0 }
        return min(1, 1 - pow(1 - min(1, Double(count) / 60), 1.6))
    }

    var body: some View {
        if wear > 0.001 {
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                ZStack {
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        let r = s / 2
                        let n = Int(6 + wear * 30)
                        for i in 0..<n {
                            let rad = r * (0.28 + 0.68 * rnd(i, 1))
                            let a0 = rnd(i, 2) * 2 * .pi
                            let sweep = 0.04 + rnd(i, 3) * 0.55
                            var path = Path()
                            path.addArc(center: c, radius: rad,
                                        startAngle: .radians(a0), endAngle: .radians(a0 + sweep),
                                        clockwise: false)
                            let op = (0.04 + 0.11 * wear) * (0.5 + 0.5 * rnd(i, 4))
                            ctx.stroke(path, with: .color(.white.opacity(op)), lineWidth: 0.6)
                        }
                    }
                    // Dust haze that gathers toward the rim.
                    Circle().fill(
                        RadialGradient(colors: [.clear, .white.opacity(0.06 * wear)],
                                       center: .center, startRadius: s * 0.18, endRadius: s * 0.5)
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
        }
    }

    /// Cheap deterministic hash → 0…1, so the scuffs are stable frame-to-frame.
    private func rnd(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43_758.5453
        return x - floor(x)
    }
}
