import SwiftUI
import AppKit

/// The account's Bandcamp wishlist — saved-but-not-bought items. They stream (Bandcamp serves
/// public previews / full streams for freely-streamable tracks) and each links straight out to
/// buy. Kept separate from the owned library so they never touch stats/radio/health.
struct WishlistView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: Space.s6)]
    private let pageSize = 20
    /// How many items are currently rendered. Wishlists can be huge (hundreds of items), and
    /// each cover is a remote image — so reveal them in pages instead of loading all at once.
    @State private var shown = 20

    var body: some View {
        VStack(spacing: Space.s4) {
            header
            if BandcampFriday.isToday() { bandcampFridayBanner }
            content
        }
        .task { await state.syncWishlist() }
    }

    /// Shown only on Bandcamp Friday — a nudge to buy today, when the artist keeps ~100%.
    private var bandcampFridayBanner: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "tag.fill").font(.system(size: 14, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("It's Bandcamp Friday").font(.system(size: 13, weight: .bold))
                Text("Buy today — Bandcamp waives its cut, so the artist keeps ~100%.")
                    .font(.system(size: 11)).opacity(0.85)
            }
            Spacer()
        }
        .foregroundStyle(p.accentInk)
        .padding(.vertical, Space.s3).padding(.horizontal, Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(p.accent))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("It's Bandcamp Friday. Buy today and the artist keeps about 100 percent.")
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Text("WISHLIST").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            if case .loaded = state.wishlistLoad, !state.wishlist.isEmpty {
                Text("\(state.wishlist.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(p.muted2)
            }
            Spacer()
            Button { Task { await state.syncWishlist(force: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.muted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(p.glassFill))
                    .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            }
            .buttonStyle(.soft)
            .tip("Refresh wishlist")
        }
    }

    @ViewBuilder private var content: some View {
        switch state.wishlistLoad {
        case .loading where state.wishlist.isEmpty:
            OrbLoadingRow(text: "Loading your wishlist…", size: 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            centeredNote(msg, systemImage: "exclamationmark.triangle")
        case .loaded where state.wishlist.isEmpty:
            centeredNote("Your Bandcamp wishlist is empty.\nSave albums on Bandcamp and they'll show up here.",
                         systemImage: "heart")
        default:
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s6) {
                ForEach(state.wishlist.prefix(shown)) { album in
                    WishlistCard(album: album)
                }
            }
            .padding(.top, Space.s2)

            if state.wishlist.count > shown {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shown = min(shown + pageSize, state.wishlist.count)
                    }
                } label: {
                    Text("Load more (\(state.wishlist.count - shown) left)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text)
                        .padding(.vertical, Space.s3).padding(.horizontal, Space.s5)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                }
                .buttonStyle(.soft)
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s5)
            }
        }
        .scrollIndicators(.hidden)
        // A refresh (or first load) resets paging back to the first page.
        .onChange(of: state.wishlist.count) { _, _ in shown = pageSize }
    }

    private func centeredNote(_ text: String, systemImage: String) -> some View {
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage).font(.system(size: 26)).foregroundStyle(p.muted2)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 14)).foregroundStyle(p.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A wishlist cover: hover to stream-preview it, with an always-visible "buy on Bandcamp" badge.
struct WishlistCard: View {
    let album: Album
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            AlbumArt(album: album)
                .accessibilityHidden(true)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topLeading) { bandcampFridayBadge }
                .overlay(alignment: .topTrailing) { buyBadge }
                .overlay { hoverPlay }
                .scaleEffect(hovering ? 1.035 : 1)
                .shadow(color: .black.opacity(hovering ? 0.5 : 0.3),
                        radius: hovering ? 22 : 14, y: hovering ? 16 : 10)
                .animation(Motion.lift, value: hovering)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(album.artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
            }
        }
        .onHover { hovering = $0 }
        .appContextMenu { menu }
    }

    /// Stream-preview play button that fades up on hover.
    @ViewBuilder private var hoverPlay: some View {
        if album.isPlayable {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(.black.opacity(hovering ? 0.28 : 0))
                Button { state.play(album, on: player) } label: {
                    Image(systemName: "play.fill").font(.system(size: 16))
                        .foregroundStyle(p.accentInk)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(p.accent))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(.soft)
                .tip("Play preview")
                .opacity(hovering ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.15), value: hovering)
        }
    }

    /// A small tag hinting the item is best bought on Bandcamp Friday — subtle most days,
    /// accent-highlighted when today actually is one.
    @ViewBuilder private var bandcampFridayBadge: some View {
        if album.bandcampItemURL != nil {
            let today = BandcampFriday.isToday()
            Image(systemName: "tag.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(today ? p.accentInk : .white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(today ? p.accent : .black.opacity(0.5)))
                .opacity(today ? 1 : 0.75)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .padding(Space.s2)
                .accessibilityHidden(true)
                .help(today ? "It's Bandcamp Friday — the artist keeps ~100% today"
                            : "Tip: buy on Bandcamp Friday and the artist keeps ~100%"
                              + (BandcampFriday.nextLabel().map { " (next: \($0))" } ?? ""))
        }
    }

    /// Always-visible "open on Bandcamp to buy" badge.
    @ViewBuilder private var buyBadge: some View {
        if album.bandcampItemURL != nil {
            Button { buy() } label: {
                Image(systemName: "bag").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.black.opacity(0.6)))
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
            .buttonStyle(.soft)
            .padding(Space.s2)
            .tip("Buy on Bandcamp")
        }
    }

    private var menu: [AppMenuItem] {
        var items: [AppMenuItem] = []
        if album.isPlayable {
            items.append(AppMenuItem(title: "Play preview", systemImage: "play.fill") {
                state.play(album, on: player)
            })
        }
        if album.bandcampItemURL != nil {
            items.append(AppMenuItem(title: "Buy on Bandcamp", systemImage: "bag") { buy() })
        }
        return items
    }

    private func buy() {
        guard let s = album.bandcampItemURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}
