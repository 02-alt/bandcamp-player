import SwiftUI
import AppKit

// MARK: - Model

/// One credit a person holds in the library: a role on a song (or on the whole album when the
/// source isn't per-track, e.g. the artist's Bandcamp credits).
struct PersonCredit: Hashable, Sendable {
    let albumID: UUID
    /// Song title (lowercased), or nil for an album-wide credit.
    let track: String?
    let role: String
    var unit: String { "\(albumID)|\(track ?? "")" }
}

/// Everyone credited across the library, keyed by a normalised name. The derived numbers are
/// computed once when the index is built, never in a view body.
struct CreditPerson: Identifiable, Sendable, Equatable {
    let key: String
    var name: String
    var credits: [PersonCredit]
    /// Credits on *other* artists' records (their own albums live on their artist page).
    var guest: [PersonCredit] = []
    /// Distinct songs among `guest` (album-wide credits count once per album).
    var guestSongCount = 0
    /// Most frequent guest roles first.
    var guestRoles: [String] = []
    /// The people who share the most guest songs with them: (key, shared songs).
    var collaborators: [Collaborator] = []
    var id: String { key }
    /// Worth a profile: credited on 2+ songs of other artists' records in your library.
    var hasProfile: Bool { guestSongCount >= 2 }

    struct Collaborator: Hashable, Sendable { let key: String; let shared: Int }

