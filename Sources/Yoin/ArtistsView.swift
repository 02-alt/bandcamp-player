import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    private struct Artist: Identifiable {
        let id: String
        var name: String { id }
        let cover: Album
        let count: Int
    }

    private var artists: [Artist] {
        let groups = Dictionary(grouping: state.albums, by: \.artist)
        return groups.map { name, albums in
            Artist(id: name, cover: albums[0], count: albums.count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.s6)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s6) {
                ForEach(artists) { artist in
                    VStack(spacing: Space.s3) {
                        AlbumArt(album: artist.cover, corner: 500)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 14, y: 10)
                        VStack(spacing: 2) {
                            Text(artist.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(artist.count) album\(artist.count == 1 ? "" : "s")")
                                .font(.system(size: 12)).foregroundStyle(p.muted)
                        }
                    }
                }
            }
            .padding(.top, Space.s2)
        }
        .scrollIndicators(.hidden)
    }
}
