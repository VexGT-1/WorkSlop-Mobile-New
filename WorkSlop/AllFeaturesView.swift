import SwiftUI
import PhotosUI

/// Every tweak and feature in one Settings-style grouped table.
/// Plain native rows — no per-row glass, no custom backgrounds, no
/// animation behind the scrolling content.
struct AllFeaturesView: View {
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore
    @StateObject private var iconStage = IconStage()

    var body: some View {
        List {
            Section {
                LockBanner()
            }

            Section("Status") {
                StatusRows()
            }

            Section {
                ForEach(liquidGlassLatest) { feature in
                    FeatureToggleRow(feature: feature)
                }
            } header: {
                Text("Liquid Glass (Latest)")
            } footer: {
                Text("SolariumForceFallback is read live by DesignLibrary from com.apple.SwiftUI on iOS 26.6.1 (firmware-verified). Its on-screen effect is not proven - an isolated device test decides it (full backup first, Low Power Mode off, reboot after apply).")
            }

            Section("Liquid Glass") {
                ForEach(liquidGlassRegular) { feature in
                    FeatureToggleRow(feature: feature)
                }
            } footer: {
                Text("Partial restore on iOS 26, Full backup \u{2192} modify \u{2192} restore on iOS 27 - the same split as desktop.")
            }

            Section("Status Bar") {
                ForEach(FeatureCatalog.features(in: "Status Bar")) { feature in
                    FeatureToggleRow(feature: feature)
                }
                NavigationLink {
                    StatusBarDetailView()
                } label: {
                    Label("Status Bar details", systemImage: "antenna.radiowaves.left.and.right")
                }
                .accessibilityIdentifier("nav-statusbar-details")
            } footer: {
                Text("Target: Library/SpringBoard/statusBarOverrides - a fixed 3,944-byte struct, not a plist (firmware-audited on iOS 26.6.1). The full-bars look without a SIM is visual only; it does not restore cellular service.")
            }

            Section("SpringBoard") {
                ForEach(FeatureCatalog.features(in: "SpringBoard")) { feature in
                    FeatureToggleRow(feature: feature)
                }
            }

            Section("Daemons") {
                ForEach(FeatureCatalog.features(in: "Daemons")) { feature in
                    FeatureToggleRow(feature: feature)
                }
            } footer: {
                Text("Daemon toggles stage the same disabled-daemons list the desktop manages.")
            }

            Section("Recommended") {
                ForEach(FeatureCatalog.features(in: "Recommended")) { feature in
                    FeatureToggleRow(feature: feature)
                }
            } footer: {
                Text("The desktop one-tap Recommended analytics set, as individual switches.")
            }

            Section("Apple Internal") {
                ForEach(FeatureCatalog.features(in: "Internal Options")) { feature in
                    FeatureToggleRow(feature: feature)
                }
            } footer: {
                Text("Internal debug switches from Apple's own preference domains. Only keys verified in the iOS firmware are listed.")
            }

            Section("PosterBoard") {
                ForEach(FeatureCatalog.features(in: "PosterBoard")) { feature in
                    FeatureToggleRow(feature: feature)
                }
                NavigationLink {
                    PosterBoardFilesView()
                } label: {
                    Label("Manage files", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("nav-posterboard-files")
            } footer: {
                Text("Descriptors ride the Partial restore route (max iOS 26), like the desktop Descriptors mode.")
            }

            Section("Custom Icons") {
                ForEach(FeatureCatalog.features(in: "Custom Icons")) { feature in
                    FeatureToggleRow(feature: feature)
                }
            } footer: {
                Text("With this on and at least one complete icon below, the staging payload built on disk gains one WorkSlop .webclip folder per app (Info.plist + icon.png). Nothing is on the Home Screen until the restore engine delivers it.")
            }

            YourIconsSection()

            Section("Dark") {
                ForEach(IOS18IconCatalog.darkIcons) { icon in
                    GalleryRow(icon: icon, variant: .dark)
                }
            } footer: {
                Text("The same apps in their iOS 18 dark-mode artwork. Tap one to stage it with its real name and bundle ID.")
            }

            Section("Light") {
                ForEach(IOS18IconCatalog.all) { icon in
                    GalleryRow(icon: icon, variant: .light)
                }
            } footer: {
                Text("The iOS 18 stock icons from your icon pack.")
            }

            Section("Tinted") {
                ForEach(IOS18IconCatalog.tintedIcons) { icon in
                    GalleryRow(icon: icon, variant: .tinted)
                }
            } footer: {
                Text("The same apps in their iOS 18 tinted artwork.")
            }

            Section("Settings") {
                SettingsRows()
            }

            Section {
                ApplySection()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .environmentObject(iconStage)
    }

    private var liquidGlassLatest: [Feature] {
        FeatureCatalog.features(in: "Liquid Glass").filter { $0.id == "lg-latest" }
    }

    private var liquidGlassRegular: [Feature] {
        FeatureCatalog.features(in: "Liquid Glass").filter { $0.id != "lg-latest" }
    }
}

// MARK: - Status rows

/// VPN tunnel (- / DETECTED), pairing file (import + status),
/// device facts and the lockdownd refresh — all reading the single
/// StatusStore from the environment.
private struct StatusRows: View {
    @EnvironmentObject private var status: StatusStore
    @State private var importing = false
    @State private var pairingNote: String?
    @State private var showTunnelInfo = false

    var body: some View {
        Group {
        LabeledContent {
            Text(status.vpnDetected ? "DETECTED" : "-")
                .foregroundStyle(status.vpnDetected ? Color.green : .secondary)
                .fontWeight(status.vpnDetected ? .semibold : .regular)
        } label: {
            Label("VPN tunnel", systemImage: "network")
        }
        .accessibilityIdentifier("status-vpn")

        LabeledContent {
            Text(status.pairingImported ? "Imported" : "Not imported")
                .foregroundStyle(.secondary)
        } label: {
            Label("Pairing file", systemImage: "key.fill")
        }
        .accessibilityIdentifier("status-pairing")

        Button("Import pairing file (.plist)") { importing = true }
            .accessibilityIdentifier("import-pairing")

        if status.pairingImported {
            Button("Delete pairing file", role: .destructive) {
                do {
                    try FileManager.default.removeItem(at: PairingStore.fileURL)
                    status.pairingChanged()
                    pairingNote = "Pairing file deleted from the app container."
                } catch {
                    pairingNote = "Could not delete the pairing file: \(error.localizedDescription)"
                }
            }
        }

        if let pairingNote {
            Text(pairingNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Button {
            showTunnelInfo = true
        } label: {
            Label("What is the VPN tunnel?", systemImage: "info.circle")
        }
        .accessibilityIdentifier("tunnel-info")

        LabeledContent("Device", value: "\(DeviceStatus.modelOrDash) \u{2022} \(DeviceInfoEx.versionWithBuild)")
            .font(.footnote)

        Button("Refresh device status") {
            status.refresh()
        }
        .disabled(status.probing)
        .accessibilityIdentifier("refresh-status")

        if status.probing {
            ProgressView()
        } else {
            Text(status.engineStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.propertyList]) { result in
            switch result {
            case .success(let url):
                pairingNote = importPairing(from: url)
            case .failure:
                pairingNote = "Import cancelled."
            }
        }
        .sheet(isPresented: $showTunnelInfo) { TunnelInfoView() }
    }

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

// MARK: - Lock banner

/// Shown at the top while the pairing-file + VPN gate is closed.
private struct LockBanner: View {
    @EnvironmentObject private var status: StatusStore

    var body: some View {
        if !status.unlocked {
            Text(ActivationGate.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - One flat tweak row: toggle, never a slider

struct FeatureToggleRow: View {
    let feature: Feature
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore
    @State private var showInfo = false

    private var availability: Availability {
        feature.availability(for: DeviceInfo.iosVersion)
    }

    /// Toggle is live only when the iOS supports the tweak AND the
    /// pairing-file + VPN gate is open.
    private var toggleEnabled: Bool {
        availability.isEnabled && status.unlocked
    }

    /// What the tweak writes, where, and through which route — from
    /// the payload spec itself.
    private var explanation: String {
        var lines: [String] = []
        lines.append(feature.subtitle)
        if let spec = PayloadSpecCatalog.all.first(where: { $0.featureID == feature.id }) {
            for w in spec.writes {
                if let key = w.key {
                    lines.append("Writes \(key) to \(w.filePath) (\(w.domain.rawValue)).")
                } else if let target = w.fileTarget {
                    lines.append("Target: \(target) at \(w.filePath) (\(w.domain.rawValue)).")
                }
                if let condition = w.condition {
                    lines.append(condition)
                }
            }
            if let note = spec.note {
                lines.append(note)
            }
        }
        lines.append("Route: \(feature.routeSummary). Support: \(feature.window.label).")
        if feature.id == "lg-latest" {
            lines.append("Build gate: iOS 26.6.x (23G82/23G83) only - the desktop arms this set on those builds.")
        }
        if feature.id == "status-bar" {
            lines.append("Classic overrides are iOS 26.x; on iOS 27 only the carrier names apply.")
        }
        return lines.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { selection.isOn(feature.id) },
                set: { selection.set(feature.id, $0) })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .lineLimit(2)
                    Text(feature.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !availability.isEnabled, let chip = availability.chipText {
                        Text(chip)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(!toggleEnabled)
            .accessibilityIdentifier("toggle-\(feature.id)")
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("info-\(feature.id)")
        }
        .opacity(availability.isEnabled ? 1 : 0.6)
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                ScrollView {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(feature.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") { showInfo = false }
                }
            }
        }
    }
}

// MARK: - Your icons + gallery

private struct YourIconsSection: View {
    @EnvironmentObject private var stage: IconStage
    @State private var picked: PhotosPickerItem?
    @State private var editingIndex: Int?

    var body: some View {
        Section("Your Icons") {
            ForEach(stage.entries.indices, id: \.self) { i in
                HStack(spacing: 12) {
                    if let data = stage.entries[i].imageData,
                       let img = EntryImageCache.thumbnail(data) {
                        Image(uiImage: img)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "app").foregroundStyle(.secondary))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.entries[i].appName.isEmpty ? "Unnamed app" : stage.entries[i].appName)
                        Text(stage.entries[i].bundleID.isEmpty ? "Bundle ID not set" : stage.entries[i].bundleID)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editingIndex = i }
                        .font(.footnote)
                }
            }
            .onDelete { offsets in
                stage.remove(at: offsets)
            }
            Button("Add app icon") {
                editingIndex = stage.addBlank()
            }
            .accessibilityIdentifier("icons-add")
        } footer: {
            Text("Pick an image, fill the app name and its bundle ID (for example com.apple.mobilesafari). Staged icons are written as Home Screen web clips by the same restore payload as the desktop icon themes.")
        }
        .sheet(item: Binding(
            get: { editingIndex.map { IndexBox(value: $0) } },
            set: { editingIndex = $0?.value })) { box in
                iconEditor(box.value)
            }
    }

    private struct IndexBox: Identifiable { let value: Int; var id: Int { value } }

    @ViewBuilder
    private func iconEditor(_ i: Int) -> some View {
        if stage.entries.indices.contains(i) {
            NavigationStack {
                Form {
                    Section("App") {
                        TextField("App name", text: $stage.entries[i].appName)
                        TextField("Bundle ID", text: $stage.entries[i].bundleID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section("Icon image") {
                        if let data = stage.entries[i].imageData, let img = EntryImageCache.full(data) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        PhotosPicker(selection: $picked, matching: .images) {
                            Label("Import image (JPEG / PNG / RAW)", systemImage: "photo")
                        }
                        Text("A bundle ID is required before this icon can be staged. The app name may stay empty (hidden label, like desktop).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Icon")
                .toolbar {
                    Button("Done") {
                        stage.save()
                        editingIndex = nil
                    }
                }
                .onChange(of: picked) { item in
                    Task {
                        if let raw = try? await item?.loadTransferable(type: Data.self),
                           let image = UIImage(data: raw),
                           let png = image.pngData() {
                            stage.entries[i].imageData = png
                            stage.save()
                        }
                    }
                }
            }
        }
    }
}

/// One row of the iOS 18 gallery tables (Dark / Light / Tinted).
private struct GalleryRow: View {
    let icon: IOS18Icon
    let variant: IconVariant
    @EnvironmentObject private var stage: IconStage

    var body: some View {
        Button {
            guard let data = galleryData() else { return }
            stage.stage(CustomIconEntry(bundleID: icon.bundleID, appName: icon.name, imageData: data))
        } label: {
            HStack(spacing: 12) {
                if let img = galleryImage() {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(icon.name)
                        .foregroundStyle(.primary)
                    Text(icon.bundleID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: stage.isStaged(bundleID: icon.bundleID) ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(stage.isStaged(bundleID: icon.bundleID) ? Color.green : Color.accentColor)
            }
        }
        .accessibilityIdentifier("ios18-\(variantLabel)-\(icon.slug)")
    }

    private var variantLabel: String {
        switch variant {
        case .light: return "light"
        case .dark: return "dark"
        case .tinted: return "tinted"
        }
    }

    private func galleryData() -> Data? {
        switch variant {
        case .light: return IOS18IconCatalog.imageData(slug: icon.slug, dark: false)
        case .dark: return IOS18IconCatalog.imageData(slug: icon.slug, dark: true)
        case .tinted: return IOS18IconCatalog.tintedImageData(slug: icon.slug)
        }
    }

    private func galleryImage() -> UIImage? {
        switch variant {
        case .light: return IOS18IconCatalog.image(slug: icon.slug, dark: false)
        case .dark: return IOS18IconCatalog.image(slug: icon.slug, dark: true)
        case .tinted: return IOS18IconCatalog.tintedImage(slug: icon.slug)
        }
    }
}

// MARK: - Settings rows

/// App icon, about, safety, credits. The old 3-UI appearance picker
/// is gone with the redesign: one native look, no themes.
private struct SettingsRows: View {
    @AppStorage("appIconChoice") private var appIconChoice = ""
    @State private var iconError: String?

    var body: some View {
        Picker(selection: $appIconChoice) {
            Text("Default").tag("")
            Text("Purple").tag("IconPurple")
            Text("Blue").tag("IconBlue")
            Text("Gray").tag("IconGray")
        } label: {
            Label("App icon", systemImage: "app.badge")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("app-icon-picker")
        .onChange(of: appIconChoice) { choice in
            iconError = nil
            UIApplication.shared.setAlternateIconName(choice.isEmpty ? nil : choice) { error in
                // setAlternateIconName fails silently without this:
                // surface it instead of leaving the picker lying.
                if let error {
                    iconError = "Could not change the app icon: \(error.localizedDescription)"
                }
            }
        }
        if let iconError {
            Text(iconError)
                .font(.footnote)
                .foregroundStyle(.red)
        }

        LabeledContent("Version", value: "14.0")
        LabeledContent("This device's iOS", value: DeviceInfoEx.fullVersion)

        Text("Find My must be OFF before an apply and back ON afterwards - same rule as the desktop.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Text("Cancel only unstages - nothing is in flight yet. A running restore has no true cancel; a hard stop is: turn off the VPN, then force-restart (Volume Up, Volume Down, hold Side button).")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Text("This app cannot reboot your iPhone. After an apply you restart manually.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        LabeledContent("Developer", value: "Adnan.120hz")
        Text("Beta testers: Charlie \u{2022} rfrz1d_ \u{2022} Davy (@Davydavpn) \u{2022} @uggtx")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Apply section

/// Builds the real payload from staged tweaks on this phone.
/// Staging only: delivery waits on the on-device restore engine.
private struct ApplySection: View {
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore
    @State private var built: BuiltPayload?
    @State private var showSheet = false
    @State private var confirmCancel = false
    @State private var isBuilding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apply builds the real payload from your staged tweaks on this phone. Delivery to the system runs over the loopback VPN tunnel with your pairing file - and only once the on-device restore engine passes its checks; if any check fails, nothing is sent.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                guard !isBuilding else { return }
                isBuilding = true
                let staged = selection.staged
                Task {
                    let result = await Task.detached(priority: .userInitiated) {
                        PayloadBuilder.build(staged: staged)
                    }.value
                    built = result
                    isBuilding = false
                    showSheet = true
                }
            } label: {
                if isBuilding {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Building payload…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Apply (\(selection.staged.count) tweaks)")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.staged.isEmpty || isBuilding)
            .accessibilityIdentifier("apply-button")
            Button(role: .destructive) {
                confirmCancel = true
            } label: {
                Text("Cancel (clear staged)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selection.staged.isEmpty)
            .accessibilityIdentifier("cancel-button")
        }
        .confirmationDialog("Clear all staged tweaks?", isPresented: $confirmCancel) {
            Button("Clear staged", role: .destructive) {
                selection.clear()
            }
            Button("Keep", role: .cancel) {}
        }
        .sheet(isPresented: $showSheet) {
            NavigationStack {
                List {
                    Section("Payload built from your selection") {
                        if let built, !built.files.isEmpty {
                            ForEach(built.files) { file in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.restorePath)
                                        .font(.system(.footnote, design: .monospaced))
                                    Text("\(file.domain) — \(file.keys.count) key(s): \(file.keys.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("No fixed payload could be built from this selection.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let built, !built.warnings.isEmpty {
                        Section("Not staged") {
                            ForEach(built.warnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Engine checks") {
                        Label("Pairing file imported", systemImage: status.pairingImported ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(status.pairingImported ? Color.green : Color.red)
                        Label("VPN tunnel on this device", systemImage: status.vpnDetected ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(status.vpnDetected ? Color.green : Color.red)
                        Text("Delivery is designed to run over this same phone: pairing file \u{2192} tunnel \u{2192} lockdownd on port 62078. Refresh device status probes the first steps for real; the TLS session and restore are not built yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Apply")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") { showSheet = false }
                }
            }
        }
    }
}

// MARK: - VPN tunnel explainer

/// What the loopback VPN tunnel is (and is not), and App Store apps
/// that can open one.
private struct TunnelInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("What the tunnel is") {
                    Text("WorkSlop runs on the same iPhone it tweaks. To deliver a payload it must talk to this phone's own lockdownd service, and iOS does not let an app open that connection directly - the traffic has to ride a local VPN tunnel (a utun interface) back into the phone itself.")
                    Text("This is NOT an internet VPN: no traffic leaves your iPhone, nothing is routed through a server, and your browsing is untouched. The tunnel is only a loopback bridge to this device, and your pairing file is what authenticates the session.")
                }
                Section("Apps that can open the tunnel") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WireGuard").font(.body.weight(.semibold))
                        Text("The official WireGuard app (free). With a loopback configuration it opens the tunnel WorkSlop detects - the standard choice.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("StikDebug").font(.body.weight(.semibold))
                        Text("Free. Creates its own local VPN profile for the same kind of loopback tunnel.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("WorkSlop only detects the tunnel; it never sees or routes your internet traffic.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VPN tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
