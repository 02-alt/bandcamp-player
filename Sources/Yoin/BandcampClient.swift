import Foundation

/// One purchased item from a Bandcamp fan collection.
struct BCItem: Sendable, Identifiable {
    let id: Int          // item_id
    let title: String
    let artist: String
    let artId: Int?
    let itemURL: String?
    let type: String     // "album" | "track"
    var downloadPageURL: String? = nil
    /// The fan's own "why I love this" note on a collection item (Bandcamp's `why` field).
    /// Present on owned items; usually empty on wishlist items.
    var review: String? = nil

    /// High-res cover from Bandcamp's image CDN.
    var artworkURL: URL? {
        guard let artId else { return nil }
        return URL(string: "https://f4.bcbits.com/img/a\(artId)_16.jpg")
    }
}

/// A Bandcamp fan the account follows — the app's "friends". Public profile info only.
struct Friend: Identifiable, Sendable, Hashable {
    let id: Int          // fan_id
    let name: String
    let imageID: Int?
    let profileURL: String?
    let location: String?

    /// Circular avatar from Bandcamp's image CDN. Fan photo ids are zero-padded to 10 digits.
    var avatarURL: URL? {
        guard let imageID, imageID > 0 else { return nil }
        return URL(string: String(format: "https://f4.bcbits.com/img/%010d_50.jpg", imageID))
    }

