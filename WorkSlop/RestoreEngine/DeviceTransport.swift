import Foundation
import CryptoKit
import SQLite3

// MARK: - Device transport: real loopback implementation
//
// Talks to the device's own lockdownd over the loopback tunnel (WireGuard
// tunnel app installed separately; presence detected by
// DeviceStatus.vpnTunnelActive()). Pure Swift, no FFI:
//   LockdownClient (CFStream, STARTTLS) + MobileBackup2Client
//   (Network.framework), both verified against libimobiledevice.
//
// Prerequisites (device side): the tunnel app installed + running, and a
// valid pairing record imported in the app (Settings).

protocol DeviceTransport: Sendable {
    /// Pull a FULL device backup into `stagingDir`. Progress 0...1.
    func pullFullBackup(to stagingDir: URL, progress: @Sendable (Double) -> Void) async throws -> URL
    /// Push `backupRoot` back as a full restore. Progress 0...1.
    /// The device itself must confirm success — a transport return value
    /// alone is never reported as success (a restore once stopped at 55%
    /// and was misreported as done).
    func pushFullRestore(from backupRoot: URL, progress: @Sendable (Double) -> Void) async throws
    /// Ask the device whether the restore landed. Must come from the
    /// device response, not from local bookkeeping.
    func verifyRestore(of backupRoot: URL) async throws -> Bool
    /// Reboot the device over lockdown.
    func rebootDevice() async throws
}

/// Real transport over the loopback tunnel. An actor: one transport =
/// serialized operations, never interleaved on the sockets.
actor LoopbackTransport: DeviceTransport {
    private let backupPassword: String?

    /// The device's own final verdict from the last push, captured verbatim
    /// from the DLMessageProcessMessage ErrorCode. verifyRestore() reports
    /// THIS value — there is no re-query protocol in mobilebackup2, so the
    /// captured device verdict is the honest maximum (it is the device's
    /// response, not an assumed success).
    private var lastRestoreDeviceConfirmed: Bool?

    init(backupPassword: String? = nil) {
        self.backupPassword = backupPassword
    }

    // MARK: - helpers

    private func requireTunnel() throws {
        guard DeviceStatus.vpnTunnelActive() else {
            throw RestoreError.phaseFailed(
                phase: .backup,
                message: "Loopback tunnel not detected. Install and start the tunnel app first.")
        }
    }

    private func loadIdentity() throws -> PairingIdentity {
        guard PairingStore.isImported, let identity = PairingIdentity.load() else {
            throw RestoreError.phaseFailed(
                phase: .backup,
                message: "No readable pairing record. Import it in Settings first.")
        }
        return identity
    }

    /// Fresh lockdown handshake (mirrors libimobiledevice's per-operation
    /// lockdownd_client_new_with_handshake pattern).
    private func handshakedLockdown() async throws -> (LockdownClient, PairingIdentity, String) {
        try requireTunnel()
        let identity = try loadIdentity()
        let lockdown = LockdownClient()
        do {
            try await lockdown.connect()
            try await lockdown.handshake(identity: identity)
        } catch {
            lockdown.close()
            throw error
        }
        let udid = (try? await lockdown.getValue(domain: nil, key: "UniqueDeviceID") as? String) ?? "device"
        return (lockdown, identity, udid)
    }

    // MARK: - DeviceTransport

    func pullFullBackup(to stagingDir: URL,
                        progress: @Sendable (Double) -> Void) async throws -> URL {
        let (lockdown, identity, udid) = try await handshakedLockdown()
        defer { lockdown.close() }

        let (port, serviceSSL) = try await lockdown.startService(
            "com.apple.mobilebackup2", escrowBag: identity.escrowBag)
        if serviceSSL {
            // UNVERIFIED: service-level SSL on the mobilebackup2 channel is
            // not covered by the examined libimobiledevice sources
            // (device_link_service.c has no SSL path). Fail loudly.
            throw RestoreError.phaseFailed(
                phase: .backup, message: "mobilebackup2 asked for service-level SSL; no verified flow")
        }

        let mb2 = MobileBackup2Client(port: port)
        await mb2.setCancelled { Task.isCancelled }
        do {
            _ = try await mb2.connect()
            let count = try await mb2.runBackup(
                targetID: udid, sourceID: udid, password: backupPassword,
                to: stagingDir,
                progress: { f, _ in if f >= 0 { progress(f) } })
            // A pulled backup that yielded zero files is not a backup.
            guard count > 0 else {
                throw RestoreError.phaseFailed(
                    phase: .backup, message: "device sent zero files; refusing to continue on an empty pull")
            }
            await mb2.disconnect()
            return stagingDir
        } catch {
            await mb2.disconnect()
            throw error
        }
    }

    func pushFullRestore(from backupRoot: URL,
                         progress: @Sendable (Double) -> Void) async throws {
        // 1. Register the injected payload files in the pulled Manifest.db
        //    so the device actually requests them (fileID → domain/path).
        let patch = try ManifestDBPatcher.patch(backupRoot: backupRoot)

        // 2. Push over the wire.
        let (lockdown, identity, udid) = try await handshakedLockdown()
        defer { lockdown.close() }

        let (port, serviceSSL) = try await lockdown.startService(
            "com.apple.mobilebackup2", escrowBag: identity.escrowBag)
        if serviceSSL {
            throw RestoreError.phaseFailed(
                phase: .restore, message: "mobilebackup2 asked for service-level SSL; no verified flow")
        }

        let mb2 = MobileBackup2Client(port: port)
        await mb2.setCancelled { Task.isCancelled }
        do {
            _ = try await mb2.connect()

            let fileIDMap = patch.fileIDMap
            let confirmed = try await mb2.runRestore(
                targetID: udid, sourceID: udid, password: backupPassword,
                from: backupRoot,
                fileResolver: { [backupRoot] path in
                    let direct = backupRoot.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: direct.path) { return direct }
                    return fileIDMap[path]
                },
                progress: { f, _ in if f >= 0 { progress(f) } })

            lastRestoreDeviceConfirmed = confirmed
            guard confirmed else {
                // Unreachable in practice (runRestore throws on ErrorCode != 0),
                // kept as a second gate: never report success without the device.
                throw RestoreError.phaseFailed(
                    phase: .restore, message: "The device did not confirm the restore landed.")
            }
            await mb2.disconnect()
        } catch {
            await mb2.disconnect()
            throw error
        }
    }

    func verifyRestore(of backupRoot: URL) async throws -> Bool {
        guard let confirmed = lastRestoreDeviceConfirmed else {
            throw RestoreError.phaseFailed(
                phase: .restore,
                message: "No restore has been pushed in this session — nothing device-confirmed to report.")
        }
        return confirmed
    }

    func rebootDevice() async throws {
        let (lockdown, _, _) = try await handshakedLockdown()
        defer { lockdown.close() }
        try await lockdown.reboot()
    }
}

