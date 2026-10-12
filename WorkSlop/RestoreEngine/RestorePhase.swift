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
        watchdog: StallWatchdog,
        progress: @Sendable @escaping (RestoreProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        progress(RestoreProgress(phase: .restore, fraction: 0.05, message: "Pushing full restore…"))
        // Last cancel point before the device is written. Once the push
        // starts, user cancel no longer interrupts it (desktop: never cut
        // an in-flight restore) — the transport only honors task-level
        // cancellation (the inner I/O watchdog), never the user flag.
        if isCancelled() { throw RestoreError.cancelled }

        try await transport.pushFullRestore(from: backupRoot) { f in
            // Gap 12 fix: every device tick proves liveness (desktop's
            // restore progress callback). Sync closure → Task hop.
            Task { await watchdog.noteProgress() }
            if f >= 0 {
                progress(RestoreProgress(phase: .restore, fraction: 0.05 + 0.85 * f,
                                         message: "Restoring… \(Int(f * 100))%"))
            }
        }

        progress(RestoreProgress(phase: .restore, fraction: 0.95, message: "Verifying restore on device…"))
        let confirmed = try await transport.verifyRestore(of: backupRoot)
        guard confirmed else {
            throw RestoreError.phaseFailed(phase: .restore, message: "The device did not confirm the restore landed.")
        }
        progress(RestoreProgress(phase: .restore, fraction: 1.0, message: "Restore verified by the device."))
    }
}
