import Foundation

/// Genius API client (read-only client access token, stored in the Keychain — never in source).
/// Used for per-song credits (its strongest data) and, as a weak fallback, artist descriptions.
/// Lyrics are intentionally NOT sourced here (Genius forbids it; we use LRCLIB).
/// One credit row — a role (heading) and the people in it.
struct GeniusCredit: Equatable { let role: String; let names: String }

enum GeniusService {
    private static var token: String? { Keychain.get(account: "geniusToken") }

    // MARK: Credits

    /// Structured credits for a song (role → names), or nil. The role reads as a heading.
    static func credits(artist: String, title: String, album: String) async -> [GeniusCredit]? {
        guard let id = await songID(artist: artist, title: title) else { return nil }
        guard let song = await get("songs/\(id)?text_format=plain")?["song"] as? [String: Any] else { return nil }

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
        return out.isEmpty ? nil : out
    }

    // MARK: Artist description

    static func artistDescription(artist: String) async -> ArtistBio? {
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
    private static func nameMatches(_ genius: String?, _ ours: String) -> Bool {
        guard let g = genius?.folding(options: .diacriticInsensitive, locale: nil).lowercased() else { return false }
        let o = ours.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        if g == o || o.contains(g) || g.contains(o) { return true }
        // Compare against the first named artist in a collaboration string.
        let lead = o.components(separatedBy: CharacterSet(charactersIn: ",&x×")).first?
            .trimmingCharacters(in: .whitespaces) ?? o
        return !lead.isEmpty && (g == lead || g.contains(lead) || lead.contains(g))
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
