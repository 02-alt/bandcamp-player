import Foundation

/// What a saved radio station is seeded from. A station is a *recipe*, not a fixed track
/// list — playing it regenerates fresh from the library (like a smart playlist).
enum RadioSeed: Codable, Equatable {
    case mood(Mood)
    case artist(String)
    case album(title: String, artist: String)   // by name, so it survives a re-sync's new ids

    var icon: String {
        switch self {
        case .mood(let m): return m.symbol
        case .artist: return "person.fill"
        case .album: return "square.stack"
        }
    }
    var kindLabel: String {
        switch self {
        case .mood: return "Mix"
        case .artist: return "Artist"
        case .album: return "Album"
        }
    }
}

/// A named, persisted radio station.
struct SavedRadio: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var seed: RadioSeed
    var createdAt = Date()
}

enum SavedRadioStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("radios.json")
    }
    static func load() -> [SavedRadio] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([SavedRadio].self, from: data) else { return [] }
        return list
    }
    static func save(_ list: [SavedRadio]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
