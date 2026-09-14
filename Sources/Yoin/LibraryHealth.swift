import Foundation

/// One album flagged by the library-health scan, with a human reason and whether a
/// Bandcamp re-download could fix it.
struct LibraryIssue: Identifiable, Equatable {
    /// What kind of problem this is, so the UI can group + prioritise (lost first).
    enum Kind: Equatable {
        case lost         // removed from Bandcamp, no offline copy — the stream is gone
        case archived     // removed from Bandcamp, but downloaded — safe, just no longer online
        case missingFile  // local files are gone from disk
        case noSource     // nothing to play it from at all
    }
    let id: UUID          // album id
    let title: String
    let artist: String
    let reason: String
    let canRedownload: Bool
    var kind: Kind = .noSource
}

enum LibraryHealth {
    /// Probe each Bandcamp album page with bounded concurrency and report its availability.
    /// A `.removed` verdict is confirmed with a second probe so one transient glitch (a momentary
    /// 404, a rate-limit page) can't wrongly mark an album dead. `progress` reports how many
    /// probes have finished.
    static func availability(_ targets: [(id: UUID, url: String)],
                             identity: String,
                             progress: @Sendable @escaping (Int) -> Void) async -> [UUID: BandcampClient.AlbumProbe] {
        var out: [UUID: BandcampClient.AlbumProbe] = [:]
        var done = 0
        let maxConcurrent = min(6, max(1, targets.count))
        var iterator = targets.makeIterator()

        await withTaskGroup(of: (UUID, BandcampClient.AlbumProbe).self) { group in
            func addNext() {
                guard let t = iterator.next() else { return }
                group.addTask {
                    let client = BandcampClient(identity: identity)
                    var result = await client.probe(forItemURL: t.url)
                    // Only a *confirmed* removal counts: re-probe once and trust the second read,
                    // so a single flaky response never surfaces as "removed from Bandcamp".
                    if case .removed = result {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        result = await client.probe(forItemURL: t.url)
                    }
                    return (t.id, result)
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            for await (id, r) in group {
                out[id] = r
                done += 1
                progress(done)
                addNext()
            }
        }
        return out
    }
}
