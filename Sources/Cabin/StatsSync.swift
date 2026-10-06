import CloudKit
import Foundation

/// Shares the listening history (what every stat, recap and history station is computed from)
/// and the profile (name + avatar) between your Macs and iPhone through the private CloudKit
/// database — the same container as the imported-song transfer (`CloudSync.containerID`).
///
/// SHARED CONTRACT — the iOS app must use exactly these names (keep `StatsSync.swift` identical):
///   zone   `CabinSync`
///   record `CabinProfile`  (name "profile")          name: String · avatar: Asset · updatedAt: Date
///   record `HistoryChunk`  (name "<deviceID>|<day>") deviceID: String · deviceName: String ·
///                                                     day: String ("yyyy-MM-dd", UTC) ·
///                                                     events: Bytes (JSON [PlayEvent]) ·
///                                                     count: Int64 · updatedAt: Date
///
/// History is conflict-free: each device only ever writes chunks of ITS OWN plays (one record
/// per device per UTC day); other devices' chunks are pulled and replace that device+day in the
/// local log. The profile is last-writer-wins on `updatedAt`. All work is best-effort and quiet —
/// with no iCloud account (or an unsigned dev build) it simply does nothing.
actor StatsSync {
    static let shared = StatsSync()

    static let zoneName = "CabinSync"
    static let profileType = "CabinProfile"
    static let chunkType = "HistoryChunk"
    enum Key {
        static let name = "name", avatar = "avatar", updatedAt = "updatedAt"
        static let deviceID = "deviceID", deviceName = "deviceName", day = "day", events = "events", count = "count"
    }

    /// Mirrors the Settings toggle (on by default).
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "cabin.statsSync") as? Bool ?? true }

    /// This install's stable device id — every local play is tagged with it.
    static let deviceID: String = {
        let k = "cabin.deviceID"
        if let id = UserDefaults.standard.string(forKey: k) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: k)
        return id
    }()
    static let deviceName: String = Host.current().localizedName ?? "Mac"

    private let container = CKContainer(identifier: CloudSync.containerID)
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private var zoneReady = false
    private var running = false

    private static let tokenKey = "cabin.statsSync.token"
    private static func pushedKey(_ day: String) -> String { "cabin.statsSync.pushed.\(day)" }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func day(_ d: Date) -> String { dayFormat.string(from: d) }

    // MARK: Entry points

    /// Pull the other devices' changes, then push ours. Returns what changed locally so the app
    /// can refresh (`history` = merged in remote plays, `profile` = a newer remote profile).
    func sync(localProfile: Profile) async -> (history: Bool, profile: Profile?) {
        guard Self.isEnabled, !running else { return (false, nil) }
        running = true; defer { running = false }
        guard (try? await container.accountStatus()) == .available else { return (false, nil) }
        do {
            try await ensureZone()
            let pulled = try await pull(localProfile: localProfile)
            try await pushHistory()
            if pulled.profile == nil { try await pushProfileIfNewer(localProfile) }
            return pulled
        } catch {
            NSLog("StatsSync: \(error)")
            return (false, nil)
        }
    }

    /// Upload the profile now (after the user edits it).
    func pushProfile(_ profile: Profile) async {
        guard Self.isEnabled, (try? await container.accountStatus()) == .available else { return }
        do { try await ensureZone(); try await saveProfile(profile) }
        catch { NSLog("StatsSync profile: \(error)") }
    }

    // MARK: Pull

    private func pull(localProfile: Profile) async throws -> (history: Bool, profile: Profile?) {
        let token = (UserDefaults.standard.data(forKey: Self.tokenKey))
            .flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        var historyChanged = false
        var remoteProfile: Profile?
        var since = token
        var more = true
        while more {
            let res = try await db.recordZoneChanges(inZoneWith: zoneID, since: since)
            for (_, result) in res.modificationResultsByID {
                guard case .success(let mod) = result else { continue }
                let r = mod.record
                switch r.recordType {
                case Self.chunkType:
                    guard let device = r[Key.deviceID] as? String, device != Self.deviceID,
                          let day = r[Key.day] as? String, let data = r[Key.events] as? Data,
                          var events = try? JSONDecoder().decode([PlayEvent].self, from: data) else { continue }
                    for i in events.indices { events[i].device = device }
                    HistoryStore.replaceRemote(device: device, day: day, with: events)
                    historyChanged = true
                case Self.profileType:
                    let remoteDate = (r[Key.updatedAt] as? Date) ?? .distantPast
                    guard remoteDate > (localProfile.updatedAt ?? .distantPast) else { continue }
                    var p = Profile()
                    p.name = (r[Key.name] as? String) ?? ""
                    if let a = r[Key.avatar] as? CKAsset, let u = a.fileURL { p.avatar = try? Data(contentsOf: u) }
                    p.updatedAt = remoteDate
                    remoteProfile = p
                default: break
                }
            }
            since = res.changeToken
            more = res.moreComing
        }
        if let since, let data = try? NSKeyedArchiver.archivedData(withRootObject: since, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.tokenKey)
        }
        return (historyChanged, remoteProfile)
    }

    // MARK: Push

    /// Upload one chunk per UTC day of THIS device's plays whose content changed since last push.
    private func pushHistory() async throws {
        let mine = HistoryStore.load().filter { $0.device == nil || $0.device == Self.deviceID }
        let byDay = Dictionary(grouping: mine) { Self.day($0.date) }
        var records: [CKRecord] = []
        var marks: [(String, String)] = []
        for (day, events) in byDay {
            let sig = "\(events.count)|\(events.map(\.date.timeIntervalSince1970).max() ?? 0)"
            if UserDefaults.standard.string(forKey: Self.pushedKey(day)) == sig { continue }
            var tagged = events
            for i in tagged.indices { tagged[i].device = nil }   // the chunk carries the device
            guard let data = try? JSONEncoder().encode(tagged) else { continue }
            let r = CKRecord(recordType: Self.chunkType,
                             recordID: CKRecord.ID(recordName: "\(Self.deviceID)|\(day)", zoneID: zoneID))
            r[Key.deviceID] = Self.deviceID as NSString
            r[Key.deviceName] = Self.deviceName as NSString
            r[Key.day] = day as NSString
            r[Key.events] = data as NSData
            r[Key.count] = events.count as NSNumber
            r[Key.updatedAt] = Date() as NSDate
            records.append(r)
            marks.append((day, sig))
        }
        // CloudKit takes up to 400 records per request; stay well under.
        for start in stride(from: 0, to: records.count, by: 100) {
            let batch = Array(records[start..<min(start + 100, records.count)])
            try await save(batch)
        }
        for (day, sig) in marks { UserDefaults.standard.set(sig, forKey: Self.pushedKey(day)) }
    }

    private func pushProfileIfNewer(_ profile: Profile) async throws {
        let k = "cabin.statsSync.profilePushed"
        let stamp = profile.updatedAt?.timeIntervalSince1970 ?? 0
        guard stamp > 0, UserDefaults.standard.double(forKey: k) != stamp else { return }
        try await saveProfile(profile)
    }

    private func saveProfile(_ profile: Profile) async throws {
        let r = CKRecord(recordType: Self.profileType, recordID: CKRecord.ID(recordName: "profile", zoneID: zoneID))
        r[Key.name] = profile.name as NSString
        if let a = profile.avatar {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try a.write(to: tmp)
            r[Key.avatar] = CKAsset(fileURL: tmp)
        } else {
            r[Key.avatar] = nil
        }
        r[Key.updatedAt] = (profile.updatedAt ?? Date()) as NSDate
        try await save([r])
        UserDefaults.standard.set(profile.updatedAt?.timeIntervalSince1970 ?? 0, forKey: "cabin.statsSync.profilePushed")
    }

    // MARK: Plumbing

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        zoneReady = true
    }

    /// Save, overwriting the server copy; per-record failures throw (the overall result alone can
    /// report success for a rejected record — see CloudUploader).
    private func save(_ records: [CKRecord]) async throws {
        let res = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
        for (_, r) in res.saveResults { if case .failure(let e) = r { throw e } }
    }
}
