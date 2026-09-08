import XCTest
import Foundation
@testable import Yoin

/// Pins the behaviour of the undocumented-Bandcamp response parsers — the code most likely to
/// silently break when Bandcamp changes its markup. Exercised through `BandcampClient`'s own
/// interface via a fixture-backed `HTTPFake`, plus direct calls to the pure static parsers.
final class BandcampClientTests: XCTestCase {

    // MARK: - Session cookie discipline

    func testIdentityCookieSentOnlyToBandcampHosts() {
        let c = BandcampClient(identity: "SECRET")
        let bc = c.authorizedRequest(URL(string: "https://bandcamp.com/api/fan/2/collection_summary")!)
        XCTAssertEqual(bc.value(forHTTPHeaderField: "Cookie"), "identity=SECRET")

        // The signed CDN must never receive the session cookie.
        let cdn = c.authorizedRequest(URL(string: "https://f4.bcbits.com/img/a123_16.jpg")!)
        XCTAssertNil(cdn.value(forHTTPHeaderField: "Cookie"))
    }

    // MARK: - looksLikeLoginPage (expired-cookie detection)

    func testLooksLikeLoginPageDetectsLoginMarkup() {
        let login = #"<!doctype html><html><body><form><input name="password"></form><a href="/login">Log in to Bandcamp</a></body></html>"#
        XCTAssertTrue(BandcampClient.looksLikeLoginPage(Data(login.utf8)))
    }

    func testLooksLikeLoginPageIgnoresJSON() {
        // A real JSON API body must not be mistaken for a login page.
        let json = #"{"fan_id": 42, "collection_summary": {"username": "me"}}"#
        XCTAssertFalse(BandcampClient.looksLikeLoginPage(Data(json.utf8)))
    }

    // MARK: - collectionSummary → notAuthenticated on a login page served with HTTP 200

    func testCollectionSummaryThrowsNotAuthenticatedOnLoginPage() async {
        let loginHTML = #"<!doctype html><html><input name="password"><a href="/login"></html>"#
        let c = BandcampClient(identity: "dead", http: HTTPFake(queue: [.html(loginHTML, status: 200)]))
        do {
            _ = try await c.collectionSummary()
            XCTFail("expected notAuthenticated")
        } catch let e as BandcampError {
            guard case .notAuthenticated = e else { return XCTFail("wrong error: \(e)") }
        } catch { XCTFail("unexpected: \(error)") }
    }

    func testCollectionSummaryParsesFanIDAndTotal() async throws {
        let body: [String: Any] = [
            "fan_id": 99,
            "collection_summary": ["tralbum_lookup": ["a1": [:], "a2": [:], "t3": [:]]]
        ]
        let c = BandcampClient(identity: "ok", http: HTTPFake(queue: [.json(body)]))
        let summary = try await c.collectionSummary()
        XCTAssertEqual(summary.fanID, 99)
        XCTAssertEqual(summary.total, 3)
    }

    // MARK: - tracks(forItemURL:) → extractTralbum + trackinfo → [Track]