// MARK: - Manifest.db patcher

/// Registers injected payload files in the PULLED Manifest.db so the
/// device requests them during restore.
///
/// What is measured (not invented):
/// - The Files table lives in the real pulled Manifest.db; the patcher
///   refuses to run if the table is absent.
/// - Row shape (domain, relativePath, flags, file blob) is COPIED from a
///   template row of the same backup — preferably the same domain.
/// - AppDomain-* entries must already be registered in Manifest.plist
///   "Applications" (else the device answers MBErrorDomain/205
///   "Unknown domain name" — GoldenNugget research).
///
/// UNVERIFIED (needs a device with a real pulled Manifest.db):
/// - fileID derivation: hex SHA1("domain-relativePath"). Verified for the
///   legacy .mbdb format (research: measured); assumed identical for the
///   Manifest.db Files.fileID column. Confirm by comparing against a
///   known row from a real pull before trusting a push.
/// - The copied `file` metadata blob is used verbatim from the template
///   row (Size is refreshed when the blob decodes and carries a Size key;
///   otherwise left untouched). Whether the device tolerates this for
///   brand-new rows is device-testable only.
struct ManifestDBPatcher {
    struct PatchResult: Sendable {
        let insertedRows: Int
        /// fileID → local payload file, for the DownloadFiles resolver.
        let fileIDMap: [String: URL]
    }

    struct Entry: Decodable {
        let fileName: String
        let domain: String
        let restorePath: String
    }

    static func patch(backupRoot: URL) throws -> PatchResult {
        // The payload manifest lives next to the backup staging dir:
        // <staging>/Payload/payload-manifest.json  vs  <staging>/FullBackup
        let manifestURL = backupRoot.deletingLastPathComponent()
            .appendingPathComponent("Payload/\(PayloadPhase.manifestFileName)")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: manifestData),
              !entries.isEmpty
        else {
            // No payload staged — push the backup as pulled, honestly.
            return PatchResult(insertedRows: 0, fileIDMap: [:])
        }

