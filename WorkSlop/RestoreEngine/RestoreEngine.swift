import Foundation

// MARK: - Restore request

/// Everything the engine needs up front. The backup password (if the
/// device backup is encrypted) is passed at call time and never stored.
struct RestoreRequest: Sendable {
    /// From lockdown at run time — never guessed, never empty.
    let deviceVersion: DeviceVersion
    /// Feature IDs the user staged (from PayloadSpec catalog).
    let stagedFeatureIDs: Set<String>
    /// Find My cannot be verified from the sandbox; the user attests it.
    /// Restoring with Find My ON risks activation issues — recorded, not faked.
    let findMyDisabledAttested: Bool
    /// Label for the staging directory (UDID when known, else "device").
    let deviceLabel: String
    let backupPassword: String?
}

// MARK: - Engine state

enum RestoreState: Sendable {
    case idle
    case running(RestorePhaseID)
    case succeeded
    case failed(String)
    case cancelled
}

// MARK: - Cooperative cancellation

/// Lock-guarded flag shared with phases. A cancelled run stops between
/// phases and inside long local loops; transport calls check it too.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }
}

// MARK: - Stall watchdog (stall-based, no hard deadline)

/// Abort only after 10 minutes with zero progress. A healthy full
/// backup/restore is never cut off for being slow — the old hard
/// 12-minute deadline is gone on purpose.
actor StallWatchdog {
    private var lastProgress = Date()
    private let stallLimit: TimeInterval = 600

    func noteProgress() { lastProgress = Date() }

    func check(phase: RestorePhaseID) throws {
        if Date().timeIntervalSince(lastProgress) > stallLimit {
            throw RestoreError.stalled(phase: phase)
        }
    }
}

// MARK: - Orchestrator

/// The iOS 27 method, in the exact mandated order:
/// BACKUP ALL DATA FULL → PAYLOAD → MODIF → RESTORE FULL → RESTART.
///
/// An actor: state transitions are serialized, and `start` while a run is
/// in flight throws `.alreadyInFlight` instead of stacking runs.
/// Phases receive `onProgress` directly — no wrapper closures, so the
/// whole chain stays Sendable-clean under Swift 6.
actor RestoreEngine {
    static let shared = RestoreEngine()

    private(set) var state: RestoreState = .idle
    private var cancelFlag: CancelFlag?

    /// Request cancellation of the in-flight run, if any.
    func cancel() {
        cancelFlag?.cancel()
    }

    /// Run the full method. The default transport is the real loopback
    /// transport (lockdown + mobilebackup2 over the tunnel app).
    func start(
        request: RestoreRequest,
        transport: DeviceTransport = LoopbackTransport(),
        onProgress: @Sendable @escaping (RestoreProgress) -> Void
    ) async throws {
        guard case .idle = state else { throw RestoreError.alreadyInFlight }
        guard request.deviceVersion.isIOS27OrLater else {
            throw RestoreError.unsupportedVersion(major: request.deviceVersion.major)
        }
        guard !request.stagedFeatureIDs.isEmpty else {
            throw RestoreError.nothingStaged
        }

        let flag = CancelFlag()
        cancelFlag = flag
        let watchdog = StallWatchdog()
        let stagingRoot = RestoreEngine.stagingRoot(label: request.deviceLabel)
        let cancelled: @Sendable () -> Bool = { flag.isCancelled }

        func throwIfCancelled() throws {
            if flag.isCancelled || Task.isCancelled { throw RestoreError.cancelled }
        }

        do {
            // — Phase 1: BACKUP ALL DATA FULL —
            state = .running(.backup)
            await watchdog.noteProgress()
            try throwIfCancelled()
            let backupResult = try await BackupPhase.run(
                request: request, stagingRoot: stagingRoot, transport: transport,
                progress: onProgress, isCancelled: cancelled
            )
            await watchdog.noteProgress()
            try throwIfCancelled()
            try await watchdog.check(phase: .backup)

            // — Phase 2: PAYLOAD FILE (dozens of locations, per active tweaks) —
            state = .running(.payload)
            let payloadResult = try await PayloadPhase.run(
                request: request, stagingRoot: stagingRoot,
                progress: onProgress, isCancelled: cancelled
            )
            await watchdog.noteProgress()
            try throwIfCancelled()
            try await watchdog.check(phase: .payload)

            // — Phase 3: MODIF (inject payload into the backup staging) —
            state = .running(.modify)
            _ = try await ModifyPhase.run(
                request: request,
                backupRoot: backupResult.backupRoot,
                payloadManifest: payloadResult.manifestURL,
                progress: onProgress, isCancelled: cancelled
            )
            await watchdog.noteProgress()
            try throwIfCancelled()
            try await watchdog.check(phase: .modify)

            // — Phase 4: RESTORE FULL —
            state = .running(.restore)
            try await RestorePhase.run(
                request: request,
                backupRoot: backupResult.backupRoot,
                transport: transport,
                progress: onProgress, isCancelled: cancelled
            )
            await watchdog.noteProgress()
            try throwIfCancelled()
            try await watchdog.check(phase: .restore)

            // — Phase 5: RESTART (with restart notification) —
            state = .running(.restart)
            _ = try await RestartPhase.run(transport: transport, progress: onProgress)
            await watchdog.noteProgress()

            state = .succeeded
            cancelFlag = nil
        } catch let error as RestoreError {
            switch error {
            case .cancelled:
                state = .cancelled
            default:
                state = .failed(error.localizedDescription)
            }
            cancelFlag = nil
            throw error
        } catch {
            state = .failed(error.localizedDescription)
            cancelFlag = nil
            throw error
        }
    }

    // MARK: - Staging

    static func stagingRoot(label: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = label.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return docs.appendingPathComponent("RestoreEngine/\(safe)", isDirectory: true)
    }
}
