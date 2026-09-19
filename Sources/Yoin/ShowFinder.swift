import SwiftUI
import AppKit

// MARK: - Model

/// One upcoming live date for an artist, as returned by Bandsintown.
struct LiveShow: Identifiable, Codable, Equatable {
    let id: String
    let date: Date
    let venue: String
    let city: String
    let region: String
    let country: String
    let eventURL: String?      // the Bandsintown event page
    let ticketURL: String?     // a "buy tickets" offer, when one is listed

    /// "Venue · City, Region, Country" with empties dropped.
    var place: String {
        let where_ = [city, region, country].filter { !$0.isEmpty }.joined(separator: ", ")
        return [venue, where_].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Preferences

/// Show Finder's Bandsintown app id. Bandsintown now rejects unregistered ids (the public events
/// endpoint returns an authorization deny for any arbitrary string), so this is opt-in: tour dates
/// appear only once the user pastes their own (free) Bandsintown app id — mirroring the Last.fm /
/// Genius / Discogs pattern. Absent = feature hidden, never blocking.
enum ShowFinderPrefs {
    static let account = "bandsintown_app_id"
    static var appID: String? {
        get { Keychain.get(account: account).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, account: account) }
            else { Keychain.delete(account: account) }
        }
    }
}

// MARK: - Service

/// Fetches upcoming shows from Bandsintown (https://rest.bandsintown.com) and memoises results —
/// including "no shows" misses — on disk with a short TTL, so an artist page hits the network at
/// most once every few hours. Every path degrades to "no shows" (empty) on any error.
enum ShowFinderService {
    private static let session = URLSession(configuration: .default)
    private static let userAgent = "Yoin (+https://github.com/02-alt/bandcamp-player)"
    /// Tour schedules change; re-check a cached artist after this long.
    private static let ttl: TimeInterval = 60 * 60 * 12   // 12 hours

    /// Upcoming shows for `artist`, or [] when there are none / no key / offline.
    @MainActor
    static func shows(forArtist artist: String) async -> [LiveShow] {
        guard let appID = ShowFinderPrefs.appID, !artist.isEmpty else { return [] }
        let key = artist.lowercased()
        if let c = ShowsStore.shared.cached(key), Date().timeIntervalSince(c.fetchedAt) < ttl {
            return c.shows
        }
        // fetch → nil on a transient error (keep any stale cache), [] on a valid "no shows".
        if let fresh = await fetch(artist: artist, appID: appID) {
            ShowsStore.shared.store(.init(fetchedAt: Date(), shows: fresh), for: key)
            ShowsStore.shared.save()
            return fresh
        }
        return ShowsStore.shared.cached(key)?.shows ?? []
    }

    private static func fetch(artist: String, appID: String) async -> [LiveShow]? {
        // Bandsintown puts the artist name in the path; "/" in a name must be double-encoded.
        let allowed = CharacterSet.urlPathAllowed
        let name = (artist.addingPercentEncoding(withAllowedCharacters: allowed) ?? artist)
            .replacingOccurrences(of: "/", with: "%252F")
        guard var comps = URLComponents(string: "https://rest.bandsintown.com/artists/\(name)/events") else { return [] }
        comps.queryItems = [.init(name: "app_id", value: appID), .init(name: "date", value: "upcoming")]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            // 404 = unknown artist (a real miss); other non-2xx = transient (keep stale).
            guard http.statusCode == 200 else { return http.statusCode == 404 ? [] : nil }
            // A non-array body (Bandsintown's error/"not found" object) decodes as a known miss.
            guard let events = try? JSONDecoder().decode([APIEvent].self, from: data) else { return [] }
            return events.compactMap { e -> LiveShow? in
                guard let dt = e.datetime, let date = df.date(from: dt) else { return nil }
                let ticket = e.offers?.first { ($0.type ?? "").localizedCaseInsensitiveContains("ticket") }?.url
                return LiveShow(id: e.id ?? UUID().uuidString, date: date,
                                venue: e.venue?.name ?? "", city: e.venue?.city ?? "",
                                region: e.venue?.region ?? "", country: e.venue?.country ?? "",
                                eventURL: e.url, ticketURL: ticket)
            }.sorted { $0.date < $1.date }
        } catch { return nil }
    }

    // Bandsintown JSON.
    private struct APIEvent: Decodable {
        let id: String?
        let url: String?
        let datetime: String?
        let venue: APIVenue?
        let offers: [APIOffer]?
    }
    private struct APIVenue: Decodable { let name: String?; let city: String?; let region: String?; let country: String? }
    private struct APIOffer: Decodable { let type: String?; let url: String?; let status: String? }

    /// Bandsintown datetimes are local, ISO-8601 without a timezone.
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

