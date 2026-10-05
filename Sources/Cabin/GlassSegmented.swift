import SwiftUI

/// A Liquid Glass segmented switch with the header tabs' look (see `ScreenSwitch`): a glass bar
/// and a glass selection pill that slides between the options. For in-page choices such as the
/// Recap's Year | Month and its month row — the stock segmented `Picker` draws the classic,
/// non-glass control inside content.
struct GlassSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var isEnabled: (Value) -> Bool = { _ in true }

    @Environment(\.palette) private var p
    @Namespace private var ns

    var body: some View {
        container {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { segment($0) }
            }
            .padding(3)
            .glass(in: Capsule(), pure: true)
        }
        .fixedSize()
    }

    private func segment(_ value: Value) -> some View {
        let on = value == selection
        return Button {
            withAnimation(Motion.glide) { selection = value }
        } label: {
            Text(label(value))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).fixedSize()
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background { if on { pill.matchedGeometryEffect(id: "pill", in: ns) } }
                .contentShape(Capsule())
                .hoverHighlight(active: on)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
        .disabled(!isEnabled(value))
        .opacity(isEnabled(value) ? 1 : 0.4)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// Real interactive Liquid Glass on macOS 26 (lenses and merges with the bar inside the
    /// container); material fallback on older systems.
    @ViewBuilder private var pill: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.interactive(), in: Capsule())
                .overlay(Capsule().strokeBorder(p.edge, lineWidth: 1))
        } else {
            Capsule().fill(p.glassFill).background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder private func container<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { content() }
        } else {
            content()
        }
    }
}
