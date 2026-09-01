import Foundation

/// An artist or genre with a play tally — one bar in the stats breakdown.
struct NamedCount: Identifiable {
    var name: String
    var plays: Int
    var id: String { name }
}

/// One day's listen count, for the contribution-style heatmap.
struct DayTally: Identifiable {
    var date: Date
    var count: Int
    var id: Date { date }
}

/// Always-on listening stats (as opposed to the once-a-year Recap): streaks, this
/// month's headline numbers, artist & genre breakdowns, and a daily heatmap.
struct ListeningStats {
    var monthListens: Int
    var monthSeconds: Double
    var totalListens: Int
    /// The most-played artist all-time — the hero of the stats card.
    var heroArtist: NamedCount?
    var heroArtworkURL: URL?
    var heroArtworkData: Data?
    var heroG0: Double = 0.28
    var heroG1: Double = 0.08
    /// The hero artist's single most-played track — revealed on the tile's flip side.
    var heroTopTrack: String?
    var heroTopTrackPlays: Int = 0
    var topArtists: [NamedCount]
    var genres: [NamedCount]
    /// Oldest → newest, exactly `heatmapDays` entries ending today.
    var heatmap: [DayTally]

    var isEmpty: Bool { totalListens == 0 }
    var monthHours: Double { monthSeconds / 3600 }
    /// The busiest single day in the heatmap window — used to scale the colour ramp.
    var heatmapPeak: Int { heatmap.map(\.count).max() ?? 0 }
}

enum StatsBuilder {
    /// Weeks shown in the heatmap (× 7 days). 18 weeks ≈ a comfortable, non-scrolling grid.
    static let heatmapWeeks = 18
    static var heatmapDays: Int { heatmapWeeks * 7 }

    static func build(albums: [Album],
                      history: [PlayEvent] = HistoryStore.load(),
                      calendar: Calendar = .current,
                      now: Date = Date()) -> ListeningStats {
        let real = history.filter { $0.isRealListen }
        let today = calendar.startOfDay(for: now)

        // MARK: This month.
        let monthEvents = real.filter {
            calendar.isDate($0.date, equalTo: now, toGranularity: .month)
        }
        let monthListens = monthEvents.count
        let monthSeconds = monthEvents.reduce(0) { $0 + $1.seconds }

        var artistCounts: [String: Int] = [:]
        for e in monthEvents where !e.artist.isEmpty { artistCounts[e.artist, default: 0] += 1 }
        let topArtists = artistCounts
            .map { NamedCount(name: $0.key, plays: $0.value) }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
            .prefix(6)

        // MARK: Genres — join plays back to library albums for their genre tags (all-time).
        func norm(_ t: String, _ a: String) -> String {
            "\(t.lowercased().trimmingCharacters(in: .whitespaces))|\(a.lowercased().trimmingCharacters(in: .whitespaces))"
        }
        var albumByID: [UUID: Album] = [:]
        var albumByTA: [String: Album] = [:]
        for a in albums { albumByID[a.id] = a; albumByTA[norm(a.title, a.artist)] = a }

        // MARK: Hero — the most-played artist all-time, with a representative cover.
        var allArtistCounts: [String: Int] = [:]
        for e in real where !e.artist.isEmpty { allArtistCounts[e.artist, default: 0] += 1 }
        let heroPair = allArtistCounts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
        let heroArtist = heroPair.map { NamedCount(name: $0.key, plays: $0.value) }
        // Prefer one of that artist's albums that actually has artwork, for the tile.
        let heroCover: Album? = heroArtist.flatMap { h in
            let mine = albums.filter { $0.artist.caseInsensitiveCompare(h.name) == .orderedSame }
            return mine.first { $0.artworkData != nil || $0.artworkURL != nil } ?? mine.first
        }
        // The hero artist's most-played individual track (flip side of the tile).
        var heroTrackCounts: [String: Int] = [:]
        if let h = heroArtist {
            for e in real where e.artist == h.name && !e.trackTitle.isEmpty {
                heroTrackCounts[e.trackTitle, default: 0] += 1
            }
        }
        let heroTrackPair = heroTrackCounts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }

        var genreCounts: [String: Int] = [:]
        for e in real {
            let album = e.albumID.flatMap { albumByID[$0] } ?? albumByTA[norm(e.albumTitle, e.artist)]
            guard let genre = album?.genre, !genre.isEmpty else { continue }
            for g in genre.split(separator: ",") {
                let name = g.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { genreCounts[name, default: 0] += 1 }
            }
        }
        let genres = genreCounts
            .map { NamedCount(name: $0.key, plays: $0.value) }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
            .prefix(6)

        // MARK: Heatmap — daily counts for the trailing window.
        var perDay: [Date: Int] = [:]
        for e in real { perDay[calendar.startOfDay(for: e.date), default: 0] += 1 }
        var heatmap: [DayTally] = []
        for offset in stride(from: heatmapDays - 1, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            heatmap.append(DayTally(date: day, count: perDay[day] ?? 0))
        }

        return ListeningStats(
            monthListens: monthListens,
            monthSeconds: monthSeconds,
            totalListens: real.count,
            heroArtist: heroArtist,
            heroArtworkURL: heroCover?.artworkURL,
            heroArtworkData: heroCover?.artworkData,
            heroG0: heroCover?.g0 ?? 0.28,
            heroG1: heroCover?.g1 ?? 0.08,
            heroTopTrack: heroTrackPair?.key,
            heroTopTrackPlays: heroTrackPair?.value ?? 0,
            topArtists: Array(topArtists),
            genres: Array(genres),
            heatmap: heatmap
        )
    }
}
