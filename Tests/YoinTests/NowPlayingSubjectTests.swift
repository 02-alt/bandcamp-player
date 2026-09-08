import XCTest
import Foundation
@testable import Yoin

final class NowPlayingSubjectTests: XCTestCase {

    private func album(_ title: String, _ artist: String, art: String? = nil) -> Album {
        Album(title: title, artist: artist, year: "", format: "", lossless: false, g0: 0.2, g1: 0.08,
              artworkURL: art.flatMap { URL(string: $0) })
    }

    func testNowPlayingAlbumWinsOverCurrentWhenNoTrack() {
        let np = NowPlayingSubject(nowPlayingAlbum: album("Geogaddi", "BoC"),
                                   current: album("Browsing", "Someone"),
                                   track: nil)
        XCTAssertEqual(np.album.title, "Geogaddi")
        XCTAssertEqual(np.title, "Geogaddi")
        XCTAssertEqual(np.artist, "BoC")
    }

    func testFallsBackToCurrentWhenNoNowPlayingAlbum() {
        let np = NowPlayingSubject(nowPlayingAlbum: nil,
                                   current: album("Browsing", "Someone"),
                                   track: nil)
        XCTAssertEqual(np.album.title, "Browsing")
    }

    func testTrackFieldsWinOverAlbum() {
        let t = Track(title: "Roygbiv", artist: "Boards of Canada",
                      streamURL: URL(string: "https://x/s.mp3")!,
                      artworkURL: URL(string: "https://x/track.jpg")!)
        let np = NowPlayingSubject(nowPlayingAlbum: album("Music Has the Right", "BoC", art: "https://x/album.jpg"),
                                   current: album("Browsing", "Someone"),
                                   track: t)
        XCTAssertEqual(np.title, "Roygbiv")
        XCTAssertEqual(np.artist, "Boards of Canada")
        XCTAssertEqual(np.coverURL?.absoluteString, "https://x/track.jpg")
        // Album identity still comes from nowPlayingAlbum.
        XCTAssertEqual(np.album.title, "Music Has the Right")
    }

    func testTrackWithoutArtworkFallsBackToAlbumCover() {
        let t = Track(title: "Untitled", artist: "BoC", streamURL: URL(string: "https://x/s.mp3")!)
        let np = NowPlayingSubject(nowPlayingAlbum: album("A", "BoC", art: "https://x/album.jpg"),
                                   current: album("B", "X"),
                                   track: t)
        XCTAssertEqual(np.coverURL?.absoluteString, "https://x/album.jpg")
    }
}
