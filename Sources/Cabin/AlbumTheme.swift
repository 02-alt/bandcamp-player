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

    /// Kanye West — "Yeezus": no cover art, clear jewel case with a strip of red tape.
    /// Stark black + a slashed red tape strip + industrial scanlines.
    static func isYeezus(_ album: Album?) -> Bool {
        guard let album else { return false }
        return album.title.localizedCaseInsensitiveContains("Yeezus")
            && album.artist.localizedCaseInsensitiveContains("Kanye")
    }

    /// Sun Kil Moon / Mark Kozelek — "Admiral Fell Promises": solo nylon guitar, quiet and
    /// melancholic. A warm candle-lit nocturne.
    static func isAdmiralFellPromises(_ album: Album?) -> Bool {
        guard let album else { return false }
        return album.title.localizedCaseInsensitiveContains("Admiral Fell Promises")
    }

    /// ptite soeur, neophron & FEMTOGO — "Pretty Dollcorpse": beauty-meets-decay. Gothic pastel
    /// rotting into horror — creeping veins, a heartbeat pulse, failing light and doll eyes.
    static func isPrettyDollcorpse(_ album: Album?) -> Bool {
        guard let album else { return false }
        return album.title.localizedCaseInsensitiveContains("Dollcorpse")
    }

    /// Whether *any* special background skin applies to the now-playing album.
    static func hasBackground(_ album: Album?) -> Bool {
        isForeverAlone(album) || isHonestlyNevermind(album)
            || isYeezus(album) || isAdmiralFellPromises(album) || isPrettyDollcorpse(album)
    }

    /// The bespoke background view for an album (call only when `hasBackground` is true).
    /// `colors` is the cover-derived palette (from AppState.ambientPalette) used by the chrome skin.
    @ViewBuilder static func background(for album: Album?, colors: [Color] = []) -> some View {
        if isHonestlyNevermind(album) {
            LiquidChromeBackground(colors: colors)
        } else if isYeezus(album) {
            YeezusBackground()
        } else if isAdmiralFellPromises(album) {
            OldPaperBackground()
        } else if isPrettyDollcorpse(album) {
            DollcorpseBackground()
        } else {
            OceanWaveBackground()
        }
    }

    /// Special title colour/gradient for an album, if any (else nil → use the normal style).
    static func titleStyle(for album: Album?) -> AnyShapeStyle? {
        if isForeverAlone(album)         { return AnyShapeStyle(gold) }
        if isYeezus(album)               { return AnyShapeStyle(Color.white) }
        if isAdmiralFellPromises(album)  { return AnyShapeStyle(silver) }
        if isPrettyDollcorpse(album)     { return AnyShapeStyle(roseRot) }
        return nil
    }

    /// Whether this album's hero disc should render as a CD instead of vinyl (Yeezus was a
    /// CD-era, artwork-less statement — the clear jewel case).
    static func usesCD(_ album: Album?) -> Bool { isYeezus(album) }

    /// Which bespoke skin (if any) applies — used to pick a share-card background.
    enum CardSkin { case none, chrome, ocean, clearcase, paper, dollcorpse }
    static func cardSkin(for album: Album?) -> CardSkin {
        if isHonestlyNevermind(album)   { return .chrome }
        if isForeverAlone(album)        { return .ocean }
        if isYeezus(album)              { return .clearcase }
        if isAdmiralFellPromises(album) { return .paper }
        if isPrettyDollcorpse(album)    { return .dollcorpse }
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
        case .clearcase:
            ZStack {
                Color.black
                CardGrain().opacity(0.06)
            }
        case .paper:
            ZStack {
                RadialGradient(colors: [Color(white: 0.19), Color(white: 0.10), Color(white: 0.03)],
                               center: .init(x: 0.5, y: 0.45), startRadius: 40, endRadius: 820)
                CardGrain().opacity(0.20)
            }
        case .dollcorpse:
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.14),
                                        Color(red: 0.05, green: 0.03, blue: 0.06)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 0.55, green: 0.34, blue: 0.42).opacity(0.22), .clear],
                               center: .init(x: 0.5, y: 0.4), startRadius: 0, endRadius: 640)
                RadialGradient(colors: [.clear, Color(red: 0.32, green: 0.02, blue: 0.04).opacity(0.6)],
                               center: .center, startRadius: 220, endRadius: 760)
                CardGrain().opacity(0.10)
            }
        case .none:
            Color.clear
        }
    }

    /// Sickly rose→bruise for a horror-pastel title (Pretty Dollcorpse).
    static let roseRot = LinearGradient(
        colors: [Color(red: 0.93, green: 0.74, blue: 0.80), Color(red: 0.70, green: 0.30, blue: 0.42),
                 Color(red: 0.40, green: 0.10, blue: 0.20)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Soft silver→grey for a quiet monochrome title (Admiral Fell Promises).
    static let silver = LinearGradient(
        colors: [Color(white: 0.95), Color(white: 0.80), Color(white: 0.62)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

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
            // ~24fps instead of the display's 60 — the full-screen Canvas rebuild + blur(24) +
            // drawingGroup is heavy, and drifting waves read fine at this rate.
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
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
        // NB: `Bundle.cabinResources` is non-trapping; SwiftPM's `Bundle.module` fatal-errors when
        // the resource bundle is missing from the hand-packaged .app.
        for b in [Bundle.cabinResources, Bundle.main].compactMap({ $0 }) {
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

    /// The app's compiled shader library, for other views (e.g. the animated cover). Nil if the
    /// `default.metallib` couldn't be located — callers should fall back to a static presentation.
    static var sharedLibrary: ShaderLibrary? { library }

    var body: some View {
        if let lib = Self.library {
            content(lib: lib)
        } else {
            fallback   // shader unavailable — a calm dark iridescent gradient
        }
    }

    @ViewBuilder private func content(lib: ShaderLibrary) -> some View {
        // Compute the ramp once per body evaluation (on `colors` change) rather than every
        // animation frame — the NSColor→deviceRGB conversions were needless per-frame CPU.
        let r = ramp
        if reduceMotion {
            // Honour Reduce Motion: one still frame of the oil-slick, no drift/breathing.
            slick(lib: lib, ramp: r, t: 0)
        } else {
            // ~30fps: the shader + blur(40) is GPU-heavy and the "breathing" reads fine slower.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                // Wrap time to keep Float precision high (avoids animation jitter over long runs).
                slick(lib: lib, ramp: r, t: Float(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)))
            }
        }
    }

    @ViewBuilder private func slick(lib: ShaderLibrary, ramp r: [(Float, Float, Float)], t: Float) -> some View {
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

/// "Yeezus" skin: stark black with a strip of red tape stuck to the RIGHT edge, running off the
/// border — recreating the famous cover (a bare CD + red tape). Faint scanlines + grain.
/// "Yeezus" skin — total restraint: pure black with only a whisper of film grain. The album
/// stripped everything away to focus on the music; so does this.
struct YeezusBackground: View {
    var body: some View {
        ZStack {
            Color.black
            CardGrain().opacity(0.06)
        }
        .ignoresSafeArea()
    }
}

/// A strip of real duct tape (photo texture: fabric weave, torn edges, sheen) tinted red — the
/// Yeezus cover tape. Fills its frame; anchor it to a border so it reads as stuck-on tape.
struct RedTape: View {
    var label: Bool = false

    /// The tape photo (transparent PNG), loaded once from the resource bundle.
    private static let image: NSImage? = {
        for b in [Bundle.cabinResources, Bundle.main].compactMap({ $0 }) {
            if let u = b.url(forResource: "yeezus-tape", withExtension: "png"),
               let img = NSImage(contentsOf: u) { return img }
        }
        return nil
    }()

    var body: some View {
        Group {
            if let img = Self.image {
                ZStack {
                    // Red tape shape from the image's alpha (torn edges + wrinkle outline).
                    Image(nsImage: img).renderingMode(.template).resizable()
                        .aspectRatio(contentMode: .fill)
                        .foregroundStyle(LinearGradient(
                            colors: [Color(red: 0.95, green: 0.15, blue: 0.08),
                                     Color(red: 0.72, green: 0.05, blue: 0.03)],
                            startPoint: .top, endPoint: .bottom))
                    // The original grey shading blended back on top → wrinkles + sheen in red.
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .blendMode(.overlay).opacity(0.85)
                }
                .compositingGroup()
                .overlay {
                    if label {
                        Text("YEEZUS")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.7))
                            .rotationEffect(.degrees(90))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .padding(.trailing, 10)
                    }
                }
            } else {
                Rectangle().fill(Color(red: 0.90, green: 0.14, blue: 0.07))
            }
        }
        .allowsHitTesting(false)
    }
}

/// "Admiral Fell Promises" skin: a faded photograph / old letter — dim, warm sepia paper with
/// soft foxing stains, a darkened vignette and heavy film grain. Vintage, literary, fully static.
/// Kept dark-toned so the app's light text stays legible over it.
struct OldPaperBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func rnd(_ i: Int, _ k: Int) -> CGFloat {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43_758.5453
        return CGFloat(x - floor(x))
    }

    @ViewBuilder private func content(_ t: Double) -> some View {
        ZStack {
            // Flat, dim aged paper — no central hotspot (edges darkened separately below).
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.06)],
                           startPoint: .top, endPoint: .bottom)
            // Foxing / age stains — soft irregular blotches, blurred and low-contrast.
            Canvas { ctx, size in
                for i in 0..<14 {
                    let x = rnd(i, 1) * size.width
                    let y = rnd(i, 2) * size.height
                    let d = 40 + rnd(i, 3) * 170
                    let dark = rnd(i, 4) > 0.5
                    let c = dark ? Color(white: 0.16) : Color(white: 0.55)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - d/2, y: y - d/2, width: d, height: d)),
                             with: .color(c.opacity(0.08 + rnd(i, 5) * 0.10)))
                }
            }
            .blur(radius: 34)
            .blendMode(.softLight)
            // Dust motes drifting slowly up through the lamp light.
            DustMotes(t: t)
            // Cursive ink that writes itself on, then erases, in a slow loop.
            Handwriting(t: t)
            // Occasional film scratches flickering vertically.
            FilmScratches(t: t)
            // Darkened, worn edges.
            RadialGradient(colors: [.clear, Color(white: 0.02).opacity(0.75)],
                           center: .center, startRadius: 260, endRadius: 780)
            // A soft light leak sweeping across now and then.
            LightLeak(t: t)
            // Heavy film grain, with a gentle projector flicker.
            CardGrain().opacity(0.20 + 0.05 * sin(t * 2.3))
        }
    }

    var body: some View {
        Group {
            if reduceMotion {
                content(0)
            } else {
                TimelineView(.animation) { tl in
                    content(tl.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Faint dust specks drifting slowly upward through lamp light. `t` in seconds.
struct DustMotes: View {
    var t: Double
    private func rnd(_ i: Int, _ k: Int) -> CGFloat {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43_758.5453
        return CGFloat(x - floor(x))
    }
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            for i in 0..<46 {
                let speed = 4 + rnd(i, 2) * 11                       // slow, px/sec upward
                let phase = rnd(i, 3) * h
                let y = h - (phase + CGFloat(t) * speed).truncatingRemainder(dividingBy: h)
                let sway = CGFloat(sin(t * 0.3 + Double(i))) * (4 + rnd(i, 5) * 9)
                let x = rnd(i, 1) * w + sway
                let d = 1 + rnd(i, 4) * 2.2
                let op = 0.04 + rnd(i, 6) * 0.09
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                         with: .color(Color(white: 0.85).opacity(op)))
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// Faint cursive ink ("promises…") that writes itself on left→right, holds, then erases in a
/// slow loop — like old ink appearing and fading on the page. `t` in seconds.
struct Handwriting: View {
    var t: Double
    private var progress: Double {
        let period = 18.0
        let ph = t.truncatingRemainder(dividingBy: period) / period
        if ph < 0.50 { return ph / 0.50 }                 // write on (slow, like a pen)
        if ph < 0.62 { return 1 }                         // hold
        if ph < 0.95 { return 1 - (ph - 0.62) / 0.33 }    // erase
        return 0                                          // blank gap
    }
    var body: some View {
        Text("Admiral Fell Promises")
            .font(.custom("Snell Roundhand", size: 38))
            .italic()
            .fixedSize()
            .foregroundStyle(Color.white.opacity(0.22))
            .shadow(color: .white.opacity(0.10), radius: 2)   // faint ink bleed
            .mask(
                // A moving pen tip: revealed up to `progress`, with a soft forming edge.
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: max(0, progress - 0.04)),
                    .init(color: .clear, location: min(1, progress)),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            )
            .rotationEffect(.degrees(-3), anchor: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 48).padding(.leading, 44)
            .allowsHitTesting(false)
    }
}

/// Thin white film scratches that flash vertically now and then. `t` in seconds.
struct FilmScratches: View {
    var t: Double
    private func rnd(_ i: Int, _ k: Int) -> CGFloat {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43_758.5453
        return CGFloat(x - floor(x))
    }
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<7 {
                let cycle = 3.0 + Double(rnd(i, 1)) * 6
                let ph = (t + Double(rnd(i, 2)) * cycle).truncatingRemainder(dividingBy: cycle) / cycle
                let vis = ph < 0.08 ? (1 - ph / 0.08) : 0     // a brief flash
                if vis <= 0 { continue }
                let x = rnd(i, 3) * size.width + CGFloat(sin(t * 13 + Double(i))) * 2
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x + (rnd(i, 4) - 0.5) * 8, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.05 + 0.11 * vis)),
                           lineWidth: 0.6 + rnd(i, 5) * 0.8)
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// A soft bright band that sweeps across the frame periodically, like a light leak on film.
struct LightLeak: View {
    var t: Double
    var body: some View {
        GeometryReader { geo in
            let period = 22.0
            let ph = t.truncatingRemainder(dividingBy: period) / period
            let x = -0.3 + (ph / 0.4) * 1.6                    // moves across during first 40%
            let env = ph < 0.4 ? sin(.pi * ph / 0.4) : 0       // smooth fade in/out
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .white.opacity(0.5), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * 0.35, height: geo.size.height * 1.7)
                .rotationEffect(.degrees(18))
                .position(x: geo.size.width * CGFloat(x), y: geo.size.height * 0.5)
                .blendMode(.screen)
                .opacity(0.18 * env)
        }
        .allowsHitTesting(false)
    }
}

/// "Pretty Dollcorpse" skin — gothic pastel rotting into horror: a sickly rose base with creeping
/// veins, a dark-red heartbeat pulse, failing light, and doll eyes that surface from the murk.
struct DollcorpseBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Failing-light brightness multiplier: gentle shimmer + occasional strong dip.
    private func flicker(_ t: Double) -> Double {
        let shimmer = 0.04 * sin(t * 20)
        let dip = (sin(t * 3.1) * sin(t * 7.3) > 0.9) ? -0.42 : 0
        return max(0.35, 1.0 + shimmer + dip)
    }
    /// Heartbeat envelope (a double thump), ~0…1.6.
    private func heartbeat(_ t: Double) -> Double {
        let x = (t / 1.15).truncatingRemainder(dividingBy: 1)
        func thump(_ c: Double, _ wdt: Double) -> Double { exp(-pow((x - c) / wdt, 2)) }
        return thump(0.02, 0.05) + 0.7 * thump(0.20, 0.05)
    }
    /// Doll-eye emergence 0…1 — mostly hidden, rising occasionally.
    private func eyeReveal(_ t: Double) -> Double { pow(max(0, sin(t * 0.13)), 6) }

    @ViewBuilder private func content(_ t: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let beat = heartbeat(t)
            ZStack {
                // Gothic pastel base — sickly rose/lilac fading into dark plum.
                LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.14),
                                        Color(red: 0.05, green: 0.03, blue: 0.06)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 0.55, green: 0.34, blue: 0.42).opacity(0.22), .clear],
                               center: .init(x: 0.5, y: 0.4), startRadius: 0, endRadius: h * 0.8)
                    .blendMode(.screen)
                // Blood seeping from the top.
                LinearGradient(colors: [Color(red: 0.22, green: 0.01, blue: 0.02).opacity(0.5), .clear],
                               startPoint: .top, endPoint: .center)
                    .blendMode(.multiply)
                // Heartbeat: a dark-red vignette pulsing inward.
                RadialGradient(colors: [.clear, Color(red: 0.32, green: 0.02, blue: 0.04).opacity(0.5 + 0.35 * beat)],
                               center: .center, startRadius: h * (0.34 - 0.06 * beat), endRadius: h * 0.9)
                CardGrain().opacity(0.10)
                // Failing light: darken everything on the flicker dips.
                Color.black.opacity(max(0, 1 - flicker(t)))
            }
            .frame(width: w, height: h)
        }
    }

    var body: some View {
        Group {
            if reduceMotion { content(0) }
            else { TimelineView(.animation) { tl in content(tl.date.timeIntervalSinceReferenceDate) } }
        }
        .ignoresSafeArea()
    }
}

