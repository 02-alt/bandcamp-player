import SwiftUI

/// Album cover (monochrome gradient placeholder; real artwork drops in later).
struct AlbumArt: View {
    let album: Album
    var corner: CGFloat = Radius.sm
    @Environment(\.palette) private var p

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(album.cover)
            .overlay {
                if let art = album.artwork {
                    Image(nsImage: art)
                        .resizable().scaledToFill()
                } else if let remote = album.artworkURL {
                    CachedRemoteImage(url: remote) { Color.clear }
                }
            }
            // Clip the (scaled-to-fill, possibly non-square) artwork to the square cover.
            // Must sit on the container — clipping the image itself leaves the overflow,
            // since `scaledToFill` grows the image's own layout frame past the square.
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(p.edgeSoft, lineWidth: 1)
            )
    }
}

/// A passive metadata tag (LOSSLESS, format, source) — read-only, not a button.
/// Styled as a subtle outlined chip so it doesn't invite a click. `filled` just
/// nudges emphasis (brighter text + faint fill) for the quality badge.
struct Pill: View {
    let text: String
    var filled: Bool = false
    @Environment(\.palette) private var p

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
            .textCase(.uppercase)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .foregroundStyle(filled ? p.text : p.muted2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(filled ? p.text.opacity(0.10) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(p.edgeSoft, lineWidth: 1)
            )
            .accessibilityAddTraits(.isStaticText)
    }
}

struct IconButton: View {
    let system: String
    /// VoiceOver label. Icon-only buttons announce only "button" without one, so pass this
    /// whenever the glyph's meaning isn't already stated by an external `.accessibilityLabel`.
    var label: String? = nil
    /// Hover tooltip text ("what does this do"). Also becomes the accessibility label.
    var tip: String? = nil
    var action: () -> Void = {}
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14))
                .foregroundStyle(p.text)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                // Match the flat glass-chip treatment used by Select, the album-detail circle
                // buttons and the wishlist refresh — one consistent control style app-wide,
                // instead of the heavier floating-glass disc this used to be.
                .background(Circle().fill(p.glassFill))
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .modifier(IconButtonHint(tip: tip, label: label))
    }
}

/// Applies the hover tooltip when `tip` is set (which also supplies the a11y label); otherwise
/// falls back to the plain accessibility label.
private struct IconButtonHint: ViewModifier {
    let tip: String?
    let label: String?
    func body(content: Content) -> some View {
        if let tip { content.tip(tip) }
        else { content.accessibilityLabel(label ?? "") }
    }
}

