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

/// The top album of a single month — powers the "your year, month by month" filmstrip.
struct MonthTop: Identifiable {
    var month: Int          // 1…12
    var item: RecapItem
    var id: Int { month }
}

/// An artist you own music by and played this year — for the "who you backed" list.
struct SupportedArtist: Identifiable {
    var name: String
    var plays: Int
    var albumsOwned: Int
    var artworkData: Data?
    var artworkURL: URL?
    var bandcampURL: String?
    var id: String { name.lowercased() }
}

/// A playful archetype summarising the year, derived from the listening shape.
struct Persona {
    var title: String
    var blurb: String
    var symbol: String
}

/// "How you listened to this album" — per-album detail shown when you tap a cover/row.
struct AlbumInsight: Identifiable {
    var id: String
    var title: String
    var artist: String
    var albumID: UUID?
    var artworkData: Data?
    var artworkURL: URL?
    var plays: Int
    var minutes: Int
    var topTrack: String?
    var topTrackPlays: Int
    var peakMonth: Int?          // 1…12
    var longestStreak: Int
    var firstListen: Date?
    var lastListen: Date?

    var asRecapItem: RecapItem {
        RecapItem(albumID: albumID, title: title, artist: artist, plays: plays,
                  seconds: 0, artworkURL: artworkURL, artworkData: artworkData)
    }
}

/// A full year's listening recap: albums ranked by plays, plus headline stats.
struct Recap {
    var year: Int
    /// Albums with ≥1 real listen, sorted by plays (then time) descending.
    var items: [RecapItem]
    var totalSeconds: Double
    var albumCount: Int
    var topArtist: String?

    // MARK: Year-in-review stats (all default to empty so partial builds/older call sites work)
    var totalPlays: Int = 0
    var topArtistPlays: Int = 0
    var distinctArtists: Int = 0
    /// Albums whose first-ever listen (across all history) landed in this year.
    var discoveryCount: Int = 0
    /// Longest run of consecutive calendar days with a real listen.
    var longestStreak: Int = 0
    /// Hour of day (0…23) you played most, or nil if unknown.
    var peakHour: Int? = nil
    var topGenres: [NamedCount] = []
    var genreCount: Int = 0
    var months: [MonthTop] = []
    // Support angle (Bandcamp is owned music, not streams):
    var ownedArtists: Int = 0        // distinct owned artists you played this year
    var ownedAlbums: Int = 0         // owned albums you played this year
    var collectionSize: Int = 0      // total Bandcamp albums in the library
    var percentOwned: Int = 0        // % of this year's plays that were music you own (0…100)
    var topSupportedArtists: [SupportedArtist] = []
    var labelCount: Int = 0          // distinct labels in the owned collection
    var topLabel: String? = nil      // label you own the most from
    var albumsAddedThisYear: Int = 0 // owned albums whose dateAdded is in this year (needs data)
    var newlySupportedArtists: Int = 0 // artists whose whole owned catalogue was added this year

    var isEmpty: Bool { items.isEmpty }
    var totalHours: Double { totalSeconds / 3600 }
    var totalMinutes: Int { max(0, Int((totalSeconds / 60).rounded())) }
    var topArtistShare: Double { totalPlays > 0 ? Double(topArtistPlays) / Double(totalPlays) : 0 }

    /// The N most-played albums — for the spiral centre and the share link.
    func top(_ n: Int) -> [RecapItem] { Array(items.prefix(n)) }

    /// A fun archetype for the year, picked from the strongest signal.
    var persona: Persona {
        if discoveryCount >= max(12, albumCount / 2), discoveryCount > 0 {
            return Persona(title: "The Explorer", blurb: "You chased down \(discoveryCount) records you'd never heard before.", symbol: "safari")
        }
        if let a = topArtist, topArtistShare >= 0.35 {
            return Persona(title: "One-Artist Devotee", blurb: "This year your ears belonged to \(a).", symbol: "heart.circle")
        }
        if genreCount >= 6 {
            return Persona(title: "Genre Nomad", blurb: "You roamed across \(genreCount) different genres.", symbol: "shuffle")
        }
        switch peakHour ?? 20 {
        case 5..<11:  return Persona(title: "Early Bird", blurb: "Mornings were your soundtrack.", symbol: "sunrise")
        case 11..<17: return Persona(title: "Daylight Spinner", blurb: "You kept the day moving to music.", symbol: "sun.max")
        case 17..<23: return Persona(title: "Evening Listener", blurb: "The night drew in with a record on.", symbol: "sunset")
        default:      return Persona(title: "Night Owl", blurb: "The small hours were yours.", symbol: "moon.stars")
        }
    }

