import XCTest
@testable import Cabin

/// The pure filename → (artist, title) normaliser. No network, no seam needed — it was always
/// a deep pure function, just never exercised.
final class MetadataParseTests: XCTestCase {

    func testSplitsArtistAndTitleOnFirstDash() {
        let r = FilenameCleaner.parse("Aphex Twin - Xtal")
        XCTAssertEqual(r.artist, "Aphex Twin")
        XCTAssertEqual(r.title, "Xtal")
    }

    func testStripsLeadingTrackNumberAndJunkTokens() {
        let r = FilenameCleaner.parse("01. Boards_of_Canada - Roygbiv (Official Audio) [HQ]")
        XCTAssertEqual(r.artist, "Boards of Canada")
        XCTAssertEqual(r.title, "Roygbiv")
    }

    func testNoDashReturnsNilArtist() {
        let r = FilenameCleaner.parse("Just A Title")
        XCTAssertNil(r.artist)
        XCTAssertEqual(r.title, "Just A Title")
    }

    func testTrackTitleStripsNumberButKeepsRest() {
        XCTAssertEqual(FilenameCleaner.trackTitle("03 - Sunset Blvd"), "Sunset Blvd")
        XCTAssertEqual(FilenameCleaner.trackTitle("01 Intro"), "Intro")
    }
}
