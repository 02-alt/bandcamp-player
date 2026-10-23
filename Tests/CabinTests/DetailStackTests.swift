import XCTest
@testable import Cabin
import CabinCore

/// The navigation rules behind Back (see Navigation.swift).
final class DetailStackTests: XCTestCase {
    private let a = UUID(), b = UUID()

    func testPushShowsOnTopAndBackReturns() {
        var s = DetailStack()
        s.push(.album(a)); s.push(.artist("Ciarán")); s.push(.credit("anthony kilhoffer"))
        XCTAssertEqual(s.top, .credit("anthony kilhoffer"))
        s.pop(); XCTAssertEqual(s.top, .artist("Ciarán"))
        s.pop(); XCTAssertEqual(s.top, .album(a))
        s.pop(); XCTAssertTrue(s.isEmpty)
        s.pop(); XCTAssertTrue(s.isEmpty)   // Back on an empty stack is harmless
    }

    func testAlbumOverAlbumReplacesInsteadOfPiling() {
        var s = DetailStack()
        s.push(.album(a)); s.push(.album(b))   // stepping ˄ ˅ between albums
        XCTAssertEqual(s.depth, 1)
        XCTAssertEqual(s.top, .album(b))
    }

    func testAlbumOpenedFromAProfileSitsOnTopOfIt() {
        // The old bug: an album opened while a credit profile was up stayed hidden under it.
        var s = DetailStack()
        s.push(.album(a)); s.push(.credit("x")); s.push(.album(b))
        XCTAssertEqual(s.top, .album(b))
        s.pop(); XCTAssertEqual(s.top, .credit("x"))   // Back returns to the profile
    }

    func testReopeningTheTopPageIsANoOp() {
        var s = DetailStack()
        s.push(.artist("A")); s.push(.artist("A"))
        XCTAssertEqual(s.depth, 1)
    }

    func testRemoveLastOfAKindLeavesTheRest() {
        var s = DetailStack()
        s.push(.album(a)); s.push(.credit("x")); s.push(.artist("A"))
        s.removeLast(.credit)
        XCTAssertEqual(s.entries.map(\.page), [.album(a), .artist("A")])
        XCTAssertEqual(s.lastCredit, nil)
        XCTAssertEqual(s.lastAlbum, a)
    }

    func testDeletedAlbumsDisappearFromTheStack() {
        var s = DetailStack()
        s.push(.album(a)); s.push(.artist("A")); s.push(.album(b))
        s.removeAll { if case .album(let id) = $0 { id == a } else { false } }
        XCTAssertEqual(s.entries.map(\.page), [.artist("A"), .album(b)])
    }

    func testEntriesKeepIdentityWhenOthersChange() {
        // Pages below the top keep their identity (so SwiftUI keeps them alive for Back).
        var s = DetailStack()
        s.push(.album(a))
        let bottom = s.entries[0].id
        s.push(.credit("x")); s.pop()
        XCTAssertEqual(s.entries[0].id, bottom)
    }
}
