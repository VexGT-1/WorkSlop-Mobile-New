import SwiftUI

/// Apply: the real thing. Preflight checks, the user's Find My
/// attestation, then the on-device restore engine:
///
/// - iOS 27+: full backup → payload → modify → restore → restart.
/// - iOS 26 and below: partial (sparse) restore, no wipe.
///
/// Nothing here is a preview: progress comes from the engine's
/// RestoreProgress ticks, and success is only reported when the
/// device confirms.
///
/// Cancel is REAL, not UI-only: the Cancel button cancels the Swift
/// Task running the engine AND sets the engine's cancel flag. The
/// transport disconnects the device socket on cancellation, unblocking
/// hung reads — after cancel, no background work survives (this is the
/// fix for runs that kept going after the user asked them to stop).
struct ApplyView: View {
    @EnvironmentObject private var status: StatusStore
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var iconStage: IconStage

    @State private var findMyOff = false
    @State private var riskAccepted = false
    @State private var backupPassword = ""
    @State private var running = false
    @State private var cancelling = false
    @State private var progress: RestoreProgress?
    @State private var logLines: [String] = []
    @State private var lastLoggedPercent = -1
    @State private var result: ApplyResult?
    @State private var showRestartSheet = false
    /// The live run's task — stored so Cancel can REALLY stop it.
    @State private var applyTask: Task<Void, Never>?

    private enum ApplyResult {
        case succeeded
        case failed(String)
        /// Cancelled before the device was written: nothing changed.
        case cancelled(phaseName: String)
        /// Cancelled while the restore push was in flight: the device
        /// may hold partial changes — re-running Apply completes them.
        case cancelledDuringRestore(phaseName: String)
    }

    /// The iOS 27 full method needs the explicit bootloop-risk acceptance;
    /// the engine fail-closes without it.
    private var needsRiskAcceptance: Bool {
        DeviceInfo.iosVersion.major >= 27
    }

