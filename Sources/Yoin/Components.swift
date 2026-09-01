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
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                } else if let remote = album.artworkURL {
                    CachedRemoteImage(url: remote) { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                }
            }
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
    var action: () -> Void = {}
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14))
                .foregroundStyle(p.text)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .glass(in: Circle(), interactive: true)
        }
        .buttonStyle(.soft)
    }
}

