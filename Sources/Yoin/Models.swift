import SwiftUI

struct Album: Identifiable, Codable {
    var id = UUID()
    var title: String
    var artist: String
    var year: String
    var format: String
    var lossless: Bool
    /// Two greyscale levels for the monochrome placeholder cover.
    var g0: Double
    var g1: Double
    /// Set for imported/downloaded files that can actually play.
    var url: URL? = nil
    /// Real embedded artwork, when available.
    var artworkData: Data? = nil
    /// Remote cover art (e.g. from Bandcamp).
    var artworkURL: URL? = nil
    /// Where this album came from.
    var source: Source = .local
    /// Bandcamp public album page, used to resolve stream URLs.
    var bandcampItemURL: String? = nil
    /// Bandcamp download page, used to fetch the lossless file(s).
    var bandcampDownloadURL: String? = nil
    /// Local audio files after a download — lossless & offline.
    var localTracks: [URL]? = nil
    var isFavourite: Bool = false

    // MARK: Enriched metadata (Discogs / iTunes)
    /// Record label, when known.
    var label: String? = nil
    /// Genre(s), comma-joined.
    var genre: String? = nil
    /// Personnel credits (role → name), Tidal-style.
    var credits: [Credit]? = nil
    /// Per-track personnel, cached so the track-credits panel doesn't refetch every open.
    /// Keyed by "<index>|<track title>".
    var trackCredits: [String: [Credit]]? = nil
    /// The confirmed Discogs release, so we can re-open the exact match.
    var discogsReleaseID: Int? = nil
    /// The confirmed MusicBrainz release id (keyless credits source).
    var musicbrainzID: String? = nil

    /// Snapshots of earlier metadata, newest first — lets the user undo a bad match/edit.
    var history: [AlbumEdit] = []

    /// The pristine Bandcamp title/artist/cover captured at sync, so a bad match or edit
    /// can always be reset to the original — even when there's no edit history yet.
    var origTitle: String? = nil
    var origArtist: String? = nil
    var origArtworkURL: URL? = nil

    /// True when we have a pristine Bandcamp original to reset back to.
    var canResetToOriginal: Bool {
        source == .bandcamp && (origTitle != nil || origArtist != nil || origArtworkURL != nil)
    }

    /// True once we've attached external credits/label metadata.
    var enriched: Bool {
        credits?.isEmpty == false || label != nil || discogsReleaseID != nil || musicbrainzID != nil
    }

    /// The editable/enrichable subset — captured for history and restored on revert.
    var metadata: AlbumMetadata {
        get {
            AlbumMetadata(title: title, artist: artist, year: year, label: label, genre: genre,
                          credits: credits, artworkURL: artworkURL, artworkData: artworkData,
                          discogsReleaseID: discogsReleaseID, musicbrainzID: musicbrainzID)
        }
        set {
            title = newValue.title; artist = newValue.artist; year = newValue.year
            label = newValue.label; genre = newValue.genre; credits = newValue.credits
            artworkURL = newValue.artworkURL; artworkData = newValue.artworkData
            discogsReleaseID = newValue.discogsReleaseID; musicbrainzID = newValue.musicbrainzID
        }
    }

    enum Source: String, Codable { case local, bandcamp }

    // MARK: Bandcamp liner notes (album description + free-text credits)
    var about: String? = nil
    var bcCredits: String? = nil
    /// Set once we've fetched the notes, so an album with none isn't re-scraped every open.
    var notesLoaded: Bool = false

