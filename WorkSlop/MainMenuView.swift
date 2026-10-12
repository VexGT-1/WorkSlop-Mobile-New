import SwiftUI

/// Home: the WorkSlop hero, device gates, the Apply button, and the
/// two menus (All Tweaks, Settings). SkyBackground behind everything.
///
/// Screenshot runs deep-link with `-DemoScreen <name>`:
/// home | alltweaks | settings | apply.
enum HomeRoute: Hashable {
    case allTweaks
    case settings
    case apply
}

struct MainMenuView: View {
    let demoScreen: String?
    @EnvironmentObject private var status: StatusStore
    @EnvironmentObject private var selection: SelectionStore
    @State private var path: [HomeRoute] = []
    @State private var importing = false
    @State private var pairingNote: String?
    @State private var showTunnelInfo = false
    @State private var showAbout = false

    init(demoScreen: String? = nil) {
        self.demoScreen = demoScreen
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SkyBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        hero
                        deviceCard
                        applyButton
                        menusCard
                        LockBanner()
                    }
                    .padding()
                }
                .onChange(of: pairingNote) { _, new in
                    // Transient notes only: clear after 6s so a stale
                    // message never sits on screen.
                    guard let current = new else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        if pairingNote == current {
                            pairingNote = nil
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .allTweaks: AllTweaksView()
                case .settings: SettingsView()
                case .apply: ApplyView()
                }
            }
        }
        .onAppear {
            guard path.isEmpty, let s = demoScreen else { return }
            switch s {
            case "alltweaks": path = [.allTweaks]
            case "settings": path = [.settings]
            case "apply": path = [.apply]
            default: break
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.propertyList]
        ) { result in
            switch result {
            case .success(let url): flashNote(importPairing(from: url) ?? "Pairing file saved.")
            case .failure: flashNote("Import cancelled.")
            }
        }
        .sheet(isPresented: $showTunnelInfo) { TunnelInfoView() }
        .sheet(isPresented: $showAbout) { AboutInfoView() }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 8) {
            Image("BrandBlue")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            HStack(spacing: 6) {
                Text("WorkSlop")
                    .font(.title.weight(.bold))
                Button {
                    showAbout = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-info")
            }
            Text("\(DeviceStatus.modelOrDash) • \(DeviceInfoEx.versionWithBuild)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Device gates

    /// One status card: pairing file and VPN tunnel share a card with a
    /// divider between them. Secondary actions are plain text links
    /// (never gray pills) so the Apply button keeps its visual hierarchy.
    private var deviceCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label {
                    Text("Pairing file")
                } icon: {
                    RowIcon(name: "key.fill")
                }
                Spacer()
                Text(status.pairingImported ? "Imported" : "Not imported")
                    .foregroundStyle(status.pairingImported ? Color.green : .secondary)
                    .fontWeight(status.pairingImported ? .semibold : .regular)
            }
            .padding(.vertical, 12)

            HStack {
                Button(status.pairingImported ? "Re-import pairing file" : "Import pairing file (.plist)") {
                    importing = true
                }
                .accessibilityIdentifier("import-pairing")
                Spacer()
                if status.pairingImported {
                    Button("Delete", role: .destructive) {
                        do {
                            try FileManager.default.removeItem(at: PairingStore.fileURL)
                            status.pairingChanged()
                            flashNote("Pairing file deleted from the app container.")
                        } catch {
                            flashNote("Could not delete the pairing file: \(error.localizedDescription)")
                        }
                    }
                }
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            if let pairingNote {
                Text(pairingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Label {
                    Text("VPN tunnel")
                } icon: {
                    RowIcon(name: "network")
                }
                Spacer()
                Text(status.vpnDetected ? "DETECTED" : "-")
                    .foregroundStyle(status.vpnDetected ? Color.green : .secondary)
                    .fontWeight(status.vpnDetected ? .semibold : .regular)
            }
            .padding(.vertical, 12)
            .accessibilityIdentifier("status-vpn")

            HStack {
                Button {
                    showTunnelInfo = true
                } label: {
                    Label("What is the VPN tunnel?", systemImage: "info.circle")
                }
                Spacer()
                Button("Refresh") { status.refresh() }
                    .disabled(status.probing)
                    .accessibilityIdentifier("refresh-status")
            }
            .font(.subheadline)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    /// Shows a transient note under the pairing row, then clears it so a
    /// stale message never lingers on screen (the "deleted" note in the
    /// screenshot was from an old action).
    private func flashNote(_ note: String) {
        pairingNote = note
    }

    // MARK: - Apply

    private var applyButton: some View {
        Button {
            path.append(.apply)
        } label: {
            Text(applyLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canApply)
        .accessibilityIdentifier("apply-button")
    }

    private var canApply: Bool {
        status.unlocked && !selection.staged.isEmpty
    }

    private var applyLabel: String {
        if selection.staged.isEmpty { return "Apply (stage tweaks first)" }
        if !status.pairingImported { return "Apply (import pairing file first)" }
        if !status.vpnDetected { return "Apply (VPN tunnel not detected)" }
        return "Apply (\(selection.staged.count) tweaks)"
    }

    // MARK: - Menus

    /// Native-style navigation rows: representative SF Symbols, a
    /// disclosure chevron, clean dividers. No pill buttons here.
    private var menusCard: some View {
        VStack(spacing: 0) {
            NavigationLink(value: HomeRoute.allTweaks) {
                HStack {
                    Label {
                        Text("All Tweaks")
                    } icon: {
                        RowIcon(name: "sparkles")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-all-tweaks")
            Divider()
                .padding(.leading, 46)
            NavigationLink(value: HomeRoute.settings) {
                HStack {
                    Label {
                        Text("Settings")
                    } icon: {
                        RowIcon(name: "gear")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-settings")
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.88))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    // MARK: - Pairing import

    private func importPairing(from url: URL) -> String? {
        guard url.pathExtension.lowercased() == "plist" else {
            return "Only a .plist pairing file is accepted - nothing was saved."
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            return "The file could not be read - nothing was saved."
        }
        guard PairingStore.validate(data) else {
            return "That file is not a readable pairing record (.plist) - nothing was saved."
        }
        do {
            try PairingStore.save(data)
            status.pairingChanged()
            return "Pairing file saved."
        } catch {
            return "Could not save the pairing file: \(error.localizedDescription)"
        }
    }
}

// MARK: - About / risks / how-to

/// What the (i) button next to the WorkSlop title opens: the honest
/// risks, the steps to use the app, and how the iOS 26 and iOS 27
/// methods differ. English only - translations live in
/// Localizable.xcstrings and are handled separately.
struct AboutInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Applying tweaks on iOS 27 is experimental and risky. iOS 27 can put your iPhone into a BOOTLOOP (stuck on the Apple logo, will not start).")
                    Text("A full backup of ALL your data is taken before anything is written, but a backup cannot undo every kind of damage. The owner of this software (adnan.120hz) is NOT responsible for any damage, bootloop, or data loss.")
                    Text("Your device backup must NOT be encrypted, otherwise the apply is refused before anything is written.")
                    Text("Find My must be OFF before an apply and back ON afterwards. A running restore cannot be cancelled mid-flight - never force-quit the app while it runs.")
                } header: {
                    Text("Risks")
                }

                Section {
                    Text("1. Import your pairing file (.plist) on this screen. On iOS 26 it comes from a computer (iDevice Pair / Apple Configurator); without it nothing can be delivered.")
                    Text("2. Start a loopback VPN tunnel (WireGuard or StikDebug with a loopback configuration) until the VPN tunnel row above says DETECTED. This is not an internet VPN - no traffic leaves your iPhone.")
                    Text("3. Open All Tweaks, pick a category, and stage the tweaks you want with the toggles.")
                    Text("4. Back on Home, tap Apply. Confirm Find My is OFF, then follow the progress. When it finishes, restart your iPhone manually and check the tweaks.")
                } header: {
                    Text("How to use")
                }

                Section {
                    Text("iOS 16 - 26: partial (sparse) restore. Only the staged files are delivered - no full backup, no wipe, no reboot by the app.")
                    Text("iOS 27: full backup → payload → modify → restore, with all your data (the WorkSlop Desktop method). The phone is rebooted as part of the method; if it does not come back, force-restart it (Volume Up, Volume Down, hold the Side button).")
                } header: {
                    Text("iOS 26 vs iOS 27")
                }
            }
            .navigationTitle("About WorkSlop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
