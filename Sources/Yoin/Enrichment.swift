import SwiftUI

/// Album metadata enrichment (covers, clean names, Tidal-style credits).
extension AppState {

    /// Auto-enrich an album after import. No-ops if it already has credits (unless forced).
    func enrich(albumID: UUID, force: Bool = false) async {
        guard let album = albums.first(where: { $0.id == albumID }) else { return }
        if !force && album.enriched { return }
        if !force && !MetadataPrefs.autoEnrich { return }
        let seed = seedQuery(for: album)
        guard let meta = await MetadataService().enrich(artist: seed.artist, title: seed.title) else { return }
        applyMeta(meta, to: albumID)
    }

    /// Apply a candidate the user picked in the "wrong album?" sheet. Keeps the existing
    /// cover — matching is for names/credits; the artwork only changes via Edit details.
    func applyCandidate(_ c: MatchCandidate, to albumID: UUID) async {
        guard let meta = await MetadataService().details(for: c) else { return }
        let name = c.title.isEmpty ? "release" : c.title
        applyMeta(meta, to: albumID, summary: "Matched \u{201C}\(name)\u{201D} · \(c.source.label)")
    }

    /// Enrich several albums at once — the multi-select "Find credits" action, so the user
    /// doesn't have to open each album and hit "Fetch credits" one by one. Force-fetches
    /// (like the per-album button), runs a few lookups in parallel, and reports via a notice.
    func enrichSelection(_ ids: Set<UUID>) {
        // Snapshot each pick's search seed now (on the main actor) so the parallel tasks
        // don't touch `self`; results are applied back here as they land.
        let targets: [(id: UUID, seed: (artist: String?, title: String))] =
            ids.compactMap { id in albums.first { $0.id == id }.map { (id, seedQuery(for: $0)) } }
        guard !targets.isEmpty else { return }
        let total = targets.count
        showNotice("Finding credits for \(total) album\(total == 1 ? "" : "s")…")
        Task { @MainActor in
            var applied = 0
            // Bounded fan-out: each lookup hits iTunes + Discogs/MusicBrainz, so keep it small
            // to stay polite and avoid rate limits.
            let maxConcurrent = min(4, targets.count)
            var iterator = targets.makeIterator()
            await withTaskGroup(of: (UUID, EnrichedMeta?).self) { group in
                func addNext() {
                    guard let t = iterator.next() else { return }
                    let (id, seed) = t
                    group.addTask {
                        (id, await MetadataService().enrich(artist: seed.artist, title: seed.title))
                    }
                }
                for _ in 0..<maxConcurrent { addNext() }
                for await (id, meta) in group {
                    if let meta { applyMeta(meta, to: id); applied += 1 }
                    addNext()
                }
            }
            showNotice("Added credits to \(applied) of \(total) album\(total == 1 ? "" : "s").")
        }
    }

    /// Save a snapshot of the album's current metadata so a later change can be undone.
    /// Newest first; older entries drop off after a small cap to keep the library light.
    func recordHistory(_ summary: String, forAlbumAt i: Int) {
        let edit = AlbumEdit(date: Date(), summary: summary, snapshot: albums[i].metadata)
        albums[i].history.insert(edit, at: 0)
        if albums[i].history.count > 10 { albums[i].history.removeLast(albums[i].history.count - 10) }
    }

