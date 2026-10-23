import SwiftUI
import CabinCore

// MARK: - Detail pages

/// A full-page detail shown over the library: an album, an artist, an album you don't own, or a
/// credit profile.
enum DetailPage: Equatable, Sendable {
    case album(UUID)
    case artist(String)
    case external(ExternalAlbum)
    case credit(String)

    enum Kind: Sendable { case album, artist, external, credit }
    var kind: Kind {
        switch self {
        case .album: .album
        case .artist: .artist
        case .external: .external
        case .credit: .credit
        }
    }
}

/// An unowned album (wishlist / a friend's pick) plus the line explaining why it's here.
/// Equal by album id — `Album` itself isn't Equatable.
struct ExternalAlbum: Equatable, @unchecked Sendable {
    let album: Album
    let note: String
    static func == (a: Self, b: Self) -> Bool { a.album.id == b.album.id && a.note == b.note }
}

/// The pages stacked over the library, bottom → top. Only the top one is visible and
/// interactive; the ones beneath stay alive (scroll position, loaded data) for Back.
///
/// One ordered stack replaces four independent "is X open" switches, whose hand-maintained
/// layering let a page open *behind* another (e.g. an album under a credit profile).
struct DetailStack: Equatable, Sendable {
    struct Entry: Equatable, Identifiable, Sendable {
        let id: UUID
        var page: DetailPage
    }

    private(set) var entries: [Entry] = []

    var top: DetailPage? { entries.last?.page }
    var isEmpty: Bool { entries.isEmpty }
    var depth: Int { entries.count }

    /// Show `page` on top. Re-opening the page that's already on top does nothing; opening an
    /// album while an album is on top *replaces* it (stepping between albums doesn't build up a
    /// pile of pages to Back through).
    mutating func push(_ page: DetailPage) {
        guard page != top else { return }
        if case .album = page, case .album = top {
            entries[entries.count - 1] = Entry(id: UUID(), page: page)
        } else {
            entries.append(Entry(id: UUID(), page: page))
        }
    }

    /// Back: close the page on top.
    mutating func pop() { if !entries.isEmpty { entries.removeLast() } }

    /// Close the top-most page of a kind (wherever it sits).
    mutating func removeLast(_ kind: DetailPage.Kind) {
        if let i = entries.lastIndex(where: { $0.page.kind == kind }) { entries.remove(at: i) }
    }

    /// Close every page matching `predicate` (e.g. albums that were just deleted).
    mutating func removeAll(where predicate: (DetailPage) -> Bool) {
        entries.removeAll { predicate($0.page) }
    }

    mutating func clear() { entries.removeAll() }

    /// The top-most page of each kind (nil if none is open).
    var lastAlbum: UUID? {
        for e in entries.reversed() { if case .album(let id) = e.page { return id } }
        return nil
    }
    var lastArtist: String? {
        for e in entries.reversed() { if case .artist(let n) = e.page { return n } }
        return nil
    }
    var lastExternal: ExternalAlbum? {
        for e in entries.reversed() { if case .external(let x) = e.page { return x } }
        return nil
    }
    var lastCredit: String? {
        for e in entries.reversed() { if case .credit(let k) = e.page { return k } }
        return nil
    }
}

// MARK: - Is this page on top?

private struct IsTopDetailKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False for a detail page that's covered by another one in the stack — it stays alive but
    /// must not put toolbar items or keyboard shortcuts in play.
    var isTopDetail: Bool {
        get { self[IsTopDetailKey.self] }
        set { self[IsTopDetailKey.self] = newValue }
    }
}

// MARK: - AppState navigation (views onto `detail`, plus the open… entry points)

extension AppState {
    var openedAlbumID: UUID? {
        get { detail.lastAlbum }
        set { if let id = newValue { detail.push(.album(id)) } else { detail.removeLast(.album) } }
    }
    /// The artist whose (zero-scrape) page is open, by display name. `nil` when closed.
    var openedArtist: String? {
        get { detail.lastArtist }
        set { if let n = newValue { detail.push(.artist(n)) } else { detail.removeLast(.artist) } }
    }

    var openedAlbum: Album? { openedAlbumID.flatMap { album(id: $0) } }

    var openedExternalAlbum: Album? {
        get { detail.lastExternal?.album }
        set {
            if let a = newValue { detail.push(.external(ExternalAlbum(album: a, note: openedExternalNote))) }
            else { detail.removeLast(.external) }
        }
    }
    /// The pill under the title on that page, e.g. "In your wishlist" or "In Alice's library".
    var openedExternalNote: String { detail.lastExternal?.note ?? "In your wishlist" }

    /// Open the read-only detail page for an unowned album (wishlist / friend's pick), on top of
    /// whatever page you're on (Back returns to it).
    func openExternalAlbum(_ album: Album, note: String = "In your wishlist") {
        searchOpen = false
        friendsOpen = false
        openedFriend = nil
        detail.push(.external(ExternalAlbum(album: album, note: note)))
    }

    /// Open the artist page for a display name, on top of the page you're on (Back returns to it).
    func openArtist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        friendsOpen = false
        openedFriend = nil
        detail.push(.artist(trimmed))
    }

    /// The credit profile on top (a person's credits across the library), by normalised name.
    var openedCreditPerson: String? {
        get { detail.lastCredit }
        set { if let k = newValue { detail.push(.credit(k)) } else { detail.removeLast(.credit) } }
    }
    /// Open a credit profile from anywhere a credited name shows — closes the full-screen player
    /// layers and any credits sheet so the page is visible.
    func openCreditProfile(_ key: String, player: PlayerEngine) {
        if player.expanded { player.expanded = false }
        if player.artMode { player.artMode = false }
        firstListenAlbum = nil
        if showNewAlbumReveal { showNewAlbumReveal = false; unboxAlbums = [] }
        queueOpen = false; searchOpen = false; paletteOpen = false
        detail.push(.credit(key))
    }

    /// A full-page detail is up: an album, artist, unowned album or credit profile.
    var anyDetailOpen: Bool { !detail.isEmpty }
}