    /// "1 AM", "9 PM" … for the peak-hour card.
    var peakHourLabel: String? {
        guard let h = peakHour else { return nil }
        let am = h < 12
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(am ? "AM" : "PM")"
    }
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
                      month: Int? = nil,
                      albums: [Album],
                      history: [PlayEvent] = HistoryStore.load(),
                      calendar: Calendar = .current) -> Recap {
        // `month == nil` → the whole year; otherwise just that calendar month.
        let inYear = history.filter {
            calendar.component(.year, from: $0.date) == year
                && (month == nil || calendar.component(.month, from: $0.date) == month)
        }

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
            // Only albums still in the library count — a removed/imported album that's no longer
            // in the app shouldn't linger in the recap (it renders as a blank, art-less tile).
            guard let live = g.albumID.flatMap({ byID[$0] }) ?? resolve(g.title, g.artist) else { continue }
            let title = live.title
            let artist = live.artist
            let key = norm(title, artist)
            if var existing = merged[key] {
                existing.plays += g.plays
                existing.seconds += g.seconds
                merged[key] = existing
            } else {
                merged[key] = RecapItem(
                    albumID: live.id,
                    title: title,
                    artist: artist,
                    plays: g.plays,
                    seconds: g.seconds,
                    artworkURL: live.artworkURL,
                    artworkData: live.artworkData,
                    bandcampURL: live.bandcampItemURL
                )
            }
        }
        let items: [RecapItem] = merged.values
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.seconds > $1.seconds }

        let totalSeconds = items.reduce(0) { $0 + $1.seconds }

        var byArtist: [String: Int] = [:]
        for it in items where !it.artist.isEmpty { byArtist[it.artist, default: 0] += it.plays }
        let topArtist = byArtist.max { $0.value < $1.value }?.key

        // Live album for an item, for source/genre lookups.
        func live(_ it: RecapItem) -> Album? { it.albumID.flatMap { byID[$0] } ?? resolve(it.title, it.artist) }

        let totalPlays = items.reduce(0) { $0 + $1.plays }

        // Discovery: albums whose earliest real listen across ALL history is in this year.
        var firstYear: [String: Int] = [:]
        for e in history where e.isRealListen {
            let l = resolve(e.albumTitle, e.artist)
            let key = norm(l?.title ?? e.albumTitle, l?.artist ?? e.artist)
            let y = calendar.component(.year, from: e.date)
            firstYear[key] = min(firstYear[key] ?? y, y)
        }
        let discoveryCount = merged.keys.filter { firstYear[$0] == year }.count

        // Longest consecutive-day listening streak within the year.
        var days = Set<Date>()
        for e in inYear where e.isRealListen { days.insert(calendar.startOfDay(for: e.date)) }
        var longestStreak = 0, run = 0
        var prev: Date?
        for d in days.sorted() {
            if let p = prev, let next = calendar.date(byAdding: .day, value: 1, to: p),
               calendar.isDate(next, inSameDayAs: d) { run += 1 } else { run = 1 }
            longestStreak = max(longestStreak, run); prev = d
        }

        // Peak listening hour.
        var hourCounts: [Int: Int] = [:]
        for e in inYear where e.isRealListen { hourCounts[calendar.component(.hour, from: e.date), default: 0] += 1 }
        let peakHour = hourCounts.max { $0.value < $1.value }?.key

        // Genres, weighted by plays.
        var genreCounts: [String: Int] = [:]
        for it in items {
            guard let g = live(it)?.genre, !g.isEmpty else { continue }
            for part in g.split(separator: ",") {
                let name = part.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { genreCounts[name, default: 0] += it.plays }
            }
        }
        let topGenres = genreCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5).map { NamedCount(name: $0.key, plays: $0.value) }

        // Month-by-month top album.
        var perMonth: [Int: [String: Int]] = [:]
        for e in inYear where e.isRealListen {
            let l = resolve(e.albumTitle, e.artist)
            let key = norm(l?.title ?? e.albumTitle, l?.artist ?? e.artist)
            let m = calendar.component(.month, from: e.date)
            perMonth[m, default: [:]][key, default: 0] += 1
        }
        var months: [MonthTop] = []
        for m in 1...12 {
            guard let counts = perMonth[m],
                  let best = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
                  let item = merged[best.key] else { continue }
            months.append(MonthTop(month: m, item: item))
        }

        // Support angle — owned (Bandcamp) music you actually played this year.
        var ownedArtistsSet = Set<String>()
        var ownedAlbums = 0
        for it in items where live(it)?.source == .bandcamp {
            ownedAlbums += 1
            if !it.artist.isEmpty { ownedArtistsSet.insert(it.artist.lowercased()) }
        }
        let collectionSize = albums.filter { $0.source == .bandcamp }.count

        // % of this year's plays that were music you own.
        let ownedPlays = items.filter { live($0)?.source == .bandcamp }.reduce(0) { $0 + $1.plays }
        let percentOwned = totalPlays > 0 ? Int((Double(ownedPlays) / Double(totalPlays) * 100).rounded()) : 0

        // Who you backed: owned artists you played this year, ranked by plays, with a cover +
        // buy link + how many of their albums you own overall.
        var supPlays: [String: Int] = [:]
        var supMeta: [String: (name: String, url: URL?, data: Data?, bc: String?)] = [:]
        for it in items where !it.artist.isEmpty && live(it)?.source == .bandcamp {
            let key = it.artist.lowercased()
            supPlays[key, default: 0] += it.plays
            if supMeta[key] == nil { supMeta[key] = (it.artist, it.artworkURL, it.artworkData, it.bandcampURL) }
        }
        var ownedByArtist: [String: Int] = [:]
        for a in albums where a.source == .bandcamp && !a.artist.isEmpty {
            ownedByArtist[a.artist.lowercased(), default: 0] += 1
        }
        let topSupportedArtists: [SupportedArtist] = supPlays
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6)
            .compactMap { key, plays in
                guard let m = supMeta[key] else { return nil }
                return SupportedArtist(name: m.name, plays: plays, albumsOwned: ownedByArtist[key] ?? 1,
                                       artworkData: m.data, artworkURL: m.url, bandcampURL: m.bc)
            }

        // Labels you back (across the owned collection).
        var labelCounts: [String: Int] = [:]
        for a in albums where a.source == .bandcamp {
            guard let l = a.label?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { continue }
            labelCounts[l, default: 0] += 1
        }
        let topLabel = labelCounts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key

        // Collection growth this year (dateAdded — nil on pre-tracking albums, so no false spike).
        var albumsAddedThisYear = 0
        var artistAddYears: [String: Set<Int>] = [:]
        var artistHasUnknownAdd = Set<String>()
        for a in albums where a.source == .bandcamp && !a.artist.isEmpty {
            let k = a.artist.lowercased()
            if let d = a.dateAdded {
                let y = calendar.component(.year, from: d)
                artistAddYears[k, default: []].insert(y)
                if y == year { albumsAddedThisYear += 1 }
            } else {
                artistHasUnknownAdd.insert(k)
            }
        }
        let newlySupportedArtists = artistAddYears.filter { k, ys in
            !artistHasUnknownAdd.contains(k) && ys == [year]
        }.count

        return Recap(year: year, items: items, totalSeconds: totalSeconds,
                     albumCount: items.count, topArtist: topArtist,
                     totalPlays: totalPlays,
                     topArtistPlays: topArtist.flatMap { byArtist[$0] } ?? 0,
                     distinctArtists: byArtist.count,
                     discoveryCount: discoveryCount,
                     longestStreak: longestStreak,
                     peakHour: peakHour,
                     topGenres: topGenres,
                     genreCount: genreCounts.count,
                     months: months,
                     ownedArtists: ownedArtistsSet.count,
                     ownedAlbums: ownedAlbums,
                     collectionSize: collectionSize,
                     percentOwned: percentOwned,
                     topSupportedArtists: topSupportedArtists,
                     labelCount: labelCounts.count,
                     topLabel: topLabel,
                     albumsAddedThisYear: albumsAddedThisYear,
                     newlySupportedArtists: newlySupportedArtists)
    }

    /// Per-album listening detail for a given year — favourite track, busiest month, streak, etc.
    static func insight(for item: RecapItem, year: Int,
                        history: [PlayEvent] = HistoryStore.load(),
                        calendar: Calendar = .current) -> AlbumInsight {
        func normT(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        let title = normT(item.title)
        // Match by album title (the event's artist is often the track artist, so title is the
        // stable key — same reasoning as RecapBuilder's resolve).
        let events = history.filter {
            calendar.component(.year, from: $0.date) == year && normT($0.albumTitle) == title
        }
        let real = events.filter { $0.isRealListen }

        var trackCounts: [String: Int] = [:]
        for e in real where !e.trackTitle.isEmpty { trackCounts[e.trackTitle, default: 0] += 1 }
        let top = trackCounts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }

        var monthCounts: [Int: Int] = [:]
        for e in real { monthCounts[calendar.component(.month, from: e.date), default: 0] += 1 }
        let peakMonth = monthCounts.max { $0.value < $1.value }?.key

        var days = Set<Date>()
        for e in real { days.insert(calendar.startOfDay(for: e.date)) }
        var longest = 0, run = 0
        var prev: Date?
        for d in days.sorted() {
            if let p = prev, let next = calendar.date(byAdding: .day, value: 1, to: p),
               calendar.isDate(next, inSameDayAs: d) { run += 1 } else { run = 1 }
            longest = max(longest, run); prev = d
        }

        let dates = events.map(\.date)
        return AlbumInsight(
            id: item.id, title: item.title, artist: item.artist, albumID: item.albumID,
            artworkData: item.artworkData, artworkURL: item.artworkURL,
            plays: real.count,
            minutes: max(0, Int((events.reduce(0) { $0 + $1.seconds } / 60).rounded())),
            topTrack: top?.key, topTrackPlays: top?.value ?? 0,
            peakMonth: peakMonth, longestStreak: longest,
            firstListen: dates.min(), lastListen: dates.max())
    }

    /// Distinct years that have at least one real listen, newest first — for the year picker.
    static func years(history: [PlayEvent] = HistoryStore.load(), calendar: Calendar = .current) -> [Int] {
        var s = Set<Int>()
        for e in history where e.isRealListen { s.insert(calendar.component(.year, from: e.date)) }
        return s.sorted(by: >)
    }
}
