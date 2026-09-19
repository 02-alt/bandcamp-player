import SwiftUI

/// How the Now Playing screen draws its hero disc.
enum NowPlayingStyle: String, CaseIterable, Identifiable {
    case flat, turntable, firstListen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flat:        "Flat disc"
        case .turntable:   "Turntable"
        case .firstListen: "First Listen"
        }
    }
    var blurb: String {
        switch self {
        case .flat:        "A clean spinning cover"
        case .turntable:   "Record on a platter, with a progress ring"
        case .firstListen: "A focused room — lyrics, credits & liner notes"
        }
    }

    /// The fuller explanation shown beneath the picker for the selected style.
    var detail: String {
        switch self {
        case .flat:
            "Flat disc keeps it simple: the cover art spins as a clean disc, no platter or wear — just the artwork, edge to edge."
        case .turntable:
            "Turntable turns the hero disc into a record on a platter, ringed by a progress track, with vinyl wear and surface crackle — and a 33/45/78 speed switch that shrinks it to a single and repitches the track."
        case .firstListen:
            "First Listen is a focused room for the album in front of you: time-synced lyrics, per-song credits and the artist's liner notes, with everything else out of the way."
        }
    }
}

/// The static, rotationally-symmetric face of a record: groove rings, play-count wear and the
/// crackle scatter, flattened once into a Metal texture (`drawingGroup`). Conforms to `Equatable`
/// on its only real inputs (`size`, `wear`) so SwiftUI short-circuits it when the owning screen
/// re-renders for an unrelated reason — e.g. the Now Playing progress tick — instead of
/// re-rasterising the gradient + 16 rings + two Canvases each time.
struct RecordArt: View, Equatable {
    var size: CGFloat
    var wear: Double

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.12), .black],
                                         center: .center, startRadius: size * 0.05, endRadius: size / 2))
            ForEach(0..<16) { i in
                Circle().strokeBorder(.white.opacity(0.05), lineWidth: 0.7)
                    .padding(size * 0.03 + CGFloat(i) * size * 0.028)
            }
            VinylPatina(wear: wear).clipShape(Circle())
            VinylCrackle(wear: wear).clipShape(Circle())
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .drawingGroup()
    }

    nonisolated static func == (l: RecordArt, r: RecordArt) -> Bool { l.size == r.size && l.wear == r.wear }
}

/// A compact-disc face — reflective silver with a rainbow iridescent sheen, fine data-track
/// rings and a clear mirror hub. Used in place of `RecordArt` for CD-era statement albums
/// (e.g. Yeezus's artwork-less clear jewel case). Static + Equatable like `RecordArt`.
struct CDArt: View, Equatable {
    var size: CGFloat

    private static let spectrum: [Color] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red
    ]

    var body: some View {
        ZStack {
            // Reflective silver base.
            Circle().fill(RadialGradient(colors: [Color(white: 0.86), Color(white: 0.58), Color(white: 0.80)],
                                         center: .center, startRadius: size * 0.08, endRadius: size / 2))
            // Rainbow iridescence swept around the disc.
            Circle().fill(AngularGradient(gradient: Gradient(colors: Self.spectrum), center: .center))
                .opacity(0.38).blendMode(.plusLighter)
            // Fine data-track rings.
            ForEach(0..<24, id: \.self) { i in
                Circle().strokeBorder(.white.opacity(0.05), lineWidth: 0.5)
                    .padding(size * 0.11 + CGFloat(i) * size * 0.016)
            }
            // Specular highlight (fixed light source).
            Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear],
                                         center: .init(x: 0.32, y: 0.26), startRadius: 0, endRadius: size * 0.42))
                .blendMode(.plusLighter)
            // Clear mirror hub + stacking ring.
            Circle().fill(Color(white: 0.9)).frame(width: size * 0.34, height: size * 0.34)
            Circle().strokeBorder(Color(white: 0.55), lineWidth: 1).frame(width: size * 0.34, height: size * 0.34)
            Circle().strokeBorder(Color(white: 0.5).opacity(0.5), lineWidth: 2).frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .drawingGroup()
    }

    nonisolated static func == (l: CDArt, r: CDArt) -> Bool { l.size == r.size }
}

/// Analog "warmth" laid over a record: a warm rim vignette plus a sparse scatter of bright dust
/// pops — the visual side of surface crackle. Deterministic and static (cheap, and safe under
/// Reduce Motion). Intensity rides the play-count `wear`, on top of a faint always-on base so a
/// pristine record still looks like vinyl, not glass. Layer it clipped to the disc so it spins.
struct VinylCrackle: View {
    /// 0…1, from `VinylPatina.wear(forCount:)`.
    var wear: Double

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let amount = 0.25 + 0.75 * wear     // base warmth even when mint
            ZStack {
                // Warm brown-amber vignette toward the rim — the "played-in" glow.
                Circle().fill(
                    RadialGradient(colors: [.clear, Color(red: 0.45, green: 0.30, blue: 0.16).opacity(0.10 * amount)],
                                   center: .center, startRadius: s * 0.16, endRadius: s * 0.5)
                )
                .blendMode(.softLight)

                // Dust pops: tiny bright specks scattered over the grooves.
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = s / 2
                    let n = Int(40 + amount * 90)
                    for i in 0..<n {
                        let rad = r * (0.30 + 0.66 * rnd(i, 1))
                        let a = rnd(i, 2) * 2 * .pi
                        let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
                        let d = 0.4 + 1.1 * rnd(i, 3)
                        let op = (0.05 + 0.14 * amount) * (0.4 + 0.6 * rnd(i, 4))
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x, y: pt.y, width: d, height: d)),
                                 with: .color(.white.opacity(op)))
                    }
                }
                .blendMode(.plusLighter)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    /// Cheap deterministic hash → 0…1, so the crackle is stable frame-to-frame.
    private func rnd(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43_758.5453
        return x - floor(x)
    }
}