// MARK: - Cache

/// Persistent cache of upcoming shows keyed by lowercased artist name. Mirrors `LyricsStore`:
/// synchronous load on init, debounced off-main writes. Entries carry a `fetchedAt` so the
/// service can expire them (tour dates go stale); an empty `shows` array is a valid known-miss.
@MainActor
final class ShowsStore {
    static let shared = ShowsStore()

    struct Cached: Codable { let fetchedAt: Date; let shows: [LiveShow] }

    private var map: [String: Cached]
    private init() { map = Self.load() }

    func cached(_ key: String) -> Cached? { map[key] }
    func store(_ c: Cached, for key: String) { map[key] = c }

    private static let ioQueue = DispatchQueue(label: "com.yoin.shows.io", qos: .utility)

    func save() {
        let snapshot = map
        Self.ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private nonisolated static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shows.json")
    }

    private nonisolated static func load() -> [String: Cached] {
        guard let data = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: Cached].self, from: data) else { return [:] }
        return m
    }
}

// MARK: - View

/// Reusable "Upcoming shows" section, shared by the Artist page and the Album page. Fetches on
/// appear and renders nothing at all when there's no key or no shows — so it never leaves an empty
/// heading behind. Set `leadingDivider` to match the album page's footer sections.
struct TourDatesView: View {
    let artist: String
    var leadingDivider: Bool = false

    @Environment(\.palette) private var p
    @State private var shows: [LiveShow] = []
    @State private var loaded = false

    private let maxShown = 12

    var body: some View {
        Group {
            if !shows.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if leadingDivider { Divider().overlay(p.edgeSoft).padding(.vertical, Space.s2) }
                    HStack(spacing: 7) {
                        Image(systemName: "music.note.house").font(.system(size: 12)).foregroundStyle(p.muted2)
                        Text("UPCOMING SHOWS").font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
                    }
                    VStack(spacing: Space.s2) {
                        ForEach(shows.prefix(maxShown)) { row($0) }
                    }
                    if shows.count > maxShown {
                        Text("+ \(shows.count - maxShown) more").font(.system(size: 11)).foregroundStyle(p.muted2)
                    }
                    Text("via Bandsintown").font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted2)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.top, leadingDivider ? Space.s3 : 0)
            }
        }
        .task(id: artist) {
            guard !loaded else { return }
            loaded = true
            shows = await ShowFinderService.shows(forArtist: artist)
        }
    }

    private func row(_ show: LiveShow) -> some View {
        Button {
            open(show.eventURL)
        } label: {
            HStack(spacing: Space.s3) {
                dateBadge(show.date)
                VStack(alignment: .leading, spacing: 1) {
                    Text(show.venue.isEmpty ? show.city : show.venue)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.tail)
                    Text([show.city, show.region, show.country].filter { !$0.isEmpty }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: Space.s2)
                if let t = show.ticketURL {
                    ticketPill { open(t) }
                }
            }
            .padding(.vertical, 6).padding(.horizontal, Space.s3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.glassFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .modifier(LinkCursor())
        .help(show.place)
    }

    private func dateBadge(_ date: Date) -> some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 10, weight: .bold)).foregroundStyle(p.muted2)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
        }
        .frame(width: 40)
    }

    private func ticketPill(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Tickets").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text)
                .padding(.vertical, 5).padding(.horizontal, Space.s3)
                .background(Capsule().fill(p.glassFill))
                .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
        .modifier(LinkCursor())
    }

    private func open(_ s: String?) {
        if let s, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}
