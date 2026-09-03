import Foundation

/// The recipe behind an auto-generated ("smart") playlist: its track list is recomputed
/// from listening history + the library instead of being hand-curated. Stored on the
/// `Playlist` it drives; `nil` means an ordinary manual playlist.
enum SmartRule: Codable, Equatable {
    /// Tracks from the albums you've played the least (never-played first) — buried treasure.
    case rarelyPlayed
    /// The most-played tracks in a calendar period. `month == nil` means the whole year.
    case bestOf(year: Int, month: Int?)

    /// The name a freshly-created smart playlist gets.
    var defaultName: String {
        switch self {
        case .rarelyPlayed: return "Rarely played"
        case .bestOf(let year, let month):
            if let month { return "Best of \(SmartRule.monthName(month)) \(year)" }
            return "Best of \(year)"
        }
    }

    /// One-line explanation shown under the header / in the create menu.
    var blurb: String {
        switch self {
        case .rarelyPlayed: return "Albums you've been neglecting"
        case .bestOf(_, let month):
            return month == nil ? "Your most-played tracks this year" : "Your most-played tracks this month"
        }
    }

    /// SF Symbol used for the badge / empty-state cover.
    var symbol: String {
        switch self {
        case .rarelyPlayed: return "sparkles"
        case .bestOf: return "trophy.fill"
        }
    }

    static func monthName(_ m: Int) -> String {
        let symbols = DateFormatter().standaloneMonthSymbols ?? []
        return symbols.indices.contains(m - 1) ? symbols[m - 1].capitalized : "—"
    }
}

/// Turns a `SmartRule` into an ordered track list. Pure (aside from the injected `resolve`
/// closure that maps an album to its playable tracks) so it stays off the main actor.
@MainActor
enum SmartPlaylistBuilder {
    /// Cap so a smart playlist stays a listenable set, not the whole library.
    static let trackLimit = 40
    /// Tracks pulled from each album in "rarely played", to spread across many albums.
    static let perAlbum = 3

    static func build(_ rule: SmartRule,
                      albums: [Album],
                      history: [PlayEvent],
                      resolve: (Album) async -> [Track]) async -> [PlaylistTrack] {
        switch rule {
        case .rarelyPlayed:
            return await rarelyPlayed(albums: albums, history: history, resolve: resolve)
        case .bestOf(let year, let month):
            return await bestOf(year: year, month: month, albums: albums, history: history, resolve: resolve)
        }
    }

    // MARK: Rules

    private static func rarelyPlayed(albums: [Album],
                                     history: [PlayEvent],
                                     resolve: (Album) async -> [Track]) async -> [PlaylistTrack] {
        var plays: [UUID: Int] = [:]
        for e in history where e.isRealListen {
            if let id = e.albumID { plays[id, default: 0] += 1 }
        }
        // Least-played first (never-played lead), stable by title so the order doesn't jitter.
        let ranked = albums.filter { $0.isPlayable }.sorted {
            let a = plays[$0.id] ?? 0, b = plays[$1.id] ?? 0
            if a != b { return a < b }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        var result: [PlaylistTrack] = []
        for album in ranked {
            if result.count >= trackLimit { break }
            let tracks = await resolve(album)
            for (i, t) in tracks.prefix(perAlbum).enumerated() {
                result.append(entry(album: album, index: i, title: t.title))
                if result.count >= trackLimit { break }
            }
        }
        return result
    }

    private static func bestOf(year: Int, month: Int?,
                               albums: [Album],
                               history: [PlayEvent],
                               resolve: (Album) async -> [Track]) async -> [PlaylistTrack] {
        let calendar = Calendar.current
        let inPeriod = history.filter { e in
            guard e.isRealListen else { return false }
            let c = calendar.dateComponents([.year, .month], from: e.date)
            guard c.year == year else { return false }
            return month == nil || c.month == month
        }
        // Tally plays per distinct track, remembering first-seen order for stable ties.
        struct Key: Hashable { let album: UUID; let title: String }
        var counts: [Key: Int] = [:]
        var order: [Key] = []
        var firstSeen: [Key: Int] = [:]
        for e in inPeriod {
            guard let id = e.albumID, !e.trackTitle.isEmpty else { continue }
            let k = Key(album: id, title: e.trackTitle.lowercased())
            if counts[k] == nil { firstSeen[k] = order.count; order.append(k) }
            counts[k, default: 0] += 1
        }
        // Explicit tie-break on first-seen order — Swift's `sort` isn't guaranteed stable,
        // so equal-play tracks would otherwise reshuffle between rebuilds.
        let ranked = order.sorted {
            let ca = counts[$0] ?? 0, cb = counts[$1] ?? 0
            return ca != cb ? ca > cb : (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0)
        }

        var resolvedCache: [UUID: [Track]] = [:]
        var result: [PlaylistTrack] = []
        for k in ranked {
            if result.count >= trackLimit { break }
            guard let album = albums.first(where: { $0.id == k.album }) else { continue }
            let tracks: [Track]
            if let c = resolvedCache[k.album] { tracks = c }
            else { tracks = await resolve(album); resolvedCache[k.album] = tracks }
            // Match the logged title to a resolved track — exact first, then a looser
            // normalized/prefix match so minor title cleaning doesn't drop the top track.
            let want = normalize(k.title)
            let index = tracks.firstIndex { $0.title.lowercased() == k.title }
                ?? tracks.firstIndex { normalize($0.title) == want }
                ?? tracks.firstIndex { let n = normalize($0.title); return n.hasPrefix(want) || want.hasPrefix(n) }
            guard let index else { continue }
            result.append(entry(album: album, index: index, title: tracks[index].title))
        }
        return result
    }

    /// Lowercase, strip punctuation, collapse whitespace — for tolerant title matching.
    private static func normalize(_ s: String) -> String {
        let cleaned = s.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    private static func entry(album: Album, index: Int, title: String) -> PlaylistTrack {
        PlaylistTrack(albumID: album.id, albumTitle: album.title, artist: album.artist,
                      title: title, trackIndex: index,
                      artworkURL: album.artworkURL, artworkData: album.artworkData,
                      g0: album.g0, g1: album.g1)
    }
}