    func testTracksParsesTralbumBlob() async throws {
        // Single-quote delimiter path: raw JSON, no HTML-escaping needed.
        let tralbum = #"{"artist":"Boards of Canada","art_id":123,"trackinfo":[{"title":"Roygbiv","file":{"mp3-128":"//bcbits.com/stream/roygbiv.mp3"}},{"title":"No Stream Here","file":{}}]}"#
        let html = "<html><head></head><body><script data-tralbum='\(tralbum)'></script></body></html>"
        let c = BandcampClient(identity: "ok", http: HTTPFake(queue: [.html(html)]))

        let tracks = try await c.tracks(forItemURL: "https://boc.bandcamp.com/album/mhtrtc")
        // The second entry has no mp3-128 file and must be dropped.
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].title, "Roygbiv")
        XCTAssertEqual(tracks[0].artist, "Boards of Canada")
        // Protocol-relative stream URL must be upgraded to https.
        XCTAssertEqual(tracks[0].streamURL.absoluteString, "https://bcbits.com/stream/roygbiv.mp3")
        XCTAssertEqual(tracks[0].artworkURL?.absoluteString, "https://f4.bcbits.com/img/a123_16.jpg")
    }

    // MARK: - parse(item:redownload:) — defensive field-name handling

    func testParseItemPrefersItemTitleAndResolvesDownloadPage() {
        let item: [String: Any] = [
            "item_title": "Geogaddi",
            "band_name": "Boards of Canada",
            "item_id": 555,
            "item_art_id": 777,
            "item_url": "https://boc.bandcamp.com/album/geogaddi",
            "item_type": "album",
            "sale_item_id": 42,
            "sale_item_type": "p",
            "why": "a desert-island record"
        ]
        let redownload = ["p42": "https://bandcamp.com/download?id=42"]
        let parsed = BandcampClient.parse(item, redownload: redownload)
        XCTAssertEqual(parsed?.title, "Geogaddi")
        XCTAssertEqual(parsed?.artist, "Boards of Canada")
        XCTAssertEqual(parsed?.id, 555)
        XCTAssertEqual(parsed?.artId, 777)
        XCTAssertEqual(parsed?.downloadPageURL, "https://bandcamp.com/download?id=42")
        XCTAssertEqual(parsed?.review, "a desert-island record")
    }

    func testParseItemFallsBackForMissingFields() {
        // Only alternate key names present; title/artist/type must fall back gracefully.
        let item: [String: Any] = ["album_title": "Untitled EP", "artist": "Someone", "tralbum_id": 7]
        let parsed = BandcampClient.parse(item, redownload: [:])
        XCTAssertEqual(parsed?.title, "Untitled EP")
        XCTAssertEqual(parsed?.artist, "Someone")
        XCTAssertEqual(parsed?.id, 7)
        XCTAssertEqual(parsed?.type, "album")
        XCTAssertNil(parsed?.downloadPageURL)
    }

    // MARK: - extractTags

    func testExtractTagsDedupesAndLowercases() {
        let html = #"<a class="tag" href="/tag/ambient">Ambient</a> <a class="tag" href="/tag/techno">techno</a> <a class="tag" href="/tag/ambient">ambient</a>"#
        XCTAssertEqual(BandcampClient.extractTags(html), ["ambient", "techno"])
    }

    // MARK: - parseFinalURL (statdownload response)

    func testParseFinalURLFromJSON() {
        let data = Data(#"{"download_url":"https://p4.bcbits.com/download/file.zip?token=1"}"#.utf8)
        XCTAssertEqual(BandcampClient.parseFinalURL(data)?.absoluteString,
                       "https://p4.bcbits.com/download/file.zip?token=1")
    }

    func testParseFinalURLFromEscapedJSONP() {
        // JSONP-ish body with escaped slashes that JSONSerialization would reject.
        let data = Data(##"someCallback({"download_url":"https:\/\/p4.bcbits.com\/download\/x.zip"})"##.utf8)
        XCTAssertEqual(BandcampClient.parseFinalURL(data)?.absoluteString,
                       "https://p4.bcbits.com/download/x.zip")
    }

    // MARK: - extractPageBlob (following_fans on a profile page)

    func testExtractPageBlobReadsFollowingFans() throws {
        let blob = #"{&quot;item_cache&quot;:{&quot;following_fans&quot;:{&quot;1&quot;:{&quot;fan_id&quot;:1,&quot;name&quot;:&quot;Ada&quot;}}}}"#
        let html = "<div id=\"pagedata\" data-blob=\"\(blob)\"></div>"
        let parsed = BandcampClient.extractPageBlob(html)
        let cache = parsed?["item_cache"] as? [String: Any]
        let fans = cache?["following_fans"] as? [String: Any]
        XCTAssertNotNil(fans?["1"])
    }
}
