import Foundation

// MARK: - Phase 3: MODIF
//
// Injects the payload files into the full-backup staging tree at their
// domain/relativePath locations — the local, real half of "modify".
// (Manifest.db row surgery happens over the transport at restore time;
// the row-shape spec lives in DeviceTransport for that future work.)
//
// SAFETY, non-negotiable on iOS 27: a nulled file MUST be a valid EMPTY
// PLIST. A 0-byte plist on iOS 27 bootloops SpringBoard. This phase
// enforces that by version — it never writes 0 bytes on 27+.

enum ModifyPhase {
    struct Result: Sendable {
        let backupRoot: URL
        let injectedCount: Int
        /// Files that would have been 0 bytes but were written as valid
        /// empty plists because the target is iOS 27+.
        let nulledAsEmptyPlistCount: Int
    }

    static func run(
        request: RestoreRequest,
        backupRoot: URL,
        payloadManifest: URL,
        progress: @Sendable (RestoreProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) async throws -> Result {
        func report(_ fraction: Double, _ message: String) {
            progress(RestoreProgress(phase: .modify, fraction: fraction, message: message))
        }

        report(0.05, "Reading payload manifest…")
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: payloadManifest)
        } catch {
            throw RestoreError.modifyFailed(reason: "Cannot read payload manifest: \(error.localizedDescription)")
        }
        let entries: [PayloadPhase.ManifestEntry]
        do {
            entries = try JSONDecoder().decode([PayloadPhase.ManifestEntry].self, from: manifestData)
        } catch {
            throw RestoreError.modifyFailed(reason: "Payload manifest is corrupt: \(error.localizedDescription)")
        }
        guard !entries.isEmpty else {
            throw RestoreError.modifyFailed(reason: "Payload manifest is empty — nothing to inject.")
        }

        let payloadDir = payloadManifest.deletingLastPathComponent()
        var injected = 0
        var nulled = 0

        for (index, entry) in entries.enumerated() {
            if isCancelled() { throw RestoreError.cancelled }
            let src = payloadDir.appendingPathComponent(entry.fileName)
            // Destination mirrors the backup tree: <backupRoot>/<domain>/<relativePath>
            let dest = backupRoot
                .appendingPathComponent(entry.domain, isDirectory: true)
                .appendingPathComponent(entry.restorePath)
            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let srcSize = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.intValue ?? -1
                if srcSize == 0 && request.deviceVersion.isIOS27OrLater {
                    // Nulled file on iOS 27: valid empty plist, NEVER 0 bytes.
                    try emptyPlistData().write(to: dest)
                    nulled += 1
                } else {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: src, to: dest)
                }
                injected += 1
            } catch {
                throw RestoreError.modifyFailed(reason: "Inject \(entry.domain):\(entry.restorePath): \(error.localizedDescription)")
            }
            report(0.05 + 0.90 * Double(index + 1) / Double(entries.count),
                   "Modify \(index + 1)/\(entries.count)")
        }

        report(1.0, "Modify done: \(injected) injected (\(nulled) nulled as empty plist).")
        return Result(backupRoot: backupRoot, injectedCount: injected, nulledAsEmptyPlistCount: nulled)
    }

    /// A valid empty plist. What iOS 27 requires where older systems
    /// tolerated 0 bytes.
    static func emptyPlistData() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>

        """.utf8)
    }
}
