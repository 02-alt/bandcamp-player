import Foundation

// MARK: - Moods

/// A listening "mood" for radio, mapped to genre-tag keywords (we have no audio features,
/// so mood is inferred from the genres you've enriched onto albums).
enum Mood: String, CaseIterable, Identifiable, Codable {
    case chill, energetic, focus, party, latenight
    case melancholy, dreamy, groovy, heavy, global, uplifting

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chill: return "Chill"
        case .energetic: return "Energetic"
        case .focus: return "Focus"
        case .party: return "Party"
        case .latenight: return "Late night"
        case .melancholy: return "Melancholy"
        case .dreamy: return "Dreamy"
        case .groovy: return "Groovy"
        case .heavy: return "Heavy"
        case .global: return "Global"
        case .uplifting: return "Uplifting"
        }
    }

    var symbol: String {
        switch self {
        case .chill: return "cloud.moon"
        case .energetic: return "bolt.fill"
        case .focus: return "brain.head.profile"
        case .party: return "figure.dance"
        case .latenight: return "moon.stars.fill"
        case .melancholy: return "cloud.rain"
        case .dreamy: return "sparkles"
        case .groovy: return "music.quarternote.3"
        case .heavy: return "flame.fill"
        case .global: return "globe"
        case .uplifting: return "sun.max.fill"
        }
    }

    /// Lowercased substrings that count as this mood. Kept broad (and overlapping) so the
    /// free-form genre/mood tags Bandcamp albums carry map onto moods generously — one album
    /// can belong to several moods (ambient → chill + focus + late night).
    var keywords: [String] {
        switch self {
        case .chill:
            return ["ambient", "downtempo", "chill", "chillout", "chillwave", "lo-fi", "lofi",
                    "dream", "folk", "acoustic", "singer-songwriter", "soul", "jazz", "blues",
                    "new age", "world", "reggae", "dub", "bossa", "mellow", "soft", "balearic",
                    "field recording", "nature", "meditation", "relax", "calm", "shoegaze", "slowcore"]
        case .energetic:
            return ["techno", "house", "drum", "dnb", "d&b", "jungle", "punk", "rock", "metal",
                    "hardcore", "hardstyle", "hard techno", "dance", "edm", "electro", "electronic",
                    "breakbeat", "breaks", "dubstep", "bass", "trance", "garage", "grunge", "thrash",
                    "indie", "alternative", "big beat", "gabber", "rave", "industrial", "noise",
                    "speedcore", "acid", "footwork", "juke"]
        case .focus:
            return ["ambient", "classical", "modern classical", "contemporary classical", "neo-classical",
                    "instrumental", "piano", "minimal", "drone", "post-rock", "soundtrack", "score",
                    "stage & screen", "study", "meditation", "new age", "field recording", "generative",
                    "idm", "glitch", "spacemusic", "textures"]
        case .party:
            return ["house", "disco", "funk", "pop", "hip hop", "hip-hop", "hiphop", "rap", "trap",
                    "dance", "afro", "afrobeat", "reggaeton", "latin", "dancehall", "ska", "soca",
                    "grime", "r&b", "rnb", "boogie", "electro-pop", "electropop", "synth-pop",
                    "synthpop", "k-pop", "club", "party", "groove", "nu-disco"]
        case .latenight:
            return ["r&b", "rnb", "soul", "neo-soul", "jazz", "trip hop", "trip-hop", "trip-hop",
                    "downtempo", "ambient", "synth", "synthwave", "chillout", "smooth", "dub",
                    "dream pop", "quiet storm", "lo-fi", "lofi", "sensual", "late night", "nocturnal",
                    "slow", "sultry"]
        case .melancholy:
            return ["sad", "melancholy", "melancholic", "emo", "slowcore", "shoegaze", "doom",
                    "dark", "darkwave", "post-punk", "gothic", "goth", "mournful", "sorrow",
                    "somber", "blues", "drone", "ambient", "lament", "elegy", "ethereal wave",
                    "coldwave", "dark ambient", "post-rock"]
        case .dreamy:
            return ["dream pop", "dreampop", "shoegaze", "ethereal", "ambient", "chillwave",
                    "vaporwave", "dreamy", "atmospheric", "hypnagogic", "psychedelic", "space",
                    "spacemusic", "gaze", "washed out", "hazy", "dream"]
        case .groovy:
            return ["funk", "disco", "groove", "groovy", "soul", "boogie", "nu-disco", "nu disco",
                    "jazz-funk", "jazz funk", "acid jazz", "afrobeat", "funky", "g-funk", "neo-soul",
                    "rare groove", "breaks", "beats", "hip hop", "hip-hop"]
        case .heavy:
            return ["metal", "hardcore", "punk", "thrash", "doom", "sludge", "death metal",
                    "black metal", "grindcore", "noise", "industrial", "hard rock", "heavy",
                    "metalcore", "post-hardcore", "screamo", "crust", "powerviolence", "gabber",
                    "speedcore", "hard techno"]
        case .global:
            return ["afrobeat", "afro", "afrobeats", "latin", "reggae", "dub", "dancehall",
                    "reggaeton", "cumbia", "highlife", "world", "bossa", "samba", "soca",
                    "amapiano", "k-pop", "j-pop", "flamenco", "balkan", "gqom", "world music",
                    "tropical", "salsa", "mbalax", "desert blues"]
        case .uplifting:
            return ["pop", "indie pop", "sunshine", "happy", "feel-good", "feelgood", "uplifting",
                    "tropical", "sunny", "power pop", "jangle pop", "twee", "bubblegum",
                    "surf", "indie", "summer", "joyful", "bright", "anthemic"]
        }
    }

    func matches(_ genre: String?) -> Bool {
        guard let g = genre?.lowercased(), !g.isEmpty else { return false }
        return keywords.contains { g.contains($0) }
    }

    /// The Last.fm tag used to pull real-world "top artists" for this mood (online mode).
    var lastfmTag: String {
        switch self {
        case .chill: return "chillout"
        case .energetic: return "energetic"
        case .focus: return "instrumental"
        case .party: return "party"
        case .latenight: return "late night"
        case .melancholy: return "melancholy"
        case .dreamy: return "dreamy"
        case .groovy: return "funk"
        case .heavy: return "heavy"
        case .global: return "world"
        case .uplifting: return "feel good"
        }
    }
}

