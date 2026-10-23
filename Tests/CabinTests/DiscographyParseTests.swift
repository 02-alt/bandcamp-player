import XCTest
import Foundation
@testable import Cabin
import CabinCore

final class DiscographyParseTests: XCTestCase {

    // A trimmed-down but structurally faithful `/music` page: two statically-rendered <li> tiles
    // (one with an artist-override, as label/compilation pages have) plus a data-client-items JSON
    // array carrying a third, lazy-loaded release. Quotes inside the attribute are HTML-escaped.
    private let html = """
    <html><body>
    <ol id="music-grid" data-client-items="[{&quot;id&quot;:333,&quot;title&quot;:&quot;Third &amp; Last&quot;,&quot;art_id&quot;:9003,&quot;page_url&quot;:&quot;/album/third-and-last&quot;,&quot;type&quot;:&quot;album&quot;,&quot;artist&quot;:null}]">
      <li class="music-grid-item" data-item-id="album-111" data-band-id="1">
        <a href="/album/first-one"><div class="art">
          <img src="https://f4.bcbits.com/img/a9001_2.jpg"></div>
          <p class="title">First One</p></a>
      </li>
      <li class="music-grid-item" data-item-id="track-222" data-band-id="1">
        <a href="/track/a-single"><div class="art">
          <img data-original="https://f4.bcbits.com/img/a9002_2.jpg"></div>
          <p class="title">A Single<br><span class="artist-override">Guest Artist</span></p></a>
      </li>
    </ol>
    </body></html>
    """

    func testParsesGridAndClientItemsInOrder() {
        let items = BandcampClient.parseDiscography(html, root: "https://band.bandcamp.com",
                                                    fallbackArtist: "The Band")
        XCTAssertEqual(items.count, 3)

        XCTAssertEqual(items[0].id, 111)
        XCTAssertEqual(items[0].title, "First One")
        XCTAssertEqual(items[0].artist, "The Band")               // no override → fallback
        XCTAssertEqual(items[0].pageURL, "https://band.bandcamp.com/album/first-one")
        XCTAssertEqual(items[0].type, "album")
        XCTAssertEqual(items[0].artId, 9001)
        XCTAssertEqual(items[0].artworkURL?.absoluteString, "https://f4.bcbits.com/img/a9001_16.jpg")

        XCTAssertEqual(items[1].id, 222)
        XCTAssertEqual(items[1].artist, "Guest Artist")           // artist-override wins
        XCTAssertEqual(items[1].type, "track")
        XCTAssertEqual(items[1].artId, 9002)                      // read from data-original

        XCTAssertEqual(items[2].id, 333)
        XCTAssertEqual(items[2].title, "Third & Last")            // HTML-unescaped
        XCTAssertEqual(items[2].artist, "The Band")               // JSON artist null → fallback
        XCTAssertEqual(items[2].pageURL, "https://band.bandcamp.com/album/third-and-last")
    }

    func testDedupesAcrossBothSources() {
        // If the same id appears in both the <li> grid and the JSON, it's listed once (grid wins).
        let dupHTML = html.replacingOccurrences(of: "\"id\":333", with: "\"id\":111")
            .replacingOccurrences(of: "&quot;id&quot;:333", with: "&quot;id&quot;:111")
        let items = BandcampClient.parseDiscography(dupHTML, root: "https://band.bandcamp.com",
                                                    fallbackArtist: "The Band")
        XCTAssertEqual(items.filter { $0.id == 111 }.count, 1)
    }

    func testEmptyGridYieldsNothing() {
        let items = BandcampClient.parseDiscography("<html><body>no grid</body></html>",
                                                    root: "https://band.bandcamp.com",
                                                    fallbackArtist: "X")
        XCTAssertTrue(items.isEmpty)
    }
}
