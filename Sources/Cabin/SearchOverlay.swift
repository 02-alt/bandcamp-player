import SwiftUI

/// Full-panel search — emulator-style: centered pill, round close, count, monospace grid.
struct SearchOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    private var query: String { state.searchQuery }

    // Reflow the results to the window width instead of a fixed 5 columns.
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.s5)]

    private var results: [Album] {
        let base = query.isEmpty ? state.albums : state.albums.filter {
            $0.title.lowercased().contains(query.lowercased())
                || $0.artist.lowercased().contains(query.lowercased())
        }
        // Collapse duplicates (same album can arrive twice from a Bandcamp re-sync).
        var seen = Set<String>()
        return base.filter { seen.insert($0.dedupeKey).inserted }
    }

    /// Open an album's detail page and dismiss the search overlay.
    private func open(_ album: Album) {
        state.openedAlbumID = album.id
        withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = false }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Transparent so RootView's ambient shows through (no black block). MainPanel hides the
            // content below while search is open.
            Color.clear.ignoresSafeArea()

            VStack(spacing: 0) {
                // (The search field lives in the window's title bar — see RootView.)
                Text("\(results.count) \(results.count == 1 ? "ALBUM" : "ALBUMS")")
                    .font(.system(size: 11, design: .monospaced)).kerning(1.8)
                    .foregroundStyle(p.muted)
                    .padding(.vertical, Space.s5)

                // Results grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Space.s6) {
                        ForEach(results) { album in
                            Button { open(album) } label: {
                                VStack(spacing: Space.s3) {
                                    AlbumArt(album: album, corner: 12)
                                        .aspectRatio(1, contentMode: .fit)
                                        .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
                                    Text(album.title)
                                        .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                        .foregroundStyle(p.text)
                                    Text(album.artist.uppercased())
                                        .font(.system(size: 10, design: .monospaced)).kerning(0.5)
                                        .foregroundStyle(p.muted2).lineLimit(1)
                                }
                                .padding(Space.s3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.soft(hover: 1.0, press: Press.medium, brighten: 0))
                            .appContextMenu { albumMenuItems(for: album, state: state, player: player) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(Space.s7)

        }
        // Flat, full-bleed screen (see AlbumDetailView) — no rounded card corners.
        .clipShape(Rectangle())
        // Escape closes search even when the title-bar field doesn't have focus.
        .background(
            Button("") { withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = false } }
                .keyboardShortcut(.escape, modifiers: []).hidden()
        )
    }
}