/// Dark tendrils of rot branching inward from the screen edges. Static, deterministic.
struct Veins: View {
    private func rnd(_ i: Int, _ k: Int) -> CGFloat {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43_758.5453
        return CGFloat(x - floor(x))
    }
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            for s in 0..<11 {
                let edge = Int(rnd(s, 1) * 4) % 4
                var cur: CGPoint
                var ang: Double
                switch edge {
                case 0: cur = CGPoint(x: rnd(s, 2) * w, y: 0);  ang = .pi / 2
                case 1: cur = CGPoint(x: w, y: rnd(s, 2) * h);  ang = .pi
                case 2: cur = CGPoint(x: rnd(s, 2) * w, y: h);  ang = -.pi / 2
                default: cur = CGPoint(x: 0, y: rnd(s, 2) * h); ang = 0
                }
                var p = Path()
                p.move(to: cur)
                for j in 0..<14 {
                    ang += Double(rnd(s * 13 + j, 4) - 0.5) * 0.9
                    let len = 16 + rnd(s * 13 + j, 3) * 34
                    cur = CGPoint(x: cur.x + CGFloat(cos(ang)) * len, y: cur.y + CGFloat(sin(ang)) * len)
                    p.addLine(to: cur)
                }
                ctx.stroke(p, with: .color(Color(red: 0.08, green: 0.01, blue: 0.02).opacity(0.75)),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
        .blur(radius: 0.6)
        .allowsHitTesting(false)
    }
}

/// A pair of pale doll eyes (sclera, iris, pupil, catchlight), softly blurred so they read as
/// something surfacing from the dark. Opacity is set by the caller.
struct DollEyes: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let eyeW = w * 0.05, eyeH = eyeW * 0.72
            ForEach([-1.0, 1.0], id: \.self) { s in
                ZStack {
                    Ellipse().fill(Color(red: 0.93, green: 0.87, blue: 0.87))
                        .frame(width: eyeW, height: eyeH)
                    Circle().fill(Color(red: 0.16, green: 0.05, blue: 0.09))
                        .frame(width: eyeH * 0.72, height: eyeH * 0.72)
                    Circle().fill(Color.black).frame(width: eyeH * 0.32, height: eyeH * 0.32)
                    Circle().fill(Color.white.opacity(0.85)).frame(width: eyeH * 0.13, height: eyeH * 0.13)
                        .offset(x: -eyeH * 0.1, y: -eyeH * 0.1)
                }
                .position(x: w * 0.5 + CGFloat(s) * w * 0.055, y: h * 0.40)
            }
        }
        .blur(radius: 3)
        .allowsHitTesting(false)
    }
}
