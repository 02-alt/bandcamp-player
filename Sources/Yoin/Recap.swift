import Foundation

/// One album's standing in a year-end recap: how much it was played, plus the
/// live artwork / Bandcamp link joined back from the current library.
struct RecapItem: Identifiable {
    var albumID: UUID?
    var title: String
    var artist: String
    /// Number of real listens (skips excluded).
    var plays: Int
    /// Total seconds spent on this album across the year (partial plays included).
    var seconds: Double
    var artworkURL: URL?
    /// Embedded artwork from imported/local files (which have no artworkURL).
    var artworkData: Data?
    /// Bandcamp public album page — powers the "Buy on Bandcamp" link in shares.
    var bandcampURL: String?

    var id: String { albumID?.uuidString ?? "\(title)|\(artist)" }
}

/// A full year's listening recap: albums ranked by plays, plus headline stats.
struct Recap {
    var year: Int
    /// Albums with ≥1 real listen, sorted by plays (then time) descending.
    var items: [RecapItem]
    var totalSeconds: Double
    var albumCount: Int
    var topArtist: String?

    var isEmpty: Bool { items.isEmpty }
    var totalHours: Double { totalSeconds / 3600 }

    /// The N most-played albums — for the spiral centre and the share link.
    func top(_ n: Int) -> [RecapItem] { Array(items.prefix(n)) }
}

/// Builds a `Recap` from the raw play log. Pure — pass albums/history/calendar in.
enum RecapBuilder {
    private struct Agg {
        var title: String
        var artist: String
        var albumID: UUID?
        var plays = 0
        var seconds = 0.0
    }

    static func build(year: Int,
                      albums: [Album],
                      history: [PlayEvent] = HistoryStore.load(),
                      calendar: Calendar = .current) -> Recap {
        let inYear = history.filter { calendar.component(.year, from: $0.date) == year }

        // Live library, indexed for joining current artwork + Bandcamp links. We key on
        // title+artist because Bandcamp albums get fresh UUIDs on every re-sync, so the
        // albumID stored at play-time goes stale — title+artist stays stable across syncs.
        func norm(_ title: String, _ artist: String) -> String {
            "\(title.lowercased().trimmingCharacters(in: .whitespaces))|\(artist.lowercased().trimmingCharacters(in: .whitespaces))"
        }
        func normT(_ title: String) -> String { title.lowercased().trimmingCharacters(in: .whitespaces) }

        var byID: [UUID: Album] = [:]
        var byTA: [String: Album] = [:]
        var byTitle: [String: Album] = [:]
        for a in albums {
            byID[a.id] = a
            byTA[norm(a.title, a.artist)] = a
            byTitle[normT(a.title)] = a
        }
        // Resolve a logged play to the current library album — title+artist first, then
        // title alone (featured-track artists vary, and old events used the track artist).
        func resolve(_ title: String, _ artist: String) -> Album? {
            byTA[norm(title, artist)] ?? byTitle[normT(title)]
        }

        // Group plays by the resolved album id (collapses re-syncs & featured-track splits),
        // falling back to title+artist when the album isn't in the library anymore.
        var groups: [String: Agg] = [:]
        for e in inYear {
            let live = resolve(e.albumTitle, e.artist)
            let key = live?.id.uuidString ?? "ta:\(norm(e.albumTitle, e.artist))"
            var g = groups[key] ?? Agg(title: live?.title ?? e.albumTitle,
                                       artist: live?.artist ?? e.artist,
                                       albumID: live?.id ?? e.albumID)
            g.seconds += e.seconds
            if e.isRealListen { g.plays += 1 }
            groups[key] = g
        }

        // Merge groups that land on the same visible album (e.g. a duplicate library entry —
        // an imported folder + the Bandcamp copy — or events resolving via different keys),
        // so one album can never appear twice in the top list.
        var merged: [String: RecapItem] = [:]
        for g in groups.values where g.plays > 0 {   // pure-skip albums don't make the recap
            let live = g.albumID.flatMap { byID[$0] } ?? resolve(g.title, g.artist)
            let title = live?.title ?? g.title
            let artist = live?.artist ?? g.artist
            let key = norm(title, artist)
            if var existing = merged[key] {
                existing.plays += g.plays
                existing.seconds += g.seconds
                merged[key] = existing
            } else {
                merged[key] = RecapItem(
                    albumID: live?.id ?? g.albumID,
                    title: title,
                    artist: artist,
                    plays: g.plays,
                    seconds: g.seconds,
                    artworkURL: live?.artworkURL,
                    artworkData: live?.artworkData,
                    bandcampURL: live?.bandcampItemURL
                )
            }
        }
        let items: [RecapItem] = merged.values
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.seconds > $1.seconds }

        let totalSeconds = items.reduce(0) { $0 + $1.seconds }

        var byArtist: [String: Int] = [:]
        for it in items where !it.artist.isEmpty { byArtist[it.artist, default: 0] += it.plays }
        let topArtist = byArtist.max { $0.value < $1.value }?.key

        return Recap(year: year, items: items, totalSeconds: totalSeconds,
                     albumCount: items.count, topArtist: topArtist)
    }
}
