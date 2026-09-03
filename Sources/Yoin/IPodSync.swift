import Foundation
import AVFoundation

extension Notification.Name {
    /// Posted after the iPod database changes, so the iPod tab reloads.
    static let ipodDBChanged = Notification.Name("yoin.ipodDBChanged")
}

extension AppState {
    /// Add downloaded albums to the connected iPod: transcode each track to ALAC, copy it into
    /// `iPod_Control/Music/`, and register it in the (checksum-signed) database. Backs the DB up
    /// first and restores it on failure. Only albums with local audio files can be added.
    func addToIPod(_ ids: Set<UUID>, device: IPodDevice) {
        guard let serial = device.serial else {
            showNotice("Couldn't read the iPod's ID — reconnect it and try again."); return
        }
        // Snapshot the source files + metadata on the main actor (Album isn't Sendable).
        var jobs: [IPodSyncEngine.Job] = []
        for a in albums where ids.contains(a.id) {
            let files = a.localTracks ?? a.url.map { [$0] } ?? []
            for f in files {
                jobs.append(.init(file: f,
                                  title: FilenameCleaner.trackTitle(f.deletingPathExtension().lastPathComponent),
                                  artist: a.artist, album: a.title, genre: a.genre ?? ""))
            }
        }
        guard !jobs.isEmpty else {
            showNotice("Download the album first — only local files can be copied to the iPod."); return
        }
        let count = jobs.count
        let vol = device.volumeURL, dbURL = device.iTunesDBURL
        showNotice("Adding \(count) song\(count == 1 ? "" : "s") to iPod…")
        Task {
            // `run` is nonisolated async → executes off the main actor (the transcode/copy/write
            // is heavy); we hop back here on the main actor to report.
            let message = await IPodSyncEngine.run(jobs: jobs, volume: vol, dbURL: dbURL, serial: serial)
            showNotice(message)
            NotificationCenter.default.post(name: .ipodDBChanged, object: nil)
        }
    }
}

extension AppState {
    /// Remove tracks from the connected iPod (deletes DB entries + audio files). Destructive;
    /// backs the DB up first and restores it if the write fails.
    func removeFromIPod(_ tracks: [IPodTrack], device: IPodDevice) {
        guard let serial = device.serial else { showNotice("Couldn't read the iPod's ID."); return }
        let ids = Set(tracks.map(\.trackID)).filter { $0 != 0 }
        // Only ever touch real file paths — an empty location would resolve to the volume root.
        let locations = tracks.map(\.location).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let vol = device.volumeURL, dbURL = device.iTunesDBURL
        showNotice("Removing \(ids.count) song\(ids.count == 1 ? "" : "s") from iPod…")
        Task {
            let msg = await IPodSyncEngine.remove(trackIDs: ids, locations: locations,
                                                  volume: vol, dbURL: dbURL, serial: serial)
            showNotice(msg)
            NotificationCenter.default.post(name: .ipodDBChanged, object: nil)
        }
    }

    /// Copy tracks from the iPod into Yoin's library (import as local albums). Non-destructive.
    func downloadFromIPod(_ albums: [(title: String, artist: String, tracks: [IPodTrack])], device: IPodDevice) {
        let vol = device.volumeURL
        let payload = albums.map { a in
            IPodSyncEngine.ImportGroup(title: a.title, artist: a.artist,
                tracks: a.tracks.filter { !$0.location.isEmpty }.map {
                    IPodSyncEngine.SrcTrack(title: $0.title, url: deviceURL(for: $0.location, volume: vol))
                })
        }
        let total = payload.reduce(0) { $0 + $1.tracks.count }
        guard total > 0 else { return }
        showNotice("Downloading \(total) song\(total == 1 ? "" : "s") to your library…")
        Task {
            let imported = await IPodSyncEngine.importToLibrary(payload)
            var added = 0
            for g in imported where !g.files.isEmpty {
                var album = Album(title: g.title, artist: g.artist.isEmpty ? "Unknown Artist" : g.artist,
                                  year: "", format: "\(g.files.count) track\(g.files.count == 1 ? "" : "s")",
                                  lossless: false, g0: 0.28, g1: 0.08)
                album.source = .local
                album.localTracks = g.files
                albums_insert(album)
                added += g.files.count
                Task { await enrich(albumID: album.id) }
            }
            persist()
            showNotice(added > 0 ? "Added \(added) song\(added == 1 ? "" : "s") to your library."
                                 : "Couldn't copy those tracks.")
        }
    }

    private func albums_insert(_ a: Album) { albums.insert(a, at: 0) }

    private func deviceURL(for location: String, volume: URL) -> URL {
        // ":iPod_Control:Music:F09:DVSI.mp3" → <volume>/iPod_Control/Music/F09/DVSI.mp3
        let rel = String(location.drop(while: { $0 == ":" })).replacingOccurrences(of: ":", with: "/")
        return volume.appendingPathComponent(rel)
    }
}

/// Off-main worker that does the file + database work for `addToIPod`.
enum IPodSyncEngine {
    struct Job: Sendable {
        let file: URL; let title: String; let artist: String; let album: String; let genre: String
    }

