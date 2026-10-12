import SwiftUI

/// Apply: the real thing. Preflight checks, the user's Find My
/// attestation, then the on-device restore engine:
///
/// - iOS 27+: full backup → payload → modify → restore → restart.
/// - iOS 26 and below: partial (sparse) restore, no wipe.
///
/// Nothing here is a preview: progress comes from the engine's
/// RestoreProgress ticks, and success is only reported when the
/// device confirms. A running restore cannot be cancelled mid-flight.
struct ApplyView: View {
    @EnvironmentObject private var status: StatusStore
    @EnvironmentObject private var selection: SelectionStore

    @State private var findMyOff = false
    @State private var riskAccepted = false
    @State private var backupPassword = ""
    @State private var running = false
    @State private var progress: RestoreProgress?
    @State private var result: ApplyResult?

    private enum ApplyResult {
        case succeeded
        case failed(String)
    }

    /// The iOS 27 full method needs the explicit bootloop-risk acceptance;
    /// the engine fail-closes without it.
    private var needsRiskAcceptance: Bool {
        DeviceInfo.iosVersion.major >= 27
    }

    var body: some View {
        List {
            Section {
                preflightRow("Tweaks staged", ok: !selection.staged.isEmpty,
                             detail: "\(selection.staged.count)")
                preflightRow("Pairing file imported", ok: status.pairingImported, detail: nil)
                preflightRow("VPN tunnel detected", ok: status.vpnDetected, detail: nil)
                Toggle("Find My is OFF on this iPhone", isOn: $findMyOff)
                    .accessibilityIdentifier("findmy-attest")
                if needsRiskAcceptance {
                    Text(G1Support.riskWarningText)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                    Toggle("I accept the full risk (iOS 27)", isOn: $riskAccepted)
                        .accessibilityIdentifier("risk-accept")
                }
                SecureField("Backup password (only if the backup is encrypted)", text: $backupPassword)
                    .accessibilityIdentifier("backup-password")
                    .disabled(running)
            } header: {
                Text("Preflight")
            } footer: {
                Text(routeText)
            }

            if running, let progress {
                Section("Running") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(progress.message)
                            .font(.subheadline)
                        ProgressView(value: progress.fraction)
                        Text("Phase: \(progress.phase.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let result {
                Section("Result") {
                    switch result {
                    case .succeeded:
                        Label("Sent - restart your iPhone manually", systemImage: "checkmark.circle")
                            .foregroundStyle(Color.green)
                        Text("The device confirmed the restore. Reboot from Settings → General → Shut Down, then verify the tweaks.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Label("Failed", systemImage: "xmark.circle")
                            .foregroundStyle(Color.red)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(running ? "Applying…" : "Apply now") {
                    startApply()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!canStart || running)
                .accessibilityIdentifier("apply-now")

                if running {
                    Button("Cancel (between phases only)", role: .destructive) {
                        Task { await RestoreEngine.shared.cancel() }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("apply-cancel")
                }
            } footer: {
                Text("A restore already in flight is never interrupted - cancel only takes effect between phases.")
            }
        }
        .navigationTitle("Apply")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - State

    private var canStart: Bool {
        status.unlocked && !selection.staged.isEmpty && findMyOff
            && (!needsRiskAcceptance || riskAccepted)
    }

    private var routeText: String {
        let major = DeviceInfo.iosVersion.major
        if major >= 27 {
            return "This device runs iOS \(major): full backup → payload → modify → restore, then restart."
        }
        return "This device runs iOS \(major): partial (sparse) restore, no wipe."
    }

    private func preflightRow(_ title: String, ok: Bool, detail: String?) -> some View {
        HStack {
            Label(title, systemImage: ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(ok ? Color.green : Color.red)
            Spacer()
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Run

    private func startApply() {
        guard canStart, !running else { return }
        guard let version = DeviceVersion(DeviceInfoEx.fullVersion) else {
            result = .failed("Could not read this device's iOS version - refusing to guess.")
            return
        }
        running = true
        result = nil
        progress = nil
        let request = RestoreRequest(
            deviceVersion: version,
            stagedFeatureIDs: selection.staged,
            findMyDisabledAttested: findMyOff,
            deviceLabel: "device",
            backupPassword: backupPassword.isEmpty ? nil : backupPassword,
            deviceBuild: DeviceInfoEx.buildNumber,
            riskWarningAccepted: riskAccepted
        )
        Task {
            do {
                // The engine's progress closure is @Sendable; marking ours
                // @MainActor makes it Sendable (global-actor-isolated
                // closures are always safe to share) and keeps the @State
                // write on the main thread.
                try await RestoreEngine.shared.start(
                    request: request,
                    onProgress: { @MainActor p in self.progress = p }
                )
                await MainActor.run {
                    self.running = false
                    self.result = .succeeded
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.running = false
                    self.result = .failed(message)
                }
            }
        }
    }
}
