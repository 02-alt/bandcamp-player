import SwiftUI

/// Spacing scale (base 4), mirrors the prototype.
/// Use these steps only — never arbitrary values — so padding/stacks share one rhythm.
/// Intent: s1 hairline gaps · s2/s3 within a tight group · s4/s5 between related blocks ·
/// s6/s7 between distinct sections · s8 page-scale breathing room.
enum Space {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32
    static let s7: CGFloat = 48
    static let s8: CGFloat = 64
}

enum Radius {
    static let card: CGFloat = 26
    static let sm: CGFloat = 16
    static let pill: CGFloat = 999
}

/// Cabin's type scale: the macOS text-style sizes (Large Title 26, Title 22, Title 2 17, Title 3 15,
/// Body 13, Callout 12, Subheadline 11, Caption 10 — the floor). Set as plain system fonts rather
/// than `.body` etc. because on macOS the text styles add extra leading (Body lays out at 19pt vs
/// 16pt), which would loosen every tuned layout. Use these instead of `.system(size:)` literals;
/// add `.weight(_:)` / `.monospacedDigit()` as needed.
extension Font {
    static let uiLargeTitle = Font.system(size: 26)
    static let uiTitle = Font.system(size: 22)
    static let uiTitle2 = Font.system(size: 17)
    static let uiTitle3 = Font.system(size: 15)
    static let uiBody = Font.system(size: 13)
    static let uiCallout = Font.system(size: 12)
    static let uiSubheadline = Font.system(size: 11)
    static let uiCaption = Font.system(size: 10)
}

/// Monochrome palette resolved from the active color scheme.
struct Palette {
    let scheme: ColorScheme
    /// System "Increase contrast": full-strength text, one muted tier, and visible hairlines.
    var highContrast: Bool = false

    var text: Color      {
        if highContrast { return scheme == .dark ? .white : .black }
        return scheme == .dark ? Color(white: 0.96) : Color(white: 0.09)
    }
    var muted: Color     {
        if highContrast { return scheme == .dark ? Color(white: 0.84) : Color(white: 0.20) }
        return scheme == .dark ? Color(white: 0.74) : Color(white: 0.33)
    }
    // Faintest text tier (section headers, captions, subtitles). Content sits on the cover-tinted
    // ambient (no glass scrim), which shifts the background luminance — so the tiers keep headroom
    // above WCAG AA on the plain page (light: muted 6.1:1, muted2 5.0:1 on 0.906; dark ≈ 9:1) to
    // stay ≥4.5:1 over that wash. (Light muted2 was 0.42 = 4.3:1, failing AA.)
    var muted2: Color    {
        if highContrast { return muted }
        return scheme == .dark ? Color(white: 0.70) : Color(white: 0.38)
    }
    var page: Color      { scheme == .dark ? Color(white: 0.047) : Color(white: 0.906) }
    var accent: Color    { text }
    var accentInk: Color { page }

