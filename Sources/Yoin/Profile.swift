import Foundation
import AppKit

/// The user's display identity for recaps/shares: a name and a (cropped) avatar.
struct Profile: Codable, Equatable {
    var name: String = ""
    /// Square PNG data for the avatar, already cropped. Nil = no photo set.
    var avatar: Data? = nil

    var avatarImage: NSImage? { avatar.flatMap { NSImage(data: $0) } }
    var hasName: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Persists the profile next to the library.
enum ProfileStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Vinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }

    static func load() -> Profile {
        guard let data = try? Data(contentsOf: fileURL),
              let profile = try? JSONDecoder().decode(Profile.self, from: data) else { return Profile() }
        return profile
    }

    static func save(_ profile: Profile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
