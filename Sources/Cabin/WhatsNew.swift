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
        Feature(symbol: "icloud.and.arrow.up",
                title: "Send to iPhone works again",
                detail: "Albums you send from Settings › Import now reliably reach the Cabin iPhone app, albums with large covers no longer fail, and if a send can't go through Cabin tells you why instead of marking it sent."),
        Feature(symbol: "text.book.closed",
                title: "Album pages that read like liner notes",
                detail: "Below the tracks: where the artist is from and how often you've played it, more from the artist, then the album's story — now with a Wikipedia description for imported albums too. Big clear titles, no clutter."),
        Feature(symbol: "capsule.on.capsule",
                title: "A steadier header",
                detail: "The draggable glass tab pill is back, and the tabs stay in place as you switch screens. Grid's Sort and Select now sit with its filters."),
        Feature(symbol: "magnifyingglass",
                title: "Search that unfolds",
                detail: "The search button now stretches into the search field, Apple-style — and in a small window the other buttons step aside to make room."),
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