    var edge: Color      {
        if highContrast { return scheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.55) }
        return scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.90)
    }
    var edgeSoft: Color  {
        if highContrast { return scheme == .dark ? Color.white.opacity(0.32) : Color.black.opacity(0.32) }
        return scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
    var glassFill: Color {
        if highContrast { return scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08) }
        return scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.45)
    }

    var blob1: Color     { scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.80) }
    var blob2: Color     { scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(scheme: .dark)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Liquid Glass surface (ported from the notch app's "black glass")

/// The signature surface: real `.glassEffect(.regular)` frosting + refraction, with a
/// size-independent scrim for the smoked-black darkness (a glass *tint* is dropped by the
/// system above ~65pt, so the darkness lives in a scrim over the glass, behind content),
/// and a manual top-lit gradient rim that restores the light-catching edge.
struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var interactive: Bool = false
    var glow: Bool = false
    /// Pure system Liquid Glass: drop the darkening scrim and heavy drop shadow so the real
    /// `.glassEffect` refraction reads clean (like the native tab-bar pill), instead of being
    /// muted by a smoked-black fill. Only affects macOS 26 with transparency on; the material
    /// fallback and Reduce-Transparency substitute are unchanged.
    var pure: Bool = false
    /// Cover-derived colour to bleed through the glass. When set, the darkening scrim is
    /// lightened and tinted so the ambient wash behind the panel reads through the frost.
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparencySetting
    @Environment(\.colorSchemeContrast) private var contrast
    /// Reduce Transparency or Increase Contrast → the opaque surface, so text never sits on frost.
    private var reduceTransparency: Bool { reduceTransparencySetting || contrast == .increased }

    private var scrim: Color {
        // A tinted panel keeps a thinner scrim so the colour behind shows; untinted keeps
        // the original smoked-black darkness.
        let dark = tint == nil ? 0.55 : 0.40
        let light = tint == nil ? 0.50 : 0.38
        return scheme == .dark ? Color.black.opacity(dark) : Color.white.opacity(light)
    }
    private var rim: LinearGradient {
        let top = scheme == .dark ? 0.18 : 0.90
        return LinearGradient(
            colors: [Color.white.opacity(top), Color.white.opacity(top * 0.35)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // True when real Liquid Glass is drawn (macOS 26, transparency on). System glass brings its
    // own specular edge and depth, so the painted rim/shadow (which only made sense over the old
    // material) are dropped there — stacking them doubled the edge and muted the refraction.
    private var realGlass: Bool {
        guard !reduceTransparency else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }
    // Real glass with `pure` — the case where the scrim can go too without losing legibility.
    private var pureGlass: Bool { pure && realGlass }

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    // Opaque substitute so the frost never shows through when the user asks
                    // for reduced transparency — this is the surface that keeps text legible.
                    shape.fill(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
                    if let tint { shape.fill(tint.opacity(scheme == .dark ? 0.28 : 0.20)) }
                } else if pureGlass {
                    // No scrim: let the system glass refract cleanly. Only an optional tint bleeds.
                    if let tint {
                        shape.fill(tint.opacity(scheme == .dark ? 0.14 : 0.10))
                            .blendMode(.plusLighter)
                    }
                } else {
                    shape.fill(scrim)
                    if let tint {
                        shape.fill(tint.opacity(scheme == .dark ? 0.22 : 0.16))
                            .blendMode(.plusLighter)
                    }
                }
            }
            .modifier(RealGlass(shape: shape, interactive: interactive, disabled: reduceTransparency))
            .overlay { if !realGlass { shape.stroke(rim, lineWidth: 1) } }
            // Floating drawers/panels (`glow`) keep a soft lift off the page on real glass; chips
            // and bars rely on the system's own depth.
            .shadow(color: .black.opacity(realGlass ? (glow ? 0.22 : 0) : (glow ? 0.5 : 0.28)),
                    radius: realGlass ? 18 : (glow ? 26 : 20), x: 0, y: realGlass ? 8 : (glow ? 16 : 12))
    }
}

/// Uses Apple's Liquid Glass on macOS 26+, falling back to a material on older systems.
private struct RealGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive: Bool = false
    /// When true (Reduce Transparency), skip the frosting entirely — the caller has already
    /// supplied an opaque background.
    var disabled: Bool = false
    func body(content: Content) -> some View {
        if disabled {
            content
        } else if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// A rounded-rectangle Liquid Glass panel. Pass `tint` to bleed the ambient cover
    /// colour through the frost.
    func glass(radius: CGFloat = Radius.card, glow: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), glow: glow, tint: tint))
    }
    /// Liquid Glass over an arbitrary shape — for circular / capsule controls.
    func glass<S: Shape>(in shape: S, interactive: Bool = false, glow: Bool = false, tint: Color? = nil, pure: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, glow: glow, pure: pure, tint: tint))
    }
}
