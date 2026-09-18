import CloudKit
import Foundation

/// CloudKit schema + record mapping for syncing IMPORTED (`.local`) albums between the
/// macOS and iOS apps through the user's private iCloud database. Both apps share ONE
/// container (see `containerID`); Bandcamp albums are excluded because they re-download
/// per device from the user's account.
///
/// This file defines the *schema and mapping only*. The upload engine (macOS) and download
/// engine (iOS) are built on top of `makeRecord`/`album(from:)` — nothing here performs any
/// network operation until an engine calls it.
///
/// NOTE: CloudKit only functions once the app is signed with a provisioning profile that
/// carries this container. The unsigned local `package.sh` build compiles this fine but
/// cannot talk to CloudKit at runtime.
enum CloudSync {
    /// Shared container across both bundle ids (`com.yoin.player`, `com.yoin.player.ios`).
    /// Must exactly match the `com.apple.developer.icloud-container-identifiers`
    /// entitlement on BOTH targets, and be created in the Apple Developer portal.
    static let containerID = "iCloud.com.yoin.shared"

    /// CKRecord type name for one imported album.
    static let recordType = "ImportedAlbum"

    /// Custom zone (in the private DB) holding the imported-album records. A dedicated zone
    /// lets the downloader fetch deltas with a server change token.
    static let zoneName = "ImportedAlbums"

    /// Field keys on an `ImportedAlbum` record.
    enum Key {
        /// JSON-encoded `Album` with local file URLs stripped (paths differ per device).
        static let metadata = "metadata"
        /// Embedded cover bytes, when present.
        static let cover = "cover"
        /// The album's audio files, in track order.
        static let audio = "audio"
        /// File name for each `audio` asset, so the downloader can restore them on disk.
        static let fileNames = "fileNames"
        /// True when this is a single-file import (`url`) rather than a multi-track folder.
        static let singleFile = "singleFile"
        /// Content fingerprint — lets the uploader skip re-uploading unchanged albums.
        static let contentHash = "contentHash"
        /// Last local change, for conflict resolution / a "synced N ago" hint.
        static let updatedAt = "updatedAt"
        /// Number of audio files — shown in the iPhone's catalog without downloading the audio.
        static let trackCount = "trackCount"
        /// Total bytes of the audio files — shown in the iPhone's catalog.
        static let sizeBytes = "sizeBytes"
    }

    /// Only imported content with backing files is eligible to sync.
    static func isSyncable(_ album: Album) -> Bool {
        album.source == .local && (album.url != nil || album.hasLocalFiles)
    }

    /// The audio files backing an imported album, in play order.
    static func audioURLs(of album: Album) -> [URL] {
        if let tracks = album.localTracks, !tracks.isEmpty { return tracks }
        if let u = album.url { return [u] }
        return []
    }

    /// Whether an imported album is a plain single-file import.
    static func isSingleFile(_ album: Album) -> Bool {
        album.url != nil && (album.localTracks?.isEmpty ?? true)
    }

    // MARK: - Upload (macOS)

    /// Build the CKRecord for an imported album. The record id reuses the album's stable
    /// UUID, so re-uploads update the same record and the id survives round-trips (matching
    /// the id-preservation rule the rest of sync relies on).
    static func makeRecord(from album: Album, in zoneID: CKRecordZone.ID) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: album.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)

        // Portable metadata: strip device-specific file URLs; the downloader re-points them.
        var portable = album
        portable.url = nil
        portable.localTracks = nil
        let blob = try JSONEncoder().encode(portable)
        record[Key.metadata] = blob as NSData

        if let art = album.artworkData {
            record[Key.cover] = try tempAsset(for: art, ext: "img")
        }

        let urls = audioURLs(of: album)
        record[Key.singleFile] = isSingleFile(album) as NSNumber
        record[Key.fileNames] = urls.map(\.lastPathComponent) as NSArray
        record[Key.audio] = urls.map { CKAsset(fileURL: $0) } as NSArray
        record[Key.contentHash] = contentHash(for: album, urls: urls) as NSString
        record[Key.updatedAt] = Date() as NSDate
        record[Key.trackCount] = urls.count as NSNumber
        record[Key.sizeBytes] = totalBytes(of: urls) as NSNumber
        return record
    }

    // MARK: - Download (iOS)

    /// Rebuild an `Album` from a fetched record, writing its audio (and cover) into `dir`.
    /// Preserves the album's id so `openedAlbumID` / now-playing / playlist refs stay valid.
    static func album(from record: CKRecord, writingFilesTo dir: URL) throws -> Album {
        guard let blob = record[Key.metadata] as? Data else {
            throw CloudSyncError.malformedRecord
        }
        var album = try JSONDecoder().decode(Album.self, from: blob)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let cover = record[Key.cover] as? CKAsset, let f = cover.fileURL {
            album.artworkData = try? Data(contentsOf: f)
        }

        let assets = (record[Key.audio] as? [CKAsset]) ?? []
        let names = (record[Key.fileNames] as? [String]) ?? []
        var written: [URL] = []
        for (i, asset) in assets.enumerated() {
            guard let src = asset.fileURL else { continue }
            let name = i < names.count ? names[i] : "\(album.id.uuidString)-\(i)"
            let dest = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            written.append(dest)
        }

        let single = (record[Key.singleFile] as? Bool) ?? (written.count == 1)
        if single, let only = written.first {
            album.url = only
            album.localTracks = nil
        } else {
            album.url = nil
            album.localTracks = written.isEmpty ? nil : written
        }
        album.source = .local
        return album
    }

    // MARK: - Helpers

    private static func tempAsset(for data: Data, ext: String) throws -> CKAsset {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: tmp)
        return CKAsset(fileURL: tmp)
    }

    /// Cheap fingerprint: file sizes + mtimes + title/artist. Enough to detect that an
    /// album's bytes changed without hashing whole audio files on every sync pass.
    static func contentHash(for album: Album, urls: [URL]) -> String {
        var parts: [String] = ["\(album.title)|\(album.artist)"]
        let fm = FileManager.default
        for u in urls {
            let attrs = try? fm.attributesOfItem(atPath: u.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(u.lastPathComponent):\(size):\(Int(mod))")
        }
        return parts.joined(separator: "\n")
    }

    /// Total size in bytes of a set of files (for the iPhone catalog's size hint).
    static func totalBytes(of urls: [URL]) -> Int64 {
        let fm = FileManager.default
        return urls.reduce(0) { acc, u in
            acc + Int64((try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int ?? 0)
        }
    }
}

enum CloudSyncError: Error { case malformedRecord }
