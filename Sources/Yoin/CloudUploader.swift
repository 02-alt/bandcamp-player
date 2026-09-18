import CloudKit
import Foundation

/// Uploads IMPORTED (`.local`) albums to the shared private CloudKit database so the iOS
/// app can pull them (see `CloudSync` for the schema, `CloudDownloader` for the pull side).
///
/// Opt-in via the `cloudSyncImports` setting. All work is best-effort: when CloudKit is
/// unavailable (unsigned local build, no iCloud account, container not yet provisioned)
/// operations fail quietly and are retried on the next import / backfill. Runs off the main
/// actor so encoding + network never block the UI.
actor CloudUploader {
    static let shared = CloudUploader()

    /// Mirrors the Settings toggle. When off, every entry point is a no-op.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "cloudSyncImports") }

    /// Whether an album has been sent to iCloud (its content hash is on record). Drives the
    /// per-album "on iPhone" state in the send picker.
    static func isUploaded(_ id: UUID) -> Bool {
        UserDefaults.standard.string(forKey: "cloudHash.\(id.uuidString)") != nil
    }

    private let container = CKContainer(identifier: CloudSync.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    /// A dedicated custom zone so the downloader can fetch deltas via change tokens.
    private let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)
    private var zoneEnsured = false

    private func hashKey(_ id: UUID) -> String { "cloudHash.\(id.uuidString)" }

    /// Upload one album, skipping it when its bytes are unchanged since the last successful
    /// send. No-op when sync is disabled or the album isn't syncable.
    func upload(_ album: Album) async {
        guard Self.isEnabled, CloudSync.isSyncable(album) else { return }
        let urls = CloudSync.audioURLs(of: album)
        let hash = CloudSync.contentHash(for: album, urls: urls)
        if UserDefaults.standard.string(forKey: hashKey(album.id)) == hash { return }
        do {
            try await ensureZone()
            let record = try CloudSync.makeRecord(from: album, in: zoneID)
            try await save(record)
            UserDefaults.standard.set(hash, forKey: hashKey(album.id))
        } catch {
            // Leave the hash unset so the next import / backfill retries this album.
            NSLog("CloudUploader: upload failed for \(album.title): \(error.localizedDescription)")
        }
    }

    /// Backfill — upload every eligible album. Called when the user first enables sync.
    func uploadAll(_ albums: [Album]) async {
        guard Self.isEnabled else { return }
        for a in albums where CloudSync.isSyncable(a) { await upload(a) }
    }

    /// Remove an album's cloud record (used when it's deleted locally — step 5).
    func delete(id: UUID) async {
        guard Self.isEnabled else { return }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [recordID])
                op.modifyRecordsResultBlock = { result in
                    switch result { case .success: cont.resume(); case .failure(let e): cont.resume(throwing: e) }
                }
                database.add(op)
            }
            UserDefaults.standard.removeObject(forKey: hashKey(id))
        } catch {
            NSLog("CloudUploader: delete failed for \(id): \(error.localizedDescription)")
        }
    }

    // MARK: - CloudKit plumbing

    private func ensureZone() async throws {
        guard !zoneEnsured else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            op.modifyRecordZonesResultBlock = { result in
                switch result { case .success: cont.resume(); case .failure(let e): cont.resume(throwing: e) }
            }
            database.add(op)
        }
        zoneEnsured = true
    }

    private func save(_ record: CKRecord) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .allKeys
            op.isAtomic = true
            op.qualityOfService = .utility
            op.modifyRecordsResultBlock = { result in
                switch result { case .success: cont.resume(); case .failure(let e): cont.resume(throwing: e) }
            }
            database.add(op)
        }
    }
}
