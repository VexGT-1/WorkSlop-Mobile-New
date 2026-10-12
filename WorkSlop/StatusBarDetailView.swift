import SwiftUI

/// All Status Bar staging controls as plain table rows bound to the
/// single StatusBarStore — no @AppStorage per row, no per-keystroke
/// page rebuilds. Values ride the 0xF68 `statusBarOverrides` struct
/// (field layout firmware-verified on iOS 26.6.1), assembled from the
/// device's captured base during a restore session.
struct StatusBarDetailView: View {
    @StateObject private var store = StatusBarStore()
    @EnvironmentObject private var status: StatusStore

    /// iOS 27: the classic overrides file is not read anymore; only
    /// the carrier names survive, riding StatusBarOverrides.archive.
    private var isIOS27: Bool { DeviceInfo.iosVersion.major >= 27 }

    /// Desktop-mapped status bar items that can be hidden (verified
    /// 2026-10-09 against the desktop page: the same 14 pairs).
    private static let hideableItems: [(idx: Int, name: String)] = [
        (2, "Focus Mode icon"), (3, "Airplane Mode icon"),
        (6, "Cellular Service icon"), (9, "Wi-Fi icon"),
        (12, "Battery icon"), (16, "Bluetooth icon"),
        (18, "Alarm icon"), (21, "Location icon"),
        (22, "Rotation Lock icon"), (24, "AirPlay icon"),
        (26, "CarPlay icon"), (29, "VPN icon"),
        (40, "Liquid Detection Warning icon"), (41, "Voice Control icon"),
    ]

    var body: some View {
        List {
            if !status.unlocked {
                Section {
                    Text(ActivationGate.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Master") {
                Toggle("Enable Status Bar Modifications", isOn: $store.masterOn)
                    .accessibilityIdentifier("sb-enable")
                Toggle("Full Signal Bars (No SIM Visual)", isOn: $store.fullSignal)
                    .disabled(!status.unlocked || isIOS27)
                Toggle("Silly Mode", isOn: $store.sillyMode)
                    .disabled(!status.unlocked || isIOS27)
            } footer: {
                Text(isIOS27
                    ? "On iOS 27 the classic statusBarOverrides file is no longer read, so only the carrier names below can still change (StatusBarOverrides.archive)."
                    : "The full-bars look without a SIM is visual only; it does not restore cellular service.")
            }

            Section("Text overrides") {
                TextField("Change Status Bar Time Text", text: $store.timeText)
                    .disabled(isIOS27)
                TextField("Change Status Bar Date Text", text: $store.dateText)
                    .disabled(isIOS27)
                TextField("Change Breadcrumb Text", text: $store.crumbText)
                    .disabled(isIOS27)
                TextField("Change Battery Detail Text", text: $store.batteryDetail)
                    .disabled(isIOS27)
                TextField("Change Carrier Text", text: $store.carrierText)
                TextField("Change Service Badge Text", text: $store.badgeText)
                    .disabled(isIOS27)
                TextField("Secondary Carrier Name", text: $store.carrier2Text)
                TextField("Secondary Service Badge", text: $store.badge2Text)
                    .disabled(isIOS27)
            }

            Section("Numbers") {
                Stepper("Change Signal Strength: \(store.signalBars)", value: $store.signalBars, in: 0...5)
                Stepper("Secondary Cellular Signal Bars: \(store.signalBars2)", value: $store.signalBars2, in: 0...5)
                Stepper("Change Wi-Fi Signal Strength: \(store.wifiBars)", value: $store.wifiBars, in: 0...3)
                Stepper("Change Battery Icon Capacity: \(store.batteryCapacity)%", value: $store.batteryCapacity, in: 0...100)
                Stepper("Change Data Network Type: \(store.netType)", value: $store.netType, in: 0...30)
                Stepper("Secondary Data Network Type: \(store.netType2)", value: $store.netType2, in: 0...30)
                Toggle("Show Numeric Cellular Strength", isOn: $store.numericCell)
                Toggle("Show Numeric Wi-Fi Strength", isOn: $store.numericWifi)
            }
            .disabled(isIOS27)

            Section("Disable icons") {
                ForEach(Self.hideableItems, id: \.idx) { item in
                    Toggle("Disable \(item.name)", isOn: Binding(
                        get: { store.hiddenItems.contains(item.idx) },
                        set: { on in
                            var items = store.hiddenItems
                            if on { items.insert(item.idx) } else { items.remove(item.idx) }
                            store.hiddenItems = items
                        }))
                }
            }
            .disabled(isIOS27)

            Section {
                Text("Values stage here exactly like the desktop page. The struct is built from the device's captured base during the restore session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Status Bar")
        .navigationBarTitleDisplayMode(.inline)
    }
}
