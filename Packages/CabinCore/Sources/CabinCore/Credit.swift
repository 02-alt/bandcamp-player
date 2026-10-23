import Foundation

/// One personnel credit (role → name), Tidal-style — from Discogs / MusicBrainz enrichment or a
/// track's own credits.
public struct Credit: Codable, Hashable, Identifiable, Sendable {
    public var role: String
    public var name: String
    public var id: String { "\(role)—\(name)" }
    public init(role: String, name: String) { self.role = role; self.name = name }
}
