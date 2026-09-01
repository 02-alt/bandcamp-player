import SwiftUI

/// Spacing scale (base 4), mirrors the prototype.
enum Space {
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32
    static let s7: CGFloat = 48
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
    var muted: Color     { scheme == .dark ? Color(white: 0.63) : Color(white: 0.42) }
    var muted2: Color    { scheme == .dark ? Color(white: 0.39) : Color(white: 0.66) }
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
    @Environment(\.colorScheme) private var scheme

    private var scrim: Color {
        scheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.50)
    }
    private var rim: LinearGradient {
        let top = scheme == .dark ? 0.18 : 0.90
        return LinearGradient(
            colors: [Color.white.opacity(top), Color.white.opacity(top * 0.35)],
            startPoint: .top, endPoint: .bottom
        )
    }

    func body(content: Content) -> some View {
        content
            .background { shape.fill(scrim) }
            .modifier(RealGlass(shape: shape, interactive: interactive))
            .overlay { shape.stroke(rim, lineWidth: 1) }
            .shadow(color: .black.opacity(glow ? 0.5 : 0.28),
                    radius: glow ? 26 : 20, x: 0, y: glow ? 16 : 12)
    }
}

/// Uses Apple's Liquid Glass on macOS 26+, falling back to a material on older systems.
private struct RealGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive: Bool = false
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// A rounded-rectangle Liquid Glass panel.
    func glass(radius: CGFloat = Radius.card, glow: Bool = false) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), glow: glow))
    }
    /// Liquid Glass over an arbitrary shape — for circular / capsule controls.
    func glass<S: Shape>(in shape: S, interactive: Bool = false, glow: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, glow: glow))
    }
}