    static func roles(_ credits: [PersonCredit]) -> [String] {
        var counts: [String: Int] = [:]
        for c in credits { counts[c.role, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// Name handling shared by the index and the views.
enum CreditNames {
    /// "1 song" / "3 songs".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(n == 1 ? noun : noun + "s")" }

    /// Normalised identity: case/diacritic-folded, Discogs "(2)" suffixes dropped, spaces collapsed.
    static func key(_ name: String) -> String {
        var s = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        s = s.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a Genius name list. Genius joins names with ", " — split only on that, so names that
    /// contain "&" / "and" ("Simon & Garfunkel") stay whole.
    static func splitList(_ joined: String) -> [String] {
        joined.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Split free text ("A, B & C and D") into names — for the artist's hand-written credits.
    static func splitProse(_ joined: String) -> [String] {
        splitList(joined.replacingOccurrences(of: " & ", with: ", ").replacingOccurrences(of: " and ", with: ", ")
            .replacingOccurrences(of: ",", with: ", ").replacingOccurrences(of: ",  ", with: ", "))
    }

    private static let companyRoles = ["label", "copyright", "phonographic", "distribut", "publish",
                                       "marketing", "management", "a&r administration", "licens"]
    private static let companyWords = ["records", "recordings", "music group", "entertainment", " ltd",
                                       " llc", " inc", "gmbh", "publishing", " label", " studios",
                                       " studio", " mastering", " productions"]
    /// Lines in an artist's credits that aren't about who made the music.
    private static let nonCreditRoles = ["thank", "follow", "contact", "booking", "email", "e-mail", "lyrics",
                                         "merch", "instagram", "twitter", "website", "support", "special", "dedicat"]

    /// Labels, publishers, studios and other companies don't get a profile — not collaborators.
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
                  !role.isEmpty, role.count <= 50, role.rangeOfCharacter(from: .decimalDigits) == nil,
                  !nonCreditRoles.contains(where: { role.lowercased().contains($0) }) else { continue }
            role = role.prefix(1).uppercased() + role.dropFirst()
            // Drop trailing places / platforms: "Bo Kondren at Calyx Mastering, Berlin".
            let cleaned = names.replacingOccurrences(of: #"\s+(at|on|for|in|with|@)\s.*$"#, with: "",
                                                     options: [.regularExpression, .caseInsensitive])
            for n in splitProse(cleaned) where looksLikeName(n) { out.append((role, n)) }
        }
        return out
    }

    private static func looksLikeName(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard (1...4).contains(words.count), s.count <= 40,
              s.rangeOfCharacter(from: .decimalDigits) == nil,
              !s.contains("@"), !s.contains("/"), !s.lowercased().contains("http"),
              s.first?.isLetter == true else { return false }
        return !["the", "a", "an"].contains(s.lowercased())
    }
}

// MARK: - Index

/// Everyone credited across the owned library, rebuilt off the main thread when the library's
/// credits change (debounced, cancelled when superseded, skipped when nothing credit-related
/// changed). Separate from AppState so only views that show credit names observe it.
@MainActor
final class CreditIndex: ObservableObject {
    static let shared = CreditIndex()

    @Published private(set) var people: [String: CreditPerson] = [:]
    /// Library artists (normalised) — for "also an artist" links.
    private(set) var artistKeys: [String: String] = [:]   // key → display name
    private var pending: Task<Void, Never>?
    private var lastFingerprint: Int?
    /// name → normalised key, so links don't run the folding regexes on every render.
    private var keyCache: [String: String] = [:]

    func key(for name: String) -> String {
        if let k = keyCache[name] { return k }
        let k = CreditNames.key(name)
        keyCache[name] = k
        return k
    }

    /// The person behind a credited name when they're worth a profile (see `hasProfile`).
    func profile(for name: String) -> CreditPerson? {
        guard let p = people[key(for: name)], p.hasProfile else { return nil }
        return p
    }

    func artistName(for key: String) -> String? { artistKeys[key] }

    private struct Snapshot: Sendable {
        let id: UUID, artist: String
        let genius: [String: [GeniusCredit]]
        let track: [String: [Credit]]
        let album: [Credit]
        let bandcamp: String?
    }

    /// Schedule a rebuild from the library. Cheap to call on every library change.
    func rebuild(from albums: [Album]) {
        var h = Hasher()
        for a in albums {
            h.combine(a.id); h.combine(a.artist); h.combine(a.bcCredits)
            h.combine(a.geniusCredits?.count); h.combine(a.geniusCredits?.values.reduce(0) { $0 + $1.count })
            h.combine(a.trackCredits?.count); h.combine(a.credits?.count)
        }
        let fp = h.finalize()
        guard fp != lastFingerprint else { return }
        lastFingerprint = fp
        pending?.cancel()
        let snaps = albums.map {
            Snapshot(id: $0.id, artist: $0.artist, genius: $0.geniusCredits ?? [:], track: $0.trackCredits ?? [:],
                     album: $0.credits ?? [], bandcamp: $0.bcCredits)
        }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))   // coalesce bursts (sync, backfill)
            guard !Task.isCancelled else { return }
            let built = await Task.detached(priority: .utility) { Self.build(snaps) }.value
            guard !Task.isCancelled else { return }
            if artistKeys != built.artists { artistKeys = built.artists }
            if people != built.people { people = built.people }
        }
    }

    nonisolated private static func build(_ snaps: [Snapshot])
        -> (people: [String: CreditPerson], artists: [String: String]) {
        var people: [String: CreditPerson] = [:]
        var nameVotes: [String: [String: Int]] = [:]
        var artists: [String: String] = [:], albumArtist: [UUID: String] = [:]
        func add(_ name: String, _ role: String, _ album: UUID, _ track: String?) {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !CreditNames.isCompany(role: role, name: name) else { return }
            let k = CreditNames.key(name)
            guard !k.isEmpty else { return }
            people[k, default: CreditPerson(key: k, name: name, credits: [])]
                .credits.append(PersonCredit(albumID: album, track: track, role: role))
            nameVotes[k, default: [:]][name, default: 0] += 1
        }
        for s in snaps {
            let ak = CreditNames.key(s.artist)
            albumArtist[s.id] = ak
            for part in CreditNames.splitProse(s.artist) { artists[CreditNames.key(part)] = part }
            artists[ak] = s.artist
            for (title, list) in s.genius {
                for g in list { for n in CreditNames.splitList(g.names) { add(n, g.role, s.id, title) } }
            }
            for (key, list) in s.track {
                let title = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? key
                for c in list { add(c.name, c.role, s.id, title.lowercased()) }
            }
            for c in s.album { add(c.name, c.role, s.id, nil) }
            if let bc = s.bandcamp { for (r, n) in CreditNames.parseBandcamp(bc) { add(n, r, s.id, nil) } }
        }
        // De-duplicate, settle on the most common spelling, and derive the guest view.
        var unitPeople: [String: [String]] = [:]   // guest song unit → people on it
        for (k, var p) in people {
            var seen = Set<PersonCredit>()
            p.credits = p.credits.filter { seen.insert($0).inserted }
            if let best = nameVotes[k]?.max(by: { $0.value < $1.value })?.key { p.name = best }
            p.guest = p.credits.filter { c in
                guard let a = albumArtist[c.albumID] else { return true }
                return a != k && !a.components(separatedBy: ", ").contains(k)
            }
            let units = Set(p.guest.map(\.unit))
            p.guestSongCount = units.count
            p.guestRoles = CreditPerson.roles(p.guest)
            for u in units { unitPeople[u, default: []].append(k) }
            people[k] = p
        }
        // Collaborators: who shares the most guest songs, among people with a profile.
        var shared: [String: [String: Int]] = [:]
        for (_, ks) in unitPeople where ks.count > 1 {
            for a in ks where people[a]?.hasProfile == true {
                for b in ks where b != a && people[b]?.hasProfile == true { shared[a, default: [:]][b, default: 0] += 1 }
            }
        }
        for (k, counts) in shared {
            people[k]?.collaborators = counts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(10).map { CreditPerson.Collaborator(key: $0.key, shared: $0.value) }
        }
        return (people, artists)
    }
}

// MARK: - Background fill-in

/// Fills in Genius per-song credits for the whole library, slowly, once (Bandcamp liner notes are
/// already fetched by the album-cache warm-up). Results land in the saved library, so the credit
/// profiles work offline afterwards. Only a definite answer ("credits" or "Genius has none") marks
/// a song done — a failed lookup is retried next launch.
@MainActor
enum CreditBackfill {
    /// Albums whose Genius pass completed (separate from anything else, so adding a Genius token
    /// later still fills the existing library).
    private static let doneKey = "cabin.creditsBackfilled.genius"
    private static var running = false

