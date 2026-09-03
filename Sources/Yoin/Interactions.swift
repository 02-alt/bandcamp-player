import SwiftUI

/// Shared motion vocabulary so every interaction across the app feels like one system.
enum Motion {
    /// Firm, quick press-in with a touch of overshoot on release.
    static let press = Animation.spring(response: 0.26, dampingFraction: 0.6)
    /// Calm hover fade — no bounce, just a gentle settle.
    static let hover = Animation.easeOut(duration: 0.16)
    /// Springy travel for sliding selections (segmented controls, chips).
    static let glide = Animation.spring(response: 0.34, dampingFraction: 0.78)
    /// Soft lift for cards raising toward the cursor.
    static let lift = Animation.spring(response: 0.34, dampingFraction: 0.72)
}

// MARK: - Universal button feel

/// One button style for the whole app: subtle grow on hover, firm scale-in on press,
/// a hint of brightness, and a link cursor. Replaces bare `.buttonStyle(.plain)`.
struct SoftButtonStyle: ButtonStyle {
    var hoverScale: CGFloat = 1.04
    var pressScale: CGFloat = 0.93
    var brighten: Double = 0.06

    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration,
                   hoverScale: hoverScale, pressScale: pressScale, brighten: brighten)
    }

    private struct SoftButton: View {
        let configuration: Configuration
        let hoverScale: CGFloat
        let pressScale: CGFloat
        let brighten: Double
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(hovering && !configuration.isPressed ? brighten : 0)
                .scaleEffect(configuration.isPressed ? pressScale : (hovering ? hoverScale : 1))
                .opacity(configuration.isPressed ? 0.92 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovering)
                .onHover { hovering = $0 }
                .modifier(LinkCursor())
        }
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    /// Default app button feel.
    static var soft: SoftButtonStyle { .init() }
    /// Tune the feel per-control (e.g. large cards want a smaller grow).
    static func soft(hover: CGFloat = 1.04, press: CGFloat = 0.93, brighten: Double = 0.06) -> SoftButtonStyle {
        .init(hoverScale: hover, pressScale: press, brighten: brighten)
    }
}

/// Shows the pointing-hand cursor over interactive elements (macOS 15+).
struct LinkCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.pointerStyle(.link) } else { content }
    }
}

// MARK: - Hover modifiers for non-button surfaces

/// Fades a soft fill in behind a row/chip on hover (used for inactive nav items).
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = Radius.pill
    var active: Bool = false
    @Environment(\.palette) private var p
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(p.glassFill)
                    .opacity(!active && hovering ? 1 : 0)
            )
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = Radius.pill, active: Bool = false) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, active: active))
    }
}
