import SwiftUI

/// Bespoke per-album skins — a specific record can override the ambient look with its own
/// background and title treatment. Matched by title + artist so it survives re-imports.
enum AlbumTheme {
    /// Ray Webster — "Forever Alone": black sand + ocean, gold title.
    static func isForeverAlone(_ album: Album?) -> Bool {
        guard let album else { return false }
        return album.title.localizedCaseInsensitiveCompare("Forever Alone") == .orderedSame
            && album.artist.localizedCaseInsensitiveContains("Ray Webster")
    }

    /// Drake — "Honestly, Nevermind": holographic liquid-chrome on black.
    static func isHonestlyNevermind(_ album: Album?) -> Bool {
        guard let album else { return false }
        return album.title.localizedCaseInsensitiveContains("Honestly, Nevermind")
            && album.artist.localizedCaseInsensitiveContains("Drake")
    }

    /// Whether *any* special background skin applies to the now-playing album.
    static func hasBackground(_ album: Album?) -> Bool {
        isForeverAlone(album) || isHonestlyNevermind(album)
    }

    /// The bespoke background view for an album (call only when `hasBackground` is true).
    /// `colors` is the cover-derived palette (from AppState.ambientPalette) used by the chrome skin.
    @ViewBuilder static func background(for album: Album?, colors: [Color] = []) -> some View {
        if isHonestlyNevermind(album) {
            LiquidChromeBackground(colors: colors)
        } else {
            OceanWaveBackground()
        }
    }

    /// Which bespoke skin (if any) applies — used to pick a share-card background.
    enum CardSkin { case none, chrome, ocean }
    static func cardSkin(for album: Album?) -> CardSkin {
        if isHonestlyNevermind(album) { return .chrome }
        if isForeverAlone(album)      { return .ocean }
        return .none
    }

    /// A STATIC, ImageRenderer-safe version of the ambient background for the share card (the live
    /// backgrounds use a Metal shader / TimelineView which ImageRenderer can't rasterize). Uses the
    /// cover's own palette (`colors`, darkest → brightest) so the card matches the live ambient.
    @ViewBuilder static func cardBackground(_ skin: CardSkin, colors: [Color] = []) -> some View {
        switch skin {
        case .chrome:
            let ramp = colors.count >= 3 ? colors : LiquidChromeBackground.defaultRamp
            ZStack {
                LinearGradient(colors: [ramp[0].opacity(0.9), ramp[min(1, ramp.count-1)],
                                        ramp[min(2, ramp.count-1)]],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [ramp[min(2, ramp.count-1)].opacity(0.55), .clear],
                               center: .init(x: 0.6, y: 0.85), startRadius: 0, endRadius: 760)
                CardGrain().opacity(0.10)
            }
        case .ocean:
            ZStack {
                LinearGradient(colors: [Color(red: 0.02, green: 0.10, blue: 0.22),
                                        Color(red: 0.05, green: 0.24, blue: 0.42),
                                        Color(red: 0.01, green: 0.04, blue: 0.09)],
                               startPoint: .top, endPoint: .bottom)
                CardGrain().opacity(0.07)
            }
        case .none:
            Color.clear
        }
    }

    /// Brushed-gold gradient for a special album title.
    static let gold = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.93, blue: 0.66),
            Color(red: 0.90, green: 0.72, blue: 0.30),
            Color(red: 0.98, green: 0.86, blue: 0.52),
            Color(red: 0.78, green: 0.56, blue: 0.18)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Static film grain drawn with Canvas (renders inside ImageRenderer, unlike a Metal shader).
struct CardGrain: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> Double {   // fast deterministic LCG
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(UInt64(1) << 31)
            }
            let count = 14000
            for _ in 0..<count {
                let x = rnd() * size.width, y = rnd() * size.height
                let v = rnd()
                ctx.fill(Path(CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                         with: .color(.white.opacity(v * 0.5)))
            }
        }
        .blendMode(.overlay)
    }
}