        let dbURL = backupRoot.appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw RestoreError.phaseFailed(
                phase: .restore,
                message: "Manifest.db missing in pulled backup — cannot register payload rows.")
        }

        // AppDomain guard (verified failure mode: 205 "Unknown domain name").
        let appDomains = Set(entries.map(\.domain).filter { $0.hasPrefix("AppDomain") })
        if !appDomains.isEmpty {
            let manifestPlistURL = backupRoot.appendingPathComponent("Manifest.plist")
            guard let data = try? Data(contentsOf: manifestPlistURL) else {
                throw RestoreError.phaseFailed(
                    phase: .restore, message: "Manifest.plist unreadable; cannot verify AppDomain registration.")
            }
            var fmt = PropertyListSerialization.PropertyListFormat.xml
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt),
                  let dict = plist as? [String: Any],
                  let apps = dict["Applications"] as? [String: Any]
            else {
                throw RestoreError.phaseFailed(
                    phase: .restore, message: "Manifest.plist unreadable; cannot verify AppDomain registration.")
            }
            for domain in appDomains {
                // "AppDomain-com.example.app" → bundle id after the dash.
                let bundleID = domain.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
                guard apps[bundleID] != nil else {
                    throw RestoreError.phaseFailed(
                        phase: .restore,
                        message: "\(domain) is not registered in Manifest.plist Applications — the device would answer 205.")
                }
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else {
            throw RestoreError.phaseFailed(phase: .restore, message: "Cannot open Manifest.db.")
        }
        defer { sqlite3_close(db) }

        // Refuse if the Files table isn't there (schema drift) — never guess.
        if !tableExists(db, "Files") {
            throw RestoreError.phaseFailed(
                phase: .restore, message: "Manifest.db has no Files table — refusing to guess the schema.")
        }

        var inserted = 0
        var fileIDMap: [String: URL] = [:]
        let payloadDir = manifestURL.deletingLastPathComponent()

        for entry in entries {
            let fileID = sha1Hex("\(entry.domain)-\(entry.restorePath)")
            let localURL = payloadDir.appendingPathComponent(entry.fileName)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                throw RestoreError.phaseFailed(
                    phase: .restore,
                    message: "Payload file missing: \(entry.fileName) for \(entry.domain):\(entry.restorePath)")
            }
            fileIDMap[fileID] = localURL

            let (flags, blob) = try templateRow(db, domain: entry.domain)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            let adjustedBlob = refreshSize(in: blob, to: fileSize)

            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
                throw RestoreError.phaseFailed(
                    phase: .restore,
                    message: "Manifest.db: prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, fileID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, entry.domain, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, entry.restorePath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(stmt, 4, flags)
            adjustedBlob.withUnsafeBytes { ptr in
                _ = sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(adjustedBlob.count),
                                       unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw RestoreError.phaseFailed(
                    phase: .restore,
                    message: "Manifest.db: insert failed for \(entry.domain):\(entry.restorePath): \(String(cString: sqlite3_errmsg(db)))")
            }
            inserted += 1
        }
        return PatchResult(insertedRows: inserted, fileIDMap: fileIDMap)
    }

    // MARK: - internals

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt
        else { return false }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// (flags, file-blob) copied from a real row of the same backup —
    /// measured, not invented. Prefers the same domain.
    private static func templateRow(_ db: OpaquePointer, domain: String) throws -> (Int64, Data) {
        for query in [
            "SELECT flags, file FROM Files WHERE domain = ? LIMIT 1",
            "SELECT flags, file FROM Files LIMIT 1",
        ] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { continue }
            if query.contains("WHERE") {
                sqlite3_bind_text(stmt, 1, domain, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                let flags = sqlite3_column_int64(stmt, 0)
                let bytes = sqlite3_column_blob(stmt, 1)
                let count = Int(sqlite3_column_bytes(stmt, 1))
                let blob = bytes.map { Data(bytes: $0, count: count) } ?? Data()
                return (flags, blob)
            }
        }
        throw RestoreError.phaseFailed(
            phase: .restore, message: "Manifest.db has no template row to copy the file-metadata shape from.")
    }

    /// If the metadata blob decodes as a plist carrying a Size key, refresh
    /// it to the real file size. Otherwise the blob is left untouched —
    /// never invent keys.
    private static func refreshSize(in blob: Data, to size: UInt64) -> Data {
        guard !blob.isEmpty else { return blob }
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard let obj = try? PropertyListSerialization.propertyList(from: blob, options: [], format: &fmt),
              var dict = obj as? [String: Any],
              dict["Size"] is NSNumber
        else { return blob }
        dict["Size"] = NSNumber(value: size)
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) ?? blob
    }

    private static func sha1Hex(_ string: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
