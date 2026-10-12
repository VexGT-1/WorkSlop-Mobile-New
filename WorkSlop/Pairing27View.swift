import SwiftUI

/// iOS 27 on-device pairing via Developer Mode (RemotePairing pairable host).
///
/// Flow: the app advertises `_remotepairing-pairable-host._tcp` via Bonjour,
/// the user taps the host in Settings > Privacy & Security > Developer Mode,
/// the app shows a 6-digit PIN, the user types it on the iPhone, and the
/// pairing file is saved to the app container.
///
/// iOS 26 and below: this view is never shown (the button is locked).
/// Those versions keep the import flow.
struct Pairing27View: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairer = Pairing27Controller()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Get a pairing file without a computer. Your iPhone pairs directly with WorkSlop over the loopback tunnel.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Steps") {
                    Label("Make sure the VPN tunnel row on Home says DETECTED", systemImage: "1.circle")
                    Label("Open Settings → Privacy & Security → Developer Mode", systemImage: "2.circle")
                    Label("Tap \"WorkSlop\" under Pair with Host", systemImage: "3.circle")
                    Label("Type the 6-digit code shown below into your iPhone", systemImage: "4.circle")
                }

                Section("Status") {
                    switch pairer.state {
                    case .idle:
                        Button("Start advertising") {
                            pairer.start()
                        }
                        .buttonStyle(.borderedProminent)
                    case .advertising:
                        Label("Advertising… open Developer Mode and tap WorkSlop", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(Color.blue)
                        Button("Stop", role: .cancel) {
                            pairer.stop()
                        }
                    case .pin(let code):
                        VStack(spacing: 8) {
                            Text("Enter this code on your iPhone:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(code)
                                .font(.system(size: 48, weight: .bold, design: .monospaced))
                                .padding()
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .frame(maxWidth: .infinity)
                        Button("Cancel", role: .cancel) {
                            pairer.stop()
                        }
                    case .done:
                        Label("Paired! The pairing file is saved and ready.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                    case .failed(let message):
                        Label("Failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(Color.red)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Try again") {
                            pairer.start()
                        }
                    }
                }

                if pairer.state.isDone {
                    Section {
                        Text("You can delete the pairing file anytime from the Home screen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Get Pairing File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        pairer.stop()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Controller
//
// The real implementation lives in Pairing27Controller.swift (FFI to
// libidevice_ffi.a). This file is UI only.
