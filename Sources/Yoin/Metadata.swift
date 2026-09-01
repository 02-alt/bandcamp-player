import Foundation
import AppKit

// MARK: - Public shapes

/// One search result the user can pick from in the "wrong album?" sheet.
struct MatchCandidate: Identifiable, Sendable {
    let id = UUID()
    var source: MetaSource
    var title: String
    var artist: String
    var year: String
    var artworkURL: URL?
    var discogsReleaseID: Int?
    var musicbrainzID: String?

    var subtitle: String {
        [artist, year.isEmpty ? nil : year, source.label]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum MetaSource: String, Sendable {
    case discogs, itunes, musicbrainz
    var label: String {
        switch self {
        case .discogs: return "Discogs"
        case .itunes: return "iTunes"
        case .musicbrainz: return "MusicBrainz"
        }
    }
}

/// Which provider supplies personnel credits. iTunes always fills covers/names.
enum CreditsSource: String, CaseIterable, Sendable {
    case auto, discogs, musicbrainz
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .discogs: return "Discogs"
        case .musicbrainz: return "MusicBrainz"
        }
    }
}

/// The metadata we attach to an album once a match is confirmed.
struct EnrichedMeta: Sendable {
    var title: String
    var artist: String
    var year: String
    var label: String?
    var genre: String?
    var credits: [Credit]
    var artworkURL: URL?
    var discogsReleaseID: Int?
    var musicbrainzID: String?
}

// MARK: - Preferences (kept out of AppState to avoid churn on the shared file)

enum MetadataPrefs {
    static let tokenAccount = "discogs_token"
    private static let autoKey = "yoin.autoEnrichImports"

    static var discogsToken: String? {
        get { Keychain.get(account: tokenAccount).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, account: tokenAccount) }
            else { Keychain.delete(account: tokenAccount) }
        }
    }

    /// Default on — imports auto-enrich when possible.
    static var autoEnrich: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    private static let sourceKey = "yoin.creditsSource"
    /// Which provider supplies credits. Defaults to automatic.
    static var creditsSource: CreditsSource {
        get { (UserDefaults.standard.string(forKey: sourceKey)).flatMap(CreditsSource.init) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }
}

// MARK: - Filename cleanup

enum FilenameCleaner {
    /// Best-effort artist/title guess from a messy downloaded filename.
    /// Handles leading track numbers, underscores, and "(Official Audio)"-style junk.
    static func parse(_ raw: String) -> (artist: String?, title: String) {
        var s = raw

        // Underscores/dots → spaces.
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: ".", with: " ")

        // Strip bracketed / parenthesised junk: (Official Video), [HQ], {Audio}…
        s = s.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ",
                                   options: .regularExpression)

        // Strip common quality/junk tokens.
        for junk in ["official video", "official audio", "lyric video", "audio", "hd", "hq",
                     "320kbps", "320 kbps", "128kbps", "free download", "youtube"] {
            s = s.replacingOccurrences(of: junk, with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }

        // Leading track number: "01 - ", "01. ", "1) ", "01 "
        s = s.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-.\)]?\s+"#, with: "",
                                   options: .regularExpression)

        // Collapse whitespace.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // "Artist - Title" split (first dash wins).
        if let dash = s.range(of: " - ") {
            let artist = String(s[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(s[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty { return (artist, title) }
        }
        return (nil, s.isEmpty ? raw : s)
    }

    /// Clean a per-track title taken from a filename: strip a leading track
    /// number ("01 ", "1. ", "03 - ") and tidy separators, but keep the rest of
    /// the title intact (no artist split, no junk-token removal). Used for the
    /// track list of multi-file albums, e.g. Apple Music exports named "01 …".
    static func trackTitle(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-.\)]?\s+"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? raw : s
    }
}

// MARK: - Service

/// Looks up album metadata & credits. Discogs first (rich personnel credits, needs a
/// free token), iTunes as a keyless fallback for clean names + cover art.
struct MetadataService {
    var token: String? = MetadataPrefs.discogsToken

    private static let session = URLSession(configuration: .default)
    private static let userAgent = "Yoin/0.1 (+https://github.com/yoin-app)"

    // MARK: Candidates for the manual picker