// MARK: - Preferences

/// Radio's optional Last.fm boost. The engine works fully without a key; when one is
/// present it adds cross-artist intelligence. Never required, never blocking.
enum RadioPrefs {
    static let lastfmAccount = "lastfm_api_key"
    static var lastfmKey: String? {
        get { Keychain.get(account: lastfmAccount).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, account: lastfmAccount) }
            else { Keychain.delete(account: lastfmAccount) }
        }
    }

    /// When on, mood radio ranks with real-world Last.fm mood data (needs a key). Off = local.
    static var moodOnline: Bool {
        get { UserDefaults.standard.bool(forKey: "yoin.moodOnline") }
        set { UserDefaults.standard.set(newValue, forKey: "yoin.moodOnline") }
    }

    /// "Auto-DJ": while a station plays, blend tracks with a beat-matched crossfade.
    static var autoDJ: Bool {
        get { UserDefaults.standard.bool(forKey: "yoin.autoDJ") }
        set { UserDefaults.standard.set(newValue, forKey: "yoin.autoDJ") }
    }
}

// MARK: - Last.fm client (optional, best-effort)

/// Thin, read-only Last.fm client. Every path swallows errors and returns empty, so a
/// missing key, offline machine, or bad response silently degrades to local-only radio.
enum LastFMClient {
    private struct SimilarResponse: Decodable {
        struct Wrapper: Decodable { let artist: [Artist]? }
        struct Artist: Decodable { let name: String; let match: String }
        let similarartists: Wrapper?
    }

