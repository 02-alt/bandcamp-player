import SwiftUI
import AppKit

/// A reusable About / Credits sheet, so every surface (First Listen, the turntable Now Playing,
/// …) shows the same information the same way. Callers fetch the raw data (artist bio, album
/// notes, Bandcamp credits, Genius credits) and hand it in.
enum TrackInfoTab { case about, credits }

struct TrackInfoSheet: View {
    let tab: TrackInfoTab
    let artist: String
    let artistBio: ArtistBio?
    let albumNotes: String?        // the album's Bandcamp "about" text
    let bcCredits: String?         // the artist's own credits block
    let geniusCredits: [GeniusCredit]?
    var onClose: () -> Void

    @Environment(\.palette) private var p

    /// Prefer the artist's own Bandcamp credits (plain text); fall back to Genius (structured).
    private var creditsFromGenius: Bool {
        (bcCredits?.isEmpty != false) && (geniusCredits?.isEmpty == false)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4).ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: Space.s4) {
                HStack {
                    Text(tab == .about ? "About" : "Credits")
                        .font(.system(size: 16, weight: .bold)).kerning(-0.3).foregroundStyle(p.text)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.muted).frame(width: 28, height: 28).glass(in: Circle())
                    }
                    .buttonStyle(.soft)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    if tab == .about {
                        aboutContent
                    } else if creditsFromGenius, let credits = geniusCredits {
                        VStack(alignment: .leading, spacing: Space.s4) {
                            ForEach(Array(credits.enumerated()), id: \.offset) { _, c in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.role).font(.system(size: 13, weight: .bold)).foregroundStyle(p.text)
                                    Text(c.names).font(.system(size: 13)).foregroundStyle(p.muted)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    } else {
                        Text(bcCredits?.isEmpty == false ? bcCredits! : "No credits for this album.")
                            .font(.system(size: 13)).foregroundStyle(p.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxHeight: 320)

                if tab == .about, let bio = artistBio, !bio.text.isEmpty {
                    attribution("via \(bio.sourceName)", url: bio.sourceURL)
                } else if tab == .credits, creditsFromGenius {
                    attribution("via Genius", url: nil)
                }
            }
            .padding(Space.s6)
            .frame(maxWidth: 520)
            .glass(radius: Radius.card, glow: true)
            .padding(Space.s6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var aboutContent: some View {
        let bio = artistBio?.text
        VStack(alignment: .leading, spacing: Space.s5) {
            if let bio, !bio.isEmpty { section(artist, bio) }
            if let notes = albumNotes, !notes.isEmpty { section("About this album", notes) }
            if (bio?.isEmpty != false) && (albumNotes?.isEmpty != false) {
                Text("No description found.").font(.system(size: 13)).foregroundStyle(p.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func section(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading.uppercased()).font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            Text(body).font(.system(size: 13)).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attribution(_ label: String, url: String?) -> some View {
        Button {
            if let s = url, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        } label: {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(p.muted2).underline(url != nil)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }
}