    /// A followed fan's "why I love this" note, when this album is shown in a friend's
    /// collection. Transient (not persisted) — only ever set on friend-browsing albums.
    var friendReview: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, year, format, lossless, g0, g1
        case url, artworkData, artworkURL, source, bandcampItemURL, bandcampDownloadURL, localTracks, isFavourite
        case label, genre, credits, trackCredits, discogsReleaseID, musicbrainzID, history
        case origTitle, origArtist, origArtworkURL
        case about, bcCredits, notesLoaded
    }

    /// Stable identity for collapsing duplicates: the source URL when we have one,
    /// else the title+artist pair. (A Bandcamp re-sync can list the same album twice.)
    var dedupeKey: String {
        if let u = bandcampItemURL, !u.isEmpty { return "bc:\(u)" }
        if let u = url { return "file:\(u.path)" }
        return "ta:\(title.lowercased())|\(artist.lowercased())"
    }

    /// Local audio files backing this album (a merged import, or a Bandcamp download).
    var hasLocalFiles: Bool { localTracks?.isEmpty == false }
    /// "Downloaded" specifically means an offline Bandcamp album (drives that filter/badge).
    var isDownloaded: Bool { source == .bandcamp && hasLocalFiles }
    var canDownload: Bool { source == .bandcamp && bandcampDownloadURL != nil && !isDownloaded }
    var isPlayable: Bool {
        url != nil || hasLocalFiles || (source == .bandcamp && bandcampItemURL != nil)
    }
    /// A plain single-file import — the kind that can be merged into an album.
    var isSingleLocalFile: Bool { source == .local && url != nil }

    var artwork: NSImage? {
        guard let d = artworkData else { return nil }
        return ArtworkCache.image(for: id, data: d)
    }

    var cover: LinearGradient {
        LinearGradient(
            colors: [Color(white: g0), Color(white: g1)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static let placeholder = Album(title: "Nothing here", artist: "", year: "", format: "", lossless: false, g0: 0.2, g1: 0.08)

    static let sample: [Album] = [
        .init(title: "Highest in the Room", artist: "Travis Scott", year: "2019", format: "FLAC · 24/44", lossless: true,  g0: 0.23, g1: 0.05),
        .init(title: "Blond",               artist: "Frank Ocean",  year: "2016", format: "FLAC",        lossless: true,  g0: 0.79, g1: 0.43),
        .init(title: "DAMN.",               artist: "Kendrick Lamar", year: "2017", format: "ALAC",      lossless: true,  g0: 0.36, g1: 0.09),
        .init(title: "Igor",                artist: "Tyler, the Creator", year: "2019", format: "WAV",   lossless: true,  g0: 0.90, g1: 0.56),
        .init(title: "Ctrl",                artist: "SZA",          year: "2017", format: "FLAC",        lossless: true,  g0: 0.14, g1: 0.32),
        .init(title: "After Hours",         artist: "The Weeknd",   year: "2020", format: "MP3 320",     lossless: false, g0: 0.65, g1: 0.17),
        .init(title: "In Rainbows",         artist: "Radiohead",    year: "2007", format: "FLAC · 24/96", lossless: true, g0: 0.46, g1: 0.07),
        .init(title: "Currents",            artist: "Tame Impala",  year: "2015", format: "FLAC",        lossless: true,  g0: 0.82, g1: 0.29),
        .init(title: "Melodrama",           artist: "Lorde",        year: "2017", format: "ALAC",        lossless: true,  g0: 0.20, g1: 0.49),
        .init(title: "Channel Orange",      artist: "Frank Ocean",  year: "2012", format: "FLAC",        lossless: true,  g0: 0.10, g1: 0.56),
        .init(title: "Blue",                artist: "Joni Mitchell", year: "1971", format: "WAV",        lossless: true,  g0: 0.72, g1: 0.24),
        .init(title: "The OOZ",             artist: "King Krule",   year: "2017", format: "FLAC",        lossless: true,  g0: 0.31, g1: 0.04)
    ]
}

/// One personnel credit — e.g. role "Producer", name "Rick Rubin".
struct Credit: Codable, Hashable, Identifiable {
    var role: String
    var name: String
    var id: String { "\(role)—\(name)" }
}

/// The metadata fields an enrich/match/manual-edit can change. Stored in history so
/// each change is reversible (including the cover, which a wrong match can wipe).
struct AlbumMetadata: Codable {
    var title: String
    var artist: String
    var year: String
    var label: String?
    var genre: String?
    var credits: [Credit]?
    var artworkURL: URL?
    var artworkData: Data?
    var discogsReleaseID: Int?
    var musicbrainzID: String?
}

/// A restorable point in an album's edit history: the metadata *before* one change.
struct AlbumEdit: Codable, Identifiable {
    var id = UUID()
    var date: Date
    /// What the change that replaced this snapshot was, e.g. "Matched via iTunes".
    var summary: String
    /// The metadata as it stood before that change — restored on revert.
    var snapshot: AlbumMetadata
}

/// A single playable track (a local file, or a Bandcamp stream URL).
struct Track: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let artist: String
    let streamURL: URL
    var artworkURL: URL? = nil
    var artworkData: Data? = nil
    /// The album this track was resolved from — lets history & Now Playing attribute a
    /// track to its album even during playlist playback (where the queue mixes albums).
    var albumID: UUID? = nil
    /// This track's position within its source album — so a single now-playing track can be
    /// added to a playlist and re-resolved to the right stream later.
    var trackIndex: Int? = nil
    // Gradient fallback for the mini cover.
    var g0: Double = 0.28
    var g1: Double = 0.08
}

/// Pseudo-random but stable waveform for the scrubber.
enum Waveform {
    static let bars: [CGFloat] = (0..<100).map { i in
        let base = abs(sin(Double(i) * 0.6))
        let jitter = Double((i * 37) % 100) / 100.0
        return CGFloat(min(1.0, 0.2 + base * 0.7 * jitter + 0.1))
    }
    static let progress = 0.51
}
