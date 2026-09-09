import SwiftUI

/// A deterministic RNG (SplitMix64) so a place's skyline + sky are stable across launches yet each
/// place gets its own look. Seeded from the place string.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The procedural night city itself — sky gradient, stars, an optional moon, and a two-layer
/// building silhouette with lit windows — all seeded from `title`. No text/tag, so it works both as
/// a big tile background and as a tiny saved-station thumbnail; the caller sizes and clips it.
struct NightCitySky: View, Equatable {
    let title: String

    // Memoised by title so unrelated app-state changes (e.g. opening a right-click menu) don't
    // force the Canvas to redraw its whole skyline — that redraw storm briefly janks input.
    nonisolated static func == (l: NightCitySky, r: NightCitySky) -> Bool { l.title == r.title }

    /// Stable seed from the name (String.hashValue is randomised per run, so fold scalars instead).
    private var seed: UInt64 {
        title.lowercased().unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
    }

    /// Dark night-sky gradients (top → bottom). All deep enough that white text and black building
    /// silhouettes stay legible on top.
    private static let skies: [[Color]] = [
        [rgb(0.05, 0.06, 0.16), rgb(0.11, 0.13, 0.30)],   // indigo
        [rgb(0.10, 0.04, 0.18), rgb(0.26, 0.10, 0.32)],   // purple night
        [rgb(0.02, 0.09, 0.14), rgb(0.05, 0.22, 0.28)],   // teal night
        [rgb(0.14, 0.05, 0.12), rgb(0.32, 0.11, 0.24)],   // magenta dusk
        [rgb(0.03, 0.05, 0.10), rgb(0.09, 0.11, 0.22)],   // midnight blue
        [rgb(0.11, 0.07, 0.03), rgb(0.30, 0.16, 0.07)],   // amber city glow
        [rgb(0.04, 0.10, 0.11), rgb(0.06, 0.16, 0.22)],   // deep cyan
        [rgb(0.09, 0.05, 0.14), rgb(0.16, 0.08, 0.28)],   // violet
    ]

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b) }

    var body: some View { Canvas { ctx, size in draw(&ctx, size) } }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var gen = SeededGenerator(seed: seed)
        // Draw in a fixed reference square and scale it to the tile, so resizing the window only
        // scales the same city rather than regenerating a different skyline each width.
        let ref: CGFloat = 400
        ctx.scaleBy(x: size.width / ref, y: size.height / ref)
        let W = ref, H = ref

        // Sky.
        let sky = Self.skies[Int(seed % UInt64(Self.skies.count))]
        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)),
                 with: .linearGradient(Gradient(colors: sky),
                                       startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))

        // Stars (upper ~60%, out of the skyline).
        let stars = Int.random(in: 20...36, using: &gen)
        for _ in 0..<stars {
            let x = Double.random(in: 0...W, using: &gen)
            let y = Double.random(in: 0...(H * 0.6), using: &gen)
            let r = Double.random(in: 0.4...1.5, using: &gen)
            let a = Double.random(in: 0.2...0.9, using: &gen)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(a)))
        }

        // A moon, sometimes.
        if Bool.random(using: &gen) {
            let mr = Double.random(in: W * 0.05...W * 0.085, using: &gen)
            let mx = Double.random(in: W * 0.6...W * 0.88, using: &gen)
            let my = Double.random(in: H * 0.12...H * 0.26, using: &gen)
            ctx.fill(Path(ellipseIn: CGRect(x: mx - mr, y: my - mr, width: mr * 2, height: mr * 2)),
                     with: .color(.white.opacity(0.9)))
            ctx.fill(Path(ellipseIn: CGRect(x: mx - mr * 1.7, y: my - mr * 1.7, width: mr * 3.4, height: mr * 3.4)),
                     with: .color(.white.opacity(0.06)))   // faint halo
        }

        // Horizon glow rising behind the skyline (the sky's warm/bright base bleeding up).
        let glow = sky.last ?? .black
        ctx.fill(Path(CGRect(x: 0, y: H * 0.5, width: W, height: H * 0.5)),
                 with: .linearGradient(Gradient(colors: [glow.opacity(0), glow.opacity(0.7)]),
                                       startPoint: CGPoint(x: 0, y: H * 0.5), endPoint: CGPoint(x: 0, y: H)))

        // Skyline: a hazy, shorter back layer, then a darker front layer with lit windows.
        drawSkyline(&ctx, &gen, W: W, H: H, minH: H * 0.16, maxH: H * 0.36,
                    color: Self.rgb(0.05, 0.05, 0.11).opacity(0.85), lit: false)
        drawSkyline(&ctx, &gen, W: W, H: H, minH: H * 0.28, maxH: H * 0.60,
                    color: Self.rgb(0.015, 0.015, 0.04), lit: true)
    }

    /// One row of buildings across the width, sitting on the bottom edge.
    private func drawSkyline(_ ctx: inout GraphicsContext, _ gen: inout SeededGenerator,
                             W: CGFloat, H: CGFloat, minH: CGFloat, maxH: CGFloat, color: Color, lit: Bool) {
        var x = -CGFloat(Double.random(in: 0...20, using: &gen))
        while x < W {
            let bw = CGFloat(Double.random(in: Double(W) * 0.08...Double(W) * 0.19, using: &gen))
            let bh = CGFloat(Double.random(in: Double(minH)...Double(maxH), using: &gen))
            let rect = CGRect(x: x, y: H - bh, width: bw + 1, height: bh)
            ctx.fill(Path(rect), with: .color(color))
            // Occasional rooftop antenna on the front layer.
            if lit, Bool.random(using: &gen) {
                let ah = CGFloat(Double.random(in: 4...16, using: &gen))
                ctx.fill(Path(CGRect(x: rect.midX - 1, y: rect.minY - ah, width: 2, height: ah)), with: .color(color))
            }
            if lit { drawWindows(&ctx, &gen, in: rect) }
            x += bw + CGFloat(Double.random(in: 1...5, using: &gen))
        }
    }

    /// A grid of small warm windows on a building, roughly half of them lit.
    private func drawWindows(_ ctx: inout GraphicsContext, _ gen: inout SeededGenerator, in rect: CGRect) {
        let cell: CGFloat = 6, pad: CGFloat = 4, ww: CGFloat = 2.4, wh: CGFloat = 3
        let cols = max(1, Int((rect.width - pad * 2) / cell))
        let rows = max(1, Int((rect.height - pad * 2) / cell))
        guard rows > 0, cols > 0 else { return }
        for r in 0..<rows {
            for c in 0..<cols {
                guard Double.random(in: 0...1, using: &gen) < 0.45 else { continue }
                let wx = rect.minX + pad + CGFloat(c) * cell
                let wy = rect.minY + pad + CGFloat(r) * cell
                let bright = Double.random(in: 0.35...0.9, using: &gen)
                ctx.fill(Path(CGRect(x: wx, y: wy, width: ww, height: wh)),
                         with: .color(Color(.sRGB, red: 1.0, green: 0.86, blue: 0.55).opacity(bright)))
            }
        }
    }
}

/// A place-radio tile: the procedural night city with the place name set in white "in the sky",
/// plus the radio glyph and RADIO tag — the square "Made for you"-style card for a place station.
struct NightCityTile: View, Equatable {
    let title: String
    let loading: Bool

    nonisolated static func == (l: NightCityTile, r: NightCityTile) -> Bool { l.title == r.title && l.loading == r.loading }

    var body: some View {
        ZStack {
            NightCitySky(title: title).equatable()
            // Name in the sky (upper portion, clear of the skyline).
            GeometryReader { geo in
                Text(title)
                    .font(.system(size: 23, weight: .heavy)).kerning(-0.5)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                    .frame(width: geo.size.width - 20, alignment: .center)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.30)
            }
            // Radio glyph (top-left) + tag (bottom-left), matching the artist mixes.
            VStack {
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                }
                Spacer()
                HStack {
                    Text("RADIO").font(.system(size: 9, weight: .heavy)).kerning(1.2)
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                }
            }
            .padding(12)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            if loading {
                ZStack {
                    Rectangle().fill(.black.opacity(0.4))
                    VStack(spacing: 6) {
                        OrbLoader(size: 26)
                        Text("Starting…").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
    }
}
