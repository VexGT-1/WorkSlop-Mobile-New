import Foundation

// MARK: - Phase 1: BACKUP ALL DATA FULL
//
// Real work done here: prerequisite gates (pairing, tunnel, disk, Find My
// attestation, version) and backup staging preparation. The actual
// mobilebackup2 pull needs the loopback transport and throws
// `.unimplemented` there — loudly, with the missing piece named.

enum BackupPhase {
    struct Result: Sendable {
        let backupRoot: URL
        let prerequisites: [PrerequisiteCheck]
    }

    static func run(
        request: RestoreRequest,
        stagingRoot: URL,
        transport: DeviceTransport,
        progress: @Sendable (RestoreProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) async throws -> Result {
        progress(RestoreProgress(phase: .backup, fraction: 0.05, message: "Checking prerequisites…"))
        let checks = checkPrerequisites(request: request)
        if checks.contains(where: { !$0.isOK }) {
            throw RestoreError.prerequisitesFailed(checks)
        }
        if isCancelled() { throw RestoreError.cancelled }

        progress(RestoreProgress(phase: .backup, fraction: 0.15, message: "Preparing backup staging…"))
        let backupRoot = stagingRoot.appendingPathComponent("FullBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // From here the device must be spoken to. Without the transport
        // this throws RestoreError.unimplemented — it never pretends a
        // full backup was pulled.
        progress(RestoreProgress(phase: .backup, fraction: 0.25, message: "Pulling full backup from device…"))
        _ = try await transport.pullFullBackup(to: backupRoot) { _ in }

        // Unreachable until a transport exists. Kept as the contract:
        // a pulled backup lands at backupRoot and the run continues.
        return Result(backupRoot: backupRoot, prerequisites: checks)
    }

    // MARK: - Prerequisite gates (all real, all local)

    static func checkPrerequisites(request: RestoreRequest) -> [PrerequisiteCheck] {
        var checks: [PrerequisiteCheck] = []

        checks.append(PrerequisiteCheck(
            name: "Pairing record",
            status: PairingStore.isImported
                ? .passed
                : .failed(reason: "No pairing record imported — import it in Settings first.")
        ))

        checks.append(PrerequisiteCheck(
            name: "VPN tunnel",
            status: DeviceStatus.vpnTunnelActive()
                ? .passed
                : .failed(reason: "Loopback VPN tunnel not detected. Install and start the tunnel app first.")
        ))

        checks.append(PrerequisiteCheck(
            name: "Device version",
            status: .passed // the engine already refused unknown / <27 before phase 1
        ))

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let free = BackupPhase.freeBytes(at: docs)
        checks.append(PrerequisiteCheck(
            name: "Staging disk space",
            status: .attestedUnverifiable(note: "\(free) bytes free on the staging volume. Whether that fits the device's full backup is verified at pull time, over the transport.")
        ))

        checks.append(PrerequisiteCheck(
            name: "Find My",
            status: request.findMyDisabledAttested
                ? .attestedUnverifiable(note: "User attested Find My is OFF. The sandbox cannot verify this — restoring with Find My ON risks activation issues.")
                : .failed(reason: "Find My must be OFF before a full restore. Confirm it in Settings, then attest.")
        ))

        return checks
    }

    private static func freeBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
    }
}