    /// Artists Last.fm considers similar to `artist`, as `lowercasedName → match (0…1)`.
    static func similarArtists(to artist: String, key: String, limit: Int = 60) async -> [String: Double] {
        guard !artist.isEmpty, var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/") else { return [:] }
        comps.queryItems = [
            .init(name: "method", value: "artist.getsimilar"),
            .init(name: "artist", value: artist),
            .init(name: "api_key", value: key),
            .init(name: "autocorrect", value: "1"),
            .init(name: "limit", value: String(limit)),
            .init(name: "format", value: "json")
        ]
        guard let url = comps.url else { return [:] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
            let decoded = try JSONDecoder().decode(SimilarResponse.self, from: data)
            var out: [String: Double] = [:]
            for a in decoded.similarartists?.artist ?? [] {
                if let m = Double(a.match) { out[a.name.lowercased()] = m }
            }
            return out
        } catch { return [:] }
    }

    private struct TagArtistsResponse: Decodable {
        struct Wrapper: Decodable { let artist: [Artist]? }
        struct Artist: Decodable { let name: String }
        let topartists: Wrapper?
    }

    /// The globally most-representative artists for a mood tag, as `lowercasedName → boost`,
    /// where boost decays with rank. Used to bias mood radio toward artists the wider world
    /// files under that mood. Empty on any error (→ local-only ranking).
    static func topArtists(forTag tag: String, key: String, limit: Int = 200) async -> [String: Double] {
        guard !tag.isEmpty, var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/") else { return [:] }
        comps.queryItems = [
            .init(name: "method", value: "tag.gettopartists"),
            .init(name: "tag", value: tag),
            .init(name: "api_key", value: key),
            .init(name: "limit", value: String(limit)),
            .init(name: "format", value: "json")
        ]
        guard let url = comps.url else { return [:] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
            let decoded = try JSONDecoder().decode(TagArtistsResponse.self, from: data)
            let names = decoded.topartists?.artist ?? []
            var out: [String: Double] = [:]
            for (i, a) in names.enumerated() {
                out[a.name.lowercased()] = 1 - Double(i) / Double(max(1, names.count))  // 1 (top) … ~0
            }
            return out
        } catch { return [:] }
    }
}

// MARK: - Radio station

/// The endless-queue engine. Seeded from an album/track, it scores the user's *own* library
/// against a rolling "context" of recent picks (a random walk that lets the station drift),
/// balancing similarity, taste (play history / favourites), diversity, and a dash of
/// exploration — then hands back batches of tracks to feed the player queue.
@MainActor
final class RadioStation {
    // Injected views onto live app state (kept as closures so the engine owns no app types).
    private let library: () -> [Album]
    private let resolve: (Album) async -> [Track]
    private let history: () -> [PlayEvent]

    // Session memory (reset on each `start`).
    private var context: [Album] = []              // recent picks; newest last — drives the walk
    private var usedTrackKeys: Set<String> = []     // exact tracks already queued/played this session
    private var skips: [String: Double] = [:]       // lowercased artist → skip penalty
    private var similar: [String: Double] = [:]     // lowercased artist → Last.fm match (optional)
    private var fetchedSimilarFor: Set<String> = [] // artists we've already asked Last.fm about
    private var resolveCache: [UUID: [Track]] = [:]
    /// When set (mood radio), every pick must pass this — so the station stays on-theme
    /// instead of drifting across the whole library.
    private var restrictTo: ((Album) -> Bool)?

    // Tuning.
    private let contextDepth = 6      // how many recent picks the walk remembers
    private let explorationRate = 0.10 // ε — share of deliberate wildcard picks

    init(library: @escaping () -> [Album],
         resolve: @escaping (Album) async -> [Track],
         history: @escaping () -> [PlayEvent]) {
        self.library = library
        self.resolve = resolve
        self.history = history
    }

    // MARK: Lifecycle

