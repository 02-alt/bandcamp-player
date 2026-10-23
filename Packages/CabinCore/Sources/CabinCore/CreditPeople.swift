import Foundation

// MARK: - Model

/// One credit a person holds in the library: a role on a song (or on the whole album when the
/// source isn't per-track, e.g. the artist's Bandcamp credits).
public struct PersonCredit: Hashable, Sendable {
    public let albumID: UUID
    /// Song title (lowercased), or nil for an album-wide credit.
    public let track: String?
    public let role: String
    public var unit: String { "\(albumID)|\(track ?? "")" }
}

/// Everyone credited across the library, keyed by a normalised name. The derived numbers are
/// computed once when the index is built, never in a view body.
public struct CreditPerson: Identifiable, Sendable, Equatable {
    public let key: String
    public var name: String
    public var credits: [PersonCredit]
    /// Credits on *other* artists' records (their own albums live on their artist page).
    public var guest: [PersonCredit] = []
    /// Distinct songs among `guest` (album-wide credits count once per album).
    public var guestSongCount = 0
    /// Most frequent guest roles first.
    public var guestRoles: [String] = []
    /// The people who share the most guest songs with them: (key, shared songs).
    public var collaborators: [Collaborator] = []
    public var id: String { key }
    /// Worth a profile: credited on 2+ songs of other artists' records in your library.
    public var hasProfile: Bool { guestSongCount >= 2 }

    public struct Collaborator: Hashable, Sendable {
        public let key: String
        public let shared: Int
        public init(key: String, shared: Int) { self.key = key; self.shared = shared }
    }

    public static func roles(_ credits: [PersonCredit]) -> [String] {
        var counts: [String: Int] = [:]
        for c in credits { counts[c.role, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// Name handling shared by the index and the views.
public enum CreditNames {
    /// "1 song" / "3 songs".
    public static func count(_ n: Int, _ noun: String) -> String { "\(n) \(n == 1 ? noun : noun + "s")" }

    /// Normalised identity: case/diacritic-folded, Discogs "(2)" suffixes dropped, spaces collapsed.
    public static func key(_ name: String) -> String {
        var s = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        s = s.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a Genius name list. Genius joins names with ", " — split only on that, so names that
    /// contain "&" / "and" ("Simon & Garfunkel") stay whole.
    public static func splitList(_ joined: String) -> [String] {
        joined.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Split free text ("A, B & C and D") into names — for the artist's hand-written credits.
    public static func splitProse(_ joined: String) -> [String] {
        splitList(joined.replacingOccurrences(of: " & ", with: ", ").replacingOccurrences(of: " and ", with: ", ")
            .replacingOccurrences(of: ",", with: ", ").replacingOccurrences(of: ",  ", with: ", "))
    }

    private static let companyRoles = ["label", "copyright", "phonographic", "distribut", "publish",
                                       "marketing", "management", "a&r administration", "licens"]
    /// Company words, matched as whole words ("label" must not catch "LaBelle").
    private static let companyWords = ["records", "recordings", "music group", "entertainment", "ltd",
                                       "llc", "inc", "gmbh", "publishing", "label", "studios",
                                       "studio", "mastering", "productions"]
    private static let companyPattern = try? NSRegularExpression(
        pattern: "\\b(" + companyWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b",
        options: [.caseInsensitive])
    /// Lines in an artist's credits that aren't about who made the music.
    private static let nonCreditRoles = ["thank", "follow", "contact", "booking", "email", "e-mail", "lyrics",
                                         "merch", "instagram", "twitter", "website", "support", "special", "dedicat"]

    /// Labels, publishers, studios and other companies don't get a profile — not collaborators.
    public static func isCompany(role: String, name: String) -> Bool {
        let r = role.lowercased()
        if companyRoles.contains(where: { r.contains($0) }) || name.contains("℗") || name.contains("©") { return true }
        let range = NSRange(name.startIndex..., in: name)
        return companyPattern?.firstMatch(in: name, range: range) != nil
    }

    /// People out of the artist's free-text Bandcamp credits. Only the common, unambiguous shapes:
    /// "Role: Name, Name" and "Role by Name (at Place)". Lines that don't match are skipped.
    public static func parseBandcamp(_ text: String) -> [(role: String, name: String)] {
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


/// Builds everyone credited across a library from per-album credit snapshots. Pure — runs off
/// the main thread; the app's CreditIndex publishes the result.
public enum CreditIndexBuilder {
    public struct Snapshot: Sendable {
        public let id: UUID, artist: String
        public let genius: [String: [GeniusCredit]]
        public let track: [String: [Credit]]
        public let album: [Credit]
        public let bandcamp: String?
        public init(id: UUID, artist: String, genius: [String: [GeniusCredit]], track: [String: [Credit]],
                    album: [Credit], bandcamp: String?) {
            self.id = id; self.artist = artist; self.genius = genius; self.track = track
            self.album = album; self.bandcamp = bandcamp
        }
    }

    public static func build(_ snaps: [Snapshot])
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
