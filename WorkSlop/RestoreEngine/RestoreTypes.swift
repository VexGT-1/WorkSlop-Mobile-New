import Foundation

// MARK: - Phase identity
//
// The iOS 27 method, exactly as ordered: BACKUP ALL DATA FULL → PAYLOAD FILE
// (dozens of locations, per active tweaks) → MODIF → RESTORE FULL → RESTART
// (with restart notification). One phase = one unit; each phase owns a
// structured result type, honest progress, and honest errors.

enum RestorePhaseID: String, CaseIterable, Sendable {
    case backup
    case payload
    case modify
    case restore
    case restart

    var displayName: String {
        switch self {
        case .backup:  return "Backup (full)"
        case .payload: return "Payload"
        case .modify:  return "Modify"
        case .restore: return "Restore (full)"
        case .restart: return "Restart"
        }
    }

    /// Overall-progress weight range for this phase (0...1). Reported
    /// honestly: a phase only advances its own slice.
    var weight: (lo: Double, hi: Double) {
        switch self {
        case .backup:  return (0.00, 0.30)
        case .payload: return (0.30, 0.45)
        case .modify:  return (0.45, 0.60)
        case .restore: return (0.60, 0.95)
        case .restart: return (0.95, 1.00)
        }
    }
}

// MARK: - Device version (never guessed)

/// Parsed from the live lockdown value at run time. An unknown/empty
/// version refuses the run — guessing once bricked a 27.0 device down
/// the iOS 26 branch (MBErrorDomain/205, no keybag in manifest).
struct DeviceVersion: Sendable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2, let major = parts.first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    var isIOS27OrLater: Bool { major >= 27 }

    var description: String { "\(major).\(minor).\(patch)" }
}

// MARK: - Prerequisites

enum PrerequisiteStatus: Sendable {
    case passed
    case failed(reason: String)
    /// The sandbox cannot verify this; the user attests it. Recorded, not faked.
    case attestedUnverifiable(note: String)
}

struct PrerequisiteCheck: Sendable {
    let name: String
    let status: PrerequisiteStatus

    var isOK: Bool {
        switch status {
        case .passed, .attestedUnverifiable: return true
        case .failed: return false
        }
    }
}

// MARK: - Progress

/// Phase-local progress. The engine maps `fraction` through the phase's
/// weight range for the overall bar; phases never claim another phase's
/// slice.
struct RestoreProgress: Sendable {
    let phase: RestorePhaseID
    /// 0...1 within the phase.
    let fraction: Double
    let message: String
}

// MARK: - Errors (all honest, all typed)

enum RestoreError: Error, LocalizedError, Sendable {
    /// A second run was attempted while one is in flight. FFI-class calls
    /// cannot be interrupted; stacking runs is how use-after-free happens.
    case alreadyInFlight
    case cancelled
    /// Version string empty/unparseable — the run is refused, never guessed.
    case versionUnknown
    /// The run was started with zero staged tweaks — meaningless, refused.
    case nothingStaged
    /// This engine is the iOS 27 method; older majors take another path.
    case unsupportedVersion(major: Int)
    case prerequisitesFailed([PrerequisiteCheck])
    /// Stall-based watchdog: no progress for 10 minutes. No hard deadline —
    /// a healthy backup/restore is never cut off for being slow.
    case stalled(phase: RestorePhaseID)
    case diskSpaceInsufficient(neededBytes: Int64, availableBytes: Int64)
    /// Something the app genuinely cannot do yet. Thrown loudly with the
    /// missing piece named — never silently faked as success.
    case unimplemented(what: String, needed: String)
    case modifyFailed(reason: String)
    case phaseFailed(phase: RestorePhaseID, message: String)

    var errorDescription: String? {
        switch self {
        case .alreadyInFlight:
            return "A restore run is already in flight. Wait for it to finish or cancel it first — runs are never stacked."
        case .cancelled:
            return "Restore cancelled by the user."
        case .versionUnknown:
            return "Device version is unknown. The run is refused rather than guessing (a guessed version once sent a 27.0 device down the wrong branch)."
        case .nothingStaged:
            return "No tweaks staged. Stage at least one tweak before running the restore method."
        case .unsupportedVersion(let major):
            return "This engine implements the iOS 27 full backup/restore method; device reports iOS \(major), which takes a different path."
        case .prerequisitesFailed(let checks):
            let bad = checks.filter { !$0.isOK }.map { $0.name }.joined(separator: ", ")
            return "Prerequisites failed: \(bad)."
        case .stalled(let phase):
            return "Stalled in \(phase.displayName): no progress for 10 minutes. Aborting rather than hanging forever."
        case .diskSpaceInsufficient(let needed, let available):
            return "Not enough free space for a full backup: need \(needed) bytes, have \(available)."
        case .unimplemented(let what, let needed):
            return "Not implemented: \(what). Needed: \(needed)."
        case .modifyFailed(let reason):
            return "Modify phase failed: \(reason)."
        case .phaseFailed(let phase, let message):
            return "\(phase.displayName) phase failed: \(message)."
        }
    }
}