    /// Restore an earlier snapshot from the album's history (recording the current
    /// state first, so the revert itself can be undone).
    func revert(albumID: UUID, to editID: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == albumID }),
              let edit = albums[i].history.first(where: { $0.id == editID }) else { return }
        recordHistory("Before revert", forAlbumAt: i)
        albums[i].metadata = edit.snapshot
        albums[i].history.removeAll { $0.id == editID }
        persist()
        // Re-fetch a remote cover if the restored state had no embedded artwork.
        if let art = albums[i].artworkURL, albums[i].artworkData == nil {
            Task { await self.cacheCover(art, for: albumID) }
        }
    }

    /// Restore a Bandcamp album's original title/artist/cover, clearing enrichment
    /// overrides. Works even with no edit history (the original is captured at sync).
    func resetToOriginal(albumID: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == albumID }), albums[i].canResetToOriginal else { return }
        recordHistory("Reset to Bandcamp original", forAlbumAt: i)
        if let t = albums[i].origTitle { albums[i].title = t }
        if let a = albums[i].origArtist { albums[i].artist = a }
        albums[i].artworkURL = albums[i].origArtworkURL
        albums[i].artworkData = nil
        albums[i].year = ""
        albums[i].label = nil
        albums[i].genre = nil
        albums[i].credits = nil
        albums[i].discogsReleaseID = nil
        albums[i].musicbrainzID = nil
        persist()
        if let art = albums[i].artworkURL {
            Task { await self.cacheCover(art, for: albumID) }
        }
    }

    /// Apply hand-typed metadata from the "Edit details" sheet, preserving credits/IDs.
    /// The sheet clears `artworkData` when the cover URL is changed, so a nil here with
    /// a URL means "fetch the new cover".
    func applyManualEdit(_ meta: AlbumMetadata, to albumID: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == albumID }) else { return }
        recordHistory("Manual edit", forAlbumAt: i)
        albums[i].metadata = meta
        persist()
        if let art = meta.artworkURL, meta.artworkData == nil {
            Task { await self.cacheCover(art, for: albumID) }
        }
    }

    /// Cache per-track personnel so the credits panel doesn't refetch on every open.
    func cacheTrackCredits(albumID: UUID, key: String, credits: [Credit]) {
        guard !credits.isEmpty,
              let i = albums.firstIndex(where: { $0.id == albumID }) else { return }
        var map = albums[i].trackCredits ?? [:]
        map[key] = credits
        albums[i].trackCredits = map
        persist()
    }

    /// The best guess we can feed the lookup: explicit tags, else a cleaned filename.
    func seedQuery(for album: Album) -> (artist: String?, title: String) {
        if album.artist != "Unknown Artist" && !album.artist.isEmpty {
            return (album.artist, album.title)
        }
        let base = album.url?.deletingPathExtension().lastPathComponent ?? album.title
        return FilenameCleaner.parse(base)
    }

    private func applyMeta(_ meta: EnrichedMeta, to albumID: UUID, summary: String? = nil) {
        guard let i = albums.firstIndex(where: { $0.id == albumID }) else { return }
        // Snapshot the pre-change metadata so the user can undo this match.
        if let summary { recordHistory(summary, forAlbumAt: i) }
        if !meta.title.isEmpty { albums[i].title = meta.title }
        if !meta.artist.isEmpty { albums[i].artist = meta.artist }
        if !meta.year.isEmpty { albums[i].year = meta.year }
        albums[i].label = meta.label
        // Keep any existing genre (e.g. read from the file's own tags) when the web match has
        // none — otherwise an iTunes/tagless match would wipe it and re-lock mood radio.
        if let g = meta.genre, !g.isEmpty { albums[i].genre = g }
        if !meta.credits.isEmpty { albums[i].credits = meta.credits }
        albums[i].discogsReleaseID = meta.discogsReleaseID
        albums[i].musicbrainzID = meta.musicbrainzID
        // Only adopt the match's cover when the album has none — never replace an existing
        // one. Changing artwork is an explicit action (Edit details), not a side effect.
        // For local imports "has a cover" means real cached image data: a bare `artworkURL`
        // with no data is a pointer that never resolved (e.g. a dead Cover Art Archive link),
        // so we still let a re-enrich replace it rather than leaving the album blank.
        let hasCover = albums[i].source == .local
            ? albums[i].artworkData != nil
            : (albums[i].artworkData != nil || albums[i].artworkURL != nil)
        if !hasCover, let art = meta.artworkURL {
            albums[i].artworkURL = art
            Task { await self.cacheCover(art, for: albumID) }
        }
        persist()
    }

    /// Download the cover so it persists offline and shows in the crate/grid.
    private func cacheCover(_ url: URL, for albumID: UUID) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              NSImage(data: data) != nil else { return }
        if let i = albums.firstIndex(where: { $0.id == albumID }) {
            albums[i].artworkData = data
            persist()
        }
    }
}
