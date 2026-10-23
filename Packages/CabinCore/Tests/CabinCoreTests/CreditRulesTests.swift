import XCTest
@testable import CabinCore

final class CreditRulesTests: XCTestCase {
    func testGeniusListsSplitOnlyOnCommas() {
        XCTAssertEqual(CreditNames.splitList("Simon & Garfunkel, Mike Dean"), ["Simon & Garfunkel", "Mike Dean"])
    }

    func testKeysFoldCaseDiacriticsAndDiscogsSuffixes() {
        XCTAssertEqual(CreditNames.key("Ciarán"), CreditNames.key("ciaran"))
        XCTAssertEqual(CreditNames.key("Jane Doe (2)"), CreditNames.key("jane  doe"))
    }

    func testCompaniesAreNotPeople() {
        XCTAssertTrue(CreditNames.isCompany(role: "Label", name: "Warp"))
        XCTAssertTrue(CreditNames.isCompany(role: "Mastering", name: "Calyx Mastering"))
        XCTAssertFalse(CreditNames.isCompany(role: "Vocals", name: "Patti LaBelle"))
    }

    func testBandcampParserReadsCreditsAndSkipsNoise() {
        let text = """
        Mastered by Bo Kondren at Calyx Mastering, Berlin.
        Guitar: Jane Doe, John Roe
        Thanks: Mom, Dad
        Contact: booking@example.com
        """
        let people = CreditNames.parseBandcamp(text).map(\.name)
        XCTAssertEqual(people, ["Bo Kondren", "Jane Doe", "John Roe"])
    }

    func testIndexCountsGuestSongsAndSeparatesOwnAlbums() {
        let a = UUID(), b = UUID()
        let snaps = [
            CreditIndexBuilder.Snapshot(id: a, artist: "Kanye West",
                genius: ["stars": [GeniusCredit(role: "Mixing Engineer", names: "Anthony Kilhoffer, Kanye West")],
                         "paid": [GeniusCredit(role: "Producer", names: "Anthony Kilhoffer")]],
                track: [:], album: [], bandcamp: nil),
            CreditIndexBuilder.Snapshot(id: b, artist: "Someone Else",
                genius: ["song": [GeniusCredit(role: "Producer", names: "Kanye West")]],
                track: [:], album: [], bandcamp: nil),
        ]
        let people = CreditIndexBuilder.build(snaps).people
        let ak = people[CreditNames.key("Anthony Kilhoffer")]!
        XCTAssertEqual(ak.guestSongCount, 2)
        XCTAssertTrue(ak.hasProfile)
        // Kanye's own album doesn't count as a guest credit: only the other artist's song does.
        let kw = people[CreditNames.key("Kanye West")]!
        XCTAssertEqual(kw.guestSongCount, 1)
        XCTAssertFalse(kw.hasProfile)
    }
}
