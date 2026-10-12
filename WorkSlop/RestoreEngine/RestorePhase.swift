import Foundation

// MARK: - Phase 4: RESTORE FULL
//
// Pushes the modified full backup back to the device. The push and the
// verification both go over the transport — and both throw
// `.unimplemented` until a lockdown transport exists.
//
// The verification rule is load-bearing: success is ONLY reported when
// the device itself confirms the restore (a restore once stopped at 55%
// and was misreported as done). A transport return value alone is never
// enough.

enum RestorePhase {
    static func run(
        request: RestoreRequest,
        backupRoot: URL,
        transport: DeviceTransport,
        progress: @Sendable (RestoreProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        progress(RestoreProgress(phase: .restore, fraction: 0.05, message: "Pushing full restore…"))
        if isCancelled() { throw RestoreError.cancelled }

        // Throws .unimplemented until the transport exists — loudly,
        // with the missing piece named. Never reported as success.
        try await transport.pushFullRestore(from: backupRoot) { f in
            progress(RestoreProgress(phase: .restore, fraction: 0.05 + 0.85 * f,
                                     message: "Restoring… \(Int(f * 100))%"))
        }

        // Unreachable today. Contract for the future transport:
        progress(RestoreProgress(phase: .restore, fraction: 0.95, message: "Verifying restore on device…"))
        let confirmed = try await transport.verifyRestore(of: backupRoot)
        guard confirmed else {
            throw RestoreError.phaseFailed(phase: .restore, message: "The device did not confirm the restore landed.")
        }
        progress(RestoreProgress(phase: .restore, fraction: 1.0, message: "Restore verified by the device."))
    }
}
