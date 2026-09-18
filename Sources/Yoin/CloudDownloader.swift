import CloudKit
import Foundation

/// Pulls IMPORTED albums the *other* device uploaded from the shared private CloudKit
/// database (see `CloudSync` for the schema, `CloudUploader` for the push side).
///
/// This is the SHARED engine for the download side: portable (CloudKit + Foundation only,
/// no AppKit/UIKit) so the iOS target reuses the exact same file. The iOS app calls
/// `pull(writingFilesTo:)` on launch and on a push, then merges the returned albums into its
/// library — preserving each album's id so `openedAlbumID` / now-playing / playlist refs stay
/// valid. macOS keeps it dormant today (uploader only); it's here for compile-checking and to
/// make bidirectional sync trivial later.
actor CloudDownloader {
    static let shared = CloudDownloader()

    private let container = CKContainer(identifier: CloudSync.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)

    private static let tokenKey = "cloudZoneToken"
    private static let subscriptionID = "imported-albums-sub"

    /// What one pull produced. `changed` albums already have their audio + cover written to
    /// disk under the caller's directory; `deletedIDs` were removed on the other device.
    struct Changes: Sendable {
        var changed: [Album] = []
        var deletedIDs: [UUID] = []
    }

    /// Fetch everything new/changed since the last pull, writing each album's files under
    /// `dir` (e.g. the iOS equivalent of `~/Music/Vinyl`). Advances the stored change token
    /// only on success, so a failed pull is retried whole next time.
    func pull(writingFilesTo dir: URL) async throws -> Changes {
        let (records, deletedIDs, newToken) = try await fetchZoneChanges()

        var out = Changes()
        for rec in records {
            if let album = try? CloudSync.album(from: rec, writingFilesTo: dir) {
                out.changed.append(album)
            }
        }
        out.deletedIDs = deletedIDs.compactMap { UUID(uuidString: $0.recordName) }

        if let t = newToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: t, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.tokenKey)
        }
        return out
    }

    /// Register a silent-push subscription so the device is woken on any change. Call once
    /// (iOS also needs the remote-notification background mode + push handling in its app
    /// delegate to turn the push into a `pull`).
    func ensureSubscription() async {
        let sub = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push, no alert
        sub.notificationInfo = info
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let op = CKModifySubscriptionsOperation(subscriptionsToSave: [sub], subscriptionIDsToDelete: nil)
                op.modifySubscriptionsResultBlock = { result in
                    switch result { case .success: cont.resume(); case .failure(let e): cont.resume(throwing: e) }
                }
                database.add(op)
            }
        } catch {
            NSLog("CloudDownloader: subscription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - CloudKit plumbing

    private func fetchZoneChanges() async throws -> ([CKRecord], [CKRecord.ID], CKServerChangeToken?) {
        var token: CKServerChangeToken? = nil
        if let data = UserDefaults.standard.data(forKey: Self.tokenKey) {
            token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token

        let collector = ChangeCollector()
        return try await withCheckedThrowingContinuation { cont in
            let op = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config])
            op.recordWasChangedBlock = { _, result in
                if case .success(let record) = result { collector.addRecord(record) }
            }
            op.recordWithIDWasDeletedBlock = { id, _ in collector.addDeleted(id) }
            op.recordZoneFetchResultBlock = { _, result in
                if case .success(let s) = result { collector.setToken(s.serverChangeToken) }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    cont.resume(returning: (collector.records, collector.deleted, collector.token))
                case .failure(let error):
                    // No zone yet (nothing uploaded from the other device) → treat as empty.
                    let code = (error as? CKError)?.code
                    if code == .zoneNotFound || code == .userDeletedZone {
                        cont.resume(returning: ([], [], nil))
                    } else {
                        cont.resume(throwing: error)
                    }
                }
            }
            database.add(op)
        }
    }
}

/// Thread-safe sink for the fetch operation's per-record callbacks (which fire on CloudKit's
/// own queue). Read only after the operation completes, when no more mutations occur.
private final class ChangeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [CKRecord] = []
    private var _deleted: [CKRecord.ID] = []
    private var _token: CKServerChangeToken? = nil

    func addRecord(_ r: CKRecord) { lock.lock(); _records.append(r); lock.unlock() }
    func addDeleted(_ id: CKRecord.ID) { lock.lock(); _deleted.append(id); lock.unlock() }
    func setToken(_ t: CKServerChangeToken?) { lock.lock(); _token = t; lock.unlock() }

    var records: [CKRecord] { lock.lock(); defer { lock.unlock() }; return _records }
    var deleted: [CKRecord.ID] { lock.lock(); defer { lock.unlock() }; return _deleted }
    var token: CKServerChangeToken? { lock.lock(); defer { lock.unlock() }; return _token }
}
