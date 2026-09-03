import SwiftUI
import AppKit

/// A self-contained, shareable "now playing" card rendered to a PNG via `ImageRenderer`.
/// Takes an explicit palette + a resolved cover image because ImageRenderer runs outside the
/// SwiftUI environment and can't wait on async remote-image loads.
struct NowPlayingCard: View {
    let title: String
    let artist: String
    let cover: NSImage?
    let coverFallback: LinearGradient
    let palette: Palette
    var ambient: Color? = nil
    /// When true, the card uses a blurred, cover-tinted backdrop; when false it's a clean flat
    /// dark card. Toggled in Settings ("Ambient share card").
    var ambientBackground: Bool = true
    /// Bespoke album skin to show behind the card (chrome / ocean), matching the app's ambient bg.
    var skin: AlbumTheme.CardSkin = .none
    /// Cover palette for the skinned card background (matches the live ambient's colours).
    var skinColors: [Color] = []
    /// Short Bandcamp link (host, e.g. "artist.bandcamp.com") printed on the card so it stays
    /// discoverable even when the image is re-shared without the attached URL. Nil for non-Bandcamp.
    var link: String? = nil

    // Portrait "poster" — feels more considered than a flat square, and reads well when shared.
    static let size = CGSize(width: 1080, height: 1350)
    private static let corner: CGFloat = 60

    var body: some View {
        // Always a dark, self-contained poster (independent of app light/dark) so white text
        // stays legible and the card looks the same wherever it's shared. The ambient colour
        // (or the cover itself) provides a soft wash behind the art.
        let base = Color(white: 0.055)
        let wash = ambient ?? Color(white: 0.16)
        ZStack {
            // Rounded card on a transparent canvas → soft, floating corners once exported.
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(base)
                .overlay {
                    if skin != .none {
                        // The album's bespoke ambient (static, card-safe version, cover-coloured).
                        AlbumTheme.cardBackground(skin, colors: skinColors)
                    } else if ambientBackground {
                        coverArt.scaledToFill()
                            .blur(radius: 90).opacity(0.55)
                            .overlay(wash.opacity(0.30).blendMode(.plusLighter))
                    }
                }
                .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                                        startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1.5))
                .padding(34)

            VStack(spacing: 40) {
                Text("Yoin")
                    .font(.system(size: 28, weight: .heavy)).kerning(1)
                    .foregroundStyle(.white.opacity(0.75))

                coverArt
                    .frame(width: 640, height: 640)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 60, y: 30)

                VStack(spacing: 13) {
                    Text("NOW PLAYING")
                        .font(.system(size: 19, weight: .bold)).kerning(4)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(title)
                        .font(.system(size: 54, weight: .bold)).kerning(-0.6)
                        .foregroundStyle(.white)
                        .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.55)
                    Text(artist)
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .frame(maxWidth: 860)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 90)

            // Bandcamp link pinned to the bottom of the card.
            if let link {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "bag.fill").font(.system(size: 15))
                        Text(link).font(.system(size: 19, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 82)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var coverArt: some View {
        if let cover {
            Image(nsImage: cover).resizable().scaledToFill()
        } else {
            coverFallback
        }
    }
}

enum ShareCard {
    /// Render a now-playing card to PNG data at 2× and hand it back as an NSImage for sharing.
    @MainActor
    static func render(_ card: NowPlayingCard) -> NSImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        return renderer.nsImage
    }

    /// Present the macOS share sheet for a rendered card, anchored to the source button's actual
    /// NSView (no fragile coordinate math) so the popover points right at the button and opens
    /// upward. Falls back to the window centre if the anchor view is gone.
    @MainActor
    static func present(_ image: NSImage, anchorView: NSView? = nil, url: URL? = nil) {
        // Attach the Bandcamp link alongside the image so Messages/Mail/AirDrop carry a
        // clickable way to reach (and buy) the track, not just a picture.
        let items: [Any] = url.map { [image, $0] } ?? [image]
        let picker = NSSharingServicePicker(items: items)
        if let anchor = anchorView, anchor.window != nil {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView {
            let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
    }
}

/// Holds a weak reference to a SwiftUI view's backing NSView, so AppKit affordances
/// (like `NSSharingServicePicker`) can anchor to it precisely.
final class NSViewAnchor: ObservableObject { weak var view: NSView? }

/// Transparent overlay that captures its backing NSView into an `NSViewAnchor`.
struct NSViewAnchorRep: NSViewRepresentable {
    let anchor: NSViewAnchor
    func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
}
