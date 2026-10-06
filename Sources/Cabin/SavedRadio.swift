import Foundation

/// What a saved radio station is seeded from. A station is a *recipe*, not a fixed track
/// list — playing it regenerates fresh from the library (like a smart playlist).
enum RadioSeed: Codable, Equatable {
    case mood(Mood)
    case artist(String)
    /// Only that artist — every album of theirs you own, nothing else.
    case onlyArtist(String)
    case album(title: String, artist: String)   // by name, so it survives a re-sync's new ids
    case place(String)                           // a spot on the collection map ("Berlin, Germany")
    /// Albums you've played before but not in the last few months.
    case rediscovery
    /// Albums you own but have never really listened to.
    case neverPlayed
    /// Your most-played albums of the last 30 days.
    case heavyRotation
    /// What you were playing in this calendar month, a year ago.
    case lastYear

    var icon: String {
        switch self {
        case .mood(let m): return m.symbol
        case .artist: return "person.fill"
        case .onlyArtist: return "person.crop.circle"
        case .album: return "square.stack"
        case .place: return "mappin.and.ellipse"
        case .rediscovery: return "sparkles"
        case .neverPlayed: return "shippingbox"
        case .heavyRotation: return "flame"
        case .lastYear: return "calendar"
        }
    }
    var kindLabel: String {
        switch self {
        case .mood: return "Mix"
        case .artist: return "Artist"
        case .onlyArtist: return "Only artist"
        case .album: return "Album"
        case .place: return "Place"
        case .rediscovery: return "Rediscovery"
        case .neverPlayed: return "Never played"
        case .heavyRotation: return "Heavy rotation"
        case .lastYear: return "A year ago"
        }
    }
}

/// A ready-to-play station on the Radio row: what it's seeded from, the plain fact that explains
/// it ("12 albums you haven't heard yet"), and a few covers from the albums it will actually play.
struct RadioSuggestion: Identifiable {
    let seed: RadioSeed
    let title: String
    let subtitle: String
    let covers: [Album]
    var id: String { seed.kindLabel + "|" + title }
    /// Name to save it under — "A year ago" rather than a month that will roll over.
    var savedName: String { seed == .lastYear ? seed.kindLabel : title }
}

/// The pools behind the history stations. Each is a plain rule over your own listening history
/// (no guessing), so a station's subtitle is something you can check.
enum RadioPools {
    /// Fewest albums a pool needs before it's offered as a station.
    static let minPool = 3
    static let rediscoveryAfter: TimeInterval = 90 * 86_400
    static let heavyWindow: TimeInterval = 30 * 86_400
    static let heavyCap = 25

    struct Stats {
        var plays: [UUID: Int] = [:]
        var last: [UUID: Date] = [:]
    }

    static func stats(_ history: [PlayEvent]) -> Stats {
        var s = Stats()
        for e in history where e.isRealListen {
            guard let id = e.albumID else { continue }
            s.plays[id, default: 0] += 1
            if e.date > s.last[id] ?? .distantPast { s.last[id] = e.date }
        }
        return s
    }

    /// Played before, but not in the last 3 months — longest-forgotten first.
    static func rediscovery(_ albums: [Album], _ s: Stats, now: Date = Date()) -> [Album] {
        albums.filter { a in s.last[a.id].map { now.timeIntervalSince($0) >= rediscoveryAfter } ?? false }
            .sorted { s.last[$0.id]! < s.last[$1.id]! }
    }

    /// Owned but never really listened to — most recently bought first.
    static func neverPlayed(_ albums: [Album], _ s: Stats) -> [Album] {
        albums.filter { s.plays[$0.id] == nil }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
    }

    /// Most-played albums of the last 30 days.
    static func heavyRotation(_ albums: [Album], history: [PlayEvent], now: Date = Date()) -> [Album] {
        ranked(albums, history.filter { now.timeIntervalSince($0.date) <= heavyWindow }, cap: heavyCap)
    }

    /// Albums you played during this calendar month, one year ago — most-played first.
    static func lastYear(_ albums: [Album], history: [PlayEvent], now: Date = Date()) -> [Album] {
        let cal = Calendar.current
        guard let then = cal.date(byAdding: .year, value: -1, to: now),
              let month = cal.dateInterval(of: .month, for: then) else { return [] }
        return ranked(albums, history.filter { month.contains($0.date) }, cap: nil)
    }

    /// "October 2025" — the month the `lastYear` pool covers.
    static func lastYearTitle(now: Date = Date()) -> String {
        let then = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return f.string(from: then)
    }

    private static func ranked(_ albums: [Album], _ events: [PlayEvent], cap: Int?) -> [Album] {
        let plays = stats(events).plays
        let hit = albums.filter { plays[$0.id] != nil }.sorted { plays[$0.id]! > plays[$1.id]! }
        return cap.map { Array(hit.prefix($0)) } ?? hit
    }
}

/// A named, persisted radio station.
struct SavedRadio: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var seed: RadioSeed
    var createdAt = Date()
}

enum SavedRadioStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("radios.json")
    }
    static func load() -> [SavedRadio] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([SavedRadio].self, from: data) else { return [] }
        return list
    }
    static func save(_ list: [SavedRadio]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
