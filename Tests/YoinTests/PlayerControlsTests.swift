import XCTest
@testable import Yoin

final class PlayerControlsTests: XCTestCase {

    func testTimeStringFormatsAndGuards() {
        XCTAssertEqual(PlayerControls.timeString(0), "0:00")
        XCTAssertEqual(PlayerControls.timeString(-5), "0:00")
        XCTAssertEqual(PlayerControls.timeString(.nan), "0:00")
        XCTAssertEqual(PlayerControls.timeString(9), "0:09")
        XCTAssertEqual(PlayerControls.timeString(65), "1:05")
        XCTAssertEqual(PlayerControls.timeString(3599), "59:59")
    }

    func testVolumeGlyphLadder() {
        XCTAssertEqual(PlayerControls.volumeGlyph(0), "speaker.slash.fill")
        XCTAssertEqual(PlayerControls.volumeGlyph(0.2), "speaker.wave.1.fill")
        XCTAssertEqual(PlayerControls.volumeGlyph(0.5), "speaker.wave.2.fill")
        XCTAssertEqual(PlayerControls.volumeGlyph(0.9), "speaker.wave.3.fill")
    }

    func testScrollNudgeClampsAndScales() {
        // Coarse tick is amplified ×8 before dividing.
        XCTAssertEqual(PlayerControls.scrollNudge(base: 0.5, raw: 9, precise: false, divisor: 900),
                       0.5 + 72.0 / 900, accuracy: 1e-9)
        // Precise (trackpad) tick is not amplified.
        XCTAssertEqual(PlayerControls.scrollNudge(base: 0.5, raw: 9, precise: true, divisor: 900),
                       0.5 + 9.0 / 900, accuracy: 1e-9)
        // Clamps to the 0…1 range.
        XCTAssertEqual(PlayerControls.scrollNudge(base: 0.99, raw: 100, precise: false, divisor: 600), 1)
        XCTAssertEqual(PlayerControls.scrollNudge(base: 0.01, raw: -100, precise: false, divisor: 600), 0)
    }
}