    static func parse(_ d: [String: Any]) -> Friend? {
        guard let id = d["fan_id"] as? Int else { return nil }
        return Friend(id: id,
                      name: (d["name"] as? String) ?? "Bandcamp fan",
                      imageID: d["image_id"] as? Int,
                      profileURL: d["trackpipe_url"] as? String,
                      location: (d["location"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

enum BandcampError: LocalizedError {
    case notAuthenticated
    case badResponse(Int)
    case decode

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not connected to Bandcamp. Please connect your account."
        case .badResponse(let code): return "Bandcamp returned an error (\(code)). Your session may have expired — reconnect."
        case .decode: return "Couldn't read your collection from Bandcamp."
        }
    }
}

/// Talks to Bandcamp's (undocumented) fan-collection endpoints using the session `identity` cookie.
/// Legitimate for reading *your own* purchases; endpoints are unofficial so this is isolated here.
struct BandcampClient {
    let identity: String

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// A request carrying the session cookie + browser UA (used for downloads too).
    func authorizedRequest(_ url: URL) -> URLRequest { request(url) }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        // Only ever send the session cookie to Bandcamp itself — never to a CDN (bcbits) or
        // any host a tampered response might redirect us to. Signed CDN file URLs don't need it.
        if Self.isBandcampHost(url) {
            r.setValue("identity=\(identity)", forHTTPHeaderField: "Cookie")
        }
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// Returns the fan_id for the logged-in account.
    func fanID() async throws -> Int { try await collectionSummary().fanID }

    /// The account's fan_id plus, when Bandcamp reports it, the total number of owned items —
    /// used to drive a real launch progress bar. `total` is nil if the summary omits it.
    func collectionSummary() async throws -> (fanID: Int, total: Int?) {
        let url = URL(string: "https://bandcamp.com/api/fan/2/collection_summary")!
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        try Self.check(resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if Self.looksLikeLoginPage(data) { throw BandcampError.notAuthenticated }
            throw BandcampError.decode
        }
        let summary = obj["collection_summary"] as? [String: Any]
        guard let fid = (obj["fan_id"] as? Int) ?? (summary?["fan_id"] as? Int) else {
            throw BandcampError.decode
        }
        // `tralbum_lookup` is a map of every owned tralbum → the count is the collection size.
        let total = (summary?["tralbum_lookup"] as? [String: Any])?.count
        return (fid, (total ?? 0) > 0 ? total : nil)
    }

    /// Pages through the entire purchased collection. `onProgress` reports the running number
    /// of items fetched after each page, for a launch progress indicator.
    func collection(fanID: Int, onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> [BCItem] {
        try await pagedItems(endpoint: "collection_items", category: "a", fanID: fanID, onProgress: onProgress)
    }

    /// The account's *wishlist* — albums/tracks the user saved but hasn't bought. Same fan
    /// collection API, different endpoint; items carry a public `item_url` we can stream + buy.
    func wishlist(fanID: Int, onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> [BCItem] {
        try await pagedItems(endpoint: "wishlist_items", category: "w", fanID: fanID, onProgress: onProgress)
    }

    /// One page of a fan-collection endpoint: the items plus the `older_than_token` to fetch the
    /// next page (nil when there are no more). Lets the UI reveal a friend's collection 20 at a
    /// time instead of pulling their whole library up front.
    func collectionPage(fanID: Int, olderThan token: String?, count: Int = 20) async throws -> (items: [BCItem], next: String?) {
        try await itemsPage(endpoint: "collection_items", category: "a", fanID: fanID, token: token, count: count)
    }
    func wishlistPage(fanID: Int, olderThan token: String?, count: Int = 20) async throws -> (items: [BCItem], next: String?) {
        try await itemsPage(endpoint: "wishlist_items", category: "w", fanID: fanID, token: token, count: count)
    }

    private func itemsPage(endpoint: String, category: String, fanID: Int,
                           token: String?, count: Int) async throws -> (items: [BCItem], next: String?) {
        let url = URL(string: "https://bandcamp.com/api/fancollection/1/\(endpoint)")!
        let tok = token ?? "\(Int(Date().timeIntervalSince1970))::\(category)::"
        let payload: [String: Any] = ["fan_id": fanID, "older_than_token": tok, "count": count]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: request(url, method: "POST", body: body))
        try Self.check(resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else {
            if Self.looksLikeLoginPage(data) { throw BandcampError.notAuthenticated }
            throw BandcampError.decode
        }
        let redownload = obj["redownload_urls"] as? [String: String] ?? [:]
        let parsed = items.compactMap { Self.parse($0, redownload: redownload) }
        let more = (obj["more_available"] as? Bool) ?? false
        let last = obj["last_token"] as? String
        let next = (more && (last?.isEmpty == false)) ? last : nil
        return (parsed, next)
    }

    /// The account's public profile username (needed to load the profile page).
    func username() async throws -> String {
        let url = URL(string: "https://bandcamp.com/api/fan/2/collection_summary")!
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        try Self.check(resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = obj["collection_summary"] as? [String: Any],
              let name = summary["username"] as? String, !name.isEmpty else {
            if Self.looksLikeLoginPage(data) { throw BandcampError.notAuthenticated }
            throw BandcampError.decode
        }
        return name
    }

    /// The fans this account follows — the app's "friends". There's no clean JSON endpoint, so
    /// we read the same public profile page the website renders and pull its embedded data-blob
    /// (`item_cache.following_fans`). Returns the first batch Bandcamp inlines (~20); deeper
    /// paging would need a follow-up request and isn't wired up yet.
    func followingFans() async throws -> [Friend] {
        let name = try await username()
        guard let url = URL(string: "https://bandcamp.com/\(name)") else { throw BandcampError.decode }
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        try Self.check(resp)
        // NB: don't run `looksLikeLoginPage` here — this is a full HTML profile page (not a JSON
        // API response), and its markup legitimately contains "/login" links, which would
        // false-positive and wrongly sign the user out. `username()` above already guards a dead
        // session (its JSON call throws notAuthenticated); a missing blob here just means no data.
        guard let blob = Self.extractPageBlob(String(decoding: data, as: UTF8.self)),
              let cache = blob["item_cache"] as? [String: Any],
              let fans = cache["following_fans"] as? [String: Any] else { return [] }

        // Preserve Bandcamp's own ordering (newest-followed first) when it gives us a sequence.
        let meta = blob["following_fans_data"] as? [String: Any]
        func seq(_ key: String) -> [String] {
            ((meta?[key] as? [Any]) ?? []).map { "\($0)" }
        }
        var order = seq("sequence") + seq("pending_sequence")
        var seen = Set(order)
        for k in fans.keys where seen.insert(k).inserted { order.append(k) }

        return order.compactMap { (fans[$0] as? [String: Any]).flatMap(Friend.parse) }
    }

    /// Shared pager for the fan-collection endpoints (collection + wishlist). `category` is the
    /// token's list letter (`a` = collection, `w` = wishlist).
    private func pagedItems(endpoint: String, category: String, fanID: Int,
                            onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> [BCItem] {
        let url = URL(string: "https://bandcamp.com/api/fancollection/1/\(endpoint)")!
        var token = "\(Int(Date().timeIntervalSince1970))::\(category)::"
        var out: [BCItem] = []
        // Bandcamp's paging can repeat an item across page boundaries — dedupe by
        // item URL (falling back to id) so the collection never lists the same album twice.
        var seen = Set<String>()

        for _ in 0..<200 { // hard safety cap on pages
            let payload: [String: Any] = ["fan_id": fanID, "older_than_token": token, "count": 100]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await URLSession.shared.data(for: request(url, method: "POST", body: body))
            try Self.check(resp)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["items"] as? [[String: Any]] else {
                if Self.looksLikeLoginPage(data) { throw BandcampError.notAuthenticated }
                NSLog("Bandcamp collection_items decode failed (\(data.count) bytes)")
                throw BandcampError.decode
            }
            let redownload = obj["redownload_urls"] as? [String: String] ?? [:]
            for item in items.compactMap({ Self.parse($0, redownload: redownload) }) {
                let key = item.itemURL ?? "id:\(item.id)"
                if seen.insert(key).inserted { out.append(item) }
            }
            onProgress?(out.count)

            let more = (obj["more_available"] as? Bool) ?? false
            guard more, let last = obj["last_token"] as? String, !last.isEmpty else { break }
            token = last
        }
        return out
    }

    /// Defensive parse — Bandcamp's item field names vary.
    private static func parse(_ item: [String: Any], redownload: [String: String]) -> BCItem? {
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = item[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        func int(_ keys: [String]) -> Int? {
            for k in keys { if let v = item[k] as? Int { return v } }
            return nil
        }
        let title = str(["item_title", "album_title", "title"]) ?? "Untitled"
        let artist = str(["band_name", "artist"]) ?? "Unknown Artist"
        let itemID = int(["item_id", "tralbum_id"]) ?? Int.random(in: 1...Int.max)

        // Download page URL lives in redownload_urls keyed by sale_item_type+sale_item_id.
        var downloadPage: String? = nil
        if let saleID = int(["sale_item_id"]) {
            let type = str(["sale_item_type"]) ?? "p"
            downloadPage = redownload["\(type)\(saleID)"]
        }

        return BCItem(
            id: itemID,
            title: title,
            artist: artist,
            artId: int(["item_art_id", "art_id"]),
            itemURL: str(["item_url"]),
            type: str(["item_type"]) ?? "album",
            downloadPageURL: downloadPage,
            review: str(["why"])
        )
    }

    // MARK: - High-quality download

    /// Resolves the actual downloadable file URL (a zip for albums) in the best available format.
    func resolveDownloadURL(pageURL: String,
                            formats: [String] = ["flac", "alac", "wav", "aiff-lossless", "mp3-320"]
    ) async throws -> (url: URL, format: String) {
        guard let url = URL(string: pageURL) else { throw BandcampError.decode }
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        try Self.check(resp)
        guard let html = String(data: data, encoding: .utf8),
              let blob = Self.extractPagedata(html),
              let items = blob["download_items"] as? [[String: Any]],
              let downloads = items.first?["downloads"] as? [String: Any] else {
            if Self.looksLikeLoginPage(data) { throw BandcampError.notAuthenticated }
            NSLog("Bandcamp: couldn't parse download page \(pageURL)")
            throw BandcampError.decode
        }

        var picked: (String, String)? = nil
        for f in formats {
            if let d = downloads[f] as? [String: Any], let u = d["url"] as? String { picked = (u, f); break }
        }
        guard let (dl, fmt) = picked else { throw BandcampError.decode }

        // The download URL must be "activated" via the statdownload endpoint to get the real file URL.
        let statStr = dl.replacingOccurrences(of: "/download/", with: "/statdownload/") + "&.vrs=1"
        if let statURL = URL(string: statStr),
           let (sdata, sresp) = try? await URLSession.shared.data(for: request(statURL)),
           ((sresp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false),
           let final = Self.parseFinalURL(sdata) {
            return (final, fmt)
        }
        // Fallback: hit the download URL directly (it often 302s to the file).
        guard let direct = URL(string: dl) else { throw BandcampError.decode }
        return (direct, fmt)
    }

    /// Extract the `#pagedata` data-blob JSON from a Bandcamp page.
    private static func extractPagedata(_ html: String) -> [String: Any]? {
        let search: Substring
        if let anchor = html.range(of: "id=\"pagedata\"") { search = html[anchor.upperBound...] }
        else { search = html[...] }
        guard let start = search.range(of: "data-blob=\"") else { return nil }
        let rest = search[start.upperBound...]
        guard let end = rest.range(of: "\"") else { return nil }
        let raw = htmlUnescape(String(rest[..<end.lowerBound]))
        guard let d = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// The statdownload response is JSONP-ish; pull out download_url.
    private static func parseFinalURL(_ data: Data) -> URL? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["download_url"] as? String { return URL(string: s) }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if let r = text.range(of: "\"download_url\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
            let match = String(text[r])
            if let q = match.range(of: ":") {
                let urlPart = match[q.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
                    .replacingOccurrences(of: "\\/", with: "/")
                return URL(string: urlPart)
            }
        }
        return nil
    }

    /// Resolves the streamable tracks for an owned album by parsing its public page.
    func tracks(forItemURL itemURL: String) async throws -> [Track] {
        guard let url = URL(string: itemURL) else { return [] }
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        try Self.check(resp)
        guard let html = String(data: data, encoding: .utf8),
              let blob = Self.extractTralbum(html) else {
            if Self.looksLikeLoginPage(data) { throw BandcampError.notAuthenticated }
            NSLog("Bandcamp: couldn't find data-tralbum on \(itemURL)")
            throw BandcampError.decode
        }

        let albumArtist = (blob["artist"] as? String) ?? "Unknown Artist"
        let artId = blob["art_id"] as? Int
        let artURL = artId.map { URL(string: "https://f4.bcbits.com/img/a\($0)_16.jpg")! }
        guard let trackInfo = blob["trackinfo"] as? [[String: Any]] else { throw BandcampError.decode }

        return trackInfo.compactMap { t in
            guard let files = t["file"] as? [String: Any],
                  var stream = files["mp3-128"] as? String else { return nil }
            if stream.hasPrefix("//") { stream = "https:" + stream }
            guard let streamURL = URL(string: stream) else { return nil }
            let title = (t["title"] as? String) ?? "Untitled"
            return Track(title: title, artist: albumArtist, streamURL: streamURL, artworkURL: artURL)
        }
    }

    /// The album's free-text liner notes from its Bandcamp page: the "about" description and
    /// the artist's "credits" block, when present.
    func notes(forItemURL itemURL: String) async throws -> (about: String?, credits: String?) {
        guard let url = URL(string: itemURL) else { return (nil, nil) }
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        try Self.check(resp)
        guard let html = String(data: data, encoding: .utf8),
              let blob = Self.extractTralbum(html) else { return (nil, nil) }
        let current = blob["current"] as? [String: Any]
        func clean(_ v: Any?) -> String? {
            guard let s = v as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return (clean(current?["about"]), clean(current?["credits"]))
    }

    /// The genre / mood tags an artist put on an album's public page (e.g. "ambient",
    /// "techno", "chillout"). Used to backfill genres so mood radio has something to match.
    func tags(forItemURL itemURL: String) async throws -> [String] {
        guard let url = URL(string: itemURL) else { return [] }
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        try Self.check(resp)
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return Self.extractTags(html)
    }

    /// Bandcamp renders each tag as `<a class="tag" href="/tag/…">name</a>`.
    private static func extractTags(_ html: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        guard let re = try? NSRegularExpression(pattern: #"class="tag"[^>]*>([^<]+)</a>"#) else { return [] }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !tag.isEmpty, seen.insert(tag).inserted { out.append(tag) }
        }
        return out
    }

    /// Pulls the `data-tralbum` JSON blob out of an album page.
    private static func extractTralbum(_ html: String) -> [String: Any]? {
        for delimiter in ["\"", "'"] {
            let marker = "data-tralbum=\(delimiter)"
            guard let start = html.range(of: marker) else { continue }
            let rest = html[start.upperBound...]
            guard let end = rest.range(of: delimiter) else { continue }
            var raw = String(rest[..<end.lowerBound])
            if delimiter == "\"" { raw = htmlUnescape(raw) }
            if let d = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    private static func htmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&#039;", with: "'")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Parses the `<div id="pagedata" data-blob="{…}">` JSON that Bandcamp embeds in profile
    /// pages. The blob is HTML-escaped (internal quotes are `&quot;`), so the first raw `"`
    /// after `data-blob="` is the closing attribute delimiter.
    private static func extractPageBlob(_ html: String) -> [String: Any]? {
        guard let id = html.range(of: "id=\"pagedata\"") else { return nil }
        let tail = html[id.upperBound...]
        guard let db = tail.range(of: "data-blob=\"") else { return nil }
        let after = tail[db.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        let json = htmlUnescape(String(after[..<end]))
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw BandcampError.notAuthenticated }
            throw BandcampError.badResponse(http.statusCode)
        }
    }

    private static func isBandcampHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "bandcamp.com" || host.hasSuffix(".bandcamp.com")
    }

    /// Bandcamp answers an expired `identity` cookie with HTTP 200 + a login/redirect page
    /// rather than a 401. Detect that so callers can clear the dead session instead of
    /// surfacing a generic "couldn't read your collection" decode error.
    static func looksLikeLoginPage(_ data: Data) -> Bool {
        guard let s = String(data: data.prefix(4000), encoding: .utf8)?.lowercased() else { return false }
        guard s.contains("<html") || s.contains("<!doctype") else { return false }
        return s.contains("/login") || s.contains("name=\"password\"") || s.contains("log in to bandcamp")
    }
}