    static func start(state: AppState) {
        guard !running, !AppState.isScreenshotRun else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            try? await Task.sleep(for: .seconds(45))   // let launch, sync and the UI settle first
            guard GeniusService.hasToken else { return }
            var done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
            for album in state.albums where !done.contains(album.id.uuidString) {
                // Don't add to Bandcamp traffic while the cache warm-up is fetching pages.
                while state.isWarmingAlbumCaches { try? await Task.sleep(for: .seconds(10)) }
                // Local files resolve instantly; Bandcamp tracklists come from the warm-up's cache.
                var tracks = TracklistCache.shared.displayTracks(for: album) ?? []
                if tracks.isEmpty, album.source != .bandcamp, album.isPlayable {
                    tracks = await state.resolveTracks(for: album, announce: false)
                }
                guard !tracks.isEmpty else { continue }   // tracklist unknown yet — next launch
                var found: [String: [GeniusCredit]] = [:]
                var failed = false
                for t in tracks {
                    let key = t.title.lowercased()
                    if state.album(id: album.id)?.geniusCredits?[key]?.isEmpty == false { continue }
                    switch await GeniusService.creditsLookup(artist: t.artist, title: t.title, album: album.title) {
                    case .found(let c): found[key] = c
                    case .none: break
                    case .failed: failed = true
                    }
                    try? await Task.sleep(for: .milliseconds(1200))
                }
                // One library write per album (each write rebuilds the library + credit index).
                if !found.isEmpty { state.cacheGeniusCredits(albumID: album.id, merging: found) }
                if !failed {
                    done.insert(album.id.uuidString)
                    UserDefaults.standard.set(Array(done), forKey: doneKey)
                }
            }
        }
    }
}

// MARK: - Clickable names

/// Opens a credit profile — set by RootView so credit names don't each observe the whole app.
private struct OpenCreditProfileKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil }
extension EnvironmentValues {
    var openCreditProfile: (@MainActor @Sendable (String) -> Void)? {
        get { self[OpenCreditProfileKey.self] }
        set { self[OpenCreditProfileKey.self] = newValue }
    }
}

