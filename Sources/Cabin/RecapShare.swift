import Foundation
import CabinCore

/// Builds a self-contained share link for a recap's top albums. The whole payload
/// lives in the URL *fragment* (after `#`), so it never reaches a server — the static
/// page at SiteURL.recap (GitHub Pages, gh-pages branch: r/index.html) decodes and renders it
/// entirely client-side (nothing is logged).
enum RecapShare {
    static let base = SiteURL.recap

    /// Compact keys keep the link short (fine for ~10 items). The avatar is deliberately
    /// NOT included — an image would bloat the URL; only the name travels.
    private struct Payload: Encodable {
        let nm: String?     // display name
        let y: Int          // year
        let tm: String      // total listening time, preformatted ("3 h" / "12 min")
        let n: Int          // album count
        let ta: String?     // top artist
        let items: [Item]
        struct Item: Encodable {
            let t: String   // title
            let a: String   // artist
            let p: Int      // plays
            let b: String?  // bandcamp album URL
            let i: String?  // cover image URL
        }
    }

    static func url(for recap: Recap, name: String = "", top n: Int = 10) -> URL? {
        let items = recap.top(n).map {
            Payload.Item(t: $0.title, a: $0.artist, p: $0.plays,
                         b: $0.bandcampURL, i: $0.artworkURL?.absoluteString)
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let time = recap.totalSeconds >= 3600
            ? "\(Int(recap.totalHours.rounded())) h"
            : "\(max(1, Int((recap.totalSeconds / 60).rounded()))) min"
        let payload = Payload(nm: trimmed.isEmpty ? nil : trimmed,
                              y: recap.year, tm: time,
                              n: recap.albumCount, ta: recap.topArtist, items: items)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        // base64url so it's URL-safe without percent-encoding.
        let token = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(base)#\(token)")
    }
}

/// Cabin's public pages, served by GitHub Pages from the repo's `gh-pages` branch. (cabin.fm is an
/// unrelated radio station — never link there.) Swap `root` if Cabin gets its own domain.
enum SiteURL {
    static let root = "https://02-alt.github.io/bandcamp-player"
    static let recap = root + "/r/"
    static let support = root + "/support/"
    static let privacy = root + "/privacy/"
}
