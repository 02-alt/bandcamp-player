import XCTest
import Foundation
@testable import Cabin

final class BandcampImageTests: XCTestCase {

    func testHiResRewritesSizeCode() {
        let thumb = URL(string: "https://f4.bcbits.com/img/a1234567890_16.jpg")!
        XCTAssertEqual(thumb.bcHiRes.absoluteString, "https://f4.bcbits.com/img/a1234567890_10.jpg")
    }

    func testArbitrarySizeCode() {
        let thumb = URL(string: "https://f4.bcbits.com/img/a1234567890_16.jpg")!
        XCTAssertEqual(thumb.bcImageSize(0).absoluteString, "https://f4.bcbits.com/img/a1234567890_0.jpg")
    }

    func testNonBandcampHostPassesThrough() {
        let other = URL(string: "https://example.com/img/a123_16.jpg")!
        XCTAssertEqual(other.bcHiRes, other)
    }

    func testNonCoverPathPassesThrough() {
        // Avatars (`_50`) match `_NN.jpg` and would be rewritten too, which is fine — we only ever
        // call bcHiRes on cover URLs. But a Bandcamp URL with no size suffix must pass through.
        let noSuffix = URL(string: "https://f4.bcbits.com/img/a1234567890.jpg")!
        XCTAssertEqual(noSuffix.bcHiRes, noSuffix)
    }
}
