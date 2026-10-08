import SwiftUI

/// A moving light band for loading placeholders. Transparent apart from the sweep, so it can
/// overlay either a neutral skeleton block or a coloured gradient (a cover that's still loading).
/// Drives the shine off the view's own width, so it reads at any size.
struct ShimmerSweep: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: w * 1.4)
                .offset(x: -w * 1.4 + phase * (w * 2.4))
                .blendMode(.plusLighter)
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

/// Sweeps a shine across a view (kept inside the view's shape) — for skeleton placeholders.
struct Shimmer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay { ShimmerSweep() }.mask(content)
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// One placeholder row (avatar + two text lines) for lists that are still loading.
struct SkeletonRow: View {
    var avatar = true
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: Space.s3) {
            if avatar { Circle().frame(width: 44, height: 44) }
            VStack(alignment: .leading, spacing: Space.s2) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).frame(height: 12)
                RoundedRectangle(cornerRadius: 4, style: .continuous).frame(width: 140, height: 12)
            }
        }
        .foregroundStyle(p.glassFill)
        .modifier(Shimmer())
    }
}

/// Album cover (monochrome gradient placeholder; real artwork drops in later).
struct AlbumArt: View {
    let album: Album
    var corner: CGFloat = Radius.sm
    /// Load the 1200px cover instead of the 700px thumbnail — for large surfaces like the
    /// tap-to-zoom lightbox where the grid tier would visibly upscale.
    var hiRes: Bool = false
    @Environment(\.palette) private var p

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(album.cover)
            .overlay {
                if let art = album.artwork {
                    Image(nsImage: art)
                        .resizable().scaledToFill()
                } else if let remote = album.artworkURL {
                    // While the remote cover loads, sweep a shine over the gradient placeholder.
                    // CachedRemoteImage swaps to the image on load, so the shimmer auto-clears.
                    CachedRemoteImage(url: remote, hiRes: hiRes) { ShimmerSweep() }
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
            .font(.uiCaption.weight(.semibold)).kerning(0.6)
            .textCase(.uppercase)
            .lineLimit(1).fixedSize()   // a tag never wraps mid-word ("LOSSLES / S")
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
                .font(.uiTitle3.weight(.medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
        }
        // Native Liquid Glass circle — same size as the album page's action circles.
        .glassIconButton(side: 40)
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