    /// Begin a fresh station seeded from one or more albums (an artist's catalogue, a mood's
    /// matching albums, …). Returns the opening tracks (any seed lead + first generated batch).
    func start(seeds: [Album], seedTrack: Track? = nil, batch: Int = 8,
               restrictTo: ((Album) -> Bool)? = nil, artistBoost: [String: Double] = [:]) async -> [Track] {
        context = seeds
        usedTrackKeys = []; skips = [:]; similar = artistBoost; fetchedSimilarFor = []
        self.restrictTo = restrictTo
        for a in seeds.prefix(3) { maybeFetchSimilar(for: a.artist) }

        var lead: [Track] = []
        if let seedTrack {
            lead = [seedTrack]
            usedTrackKeys.insert(key(for: seedTrack))
        } else if seeds.count == 1, let only = seeds.first {
            // Single-album seed leads with that album's own tracks; multi-seed (artist/mood)
            // jumps straight into generated picks so it doesn't front-load one album.
            for t in await resolveCached(only).prefix(3) {
                lead.append(t); usedTrackKeys.insert(key(for: t))
            }
        }
        return lead + (await generate(count: batch))
    }

    func stop() { context = []; restrictTo = nil }

    /// More tracks to append when the queue runs low.
    func topUp(count: Int = 8) async -> [Track] { await generate(count: count) }

    /// Fold a finished track's outcome back into the station: a skip demotes that artist for
    /// the rest of the session; a real listen eases any penalty back off.
    func recordFeedback(artist: String, liked: Bool) {
        let k = artist.lowercased()
        if liked { skips[k] = max(0, (skips[k] ?? 0) - 0.5) }
        else { skips[k] = (skips[k] ?? 0) + 1 }
    }

    // MARK: Generation

    private func generate(count: Int) async -> [Track] {
        let pool = library().filter { $0.isPlayable }
        guard !pool.isEmpty else { return [] }
        let trackPlays = perTrackPlays()
        let albumPlays = perAlbumPlays()

        var out: [Track] = []
        var exhausted: Set<UUID> = []
        var lastArtist = context.last?.artist.lowercased()
        var attempts = 0
        while out.count < count && attempts < count * 8 {
            attempts += 1
            guard let album = chooseAlbum(from: pool, excludingArtist: lastArtist,
                                          exhausted: exhausted, albumPlays: albumPlays) else { break }
            let tracks = await resolveCached(album)
            guard let pick = pickTrack(tracks, trackPlays: trackPlays) else {
                exhausted.insert(album.id)   // nothing left on this album — don't reconsider it
                continue
            }
            out.append(pick)
            usedTrackKeys.insert(key(for: pick))
            pushContext(album)
            lastArtist = album.artist.lowercased()
            maybeFetchSimilar(for: album.artist)
        }
        return out
    }

    /// Pick the next album: mostly the best match to the current context (with a little
    /// randomness among the top few so it never loops), occasionally a pure wildcard.
    private func chooseAlbum(from pool: [Album], excludingArtist: String?,
                             exhausted: Set<UUID>, albumPlays: [UUID: Int]) -> Album? {
        // In-mood / not-yet-exhausted albums.
        let eligible = pool.filter { !exhausted.contains($0.id) && (restrictTo?($0) ?? true) }
        guard !eligible.isEmpty else { return nil }
        // Prefer a different artist than the last pick, but if that leaves nothing (e.g. a mood
        // whose only matches are one artist), fall back to same-artist rather than dead-ending.
        let diverse = eligible.filter { $0.artist.lowercased() != excludingArtist }
        let candidates = diverse.isEmpty ? eligible : diverse

        if Double.random(in: 0..<1) < explorationRate {
            return candidates.randomElement()
        }
        let ranked = candidates
            .map { ($0, score($0, albumPlays: albumPlays)) }
            .sorted { $0.1 > $1.1 }
        // Randomise among the strongest handful for organic variety.
        return ranked.prefix(3).map(\.0).randomElement() ?? ranked.first?.0
    }