/// A credited name. People worth a profile (2+ songs on others' records in your library) get a
/// dotted underline; hover firms it up with a ↗ and the hand cursor; click opens their credit
/// profile. Everyone else is plain text — no underline, no hover, not clickable.
struct CreditNameLink: View {
    let name: String
    var font: Font = .uiBody.weight(.medium)
    @ObservedObject private var index = CreditIndex.shared
    @Environment(\.openCreditProfile) private var open
    @Environment(\.palette) private var p
    @State private var hover = false

    var body: some View {
        if let open, let person = index.profile(for: name) {
            Button { open(person.key) } label: {
                Text(name).font(font).foregroundStyle(p.text)
                    .underline(true, pattern: hover ? .solid : .dot, color: p.text.opacity(hover ? 0.9 : 0.45))
                    // The ↗ floats past the trailing edge, so links and plain names line up.
                    .overlay(alignment: .trailing) {
                        Image(systemName: "arrow.up.right").font(.uiCaption.weight(.bold))
                            .foregroundStyle(p.muted).opacity(hover ? 1 : 0)
                            .offset(x: 13)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .modifier(LinkCursor())
            .help("\(CreditNames.count(person.guestSongCount, "song")) in your library")
            .accessibilityAddTraits(.isLink)
            .accessibilityHint("Opens their credits in your library")
        } else {
            Text(name).font(font).foregroundStyle(p.text)
        }
    }
}

/// A Genius name list ("A, B, C") as individual links, wrapping like text.
struct CreditNamesLine: View {
    let names: String
    var font: Font = .uiBody
    var body: some View {
        let list = CreditNames.splitList(names)
        WrapLayout(spacing: 0, lineSpacing: 2) {
            ForEach(Array(list.enumerated()), id: \.offset) { i, n in
                HStack(spacing: 0) {
                    CreditNameLink(name: n, font: font)
                    if i < list.count - 1 {
                        Text(", ").font(font).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

/// The people in an artist's free-text Bandcamp credits who have a profile, as a row of links
/// under the text (the text itself stays as written). Parsed once, not per render.
struct BandcampCreditPeople: View {
    private let names: [String]
    @ObservedObject private var index = CreditIndex.shared
    init(text: String) { names = Array(Set(CreditNames.parseBandcamp(text).map(\.name))).sorted() }
    var body: some View {
        let people = names.filter { index.profile(for: $0) != nil }
        if !people.isEmpty {
            WrapLayout(spacing: Space.s5, lineSpacing: Space.s1) {
                ForEach(people, id: \.self) { CreditNameLink(name: $0, font: .uiCallout.weight(.medium)) }
            }
        }
    }
}

/// Left-to-right wrapping layout (names flow like a sentence). Subviews wider than the line are
/// clamped to it so a long name wraps instead of overflowing.
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    private func sizes(_ subviews: Subviews, maxW: CGFloat) -> [CGSize] {
        subviews.map { v in
            let s = v.sizeThatFits(.unspecified)
            guard s.width > maxW, maxW.isFinite else { return s }
            return v.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for s in sizes(subviews, maxW: maxW) {
            if x > 0, x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for (v, s) in zip(subviews, sizes(subviews, maxW: bounds.width)) {
            if x > bounds.minX, x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

// MARK: - Credit profile page

/// A person's credits across your library. Built from the same parts as the artist and album
/// pages (header, section headings, track-style rows, glass pills); what sets it apart is the
/// CREDITS eyebrow, a monogram instead of artwork, and rows of roles rather than a cover grid.
struct CreditProfileView: View {
    let key: String
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var index = CreditIndex.shared
    @Environment(\.palette) private var p
    @State private var expanded: Set<UUID> = []
    /// Tracklists for expanded albums not in the display cache yet (for numbers + real titles).
    @State private var loadedTracks: [UUID: [Track]] = [:]

    private func tracks(for album: Album) -> [Track] {
        loadedTracks[album.id] ?? TracklistCache.shared.displayTracks(for: album) ?? []
    }
    @State private var loadingTracks: Set<UUID> = []
    private func ensureTracks(_ album: Album) {
        guard tracks(for: album).isEmpty, loadingTracks.insert(album.id).inserted else { return }
        Task {
            loadedTracks[album.id] = await state.resolveTracks(for: album, announce: false)
            loadingTracks.remove(album.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            if let person = index.people[key] {
                let guest = person.guest
                header(person, guest: guest)
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s7) {
                        recordsSection(guest)
                        timelineSection(guest)
                        collaboratorsSection(person)
                    }
                    .padding(.top, Space.s2)
                    .padding(.bottom, state.playerBarHeight + Space.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                // Open on the album they're on most, so the songs show straight away.
                .onAppear {
                    if expanded.isEmpty, let top = orderedAlbums(guest).first { expanded = [top.id]; ensureTracks(top) }
                }
            } else {
                Text("No credits for this person in your library.").font(.uiBody).foregroundStyle(p.muted)
            }
        }
        .padding(.horizontal, Space.s7).padding(.bottom, Space.s7)
        .padding(.top, Space.s4)   // Back sits in the title-bar row above
        .clipShape(Rectangle())
    }

    // MARK: Header

    private func header(_ person: CreditPerson, guest: [PersonCredit]) -> some View {
        let songs = person.guestSongCount
        let albums = Set(guest.map(\.albumID)).count
        let roles = person.guestRoles.prefix(3)
        let artist = index.artistName(for: person.key)
        let subtitle = ([roles.joined(separator: " · ")].filter { !$0.isEmpty }
                        + ["\(CreditNames.count(songs, "song")) on \(albums) of your \(albums == 1 ? "album" : "albums")"])
            .joined(separator: " — ")
        return HStack(alignment: .center, spacing: Space.s4) {
            Text(initials(person.name))
                .font(.uiTitle3.weight(.bold)).foregroundStyle(p.text)
                .frame(width: 56, height: 56)
                .background(Circle().fill(p.glassFill))
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("CREDITS").font(.uiSubheadline).kerning(1).foregroundStyle(p.muted2)
                Text(person.name).font(.system(size: 30, weight: .bold)).kerning(-0.6)
                    .foregroundStyle(p.text).lineLimit(1).truncationMode(.tail)
                    .help(person.name).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.uiBody).foregroundStyle(p.muted).lineLimit(1).help(subtitle)
            }
            Spacer(minLength: Space.s3)
            HStack(spacing: Space.s2) {
                pill("Play Their Songs", systemImage: "play.fill") { playAll(guest) }
                // Bandcamp's own search for the name — more of their work you don't own yet.
                if let url = bandcampSearchURL(person.name) {
                    pill("Find on Bandcamp", systemImage: "safari") { NSWorkspace.shared.open(url) }
                }
                if let artist {
                    pill("Artist Page", systemImage: "music.mic") {
                        state.openArtist(artist)
                    }
                }
            }
        }
    }

    private func pill(_ title: String, systemImage: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.uiCallout)
                Text(title).font(.uiBody.weight(.semibold))
            }
        }
        .modifier(GlassButton())
        .controlSize(.large)
    }

    // MARK: Records

    private func recordsSection(_ guest: [PersonCredit]) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeading("ON YOUR RECORDS")
            VStack(spacing: 0) {
                ForEach(orderedAlbums(guest), id: \.id) { album in
                    albumRow(album, credits: guest.filter { $0.albumID == album.id })
                }
            }
        }
    }

    private func albumRow(_ album: Album, credits: [PersonCredit]) -> some View {
        let open = expanded.contains(album.id)
        let roles = Array(Set(credits.map(\.role))).sorted()
        let songCount = Set(credits.compactMap(\.track)).count
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.fluid) {
                    if open { expanded.remove(album.id) } else { expanded.insert(album.id); ensureTracks(album) }
                }
            } label: {
                HStack(spacing: Space.s4) {
                    AlbumArt(album: album, corner: 8).frame(width: 44, height: 44).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title).font(.uiBody.weight(.semibold)).foregroundStyle(p.text)
                            .lineLimit(1).help(album.title)
                        Text(album.artist).font(.uiCallout).foregroundStyle(p.muted).lineLimit(1)
                    }
                    Spacer(minLength: Space.s4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(roles.prefix(2).joined(separator: ", ") + (roles.count > 2 ? " +\(roles.count - 2)" : ""))
                            .font(.uiCallout).foregroundStyle(p.muted).lineLimit(1)
                            .help(roles.joined(separator: ", "))
                        if songCount > 0 {
                            Text(CreditNames.count(songCount, "song"))
                                .font(.uiSubheadline.monospacedDigit()).foregroundStyle(p.muted2)
                        }
                    }
                    Image(systemName: "chevron.right").font(.uiSubheadline.weight(.semibold))
                        .foregroundStyle(p.muted2).rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, Space.s2).padding(.horizontal, Space.s3)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: 10, active: open)
            }
            .buttonStyle(.soft(hover: 1.0, press: Press.surface, brighten: 0))
            .accessibilityLabel("\(album.title), \(album.artist), \(roles.joined(separator: ", "))")
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    let bySong = Dictionary(grouping: credits, by: { $0.track })
                    let tracks = tracks(for: album)
                    // lowercased title → (index, real title), built once per render of the row.
                    let lookup = Dictionary(tracks.enumerated().map { ($1.title.lowercased(), ($0, $1.title)) },
                                            uniquingKeysWith: { a, _ in a })
                    let order: (String?) -> Int = { t in t.map { lookup[$0]?.0 ?? Int.max } ?? -1 }
                    ForEach(bySong.keys.sorted { order($0) < order($1) }, id: \.self) { title in
                        CreditSongRow(number: title.flatMap { lookup[$0].map { $0.0 + 1 } },
                                      title: title.map { lookup[$0]?.1 ?? $0.capitalized } ?? "Whole Album",
                                      roles: Array(Set((bySong[title] ?? []).map(\.role))).sorted(),
                                      playable: album.isPlayable) { play(album, title: title) }
                    }
                    Button { state.openedAlbumID = album.id } label: {
                        Label("Open Album", systemImage: "arrow.right").font(.uiCallout.weight(.semibold))
                    }
                    .modifier(GlassButton())
                    .padding(.top, Space.s2).padding(.bottom, Space.s3)
                }
                .padding(.leading, 44 + Space.s4)
                .transition(.opacity)
            }
        }
    }

    // MARK: Over the years

    /// Their credits on your records by release year — how the roles moved over time. Shown once
    /// at least two different years are known (years come from tags / Bandcamp release dates).
    @ViewBuilder private func timelineSection(_ guest: [PersonCredit]) -> some View {
        let byYear = Dictionary(grouping: guest) { c -> String? in
            guard let y = state.album(id: c.albumID)?.year.prefix(4), y.count == 4, Int(y) != nil else { return nil }
            return String(y)
        }
        let years = byYear.keys.compactMap { $0 }.sorted()
        if years.count >= 2 {
            VStack(alignment: .leading, spacing: Space.s3) {
                sectionHeading("OVER THE YEARS")
                VStack(spacing: 0) {
                    ForEach(years, id: \.self) { year in
                        let credits = byYear[year] ?? []
                        let albums = Array(Set(credits.map(\.albumID))).compactMap { state.album(id: $0) }
                            .sorted { $0.title < $1.title }
                        let roles = CreditPerson.roles(credits).prefix(3).joined(separator: ", ")
                        HStack(spacing: Space.s4) {
                            Text(year).font(.uiBody.weight(.bold).monospacedDigit()).foregroundStyle(p.text)
                                .frame(width: 44, alignment: .leading)
                            Text(roles).font(.uiCallout).foregroundStyle(p.muted).lineLimit(1).help(roles)
                            Spacer(minLength: Space.s3)
                            HStack(spacing: -6) {
                                ForEach(albums.prefix(5), id: \.id) { a in
                                    AlbumArt(album: a, corner: 5).frame(width: 26, height: 26).help(a.title)
                                }
                            }
                        }
                        .padding(.vertical, Space.s2).padding(.horizontal, Space.s3)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(year): \(roles). \(albums.map(\.title).joined(separator: ", "))")
                    }
                }
            }
        }
    }

    private func bandcampSearchURL(_ name: String) -> URL? {
        var c = URLComponents(string: "https://bandcamp.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: name)]
        return c?.url
    }

    // MARK: Worked with

    @ViewBuilder private func collaboratorsSection(_ person: CreditPerson) -> some View {
        let team = person.collaborators.compactMap { c in index.people[c.key].map { (person: $0, shared: c.shared) } }
        if !team.isEmpty {
            VStack(alignment: .leading, spacing: Space.s3) {
                sectionHeading("WORKED WITH")
                WrapLayout(spacing: Space.s5, lineSpacing: Space.s3) {
                    ForEach(team, id: \.person.key) { t in
                        HStack(spacing: Space.s1) {
                            CreditNameLink(name: t.person.name, font: .uiBody.weight(.medium))
                            Text("\(t.shared)").font(.uiSubheadline.monospacedDigit()).foregroundStyle(p.muted2)
                                .help("\(CreditNames.count(t.shared, "song")) together")
                                .accessibilityLabel("\(CreditNames.count(t.shared, "song")) together")
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func play(_ album: Album, title: String?) {
        guard let title else { state.play(album, on: player); return }
        state.nowPlayingAlbumID = album.id
        Task {
            let tracks = await state.resolveTracks(for: album)
            let i = tracks.firstIndex { $0.title.lowercased() == title } ?? 0
            if !tracks.isEmpty { player.play(tracks, startAt: i) }
        }
    }

    /// Queue every song they're credited on, album by album (whole albums for album-wide credits).
    private func playAll(_ guest: [PersonCredit]) {
        let albums = orderedAlbums(guest)
        Task {
            var queue: [Track] = []
            for album in albums {
                let tracks = await state.resolveTracks(for: album)
                let titles = Set(guest.filter { $0.albumID == album.id }.compactMap(\.track))
                queue += titles.isEmpty ? tracks : tracks.filter { titles.contains($0.title.lowercased()) }
            }
            if !queue.isEmpty { player.play(queue) }
        }
    }

    private func orderedAlbums(_ credits: [PersonCredit]) -> [Album] {
        var counts: [UUID: Int] = [:]
        for c in credits { counts[c.albumID, default: 0] += 1 }
        return counts.keys.compactMap { state.album(id: $0) }.sorted {
            let a = counts[$0.id] ?? 0, b = counts[$1.id] ?? 0
            return a != b ? a > b : $0.title < $1.title
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text).font(.uiSubheadline.weight(.bold)).kerning(1).foregroundStyle(p.muted2)
            .accessibilityAddTraits(.isHeader)
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// One song on a credit profile — the album page's track row (number ↔ play on hover), with the
/// person's role where the like / more buttons would be.
private struct CreditSongRow: View {
    let number: Int?
    let title: String
    let roles: [String]
    let playable: Bool
    let onPlay: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: Space.s4) {
                ZStack {
                    Text(number.map(String.init) ?? "–").font(.uiBody.monospacedDigit())
                        .foregroundStyle(p.muted2).opacity(hovering && playable ? 0 : 1)
                    Image(systemName: "play.fill").font(.uiSubheadline)
                        .foregroundStyle(p.text).opacity(hovering && playable ? 1 : 0)
                }
                .frame(width: 26)
                .animation(.easeInOut(duration: 0.12), value: hovering)
                Text(title).font(.system(size: 14)).foregroundStyle(p.text.opacity(0.85))
                    .lineLimit(1).help(title).layoutPriority(1)
                Spacer(minLength: Space.s3)
                Text(roles.joined(separator: ", ")).font(.uiCallout).foregroundStyle(p.muted).lineLimit(1)
                    .help(roles.joined(separator: ", "))
            }
            .padding(.vertical, Space.s2).padding(.horizontal, Space.s3)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 10)
        }
        .buttonStyle(.soft(hover: 1.0, press: Press.surface, brighten: 0))
        .disabled(!playable)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(roles.joined(separator: ", "))")
    }
}
