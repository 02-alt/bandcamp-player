import SwiftUI

/// "What's New" release notes. Shown once on the first launch after an update, and always
/// re-openable from Settings ▸ About. Modelled on the emulator app's card.
///
/// How the once-per-build behaviour works: `UserDefaults` remembers the last version whose
/// notes were seen (`lastSeenWhatsNewVersion`). On launch, if that differs from the running
/// version, the card is shown and the marker advances — so it appears exactly once per build,
/// and any version bump re-triggers it. A genuine fresh install (no marker yet) records the
/// version silently: a brand-new player hasn't "updated" to anything.
///
/// To ship notes for a release: bump the version in `package.sh` as usual, then rewrite
/// `items` to describe what changed. Nothing else to wire.
enum WhatsNew {
    /// The build these notes describe — the running app version, so a version bump alone
    /// re-shows them. `nil` on an unbundled dev build (no `CFBundleShortVersionString`),
    /// where the card stays dormant.
    static var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private static let lastSeenKey = "lastSeenWhatsNewVersion"

    struct Feature: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    /// The highlights of the latest update. Keep it short — three or four lines.
    static let items: [Feature] = [
        Feature(symbol: "moon.stars",
                title: "Slowed + Reverb, seamless",
                detail: "Dial the effect in and out without a cut, a jump or a skipped track. Speed changes on streams settle in one short dip instead of stuttering."),
        Feature(symbol: "contextualmenu.and.cursorarrow",
                title: "Right there in the right-click menu",
                detail: "Effects ▸ Slowed + Reverb: Normal, the classic Slowed + Reverb, or Customise… for speed, pitch and reverb sliders. Hover a preset to hear it first."),
        Feature(symbol: "speaker.wave.2",
                title: "Room & vinyl stays on",
                detail: "Your EQ and Room & vinyl presets keep working while Slowed + Reverb has the track, and mono or 48 kHz downloads now play through the effect too."),
    ]

    /// True when these notes haven't been seen on this build yet — and advances the marker so
    /// the next call returns false. A fresh install records the version silently (returns false).
    static func shouldAutoShow() -> Bool {
        guard let version else { return false }   // dev build — nothing to show
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: lastSeenKey)
        defaults.set(version, forKey: lastSeenKey)   // advance the marker either way
        // nil marker = fresh install (skip); same version = already seen; empty notes = nothing.
        guard let last, last != version, !items.isEmpty else { return false }
        return true
    }
}

/// The card itself — release-note highlights for the running build, in Cabin's theme. Presented
/// as a sheet on the first launch after an update and from the "Release notes" button in Settings.
struct WhatsNewView: View {
    @Environment(\.palette) private var p
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New").font(.uiTitle.weight(.bold)).kerning(-0.3)
                        .foregroundStyle(p.text)
                        .accessibilityAddTraits(.isHeader)
                    if let v = WhatsNew.version {
                        Text("Version \(v)").font(.uiCallout.weight(.medium))
                            .foregroundStyle(p.muted2)
                    }
                }
                Spacer()
                IconButton(system: "xmark", tip: "Close what's new", action: onClose)
            }

            VStack(alignment: .leading, spacing: Space.s4) {
                ForEach(WhatsNew.items) { item in
                    HStack(alignment: .top, spacing: Space.s4) {
                        Image(systemName: item.symbol)
                            .font(.uiTitle2.weight(.semibold))
                            .foregroundStyle(p.accent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(p.glassFill))
                            .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(p.text)
                            Text(item.detail).font(.uiCallout)
                                .foregroundStyle(p.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Button(action: onClose) {
                Text("Continue").font(.uiBody.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .modifier(GlassButton(prominent: true)).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Continue")
        }
        .padding(Space.s6)
        .frame(width: 430)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(p.page))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
    }
}
