import Foundation

/// Genius API client (read-only client access token, stored in the Keychain — never in source).
/// Used for per-song credits (its strongest data) and, as a weak fallback, artist descriptions.
/// Lyrics are intentionally NOT sourced here (Genius forbids it; we use LRCLIB).
/// One credit row — a role (heading) and the people in it.
public struct GeniusCredit: Codable, Equatable, Sendable {
    public let role: String
    public let names: String
    public init(role: String, names: String) { self.role = role; self.names = names }
}

/// In-memory memo of resolved song credits, so reopening the album Credits (or revisiting a
/// track) doesn't re-hit Genius. Caches definite results — hits *and* "song found, no credits"
/// — but not transient lookup failures, so those still retry. Cleared on relaunch.
private actor GeniusCreditsCache {
    public static let shared = GeniusCreditsCache()
    private var store: [String: [GeniusCredit]] = [:]   // empty array = resolved, no credits
    public func get(_ key: String) -> [GeniusCredit]? { store[key] }
    public func set(_ key: String, _ value: [GeniusCredit]) { store[key] = value }
}

public enum GeniusService {
    private static var token: String? { Keychain.get(account: "geniusToken") }
    /// Whether a Genius token is set (the credits fill-in only asks Genius when it is).
    public static var hasToken: Bool { token != nil }

    // MARK: Credits

    /// The outcome of a credits lookup: credits, a definite "Genius has none", or a failure
    /// (network, rate limit, no token) that's worth retrying later.
    public enum CreditsLookup { case found([GeniusCredit]), none, failed }

    /// Structured credits for a song (role → names), or nil. The role reads as a heading.
    public static func credits(artist: String, title: String, album: String) async -> [GeniusCredit]? {
        if case .found(let c) = await creditsLookup(artist: artist, title: title, album: album) { return c }
        return nil
    }

