import SwiftUI

/// Full-panel search — emulator-style: centered pill, round close, count, monospace grid.
struct SearchOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.palette) private var p
    private var query: String { state.searchQuery }

    // Reflow the results to the window width instead of a fixed 5 columns.
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.s5)]

    /// Computed off the render path: re-filtering the whole library twice per body, on every
    /// keystroke, made typing lag on big libraries. Debounced slightly while typing.
    @State private var results: [Album] = []
    /// People from the credits (those with a profile) whose name matches.
    @State private var people: [CreditPerson] = []

    private static func matchPeople(_ query: String) -> [CreditPerson] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let index = CreditIndex.shared
        return index.people.values
            .filter { $0.name.localizedStandardContains(q) && index.profile(for: $0.name) != nil }
            .sorted { $0.songCount != $1.songCount ? $0.songCount > $1.songCount : $0.name < $1.name }
            .prefix(8).map { $0 }
    }

    private static func filter(_ albums: [Album], _ query: String) -> [Album] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? albums : albums.filter {
            $0.title.localizedStandardContains(q) || $0.artist.localizedStandardContains(q)
        }
        // Collapse duplicates (same album can arrive twice from a Bandcamp re-sync).
        var seen = Set<String>()
        return base.filter { seen.insert($0.dedupeKey).inserted }
    }

    /// Credited people matching the query — a monogram + name chip each, opening their credit
    /// profile. In the overlay's own monospace style.
    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("PEOPLE IN YOUR CREDITS").font(.system(size: 11, design: .monospaced)).kerning(1.8)
                .foregroundStyle(p.muted)
            WrapLayout(spacing: Space.s3, lineSpacing: Space.s3) {
                ForEach(people) { person in
                    Button { state.openCreditProfile(person.key, player: player) } label: {
                        HStack(spacing: Space.s2) {
                            Text(person.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased())
                                .font(.uiCaption.weight(.bold)).foregroundStyle(p.text)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(p.glassFill))
                                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(person.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.text)
                                    .lineLimit(1)
                                Text(person.topRoles.first.map { "\($0) · \(person.songCount) songs" } ?? "\(person.songCount) songs")
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted2).lineLimit(1)
                            }
                        }
                        .padding(.vertical, Space.s1).padding(.leading, Space.s1).padding(.trailing, Space.s3)
                        .contentShape(Capsule())
                        .hoverHighlight()
                    }
                    .buttonStyle(.soft(press: Press.small, brighten: 0))
                    .help("Open \(person.name)'s credits")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.s3)
        .padding(.bottom, Space.s5)
    }

    /// Open an album's detail page and dismiss the search overlay.
    private func open(_ album: Album) {
        state.openedAlbumID = album.id
        withAnimation(.easeInOut(duration: 0.2)) { state.searchOpen = false }
    }

    var body: some View {
        content
            .task(id: query) {
                if !results.isEmpty, !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
                guard !Task.isCancelled else { return }
                results = Self.filter(state.albums, query)
                people = Self.matchPeople(query)
            }
            .onChange(of: state.albums.count) { _, _ in results = Self.filter(state.albums, query) }
    }

    private var content: some View {
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
                    if !people.isEmpty { peopleRow }
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