    func candidates(query: String) async -> [MatchCandidate] {
        async let itunes = itunesSearch(query)   // always: covers + clean names
        var creditsProvider: [MatchCandidate]
        switch MetadataPrefs.creditsSource {
        case .discogs:      creditsProvider = await discogsSearch(query)
        case .musicbrainz:  creditsProvider = await musicbrainzSearch(query)
        case .auto:         creditsProvider = token != nil ? await discogsSearch(query)
                                                           : await musicbrainzSearch(query)
        }
        return creditsProvider + (await itunes)
    }

    /// One-shot enrichment: pick the best candidate and resolve full details.
    func enrich(artist: String?, title: String) async -> EnrichedMeta? {
        let query = [artist, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let list = await candidates(query: query)
        guard let best = list.first else { return nil }
        return await details(for: best)
    }

    /// Resolve a chosen candidate into full metadata (personnel credits when possible).
    func details(for c: MatchCandidate) async -> EnrichedMeta? {
        if let id = c.discogsReleaseID, let token {
            return await discogsRelease(id: id, token: token, fallback: c)
        }
        if let mbid = c.musicbrainzID {
            return await musicbrainzRelease(id: mbid, fallback: c)
        }
        // iTunes candidate: no personnel credits, but clean name + cover + year.
        return EnrichedMeta(title: c.title, artist: c.artist, year: c.year,
                            label: nil, genre: nil, credits: [],
                            artworkURL: c.artworkURL, discogsReleaseID: nil, musicbrainzID: nil)
    }

    /// Per-track credits from whichever provider matched this album.
    func trackCredits(for album: Album, index: Int, title: String) async -> [Credit] {
        if let id = album.discogsReleaseID, token != nil {
            return await trackCredits(releaseID: id, index: index, title: title)
        }
        if let mbid = album.musicbrainzID {
            return await musicbrainzTrackCredits(id: mbid, index: index, title: title)
        }
        return []
    }

    // MARK: iTunes (keyless)

    private func itunesSearch(_ query: String) async -> [MatchCandidate] {
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        comps.queryItems = [
            .init(name: "term", value: query),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "6")
        ]
        guard let url = comps.url,
              let res: ITunesResponse = try? await Self.get(url) else { return [] }
        return res.results.map { r in
            MatchCandidate(source: .itunes,
                           title: r.collectionName ?? "",
                           artist: r.artistName ?? "",
                           year: String((r.releaseDate ?? "").prefix(4)),
                           artworkURL: r.hiResArtwork,
                           discogsReleaseID: nil)
        }.filter { !$0.title.isEmpty }
    }

    // MARK: Discogs

