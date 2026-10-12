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
            }
            .navigationTitle("WorkSlop")
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
            case .success(let url): pairingNote = importPairing(from: url)
            case .failure: pairingNote = "Import cancelled."
            }
        }
        .sheet(isPresented: $showTunnelInfo) { TunnelInfoView() }
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
            Text("WorkSlop")
                .font(.title.weight(.bold))
            Text("\(DeviceStatus.modelOrDash) • \(DeviceInfoEx.versionWithBuild)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Device gates

    private var deviceCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Pairing file", systemImage: "key.fill")
                Spacer()
                Text(status.pairingImported ? "Imported" : "Not imported")
                    .foregroundStyle(status.pairingImported ? Color.green : .secondary)
                    .fontWeight(status.pairingImported ? .semibold : .regular)
            }
            .padding(.vertical, 10)

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
                            pairingNote = "Pairing file deleted from the app container."
                        } catch {
                            pairingNote = "Could not delete the pairing file: \(error.localizedDescription)"
                        }
                    }
                }
            }
            .font(.subheadline)
            .padding(.bottom, 4)

            if let pairingNote {
                Text(pairingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }

            Divider()

            HStack {
                Label("VPN tunnel", systemImage: "network")
                Spacer()
                Text(status.vpnDetected ? "DETECTED" : "-")
                    .foregroundStyle(status.vpnDetected ? Color.green : .secondary)
                    .fontWeight(status.vpnDetected ? .semibold : .regular)
            }
            .padding(.vertical, 10)
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
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
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

    private var menusCard: some View {
        VStack(spacing: 0) {
            NavigationLink(value: HomeRoute.allTweaks) {
                Label("All Tweaks", systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            .accessibilityIdentifier("menu-all-tweaks")
            Divider()
            NavigationLink(value: HomeRoute.settings) {
                Label("Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
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
