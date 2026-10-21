import SwiftUI
import AppKit

// MARK: - Model

/// One credit a person holds in the library: a role on a song (or on the whole album when the
/// source isn't per-track, e.g. the artist's Bandcamp credits).
struct PersonCredit: Hashable, Sendable {
    let albumID: UUID
    /// Song title, or nil for an album-wide credit.
    let track: String?
    let role: String
}

/// Everyone credited across the library, keyed by a normalised name.
struct CreditPerson: Identifiable, Sendable {
    let key: String
    var name: String
    var credits: [PersonCredit]
    var id: String { key }

    /// Distinct songs (album-wide credits count once per album).
    var songCount: Int { Set(credits.map { "\($0.albumID)|\($0.track ?? "")" }).count }
    var albumIDs: [UUID] {
        var seen = Set<UUID>(), out: [UUID] = []
        for c in credits where seen.insert(c.albumID).inserted { out.append(c.albumID) }
        return out
    }
    /// Most frequent roles first.
    var topRoles: [String] {
        var counts: [String: Int] = [:]
        for c in credits { counts[c.role, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// Name handling shared by the index and the views.
enum CreditNames {
    /// Normalised identity: case/diacritic-folded, Discogs "(2)" suffixes dropped, spaces collapsed.
    static func key(_ name: String) -> String {
        var s = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        s = s.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a joined list ("A, B & C") into names.
    static func split(_ joined: String) -> [String] {
        joined.replacingOccurrences(of: " & ", with: ", ")
            .replacingOccurrences(of: " and ", with: ", ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let companyRoles = ["label", "copyright", "phonographic", "distribut", "publish",
                                       "marketing", "management", "a&r administration", "licens"]
    private static let companyWords = ["records", "recordings", "music group", "entertainment", " ltd",
                                       " llc", " inc", "gmbh", "publishing", "music publishing", "label",
                                       " studios", " studio", "mastering", "productions"]

    /// Labels, publishers and other companies don't get a profile — they're not collaborators.
    static func isCompany(role: String, name: String) -> Bool {
        let r = role.lowercased(), n = " " + name.lowercased()
        return companyRoles.contains { r.contains($0) } || companyWords.contains { n.contains($0) }
            || n.contains("℗") || n.contains("©")
    }

    /// People out of the artist's free-text Bandcamp credits. Only the common, unambiguous shapes:
    /// "Role: Name, Name" and "Role by Name (at Place)". Lines that don't match are skipped.
    static func parseBandcamp(_ text: String) -> [(role: String, name: String)] {
        var out: [(String, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".;"))
            guard !line.isEmpty, line.count < 160 else { continue }
            var role: String?, names: String?
            if let r = line.range(of: " by:? ", options: [.regularExpression, .caseInsensitive]) {
                role = String(line[..<r.lowerBound]); names = String(line[r.upperBound...])
            } else if let c = line.firstIndex(of: ":") {
                role = String(line[..<c]); names = String(line[line.index(after: c)...])
            }
            guard var role = role?.trimmingCharacters(in: .whitespaces), let names,
                  !role.isEmpty, role.count <= 50, role.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            role = role.prefix(1).uppercased() + role.dropFirst()
            // Drop trailing places / platforms: "Bo Kondren at Calyx Mastering, Berlin".
            let cleaned = names.replacingOccurrences(of: #"\s+(at|on|for|in|with|@)\s.*$"#, with: "",
                                                     options: [.regularExpression, .caseInsensitive])
            for n in split(cleaned) where looksLikeName(n) { out.append((role, n)) }
        }
        return out
    }

    private static func looksLikeName(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard (1...4).contains(words.count), s.count <= 40,
              s.rangeOfCharacter(from: .decimalDigits) == nil,
              s.first?.isLetter == true else { return false }
        return !["the", "a", "an"].contains(s.lowercased())
    }
}

// MARK: - Index

/// Everyone credited across the owned library, rebuilt off the main thread whenever the library
/// changes. Separate from AppState so only views that show credit names observe it.
@MainActor
final class CreditIndex: ObservableObject {
    static let shared = CreditIndex()

    @Published private(set) var people: [String: CreditPerson] = [:]
    /// Library artists (normalised) — for "also an artist" links.
    private(set) var artistKeys: [String: String] = [:]   // key → display name
    /// Album artist per album (normalised), to separate someone's own records from guest credits.
    private(set) var albumArtistKey: [UUID: String] = [:]
    private var generation = 0

    /// A person's credits on *other* artists' records (their own albums live on the artist page).
    func guestCredits(_ p: CreditPerson) -> [PersonCredit] {
        p.credits.filter { albumArtistKey[$0.albumID].map { !artistMatches($0, p.key) } ?? true }
    }
    private func artistMatches(_ albumArtist: String, _ person: String) -> Bool {
        albumArtist == person || albumArtist.components(separatedBy: ", ").contains(person)
    }

    /// The person behind a credited name when they're worth a profile: credited on 2+ songs of
    /// other artists' records in the library.
    func profile(for name: String) -> CreditPerson? {
        guard let p = people[CreditNames.key(name)] else { return nil }
        let guest = guestCredits(p)
        return Set(guest.map { "\($0.albumID)|\($0.track ?? "")" }).count >= 2 ? p : nil
    }

    func artistName(for key: String) -> String? { artistKeys[key] }

    /// The people who share the most songs with `p`.
    func collaborators(of p: CreditPerson, limit: Int = 10) -> [(person: CreditPerson, shared: Int)] {
        let mine = Set(p.credits.map { "\($0.albumID)|\($0.track ?? "")" })
        var counts: [String: Int] = [:]
        for (k, other) in people where k != p.key {
            let n = Set(other.credits.map { "\($0.albumID)|\($0.track ?? "")" }).intersection(mine).count
            if n > 0 { counts[k] = n }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).compactMap { k, n in people[k].map { ($0, n) } }
    }

    private struct Snapshot: Sendable {
        let id: UUID, artist: String
        let genius: [String: [GeniusCredit]]
        let track: [String: [Credit]]
        let album: [Credit]
        let bandcamp: String?
    }

    /// Rebuild from the library (coalesced; the work runs off main).
    func rebuild(from albums: [Album]) {
        generation += 1
        let gen = generation
        let snaps = albums.map {
            Snapshot(id: $0.id, artist: $0.artist, genius: $0.geniusCredits ?? [:], track: $0.trackCredits ?? [:],
                     album: $0.credits ?? [], bandcamp: $0.bcCredits)
        }
        Task.detached(priority: .utility) {
            let built = Self.build(snaps)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.artistKeys = built.artists
                self.albumArtistKey = built.albumArtist
                self.people = built.people
            }
        }
    }

    nonisolated private static func build(_ snaps: [Snapshot])
        -> (people: [String: CreditPerson], artists: [String: String], albumArtist: [UUID: String]) {
        var people: [String: CreditPerson] = [:]
        var nameVotes: [String: [String: Int]] = [:]
        var artists: [String: String] = [:], albumArtist: [UUID: String] = [:]
        func add(_ name: String, _ role: String, _ album: UUID, _ track: String?) {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !CreditNames.isCompany(role: role, name: name) else { return }
            let k = CreditNames.key(name)
            guard !k.isEmpty else { return }
            let c = PersonCredit(albumID: album, track: track, role: role)
            people[k, default: CreditPerson(key: k, name: name, credits: [])].credits.append(c)
            nameVotes[k, default: [:]][name, default: 0] += 1
        }
        for s in snaps {
            let ak = CreditNames.key(s.artist)
            albumArtist[s.id] = ak
            for part in CreditNames.split(s.artist) { artists[CreditNames.key(part)] = part }
            artists[ak] = s.artist
            for (title, list) in s.genius {
                for g in list { for n in CreditNames.split(g.names) { add(n, g.role, s.id, title) } }
            }
            for (key, list) in s.track {
                let title = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? key
                for c in list { add(c.name, c.role, s.id, title.lowercased()) }
            }
            for c in s.album { add(c.name, c.role, s.id, nil) }
            if let bc = s.bandcamp { for (r, n) in CreditNames.parseBandcamp(bc) { add(n, r, s.id, nil) } }
        }
        // De-duplicate identical credits and settle on the most common spelling.
        for (k, var p) in people {
            var seen = Set<PersonCredit>()
            p.credits = p.credits.filter { seen.insert($0).inserted }
            if let best = nameVotes[k]?.max(by: { $0.value < $1.value })?.key { p.name = best }
            people[k] = p
        }
        return (people, artists, albumArtist)
    }
}

// MARK: - Background fill-in

/// Fetches missing credits for the whole library, slowly, once: the artist's Bandcamp notes and
/// (with a Genius token) per-song Genius credits. Everything lands in the saved library, so the
/// credit profiles work offline afterwards.
@MainActor
enum CreditBackfill {
    private static let doneKey = "cabin.creditsBackfilled"
    private static var running = false

    static func start(state: AppState) {
        guard !running, !AppState.isScreenshotRun else { return }
        running = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))   // let launch, sync and the UI settle first
            var done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
            for album in state.albums where !done.contains(album.id.uuidString) {
                // Bandcamp liner notes (about + credits), if never loaded.
                if album.source == .bandcamp, !album.notesLoaded {
                    state.loadNotes(for: album.id)
                    try? await Task.sleep(for: .seconds(2))
                }
                if GeniusService.hasToken {
                    var tracks = TracklistCache.shared.displayTracks(for: album) ?? []
                    if tracks.isEmpty, album.isPlayable {
                        tracks = await state.resolveTracks(for: album, announce: false)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    for t in tracks {
                        let key = t.title.lowercased()
                        if state.album(id: album.id)?.geniusCredits?[key]?.isEmpty == false { continue }
                        if let c = await GeniusService.credits(artist: t.artist, title: t.title, album: album.title),
                           !c.isEmpty {
                            state.cacheGeniusCredits(albumID: album.id, key: key, credits: c)
                        }
                        try? await Task.sleep(for: .milliseconds(1200))
                    }
                    // Only mark done once its tracklist was known (else retry next launch).
                    if !tracks.isEmpty { done.insert(album.id.uuidString) }
                } else if album.source != .bandcamp || album.notesLoaded {
                    done.insert(album.id.uuidString)
                }
                UserDefaults.standard.set(Array(done), forKey: doneKey)
            }
            running = false
        }
    }
}

// MARK: - Clickable names

/// A credited name. People worth a profile (2+ songs on others' records in your library) read in
/// full ink with a dotted underline; hover firms it up with a ↗ and the hand cursor; click opens
/// their credit profile. Everyone else is plain secondary text — no hover, not clickable.
struct CreditNameLink: View {
    let name: String
    var font: Font = .uiBody.weight(.medium)
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var index = CreditIndex.shared
    @Environment(\.palette) private var p
    @State private var hover = false

    var body: some View {
        if let person = index.profile(for: name) {
            Button { state.openCreditProfile(person.key, player: player) } label: {
                HStack(spacing: 3) {
                    Text(name).font(font).foregroundStyle(p.text)
                        .underline(true, pattern: hover ? .solid : .dot, color: p.text.opacity(hover ? 0.9 : 0.45))
                    Image(systemName: "arrow.up.right").font(.uiCaption.weight(.bold))
                        .foregroundStyle(p.muted).opacity(hover ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .modifier(LinkCursor())
            .help("\(person.songCount) credits in your library")
            .accessibilityHint("Opens their credits in your library")
        } else {
            Text(name).font(font).foregroundStyle(p.muted)
        }
    }
}

/// A joined Genius-style name list ("A, B & C") as individual links, wrapping like text.
struct CreditNamesLine: View {
    let names: String
    var font: Font = .uiBody
    var body: some View {
        WrapLayout(spacing: 0, lineSpacing: 2) {
            let list = CreditNames.split(names)
            ForEach(Array(list.enumerated()), id: \.offset) { i, n in
                HStack(spacing: 0) {
                    CreditNameLink(name: n, font: font)
                    if i < list.count - 1 { Text(", ").font(font).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// The people in an artist's free-text Bandcamp credits who have a profile, as a row of links
/// under the text (the text itself stays as written).
struct BandcampCreditPeople: View {
    let text: String
    @ObservedObject private var index = CreditIndex.shared
    @Environment(\.palette) private var p
    var body: some View {
        let people = Array(Set(CreditNames.parseBandcamp(text).map(\.name)))
            .filter { index.profile(for: $0) != nil }.sorted()
        if !people.isEmpty {
            WrapLayout(spacing: Space.s3, lineSpacing: Space.s1) {
                ForEach(people, id: \.self) { CreditNameLink(name: $0, font: .uiCallout.weight(.medium)) }
            }
        }
    }
}

/// Left-to-right wrapping layout (names flow like a sentence).
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

// MARK: - Credit profile page

/// A person's credits across your library, styled like the back of a record sleeve — a ruled,
/// typewriter-labelled list — so it never reads as an artist page.
struct CreditProfileView: View {
    let key: String
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var index = CreditIndex.shared
    @Environment(\.palette) private var p
    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollView {
            if let person = index.people[key] {
                content(person)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, Space.s7)
                    .padding(.top, WindowSize.titlebarHeight + Space.s6)
                    .padding(.bottom, state.playerBarHeight + Space.s7)
                    .frame(maxWidth: .infinity)
            } else {
                Text("No credits for this person.").font(.uiBody).foregroundStyle(p.muted)
                    .padding(.top, WindowSize.titlebarHeight + Space.s7)
            }
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(.container, edges: .top)
        .modifier(TopScrollEdge(hiddenHeight: WindowSize.titlebarHeight - Space.s3))
    }

    @ViewBuilder private func content(_ person: CreditPerson) -> some View {
        let guest = index.guestCredits(person)
        let albums = orderedAlbums(guest)
        let songs = Set(guest.map { "\($0.albumID)|\($0.track ?? "")" }).count
        VStack(alignment: .leading, spacing: Space.s6) {
            header(person, songs: songs, albums: albums.count, roles: CreditPerson(key: person.key, name: person.name, credits: guest).topRoles)

            if let artist = index.artistName(for: person.key) {
                Button { state.openedCreditPerson = nil; state.openArtist(artist) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "music.mic").font(.uiCallout)
                        Text("Also an artist in your library").font(.uiCallout.weight(.semibold))
                        Image(systemName: "arrow.right").font(.uiCaption.weight(.bold))
                    }
                    .foregroundStyle(p.text)
                    .padding(.horizontal, Space.s3).padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(p.edgeSoft.opacity(3), lineWidth: 1))
                }
                .buttonStyle(.soft(press: Press.small)).modifier(LinkCursor())
            }

            eyebrow("On your records")
            VStack(spacing: 0) {
                ForEach(albums, id: \.id) { album in
                    albumRow(album, credits: guest.filter { $0.albumID == album.id })
                    rule
                }
            }

            let team = index.collaborators(of: person)
                .filter { index.profile(for: $0.person.name) != nil }
            if !team.isEmpty {
                eyebrow("Worked with").padding(.top, Space.s3)
                WrapLayout(spacing: Space.s4, lineSpacing: Space.s2) {
                    ForEach(team, id: \.person.key) { t in
                        HStack(spacing: 4) {
                            CreditNameLink(name: t.person.name, font: .uiBody.weight(.medium))
                            Text("\(t.shared)").font(.uiSubheadline.monospacedDigit()).foregroundStyle(p.muted2)
                        }
                    }
                }
            }
        }
    }

    private func header(_ person: CreditPerson, songs: Int, albums: Int, roles: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            eyebrow("Credits")
            HStack(alignment: .center, spacing: Space.s4) {
                Text(initials(person.name))
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(p.text)
                    .frame(width: 64, height: 64)
                    .overlay(Circle().strokeBorder(p.text.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                VStack(alignment: .leading, spacing: 4) {
                    // A serif name (artist pages use a bold sans hero) — reads as a liner credit.
                    Text(person.name).font(.system(size: 34, weight: .regular, design: .serif))
                        .foregroundStyle(p.text).lineLimit(2)
                    Text(roles.prefix(4).joined(separator: " · "))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(p.muted).lineLimit(1)
                }
            }
            Text("\(songs) \(songs == 1 ? "song" : "songs") on \(albums) of your \(albums == 1 ? "album" : "albums")")
                .font(.uiCallout.monospacedDigit()).foregroundStyle(p.muted2)
        }
    }

    private func albumRow(_ album: Album, credits: [PersonCredit]) -> some View {
        let open = expanded.contains(album.id)
        let roles = Array(Set(credits.map(\.role))).sorted()
        let songs = credits.compactMap(\.track)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.fluid) { if open { expanded.remove(album.id) } else { expanded.insert(album.id) } }
            } label: {
                HStack(spacing: Space.s4) {
                    AlbumArt(album: album, corner: 6).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title).font(.uiBody.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                        Text(album.artist).font(.uiCallout).foregroundStyle(p.muted).lineLimit(1)
                    }
                    Spacer(minLength: Space.s4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(roles.prefix(2).joined(separator: ", "))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                        if !songs.isEmpty {
                            Text("\(Set(songs).count) \(Set(songs).count == 1 ? "song" : "songs")")
                                .font(.uiSubheadline.monospacedDigit()).foregroundStyle(p.muted2)
                        }
                    }
                    Image(systemName: "chevron.right").font(.uiCaption.weight(.bold)).foregroundStyle(p.muted2)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.vertical, Space.s3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the songs")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    let bySong = Dictionary(grouping: credits, by: { $0.track })
                    ForEach(bySong.keys.sorted { ($0 ?? "") < ($1 ?? "") }, id: \.self) { title in
                        songRow(album: album, title: title, roles: (bySong[title] ?? []).map(\.role))
                    }
                    Button { state.openedCreditPerson = nil; state.openedAlbumID = album.id } label: {
                        HStack(spacing: 4) {
                            Text("Open album").font(.uiCallout.weight(.semibold))
                            Image(systemName: "arrow.right").font(.uiCaption.weight(.bold))
                        }
                        .foregroundStyle(p.text)
                    }
                    .buttonStyle(.soft(press: Press.small)).modifier(LinkCursor())
                    .padding(.vertical, Space.s3)
                }
                .padding(.leading, 48 + Space.s4)
                .transition(.opacity)
            }
        }
    }

    /// "Song title ……… Role" — a dotted leader like a sleeve credit; click plays the song.
    private func songRow(album: Album, title: String?, roles: [String]) -> some View {
        Button { play(album, title: title) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Image(systemName: "play.fill").font(.uiCaption).foregroundStyle(p.muted2)
                Text(title.map(displayTitle(album)) ?? "Whole album").font(.uiBody).foregroundStyle(p.text).lineLimit(1)
                Text(String(repeating: ".", count: 80)).font(.uiCallout).foregroundStyle(p.muted2.opacity(0.6))
                    .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                Text(Array(Set(roles)).sorted().joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft(press: Press.surface, brighten: 0.04))
        .disabled(!album.isPlayable)
    }

    /// Stored song keys are lowercased; show the real casing from the tracklist when known.
    private func displayTitle(_ album: Album) -> (String) -> String {
        let real = TracklistCache.shared.displayTracks(for: album)?.map(\.title) ?? []
        return { key in real.first { $0.lowercased() == key } ?? key.capitalized }
    }

    private func play(_ album: Album, title: String?) {
        guard let title else { state.play(album, on: player); return }
        state.nowPlayingAlbumID = album.id
        Task {
            let tracks = await state.resolveTracks(for: album)
            let i = tracks.firstIndex { $0.title.lowercased() == title } ?? 0
            if !tracks.isEmpty { player.play(tracks, startAt: i) }
        }
    }

    private func orderedAlbums(_ credits: [PersonCredit]) -> [Album] {
        var counts: [UUID: Int] = [:]
        for c in credits { counts[c.albumID, default: 0] += 1 }
        return counts.keys.compactMap { state.album(id: $0) }
            .sorted { (counts[$0.id] ?? 0) != (counts[$1.id] ?? 0) ? (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) : $0.title < $1.title }
    }

    private func eyebrow(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).kerning(3)
            .foregroundStyle(p.muted2)
    }
    private var rule: some View { Rectangle().fill(p.edgeSoft).frame(height: 1) }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
