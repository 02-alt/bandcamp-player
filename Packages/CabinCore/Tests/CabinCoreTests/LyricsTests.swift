import XCTest
@testable import CabinCore

final class LyricsTests: XCTestCase {
    func testLRCParsesTimedLines() {
        let ly = LRC.parse("[ar:Makala]\n[00:12.50]Jet privé\n[01:02]Pour Budapest")
        XCTAssertEqual(ly?.lines.map(\.time), [12.5, 62])
        XCTAssertEqual(ly?.isTimed, true)
        XCTAssertEqual(ly?.activeIndex(at: 13), 0)
    }

    func testPlainTextIsUntimedAndKeepsStanzaGaps() {
        XCTAssertNil(LRC.parse("Eh mon amour\nEh fais-moi kiss"))
        let ly = SyncedLyrics.plain("Eh mon amour\n\nEh fais-moi kiss")
        XCTAssertEqual(ly?.isTimed, false)
        XCTAssertEqual(ly?.lines.map(\.text), ["Eh mon amour", "", "Eh fais-moi kiss"])
        XCTAssertNil(ly?.activeIndex(at: 30))
    }

    func testBlankPlainTextIsNoLyrics() {
        XCTAssertNil(SyncedLyrics.plain(" \n\n "))
    }
}