    /// How well `candidate` fits the station right now.
    private func score(_ candidate: Album, albumPlays: [UUID: Int]) -> Double {
        var s = 0.0
        // Similarity to the recent walk, newest picks weighted heaviest.
        for (i, ctx) in context.reversed().prefix(4).enumerated() {
            s += pow(0.6, Double(i)) * pairSimilarity(ctx, candidate)
        }
        // Taste: reward what you actually play, and favourites.
        s += log(1 + Double(albumPlays[candidate.id] ?? 0)) * 0.4
        if candidate.isFavourite { s += 0.6 }
        // Optional Last.fm boost.
        if let m = similar[candidate.artist.lowercased()] { s += m * 2.0 }
        // Learned dislikes this session.
        s -= (skips[candidate.artist.lowercased()] ?? 0) * 1.5
        return s
    }

    /// Content similarity between two albums from the signals we store.
    private func pairSimilarity(_ a: Album, _ b: Album) -> Double {
        var s = 0.0
        if a.artist.caseInsensitiveCompare(b.artist) == .orderedSame { s += 3 }
        s += Double(overlap(genres(a), genres(b))) * 1.0
        if let la = a.label, let lb = b.label, !la.isEmpty, la.caseInsensitiveCompare(lb) == .orderedSame { s += 1 }
        s += Double(min(3, overlap(creditNames(a), creditNames(b)))) * 0.7
        if let ya = Int(a.year), let yb = Int(b.year), ya > 0, yb > 0 {
            s += max(0, 1 - Double(abs(ya - yb)) / 15) * 0.5
        }
        return s
    }

    // MARK: Track selection within an album

    private func pickTrack(_ tracks: [Track], trackPlays: [String: Int]) -> Track? {
        let unused = tracks.filter { !usedTrackKeys.contains(key(for: $0)) }
        guard !unused.isEmpty else { return nil }
        // Lead with the album's most-played (best-loved) track that's still unused.
        return unused.max { plays($0, trackPlays) < plays($1, trackPlays) }
    }

    // MARK: Last.fm (fire-and-forget)

    private func maybeFetchSimilar(for artist: String) {
        let k = artist.lowercased()
        guard !k.isEmpty, !fetchedSimilarFor.contains(k), let key = RadioPrefs.lastfmKey else { return }
        fetchedSimilarFor.insert(k)
        Task { [weak self] in
            let result = await LastFMClient.similarArtists(to: artist, key: key)
            guard !result.isEmpty else { return }
            self?.similar.merge(result) { old, new in max(old, new) }
        }
    }

    // MARK: Helpers

    private func resolveCached(_ album: Album) async -> [Track] {
        if let c = resolveCache[album.id] { return c }
        let t = await resolve(album)
        resolveCache[album.id] = t
        return t
    }

    private func pushContext(_ album: Album) {
        context.append(album)
        if context.count > contextDepth { context.removeFirst() }
    }

    private func key(for t: Track) -> String { "\(t.albumID?.uuidString ?? "-")|\(t.trackIndex ?? -1)" }
    private func plays(_ t: Track, _ tp: [String: Int]) -> Int {
        tp["\(t.albumID?.uuidString ?? "-")|\(t.title.lowercased())"] ?? 0
    }

    private func genres(_ a: Album) -> Set<String> {
        Set((a.genre ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }
    private func creditNames(_ a: Album) -> Set<String> {
        Set((a.credits ?? []).map { $0.name.lowercased() }.filter { !$0.isEmpty })
    }
    private func overlap(_ a: Set<String>, _ b: Set<String>) -> Int { a.intersection(b).count }

    private func perAlbumPlays() -> [UUID: Int] {
        var m: [UUID: Int] = [:]
        for e in history() where e.isRealListen { if let id = e.albumID { m[id, default: 0] += 1 } }
        return m
    }
    private func perTrackPlays() -> [String: Int] {
        var m: [String: Int] = [:]
        for e in history() where e.isRealListen {
            guard let id = e.albumID, !e.trackTitle.isEmpty else { continue }
            m["\(id.uuidString)|\(e.trackTitle.lowercased())", default: 0] += 1
        }
        return m
    }
}