    public static func creditsLookup(artist: String, title: String, album: String) async -> CreditsLookup {
        let cacheKey = "\(artist)|\(title)|\(album)".lowercased()
        if let cached = await GeniusCreditsCache.shared.get(cacheKey) {
            return cached.isEmpty ? .none : .found(cached)
        }
        guard let hits = await searchHits("\(title) \(artist)") else { return .failed }
        let id = hits.lazy.compactMap { h -> Int? in
            guard let r = h["result"] as? [String: Any], let pa = r["primary_artist"] as? [String: Any],
                  nameMatches(pa["name"] as? String, artist) else { return nil }
            return r["id"] as? Int
        }.first
        guard let id else {
            await GeniusCreditsCache.shared.set(cacheKey, [])   // searched fine, no such song
            return .none
        }
        guard let song = await get("songs/\(id)?text_format=plain")?["song"] as? [String: Any] else { return .failed }

        func names(_ key: String) -> [String] {
            (song[key] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        }
        var out: [GeniusCredit] = []
        let prod = names("producer_artists"); if !prod.isEmpty { out.append(.init(role: "Producer", names: prod.joined(separator: ", "))) }
        let writ = names("writer_artists");   if !writ.isEmpty { out.append(.init(role: "Writer", names: writ.joined(separator: ", "))) }
        let feat = names("featured_artists");  if !feat.isEmpty { out.append(.init(role: "Featuring", names: feat.joined(separator: ", "))) }

        for p in (song["custom_performances"] as? [[String: Any]] ?? []) {
            guard let label = p["label"] as? String else { continue }
            let who = (p["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            if !who.isEmpty { out.append(.init(role: label, names: who.joined(separator: ", "))) }
        }
        // Song resolved (hit or genuinely empty) — memo it so we don't ask again this session.
        await GeniusCreditsCache.shared.set(cacheKey, out)
        return out.isEmpty ? .none : .found(out)
    }

    // MARK: Artist description

    public static func artistDescription(artist: String) async -> ArtistBio? {
        var sid = await songID(artist: artist, title: artist)
        if sid == nil { sid = await songID(artistOnly: artist) }
        guard let sid,
              let song = await get("songs/\(sid)?text_format=plain")?["song"] as? [String: Any],
              let pa = song["primary_artist"] as? [String: Any],
              nameMatches(pa["name"] as? String, artist),
              let aid = pa["id"] as? Int,
              let a = await get("artists/\(aid)?text_format=plain")?["artist"] as? [String: Any] else { return nil }
        let text = ((a["description"] as? [String: Any])?["plain"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        return ArtistBio(text: text, sourceName: "Genius", sourceURL: a["url"] as? String)
    }

    // MARK: Album description

    /// Genius's editorial description for an album (reached via one of its songs), or nil.
    /// Used as a fallback for the "About this album" panel when Bandcamp has no about text.
    public static func albumDescription(artist: String, album: String) async -> ArtistBio? {
        guard let hits = await searchHits("\(album) \(artist)") else { return nil }
        for h in hits {
            guard let r = h["result"] as? [String: Any],
                  let pa = r["primary_artist"] as? [String: Any],
                  nameMatches(pa["name"] as? String, artist),
                  let songID = r["id"] as? Int,
                  let song = await get("songs/\(songID)?text_format=plain")?["song"] as? [String: Any],
                  let alb = song["album"] as? [String: Any],
                  let albID = alb["id"] as? Int,
                  albumMatches(alb["name"] as? String, album),
                  let a = await get("albums/\(albID)?text_format=plain")?["album"] as? [String: Any]
            else { continue }
            let text = ((a["description"] as? [String: Any])?["plain"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            return ArtistBio(text: text, sourceName: "Genius", sourceURL: a["url"] as? String)
        }
        return nil
    }

    /// Loose album-title match — tolerates "(Deluxe)", edition suffixes, punctuation.
    private static func albumMatches(_ genius: String?, _ ours: String) -> Bool {
        func norm(_ s: String) -> String {
            s.folding(options: .diacriticInsensitive, locale: nil).lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard let g = genius.map(norm), !g.isEmpty else { return false }
        let o = norm(ours)
        return g == o || o.contains(g) || g.contains(o)
    }

    // MARK: Search / match

    /// The Genius song id for an artist+title whose primary artist matches (namesake guard).
    private static func songID(artist: String, title: String) async -> Int? {
        let q = "\(title) \(artist)"
        guard let hits = await searchHits(q) else { return nil }
        for h in hits {
            guard let r = h["result"] as? [String: Any],
                  let pa = r["primary_artist"] as? [String: Any] else { continue }
            if nameMatches(pa["name"] as? String, artist), let id = r["id"] as? Int { return id }
        }
        return nil
    }

    /// Loosest search (artist only) — used to reach an artist page for the description fallback.
    private static func songID(artistOnly artist: String) async -> Int? {
        guard let hits = await searchHits(artist) else { return nil }
        for h in hits {
            guard let r = h["result"] as? [String: Any],
                  let pa = r["primary_artist"] as? [String: Any] else { continue }
            if nameMatches(pa["name"] as? String, artist), let id = r["id"] as? Int { return id }
        }
        return nil
    }

    private static func searchHits(_ q: String) async -> [[String: Any]]? {
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let resp = await get("search?q=\(enc)") else { return nil }
        return resp["hits"] as? [[String: Any]]
    }

    /// Case/diacritic-insensitive match that tolerates collab strings (Genius often lists only the
    /// lead artist, e.g. "A" for a Bandcamp credit of "A & B").
    ///
    /// Whole names only: plain substring matching accepted namesakes once accents were folded —
    /// "Ciarán" → "ciaran" contains "ciara", so Ciara's bio showed for Ciarán.
    public static func nameMatches(_ genius: String?, _ ours: String) -> Bool {
        guard let genius else { return false }
        func norm(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // "A & B", "A, B x C", "A feat. B" → ["a", "b", "c"].
        func members(_ s: String) -> [String] {
            var parts = [norm(s)]
            for sep in [" & ", ", ", " x ", " × ", " and ", " feat. ", " feat ", " featuring ", " with "] {
                parts = parts.flatMap { $0.components(separatedBy: sep) }
            }
            return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let g = norm(genius), o = norm(ours)
        if g == o { return true }
        // A collaboration on either side: match when one side is exactly a member of the other.
        return members(ours).contains(g) || members(genius).contains(o)
    }

    // MARK: Networking

    /// GET an api.genius.com path, returning the `response` object.
    private static func get(_ path: String) async -> [String: Any]? {
        guard let token, let url = URL(string: "https://api.genius.com/\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j["response"] as? [String: Any]
    }
}
