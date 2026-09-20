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
        Feature(symbol: "arrow.down.right.and.arrow.up.left",
                title: "Comfortable at any window size",
                detail: "Shrink the window and everything now reflows instead of overlapping or clipping — a compact header (screen menu + “•••”), Playlists collapse to a single pane you can page back from, the iPod sync panes stack, and detail headers slim down so lists still fit."),
        Feature(symbol: "quote.bubble",
                title: "More room for lyrics & credits",
                detail: "In First Listen's landscape layout, the Lyrics and Credits tabs now dock a slim one-row control bar so the words fill the whole panel."),
        Feature(symbol: "slider.horizontal.3",
                title: "Cleaner playback controls",
                detail: "A native volume slider, a distinct draggable handle on the timeline, larger tap targets and higher-contrast labels throughout the player."),
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
                    Text("What's New").font(.system(size: 22, weight: .bold)).kerning(-0.3)
                        .foregroundStyle(p.text)
                        .accessibilityAddTraits(.isHeader)
                    if let v = WhatsNew.version {
                        Text("Version \(v)").font(.system(size: 12, weight: .medium))
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
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(p.accent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(p.glassFill))
                            .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(p.text)
                            Text(item.detail).font(.system(size: 12))
                                .foregroundStyle(p.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Button(action: onClose) {
                Text("Continue").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(p.accentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(p.accent))
            }
            .buttonStyle(.soft)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Continue")
        }
        .padding(Space.s6)
        .frame(width: 430)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(p.page))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
    }
}
