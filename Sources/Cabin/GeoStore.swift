import Foundation
import CoreLocation

/// A geocoded place: coordinates plus the resolved country name (for the "top country" stat).
struct GeoPoint: Codable, Equatable {
    let lat: Double
    let lon: Double
    let country: String?
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// Turns Bandcamp artist-location strings ("Berlin, Germany") into map coordinates via Apple's
/// on-device-friendly `CLGeocoder` — no API key. Results (and the country) are cached to disk so
/// each distinct place is geocoded once; misses are remembered in-memory to avoid re-hitting the
/// rate-limited geocoder in a session. Mirrors `BPMStore`'s persistence.
@MainActor
final class GeoStore: ObservableObject {
    static let shared = GeoStore()

    @Published private(set) var map: [String: GeoPoint]   // key = normalised location string
    private var misses: Set<String> = []
    private let geocoder = CLGeocoder()

    private init() { map = Self.load() }

    nonisolated static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func point(for location: String) -> GeoPoint? { map[Self.key(location)] }

    /// Geocode any of `locations` we don't already have. Sequential + gently throttled because
    /// `CLGeocoder` rejects rapid/concurrent requests; publishes each result as it lands so an
    /// open map fills in progressively.
    func resolve(_ locations: [String]) async {
        let pending = Set(locations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { !$0.isEmpty }
        for loc in pending {
            if Task.isCancelled { return }   // don't record cancelled requests as misses
            let k = Self.key(loc)
            if map[k] != nil || misses.contains(k) { continue }
            if let placemarks = try? await geocoder.geocodeAddressString(loc),
               let placemark = placemarks.first, let c = placemark.location?.coordinate {
                map[k] = GeoPoint(lat: c.latitude, lon: c.longitude, country: placemark.country)
                save()
            } else if !Task.isCancelled {
                misses.insert(k)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: Persistence

    private static let ioQueue = DispatchQueue(label: "com.cabin.geo.io", qos: .utility)

    private func save() {
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
        return dir.appendingPathComponent("geo.json")
    }

    private nonisolated static func load() -> [String: GeoPoint] {
        guard let data = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: GeoPoint].self, from: data) else { return [:] }
        return m
    }
}