    var body: some View {
        List {
            Section {
                preflightRow("Tweaks staged", ok: !effectiveStaged.isEmpty,
                             detail: "\(selection.staged.count + (hasStagedIcons ? 1 : 0))")
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
                Section(cancelling ? "Cancelling…" : "Running") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(Int(progress.fraction * 100))%")
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                            Spacer()
                            Text(cancelling ? "Stopping…" : progress.phase.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress.fraction)
                        Text(cancelling
                             ? "Cancel requested — closing device connections…"
                             : progress.message)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }

                Section("Log") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(logLines.indices, id: \.self) { i in
                                    Text(logLines[i])
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .id(i)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                        .onChange(of: logLines.count) { _ in
                            if let last = logLines.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
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
                        NavigationLink {
                            SetupGuideView()
                        } label: {
                            Label("Open the setup guide", systemImage: "book.fill")
                                .font(.footnote)
                        }
                    case .cancelled(let phaseName):
                        Label("Cancelled", systemImage: "stop.circle")
                            .foregroundStyle(Color.orange)
                        Text("Stopped during \(phaseName) before anything was written to the device. All connections are closed — nothing is running in the background.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .cancelledDuringRestore(let phaseName):
                        Label("Cancelled during restore", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange)
                        Text("Stopped during \(phaseName). The device may hold partial changes — re-run Apply to complete them. All connections are closed — nothing is running in the background.")
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
                    Button(cancelling ? "Cancelling…" : "Cancel", role: .destructive) {
                        cancelApply()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(cancelling)
                    .accessibilityIdentifier("apply-cancel")
                }

                NavigationLink {
                    SetupGuideView()
                } label: {
                    Label("Setup guide: tunnel app + pairing file", systemImage: "book.fill")
                }
                .accessibilityIdentifier("setup-guide")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cancel stops the run for real: the task is cancelled, device connections are closed, and no background work continues. If cancelled during Restore, re-run Apply to complete the changes.")
                    Text("IMPORTANT: if Cancel does not respond or the app hangs, you MUST fully close WorkSlop (swipe it away from the app switcher). If the problem persists, restart your iPhone manually (Settings → General → Shut Down). This is required to keep your device safe.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apply")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRestartSheet) {
            NavigationStack {
                List {
                    Section {
                        Label("Apply complete", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                            .font(.headline)
                        Text("The device confirmed every phase. Now restart your iPhone so SpringBoard picks up the new files.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Section("How to restart") {
                        Label("Open Settings → General → Shut Down", systemImage: "1.circle")
                        Label("Slide to power off, wait 10 seconds", systemImage: "2.circle")
                        Label("Hold the side button until the Apple logo appears", systemImage: "3.circle")
                        Label("After reboot, check that your tweaks are active", systemImage: "4.circle")
                    }
                    Section {
                        Text("If a tweak didn't take effect, re-run Apply — the engine re-sends only what's needed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Restart your iPhone")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showRestartSheet = false }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - State

    /// Custom icons with a bundle ID count as staged: they are
    /// delivered by the same restore payload, so icons alone (no
    /// other tweak toggled) are enough to enable Apply.
    private var hasStagedIcons: Bool {
        iconStage.entries.contains { !$0.bundleID.isEmpty }
    }

    /// The feature IDs actually sent to the engine: the toggled
    /// tweaks plus "custom-icons" when icons are staged. The ID is
    /// injected into the request only (never persisted into
    /// SelectionStore) so the payload builder's custom-icons gate
    /// fires and the engine's nothing-staged guard passes.
    private var effectiveStaged: Set<String> {
        var ids = selection.staged
        if hasStagedIcons { ids.insert("custom-icons") }
        return ids
    }

    private var canStart: Bool {
        status.unlocked && !effectiveStaged.isEmpty && findMyOff
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
        cancelling = false
        result = nil
        progress = nil
        lastLoggedPercent = -1
        logLines = ["[WorkSlop] Apply started — iOS \(DeviceInfoEx.fullVersion) (\(DeviceInfoEx.buildNumber))"]
        let request = RestoreRequest(
            deviceVersion: version,
            stagedFeatureIDs: effectiveStaged,
            findMyDisabledAttested: findMyOff,
            deviceLabel: "device",
            backupPassword: backupPassword.isEmpty ? nil : backupPassword,
            deviceBuild: DeviceInfoEx.buildNumber,
            riskWarningAccepted: riskAccepted
        )
        // The task handle is stored so Cancel can REALLY stop it:
        // applyTask.cancel() trips Task.isCancelled inside every phase
        // and transport loop, and the transport disconnects the device
        // socket on cancellation. Nothing survives in the background.
        applyTask = Task {
            do {
                // The engine's progress closure is @Sendable; marking ours
                // @MainActor makes it Sendable (global-actor-isolated
                // closures are always safe to share) and keeps the @State
                // write on the main thread.
                try await RestoreEngine.shared.start(
                    request: request,
                    onProgress: { @MainActor p in
                        self.progress = p
                        let pct = Int(p.fraction * 100)
                        // Throttle the log: one line per percent point, not
                        // per tick — a full backup emits thousands of ticks
                        // and the log must not grow without bound.
                        if pct != self.lastLoggedPercent {
                            self.lastLoggedPercent = pct
                            self.logLines.append("[\(pct)%] [\(p.phase.displayName)] \(p.message)")
                        }
                    }
                )
                await MainActor.run {
                    self.applyTask = nil
                    self.running = false
                    self.cancelling = false
                    self.logLines.append("[100%] Done — all phases confirmed by the device.")
                    self.result = .succeeded
                    self.showRestartSheet = true
                }
            } catch is CancellationError {
                await MainActor.run { self.finishCancelled() }
            } catch let error as RestoreError {
                await MainActor.run {
                    if case .cancelled = error {
                        self.finishCancelled()
                    } else {
                        self.applyTask = nil
                        self.running = false
                        self.cancelling = false
                        self.result = .failed(error.localizedDescription)
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.applyTask = nil
                    self.running = false
                    self.cancelling = false
                    self.result = .failed(message)
                }
            }
        }
    }

    /// REAL cancel — not UI-only. Cancels the Swift Task (trips
    /// Task.isCancelled in every phase and transport loop, and the
    /// transport disconnects the device socket so hung reads unblock)
    /// and sets the engine's cancel flag as a backstop. The run stops;
    /// nothing keeps going in the background.
    private func cancelApply() {
        guard running, !cancelling else { return }
        cancelling = true
        logLines.append("[WorkSlop] Cancel requested — stopping the run and closing device connections…")
        applyTask?.cancel()
        Task { await RestoreEngine.shared.cancel() }
    }

    /// Honest cancel report: names the phase that was active and whether
    /// the device may have been written, so the user knows exactly what
    /// to do next.
    private func finishCancelled() {
        let phaseName = progress?.phase.displayName ?? "startup"
        let wasRestore = progress?.phase == .restore
        applyTask = nil
        running = false
        cancelling = false
        logLines.append("[WorkSlop] Cancelled during \(phaseName) — all connections closed, no background work remains.")
        result = wasRestore ? .cancelledDuringRestore(phaseName: phaseName) : .cancelled(phaseName: phaseName)
    }
}

// MARK: - Setup guide

/// Step-by-step: tunnel app + pairing file. This is the missing manual
/// that "backend mati" reports kept asking for: most failures are not
/// code bugs but a missing tunnel app or a bad pairing file, and the
/// preflight rows only say WHAT is red, never HOW to fix it.
struct SetupGuideView: View {
    var body: some View {
        List {
            Section("1 — Install the tunnel app") {
                Text("WorkSlop talks to this iPhone's own lockdownd service through a loopback VPN tunnel (a utun interface pointing at 127.0.0.1). iOS apps cannot open that tunnel themselves — a separate tunnel app does it.")
                Label("Install LocalDevVPN (the tunnel app WorkSlop detects)", systemImage: "1.circle")
                Text("Open LocalDevVPN and enable its loopback configuration (tunnel IP 127.0.0.1). Keep it running while you use WorkSlop.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("2 — Export a pairing file") {
                Text("The tunnel session is authenticated with a pairing file. Export one on a computer:")
                Label("Option A: run \"idevicepair pair\" on a Mac/PC, then copy the generated .plist to this iPhone (AirDrop / Files).", systemImage: "2.circle")
                Label("Option B: use the Jitterbug app to pair and export the pairing file.", systemImage: "2.circle")
                Text("Tip: on iOS 17+ the export may be a RemotePairing file (identifier/private_key/public_key). WorkSlop accepts it for import, but the TLS session upgrade for that format is still unverified — if Apply fails at the handshake, re-export a legacy lockdown pairing file instead.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("3 — Import it here") {
                Label("Main menu → \"Import pairing file (.plist)\" and pick the file.", systemImage: "3.circle")
                Text("A bad file is rejected at import with the exact reason (not a plist, empty, missing keys) — nothing is saved until the file is a recognised pairing record.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("4 — Verify, then Apply") {
                Label("Back on the main menu, refresh the device status: both \"Pairing file\" and \"VPN tunnel detected\" must be green.", systemImage: "4.circle")
                Label("Open Apply: every preflight row must be green before \"Apply now\" enables.", systemImage: "5.circle")
                Text("If a run fails, the Result section names the failing phase (backup / restore / handshake / tunnel) with the device's own error — send that exact text when asking for help, not just \"backend mati\".")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Setup guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}
