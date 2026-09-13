import Foundation

/// A fetched artist description with its provenance (for attribution).
struct ArtistBio: Codable, Equatable {
    let text: String
    let sourceName: String    // e.g. "Wikipedia"
    let sourceURL: String?
}

/// Disk-cached artist descriptions.
///
/// The hard part is making sure we surface the *right* entity, not a namesake or an unrelated
/// "Chanel Beads" product page. Two tiers:
///   1. Authoritative — resolve via MusicBrainz → Wikidata/Wikipedia ID links (only trusted when
///      the artist name matches exactly). No ambiguity when the link exists.
///   2. Guarded name lookup — fetch Wikipedia by name, and accept only if the page is a real
///      article (not a disambiguation) AND is clearly about a musical act: its description/extract
///      contains music words, or it mentions an album the user actually owns by that artist.
///      That album-title corroboration is what rules out a same-named non-music page.
/// If neither passes we return nil (a caller can fall back to the Bandcamp band-page bio).
enum ArtistBioService {
    private static let ua = "Yoin (+https://github.com/02-alt/bandcamp-player)"
    private static let musicWords = ["musician", "band", "singer", "rapper", "producer", "dj",
        "musical", "songwriter", "record producer", "duo", "composer", "instrumentalist",
        "recording artist", "girl group", "boy band", "rock group"]

    /// Cached-or-fetched bio for an artist. `ownedAlbumTitles` are album titles the user owns by
    /// this artist — used to corroborate a name-based Wikipedia match.
    @MainActor
    static func bio(artist: String, ownedAlbumTitles: [String]) async -> ArtistBio? {
        let key = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let hit = BioStore.shared.cached(key) { return hit.text.isEmpty ? nil : hit }
        let bio = await fetch(artist: artist, owned: ownedAlbumTitles)
        BioStore.shared.store(bio ?? ArtistBio(text: "", sourceName: "", sourceURL: nil), for: key)
        return bio
    }

    // MARK: Fetch pipeline

    private static func fetch(artist: String, owned: [String]) async -> ArtistBio? {
        if let b = await resolveOne(artist, owned: owned) { return b }
        // Collaboration string ("A & B", "A, B x C") → try each member; return the first notable one.
        let parts = splitArtists(artist)
        if parts.count > 1 {
            for name in parts { if let b = await resolveOne(name, owned: owned) { return b } }
        }
        // Tier 3: Genius artist description (broader indie coverage than Wikipedia).
        if let g = await GeniusService.artistDescription(artist: artist) { return g }
        return nil
    }

    /// Resolve a single artist name via the two Wikipedia tiers.
    private static func resolveOne(_ artist: String, owned: [String]) async -> ArtistBio? {
        // Tier 1: authoritative ID chain.
        if let title = await wikipediaTitleViaMusicBrainz(artist),
           let s = await summary(title: title), s.type != "disambiguation", !s.extract.isEmpty {
            return ArtistBio(text: s.extract, sourceName: "Wikipedia", sourceURL: s.page)
        }
        // Tier 2: guarded name lookup.
        if let s = await summary(title: artist), s.type == "standard", !s.extract.isEmpty {
            let hay = (s.description + " " + s.extract).lowercased()
            let isMusic = musicWords.contains { hay.contains($0) }
            let mentionsOwned = owned.contains { !$0.isEmpty && s.extract.localizedCaseInsensitiveContains($0) }
            if isMusic || mentionsOwned {
                return ArtistBio(text: s.extract, sourceName: "Wikipedia", sourceURL: s.page)
            }
        }
        return nil
    }

    /// Break a collaboration credit into individual artist names.
    private static func splitArtists(_ s: String) -> [String] {
        let seps = [" & ", ", ", " x ", " × ", " vs. ", " vs ", " feat. ", " feat ", " featuring ", " with "]
        var parts = [s]
        for sep in seps { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 }
    }

    // MARK: Wikipedia

    private struct Summary { let type: String; let description: String; let extract: String; let page: String? }

    private static func summary(title: String) async -> Summary? {
        guard let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let j = await getJSON("https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)") as? [String: Any]
        else { return nil }
        let page = ((j["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        return Summary(type: j["type"] as? String ?? "",
                       description: j["description"] as? String ?? "",
                       extract: j["extract"] as? String ?? "",
                       page: page)
    }

    /// The exact enwiki article title for an artist, resolved through MusicBrainz's ID links.
    private static func wikipediaTitleViaMusicBrainz(_ artist: String) async -> String? {
        guard let q = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let j = await getJSON("https://musicbrainz.org/ws/2/artist/?query=artist:%22\(q)%22&fmt=json") as? [String: Any],
              let artists = j["artists"] as? [[String: Any]] else { return nil }
        // Only trust the ID link when the name matches exactly (avoids linking a namesake).
        guard let match = artists.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(artist) == .orderedSame }),
              let id = match["id"] as? String,
              let a = await getJSON("https://musicbrainz.org/ws/2/artist/\(id)?inc=url-rels&fmt=json") as? [String: Any],
              let rels = a["relations"] as? [[String: Any]] else { return nil }

        for r in rels where (r["type"] as? String) == "wikipedia" {
            if let res = (r["url"] as? [String: Any])?["resource"] as? String, let t = wikiTitle(from: res) { return t }
        }
        for r in rels where (r["type"] as? String) == "wikidata" {
            if let res = (r["url"] as? [String: Any])?["resource"] as? String,
               let qid = res.split(separator: "/").last.map(String.init),
               let t = await enwikiTitle(fromWikidata: qid) { return t }
        }
        return nil
    }

    private static func enwikiTitle(fromWikidata qid: String) async -> String? {
        guard let j = await getJSON("https://www.wikidata.org/wiki/Special:EntityData/\(qid).json") as? [String: Any],
              let entities = j["entities"] as? [String: Any],
              let entity = entities[qid] as? [String: Any],
              let sitelinks = entity["sitelinks"] as? [String: Any],
              let enwiki = sitelinks["enwiki"] as? [String: Any] else { return nil }
        return enwiki["title"] as? String
    }

    private static func wikiTitle(from resource: String) -> String? {
        guard let range = resource.range(of: "/wiki/") else { return nil }
        let slug = String(resource[range.upperBound...])
        return slug.removingPercentEncoding?.replacingOccurrences(of: "_", with: " ")
    }

    private static func getJSON(_ urlStr: String) async -> Any? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// UserDefaults-backed cache of artist bios. Stores misses (empty text) too, so a fruitless
/// lookup isn't repeated every time.
@MainActor
final class BioStore {
    static let shared = BioStore()
    private var map: [String: ArtistBio]
    private let key = "yoin.artistBios.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let m = try? JSONDecoder().decode([String: ArtistBio].self, from: d) {
            map = m
        } else { map = [:] }
    }

    func cached(_ k: String) -> ArtistBio? { map[k] }

    func store(_ bio: ArtistBio, for k: String) {
        map[k] = bio
        if let d = try? JSONEncoder().encode(map) { UserDefaults.standard.set(d, forKey: key) }
    }
}
