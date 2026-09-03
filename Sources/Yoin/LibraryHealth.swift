import Foundation

/// One album flagged by the library-health scan, with a human reason and whether a
/// Bandcamp re-download could fix it.
struct LibraryIssue: Identifiable, Equatable {
    let id: UUID          // album id
    let title: String
    let artist: String
    let reason: String
    let canRedownload: Bool
}

enum LibraryHealth {
    /// Probe Bandcamp stream pages with bounded concurrency; returns the ids that failed to
    /// resolve any playable track (removed, private, or otherwise unstreamable). `progress`
    /// reports how many probes have finished.
    static func unreachable(_ targets: [(id: UUID, url: String)],
                            identity: String,
                            progress: @Sendable @escaping (Int) -> Void) async -> Set<UUID> {
        var bad = Set<UUID>()
        var done = 0
        let maxConcurrent = min(6, max(1, targets.count))
        var iterator = targets.makeIterator()

        await withTaskGroup(of: (UUID, Bool).self) { group in
            func addNext() {
                guard let t = iterator.next() else { return }
                group.addTask {
                    let ok = ((try? await BandcampClient(identity: identity).tracks(forItemURL: t.url))?.isEmpty == false)
                    return (t.id, ok)
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            for await (id, ok) in group {
                if !ok { bad.insert(id) }
                done += 1
                progress(done)
                addNext()
            }
        }
        return bad
    }
}
