import SwiftUI
import CabinCore

/// A small sheet with the Slowed + Reverb controls — speed, extra pitch, reverb — plus the two
/// one-click presets. Hosted by RootView so it can be opened from any Now Playing surface
/// (player bar, Now Playing, First Listen) via the right-click menu's "Customise…" row.
struct SlowedReverbPanel: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            HStack {
                Text("SLOWED + REVERB").font(.uiSubheadline.weight(.bold)).kerning(1.2)
                    .foregroundStyle(p.muted2)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.uiSubheadline.weight(.bold)).foregroundStyle(p.muted)
                        .frame(width: 26, height: 26).background(Circle().fill(p.glassFill))
                }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            }

            slider("Speed", value: String(format: "%.2f×", player.speed)) {
                Slider(value: $player.speed, in: 0.5...1.5, step: 0.01)
            }
            slider("Extra pitch", value: player.pitch == 0 ? "0 st" : String(format: "%+.0f st", player.pitch)) {
                Slider(value: Binding(get: { player.pitch }, set: { player.pitch = abs($0) < 0.5 ? 0 : $0.rounded() }),
                       in: -12...12, step: 1)
            }
            slider("Reverb", value: String(format: "%.0f%%", player.reverbMix)) {
                Slider(value: $player.reverbMix, in: 0...100, step: 1)
            }

            HStack(spacing: Space.s2) {
                pill("Slowed + reverb") { player.speed = 0.80; player.pitch = 0; player.reverbMix = 40 }
                pill("Normal", subtle: true) { player.speed = 1.0; player.pitch = 0; player.reverbMix = 0 }
                Spacer()
            }
            Text("Pitch & reverb apply to downloaded tracks; speed also works on streams.")
                .font(.uiCaption).foregroundStyle(p.muted2)
        }
        .padding(Space.s6)
        .frame(width: 340)
        .background(p.page)
        .onAppear { if !player.djMode { player.djMode = true } }
    }

    private func slider(_ label: String, value: String, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.uiCallout.weight(.medium)).foregroundStyle(p.text)
                Spacer()
                Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
            }
            control().tint(p.accent).accessibilityLabel(label)
        }
    }

    private func pill(_ label: String, subtle: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.uiCallout.weight(.bold))
                .foregroundStyle(subtle ? p.muted : p.accentInk)
                .padding(.vertical, 8).padding(.horizontal, Space.s4)
                .background(Capsule().fill(subtle ? p.glassFill : p.accent))
                .overlay(Capsule().strokeBorder(subtle ? p.edgeSoft : .clear, lineWidth: 1))
        }.buttonStyle(.soft)
    }
}