/// Black ocean: a black base with soft blue/black wave bands drifting horizontally, echoing
/// the "Forever Alone" cover (black beach, blue sea). Used as the app background while that
/// record plays.
struct OceanWaveBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct Band {
        let color: Color
        let amp: CGFloat
        let speed: Double
        let yFrac: CGFloat
        let wavelength: CGFloat
        /// A faint white foam line along this wave's crest (0 = none).
        let foam: Double
    }

    private let bands: [Band] = [
        Band(color: Color(red: 0.03, green: 0.11, blue: 0.24), amp: 26, speed: 0.35, yFrac: 0.34, wavelength: 540, foam: 0.28),
        Band(color: Color(red: 0.05, green: 0.24, blue: 0.44), amp: 34, speed: -0.55, yFrac: 0.50, wavelength: 660, foam: 0.38),
        Band(color: Color(red: 0.10, green: 0.42, blue: 0.64), amp: 28, speed: 0.75, yFrac: 0.66, wavelength: 470, foam: 0.42),
        Band(color: Color(red: 0.01, green: 0.05, blue: 0.11), amp: 42, speed: -0.45, yFrac: 0.82, wavelength: 760, foam: 0.0)
    ]

    var body: some View {
        if reduceMotion {
            // Honour Reduce Motion: a single still frame of the ocean, no drifting waves.
            waves(t: 0)
        } else {
            TimelineView(.animation) { timeline in
                waves(t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    @ViewBuilder private func waves(t: Double) -> some View {
        Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                for band in bands {
                    let baseY = size.height * band.yFrac
                    // The wave crest, sampled once and reused for both fill and foam.
                    var crest = Path()
                    var x: CGFloat = 0
                    crest.move(to: CGPoint(x: 0, y: baseY + CGFloat(sin(t * band.speed)) * band.amp))
                    while x <= size.width {
                        let phase = Double(x / band.wavelength) * 2 * .pi + t * band.speed
                        crest.addLine(to: CGPoint(x: x, y: baseY + CGFloat(sin(phase)) * band.amp))
                        x += 8
                    }

                    var fill = crest
                    fill.addLine(to: CGPoint(x: size.width, y: size.height))
                    fill.addLine(to: CGPoint(x: 0, y: size.height))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(band.color))

                    if band.foam > 0 {
                        ctx.stroke(crest, with: .color(.white.opacity(band.foam)), lineWidth: 5)
                    }
                }
            }
            .blur(radius: 24)
            .drawingGroup()
        }
    }

/// Liquid-chrome / oil-slick: a near-black base with slow iridescent (steel/pink/cyan/violet/mint)
/// sheens drifting and hue-shifting like oil on water, gently "breathing." Echoes the holographic
/// chrome cover of Drake's "Honestly, Nevermind" while staying dark enough to keep content legible.
struct LiquidChromeBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Cover-derived ramp colours (from AppState.ambientPalette). Empty → the default trio.
    var colors: [Color] = []

    /// Default ramp if the cover yields nothing usable.
    static let defaultRamp: [Color] = [
        Color(red: 0.16, green: 0.13, blue: 0.45),
        Color(red: 0.62, green: 0.26, blue: 0.72),
        Color(red: 1.00, green: 0.52, blue: 0.22),
    ]

    /// Three ramp colours (darkest → brightest) as RGB tuples for the shader.
    private var ramp: [(Float, Float, Float)] {
        var src = colors.isEmpty ? Self.defaultRamp : colors
        while src.count < 3 { src.append(src.last ?? .gray) }
        return src.prefix(3).map { c in
            let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? .gray
            return (Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent))
        }
    }

    /// Vivid metallic-iridescent ramp — bright enough to read as flowing chrome, not a haze.
    private static let sheen: [Color] = [
        Color(red: 0.78, green: 0.82, blue: 0.90),   // silver
        Color(red: 0.96, green: 0.52, blue: 0.86),   // pink
        Color(red: 0.42, green: 0.86, blue: 0.97),   // cyan
        Color(red: 0.70, green: 0.54, blue: 0.99),   // violet
        Color(red: 0.55, green: 0.97, blue: 0.76),   // mint
        Color(red: 0.99, green: 0.86, blue: 0.55),   // warm gold
        Color(red: 0.78, green: 0.82, blue: 0.90),   // back to silver (seamless loop)
    ]

    /// The compiled Metal shader library. package.sh emits `default.metallib`; search the likely
    /// bundles for it (module bundle, main bundle, and any nested .bundle under Resources).
    private static let library: ShaderLibrary? = {
        var candidates: [URL] = []
        for b in [Bundle.module, Bundle.main] {
            if let u = b.url(forResource: "default", withExtension: "metallib") { candidates.append(u) }
        }
        // Fallback: scan Contents/Resources for a *.bundle containing default.metallib.
        if let res = Bundle.main.resourceURL,
           let items = try? FileManager.default.contentsOfDirectory(at: res, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "bundle" {
                let u = item.appendingPathComponent("default.metallib")
                if FileManager.default.fileExists(atPath: u.path) { candidates.append(u) }
            }
        }
        return candidates.first.map { ShaderLibrary(url: $0) }
    }()

    var body: some View {
        if let lib = Self.library {
            if reduceMotion {
                // Honour Reduce Motion: one still frame of the oil-slick, no drift/breathing.
                slick(lib: lib, t: 0)
            } else {
                TimelineView(.animation) { tl in
                    // Wrap time to keep Float precision high (avoids animation jitter over long runs).
                    slick(lib: lib, t: Float(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)))
                }
            }
        } else {
            fallback   // shader unavailable — a calm dark iridescent gradient
        }
    }

    @ViewBuilder private func slick(lib: ShaderLibrary, t: Float) -> some View {
        let r = ramp
        GeometryReader { geo in
            Rectangle()
                .colorEffect(lib.oilSlick(
                    .float2(Float(geo.size.width), Float(geo.size.height)),
                    .float(t),
                    .float3(r[0].0, r[0].1, r[0].2),
                    .float3(r[1].0, r[1].1, r[1].2),
                    .float3(r[2].0, r[2].1, r[2].2)))
                .blur(radius: 40)                    // soft, but keeps the colour drips readable
                .scaleEffect(1.14)                   // hide blur's edge falloff
                .overlay(Rectangle().colorEffect(lib.filmGrain(.float(t)))
                    .blendMode(.overlay).opacity(0.08))   // faint film texture
                // Frosted veil keeps foreground content legible; use an opaque scrim under Reduce Transparency.
                .overlay(reduceTransparency
                         ? AnyView(Rectangle().fill(Color.black.opacity(0.5)))
                         : AnyView(Rectangle().fill(.ultraThinMaterial).opacity(0.30)))
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.18)],
                                        startPoint: .top, endPoint: .bottom))
                .clipped()
        }
    }

    /// Non-Metal fallback (kept simple and non-ugly): a dark base with a couple of soft
    /// iridescent glows. Only used if the shader library fails to load.
    private var fallback: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Self.sheen[2].opacity(0.30), .clear],
                           center: .init(x: 0.35, y: 0.4), startRadius: 0, endRadius: 500).blur(radius: 80)
            RadialGradient(colors: [Self.sheen[1].opacity(0.25), .clear],
                           center: .init(x: 0.7, y: 0.7), startRadius: 0, endRadius: 460).blur(radius: 80)
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