    private func discogsSearch(_ query: String) async -> [MatchCandidate] {
        guard let token, var comps = URLComponents(string: "https://api.discogs.com/database/search")
        else { return [] }
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "type", value: "release"),
            .init(name: "per_page", value: "6"),
            .init(name: "token", value: token)
        ]
        guard let url = comps.url,
              let res: DiscogsSearch = try? await Self.get(url) else { return [] }
        return res.results.map { r in
            // Discogs titles are "Artist - Album".
            let parts = (r.title ?? "").components(separatedBy: " - ")
            let artist = parts.count > 1 ? parts[0] : ""
            let album = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : (r.title ?? "")
            return MatchCandidate(source: .discogs,
                                  title: album,
                                  artist: artist,
                                  year: r.year ?? "",
                                  artworkURL: r.cover_image.flatMap(URL.init(string:)),
                                  discogsReleaseID: r.id)
        }
    }

    private func discogsRelease(id: Int, token: String, fallback c: MatchCandidate) async -> EnrichedMeta? {
        guard let url = URL(string: "https://api.discogs.com/releases/\(id)?token=\(token)"),
              let r: DiscogsRelease = try? await Self.get(url) else { return nil }

        let credits: [Credit] = (r.extraartists ?? []).map {
            Credit(role: prettyRole($0.role ?? ""), name: ($0.name ?? "").trimmingCharacters(in: .whitespaces))
        }.filter { !$0.name.isEmpty && !$0.role.isEmpty }

        let artist = (r.artists?.compactMap { $0.name }.joined(separator: ", ")).flatMap { $0.isEmpty ? nil : $0 } ?? c.artist
        return EnrichedMeta(
            title: r.title ?? c.title,
            artist: artist,
            year: r.year.map(String.init) ?? c.year,
            label: r.labels?.first?.name,
            genre: (r.genres ?? []).joined(separator: ", ").nonEmpty,
            credits: dedupe(credits),
            artworkURL: r.images?.first?.uri.flatMap(URL.init(string:)) ?? c.artworkURL,
            discogsReleaseID: id,
            musicbrainzID: nil
        )
    }

    // MARK: MusicBrainz (keyless — no account needed)

    private func musicbrainzSearch(_ query: String) async -> [MatchCandidate] {
        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release") else { return [] }
        comps.queryItems = [
            .init(name: "query", value: query),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "6")
        ]
        guard let url = comps.url,
              let res: MBSearch = try? await Self.mbGet(url) else { return [] }
        return res.releases.map { r in
            let artist = (r.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: ", ")) ?? ""
            return MatchCandidate(
                source: .musicbrainz,
                title: r.title ?? "",
                artist: artist,
                year: String((r.date ?? "").prefix(4)),
                artworkURL: URL(string: "https://coverartarchive.org/release/\(r.id)/front-500"),
                discogsReleaseID: nil,
                musicbrainzID: r.id)
        }.filter { !$0.title.isEmpty }
    }

    private func musicbrainzRelease(id: String, fallback c: MatchCandidate) async -> EnrichedMeta? {
        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)") else { return nil }
        comps.queryItems = [
            .init(name: "fmt", value: "json"),
            .init(name: "inc", value: "artist-credits+labels+recordings+artist-rels+recording-level-rels+genres")
        ]
        guard let url = comps.url, let r: MBRelease = try? await Self.mbGet(url) else { return nil }

        let credits = dedupe((r.relations ?? []).compactMap { mbCredit($0) })
        let artist = (r.artistCredit?.compactMap { $0.name }.joined(separator: ", ")).flatMap { $0.isEmpty ? nil : $0 } ?? c.artist
        let genres = (r.genres ?? []).compactMap { $0.name }.prefix(2).joined(separator: ", ")
        return EnrichedMeta(
            title: r.title ?? c.title,
            artist: artist,
            year: String((r.date ?? c.year).prefix(4)),
            label: r.labelInfo?.first?.label?.name,
            genre: genres.isEmpty ? nil : genres,
            credits: credits,
            artworkURL: c.artworkURL,
            discogsReleaseID: nil,
            musicbrainzID: id)
    }

    private func musicbrainzTrackCredits(id: String, index: Int, title: String) async -> [Credit] {
        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)") else { return [] }
        comps.queryItems = [
            .init(name: "fmt", value: "json"),
            .init(name: "inc", value: "recordings+recording-level-rels+artist-credits")
        ]
        guard let url = comps.url, let r: MBRelease = try? await Self.mbGet(url) else { return [] }
        let tracks = (r.media ?? []).flatMap { $0.tracks ?? [] }
        let entry = tracks.first { ($0.title ?? "").caseInsensitiveCompare(title) == .orderedSame }
            ?? (index < tracks.count ? tracks[index] : nil)
        let rels = entry?.recording?.relations ?? []
        return dedupe(rels.compactMap { mbCredit($0) })
    }

    /// Turn a MusicBrainz relationship into a role/name credit.
    private func mbCredit(_ rel: MBRelease.Relation) -> Credit? {
        guard let name = rel.artist?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let type = rel.type, !type.isEmpty else { return nil }
        let attrs = rel.attributes ?? []
        let role: String
        switch type {
        case "instrument": role = attrs.first.map { $0.capitalized } ?? "Performer"
        case "vocal":      role = attrs.first.map { "\($0.capitalized) Vocals" } ?? "Vocals"
        default:           role = type.capitalized
        }
        return Credit(role: role, name: name)
    }

    /// Per-track personnel for one track of a Discogs release (producer, vocals, etc.).
    /// Matches by title first, then by track index among the actual tracks.
    func trackCredits(releaseID: Int, index: Int, title: String) async -> [Credit] {
        guard let token,
              let url = URL(string: "https://api.discogs.com/releases/\(releaseID)?token=\(token)"),
              let r: DiscogsRelease = try? await Self.get(url) else { return [] }

        // Real tracks only (skip headings/index entries that have no position).
        let tracks = (r.tracklist ?? []).filter { !($0.position ?? "").isEmpty }
        let entry = tracks.first { ($0.title ?? "").caseInsensitiveCompare(title) == .orderedSame }
            ?? (index < tracks.count ? tracks[index] : nil)

        var credits: [Credit] = []
        if let performers = entry?.artists, !performers.isEmpty {
            credits += performers.map { Credit(role: "Artist", name: ($0.name ?? "").trimmingCharacters(in: .whitespaces)) }
        }
        credits += (entry?.extraartists ?? []).map {
            Credit(role: prettyRole($0.role ?? ""), name: ($0.name ?? "").trimmingCharacters(in: .whitespaces))
        }
        return dedupe(credits.filter { !$0.name.isEmpty && !$0.role.isEmpty })
    }

    // MARK: Helpers

    /// Discogs roles can be "Producer, Mixed By" — split and tidy.
    private func prettyRole(_ role: String) -> String {
        role.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? role
    }

    private func dedupe(_ credits: [Credit]) -> [Credit] {
        var seen = Set<String>(); var out: [Credit] = []
        for c in credits where seen.insert(c.id).inserted { out.append(c) }
        return out
    }

    /// MusicBrainz allows ~1 request/second; serialize + space MB calls to stay under it.
    private static func mbGet<T: Decodable>(_ url: URL) async throws -> T {
        await MBThrottle.shared.wait()
        return try await get(url)
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Wire formats

private struct ITunesResponse: Decodable {
    struct Result: Decodable {
        var collectionName: String?
        var artistName: String?
        var releaseDate: String?
        var artworkUrl100: String?
        var hiResArtwork: URL? {
            artworkUrl100
                .map { $0.replacingOccurrences(of: "100x100bb", with: "1200x1200bb") }
                .flatMap(URL.init(string:))
        }
    }
    var results: [Result]
}

private struct DiscogsSearch: Decodable {
    struct Result: Decodable {
        var id: Int
        var title: String?
        var year: String?
        var cover_image: String?
    }
    var results: [Result]
}

private struct DiscogsRelease: Decodable {
    struct Artist: Decodable { var name: String? }
    struct Label: Decodable { var name: String? }
    struct Image: Decodable { var uri: String? }
    struct ExtraArtist: Decodable { var name: String?; var role: String? }
    struct TrackEntry: Decodable {
        var position: String?
        var title: String?
        var artists: [Artist]?
        var extraartists: [ExtraArtist]?
    }
    var title: String?
    var year: Int?
    var artists: [Artist]?
    var labels: [Label]?
    var genres: [String]?
    var images: [Image]?
    var extraartists: [ExtraArtist]?
    var tracklist: [TrackEntry]?
}

private struct MBNameRef: Decodable { var name: String? }

private struct MBSearch: Decodable {
    struct ArtistCredit: Decodable { var name: String?; var artist: MBNameRef? }
    struct Release: Decodable {
        var id: String
        var title: String?
        var date: String?
        var artistCredit: [ArtistCredit]?
        enum CodingKeys: String, CodingKey { case id, title, date, artistCredit = "artist-credit" }
    }
    var releases: [Release]
}

private struct MBRelease: Decodable {
    struct ArtistCredit: Decodable { var name: String? }
    struct LabelInfo: Decodable { var label: MBNameRef? }
    struct Relation: Decodable { var type: String?; var attributes: [String]?; var artist: MBNameRef? }
    struct Recording: Decodable { var title: String?; var relations: [Relation]? }
    struct Track: Decodable { var position: Int?; var title: String?; var recording: Recording? }
    struct Media: Decodable { var tracks: [Track]? }
    struct Genre: Decodable { var name: String? }
    var title: String?
    var date: String?
    var artistCredit: [ArtistCredit]?
    var labelInfo: [LabelInfo]?
    var relations: [Relation]?
    var media: [Media]?
    var genres: [Genre]?
    enum CodingKeys: String, CodingKey {
        case title, date, relations, media, genres
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
    }
}

/// Serializes MusicBrainz requests to stay within its ~1 request/second limit.
private actor MBThrottle {
    static let shared = MBThrottle()
    private var last = Date(timeIntervalSince1970: 0)
    func wait() async {
        let gap = Date().timeIntervalSince(last)
        if gap < 1.1 { try? await Task.sleep(nanoseconds: UInt64((1.1 - gap) * 1_000_000_000)) }
        last = Date()
    }
}