    static func run(jobs: [Job], volume: URL, dbURL: URL, serial: String) async -> String {
        let fm = FileManager.default
        guard let dbData = try? Data(contentsOf: dbURL) else {
            return "Couldn't read the iPod database."
        }
        // Safety backup next to the DB.
        try? dbData.write(to: dbURL.appendingPathExtension("yoinbak"))

        let musicDir = volume.appendingPathComponent("iPod_Control/Music/F00", isDirectory: true)
        try? fm.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory

        var newTracks: [IPodNewTrack] = []
        var copied: [URL] = []           // roll back these files if the DB write fails
        var failed = 0                   // tracks skipped due to transcode/copy errors
        for job in jobs {
            let name = uniqueName(in: musicDir)
            let dst = musicDir.appendingPathComponent(name)
            let staged = tmp.appendingPathComponent(UUID().uuidString + ".m4a")
            do { try IPodExport.transcodeToALAC(source: job.file, destination: staged) } catch { failed += 1; continue }
            do { try fm.copyItem(at: staged, to: dst) } catch { try? fm.removeItem(at: staged); failed += 1; continue }
            try? fm.removeItem(at: staged)
            copied.append(dst)
            let size = ((try? fm.attributesOfItem(atPath: dst.path))?[.size] as? Int) ?? 0
            let durMs = await durationMs(dst)
            newTracks.append(IPodNewTrack(title: job.title, artist: job.artist, album: job.album,
                                          genre: job.genre, durationMs: durMs, sizeBytes: size,
                                          location: ":iPod_Control:Music:F00:\(name)"))
        }
        guard !newTracks.isEmpty else { return "Couldn't prepare any tracks for the iPod." }

        guard let newDB = IPodWriter.append(tracks: newTracks, to: [UInt8](dbData), serial: serial) else {
            copied.forEach { try? fm.removeItem(at: $0) }
            return "Couldn't update the iPod database — nothing was changed."
        }
        do {
            try Data(newDB).write(to: dbURL)
        } catch {
            try? dbData.write(to: dbURL)                 // restore original DB
            copied.forEach { try? fm.removeItem(at: $0) }
            return "Write failed — the iPod database was restored."
        }
        let n = newTracks.count
        let base = "Added \(n) song\(n == 1 ? "" : "s") to iPod. Eject it safely before unplugging."
        return failed == 0 ? base
            : "\(base) \(failed) track\(failed == 1 ? "" : "s") couldn't be converted and were skipped."
    }

    struct SrcTrack: Sendable { let title: String; let url: URL }
    struct ImportGroup: Sendable { let title: String; let artist: String; var tracks: [SrcTrack] }
    struct ImportedGroup: Sendable { let title: String; let artist: String; let files: [URL] }

    /// Delete tracks from the iPod DB + remove their audio files. Backup/restore on failure.
    static func remove(trackIDs: Set<Int>, locations: [String], volume: URL, dbURL: URL, serial: String) async -> String {
        let fm = FileManager.default
        guard let dbData = try? Data(contentsOf: dbURL) else { return "Couldn't read the iPod database." }
        try? dbData.write(to: dbURL.appendingPathExtension("yoinbak"))
        guard let newDB = IPodWriter.remove(trackIDs: trackIDs, from: [UInt8](dbData), serial: serial) else {
            return "Couldn't update the iPod database — nothing was removed."
        }
        do { try Data(newDB).write(to: dbURL) }
        catch { try? dbData.write(to: dbURL); return "Remove failed — the iPod database was restored." }
        // Delete the audio files (best-effort; the DB is already updated). Guard hard against
        // ever removing anything outside iPod_Control/Music (e.g. a blank/odd location).
        for loc in locations where !loc.isEmpty {
            let rel = String(loc.drop(while: { $0 == ":" })).replacingOccurrences(of: ":", with: "/")
            guard rel.hasPrefix("iPod_Control/Music/") else { continue }
            let url = volume.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                try? fm.removeItem(at: url)
            }
        }
        let n = trackIDs.count
        return "Removed \(n) song\(n == 1 ? "" : "s") from iPod. Eject it safely before unplugging."
    }

    /// Copy iPod audio files into Yoin's library folder, naming each file by its REAL track title
    /// (the iPod stores files under mangled 4-char names, so we can't keep those or the library
    /// would show "MHAH", "QAHQ"…). Returns groups with the copied URLs.
    static func importToLibrary(_ groups: [ImportGroup]) async -> [ImportedGroup] {
        let fm = FileManager.default
        let dir = AppState.libraryFolder.appendingPathComponent("FromIPod", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [ImportedGroup] = []
        for g in groups {
            var copied: [URL] = []
            for t in g.tracks {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: t.url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let dst = uniqueDestination(title: t.title, ext: t.url.pathExtension, in: dir)
                if (try? fm.copyItem(at: t.url, to: dst)) != nil { copied.append(dst) }
            }
            out.append(ImportedGroup(title: g.title, artist: g.artist, files: copied))
        }
        return out
    }

    /// A filesystem-safe destination named after the track title (so the library shows real names).
    private static func uniqueDestination(title: String, ext: String, in dir: URL) -> URL {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        var base = title.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Track" }
        let e = ext.isEmpty ? "m4a" : ext
        var dst = dir.appendingPathComponent("\(base).\(e)")
        var i = 1
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = dir.appendingPathComponent("\(base) (\(i)).\(e)"); i += 1
        }
        return dst
    }

    /// A 4-char uppercase name (iPod convention) not already used in the folder.
    private static func uniqueName(in dir: URL) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        while true {
            let name = String((0..<4).map { _ in chars.randomElement()! }) + ".m4a"
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        }
    }

    private static func durationMs(_ url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        let secs = CMTimeGetSeconds(d)
        return secs.isFinite ? Int(secs * 1000) : 0
    }
}
