import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// AirFlit: custom passcode themes + Apple Wallet card images,
/// using 100% the AirCard method (AirTraffic via AirliftFFI).
/// NOT sparse restore — this menu rides its own delivery channel.
///
/// - Passcode: writes keypad PNGs to /var/mobile/Library/Caches/TelephonyUI-10.
///   Lock the iPhone to see the new keypad (it reloads every lock screen).
/// - Wallet: writes card artwork into the .pkpass folder and corrupts the
///   FrontFace/Preview caches. Force-close the Wallet app to see changes.
///
/// iOS window: 18.0 – 27.2 beta 2 (27.2 beta 3+ patched the vector).
struct AirFlitView: View {
    @StateObject private var vm = AirFlitViewModel()
    @State private var passcodeItem: PhotosPickerItem?
    @State private var walletItem: PhotosPickerItem?
    @State private var importKind: ImportKind?

    enum ImportKind: Identifiable {
        case pairing, passthm
        var id: Int { self == .pairing ? 0 : 1 }
    }

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                if !vm.iosOK {
                    Section {
                        Label("AirFlit needs iOS 18.0 – 27.2 beta 2. This device runs \(DeviceInfoEx.versionWithBuild).",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    HStack {
                        Label("Pairing file", systemImage: "key.fill")
                        Spacer()
                        Text(vm.hasPairingFile ? "Imported" : "Missing")
                            .foregroundStyle(vm.hasPairingFile ? .green : .red)
                    }
                    Button {
                        importKind = .pairing
                    } label: {
                        Label("Import pairing file…", systemImage: "square.and.arrow.down")
                    }
                    if let note = vm.pairingNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !vm.hasPairingFile {
                        Text("Import the same pairing file you use for WorkSlop (from SideStore / AltStore / etc.). AirFlit keeps its own copy for the AirTraffic channel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Setup")
                }

                Section {
                    // .passthm file import (AirCard's native theme format)
                    Button {
                        importKind = .passthm
                    } label: {
                        Label(vm.passthmURL == nil ? "Import .passthm theme…" : "Change .passthm theme…",
                              systemImage: "doc.zipper")
                    }
                    if vm.passthmURL != nil {
                        Text("Loaded .passthm with \(vm.passthmFileCount) key images.")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let img = vm.passcodeImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    PhotosPicker(selection: $passcodeItem, matching: .images) {
                        Label(vm.passcodeImage == nil ? "Choose keypad image…" : "Change image…",
                              systemImage: "photo")
                    }
                    .onChange(of: passcodeItem) { item in
                        Task {
                            if let raw = try? await item?.loadTransferable(type: Data.self),
                               let img = UIImage(data: raw) {
                                vm.passcodeImage = img
                                vm.passthmURL = nil // single image clears .passthm
                                vm.passthmFileCount = 0
                            }
                        }
                    }
                    Button {
                        vm.applyPasscodeTheme()
                    } label: {
                        Label("Apply passcode theme", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((vm.passcodeImage == nil && vm.passthmURL == nil) || vm.running || !vm.iosOK || !vm.hasPairingFile)
                    Text("Writes to the TelephonyUI keypad cache. Lock your iPhone to see the new keypad — no restart needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Passcode Theme")
                }

                Section {
                    TextField("Card ID (from Wallet scan)", text: $vm.walletCardID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    if let img = vm.walletImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    PhotosPicker(selection: $walletItem, matching: .images) {
                        Label(vm.walletImage == nil ? "Choose card artwork…" : "Change artwork…",
                              systemImage: "photo")
                    }
                    .onChange(of: walletItem) { item in
                        Task {
                            if let raw = try? await item?.loadTransferable(type: Data.self),
                               let img = UIImage(data: raw) {
                                vm.walletImage = img
                            }
                        }
                    }
                    Button {
                        vm.applyWalletSkin()
                    } label: {
                        Label("Apply wallet skin", systemImage: "creditcard.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.walletImage == nil || vm.walletCardID.trimmingCharacters(in: .whitespaces).isEmpty
                              || vm.running || !vm.iosOK || !vm.hasPairingFile)
                    Text("Writes artwork into the card's .pkpass folder and invalidates its cache. Force-close the Wallet app to see changes — no restart needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Wallet Image")
                }

                if vm.running {
                    Section("Applying") {
                        ProgressView(value: vm.progress)
                        Text("\(Int(vm.progress * 100))%")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if !vm.logLines.isEmpty {
                    Section("Log") {
                        ForEach(vm.logLines.indices, id: \.self) { i in
                            Text(vm.logLines[i])
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let result = vm.result {
                    Section("Result") {
                        Label(result, systemImage: vm.resultOK ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(vm.resultOK ? .green : .red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("AirFlit")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: Binding(
                get: { importKind != nil },
                set: { if !$0 { importKind = nil } }
            ),
            allowedContentTypes: importKind == .passthm ? [.zip] : [.propertyList]
        ) { result in
            let kind = importKind
            importKind = nil
            switch result {
            case .success(let url):
                if kind == .passthm {
                    vm.loadPassthm(from: url)
                } else {
                    vm.savePairingFile(from: url)
                }
            case .failure:
                if kind != .passthm {
                    vm.pairingNote = "Import cancelled."
                }
            }
        }
    }
}
