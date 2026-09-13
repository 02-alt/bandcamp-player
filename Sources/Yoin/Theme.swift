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

/// Monochrome palette resolved from the active color scheme.
struct Palette {
    let scheme: ColorScheme

    var text: Color      { scheme == .dark ? Color(white: 0.96) : Color(white: 0.09) }
    var muted: Color     { scheme == .dark ? Color(white: 0.70) : Color(white: 0.38) }
    // Faintest text tier (section headers, captions, subtitles). Content now sits on the
    // cover-tinted ambient (no glass scrim), which lifts the background luminance — so these
    // tiers are brightened (dark) / darkened (light) to keep ≥4.5:1 (WCAG AA) over that wash.
    var muted2: Color    { scheme == .dark ? Color(white: 0.68) : Color(white: 0.42) }
    var page: Color      { scheme == .dark ? Color(white: 0.047) : Color(white: 0.906) }
    var accent: Color    { text }
    var accentInk: Color { page }

    var edge: Color      { scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.90) }
    var edgeSoft: Color  { scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06) }
    var glassFill: Color { scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.45) }

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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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

    // True only when real Liquid Glass is actually drawn (macOS 26, transparency on) — the case
    // where `pure` can safely drop the scrim without losing legibility.
    private var pureGlass: Bool {
        guard pure, !reduceTransparency else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

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
            .overlay { shape.stroke(rim, lineWidth: 1) }
            .shadow(color: .black.opacity(pureGlass ? 0.16 : (glow ? 0.5 : 0.28)),
                    radius: pureGlass ? 10 : (glow ? 26 : 20), x: 0, y: pureGlass ? 4 : (glow ? 16 : 12))
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
