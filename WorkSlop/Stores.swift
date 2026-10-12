import SwiftUI

/// Device + gate state for the whole app, in ONE place.
///
/// The old UI probed the VPN tunnel and the pairing file from
/// several views (and once per row per render, before the perf
/// fixes). Every row now reads this single object from the
/// environment — no per-row probing, no per-row @AppStorage.
final class StatusStore: ObservableObject {
    @Published private(set) var vpnDetected: Bool
    @Published private(set) var pairingImported: Bool
    @Published private(set) var engineStatus: String
    @Published private(set) var probing = false

    /// The activation gate: no tweak toggles on before BOTH the
    /// pairing file is imported AND a VPN tunnel is up.
    var unlocked: Bool { vpnDetected && pairingImported }

    init() {
        vpnDetected = DeviceStatus.vpnTunnelActive()
        pairingImported = PairingStore.isImported
        engineStatus = "Not probed yet - tap Refresh device status."
    }

    /// Re-probe tunnel + pairing file, then ask lockdownd whether it
    /// answers on the tunnel (the real two-phase check).
    func refresh() {
        guard !probing else { return }
        probing = true
        vpnDetected = DeviceStatus.vpnTunnelActive()
        pairingImported = PairingStore.isImported
        engineStatus = "Probing lockdownd..."
        LockdownProbe.probe { [weak self] result in
            DispatchQueue.main.async {
                self?.engineStatus = result.summary
                self?.probing = false
            }
        }
    }

    /// Called after import/delete so the rows update without a refresh.
    func pairingChanged() {
        pairingImported = PairingStore.isImported
    }
}

/// Staged custom icons, shared by the Your Icons table and all
/// three gallery tables so every row sees the same staged set.
/// Single writer to CustomIconStore.
final class IconStage: ObservableObject {
    @Published var entries: [CustomIconEntry] = CustomIconStore.load()

    func isStaged(bundleID: String) -> Bool {
        entries.contains { $0.bundleID == bundleID }
    }

    func stage(_ entry: CustomIconEntry) {
        if let i = entries.firstIndex(where: { $0.bundleID == entry.bundleID }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        CustomIconStore.save(entries)
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        CustomIconStore.save(entries)
    }

    /// Appends a blank entry for the editor; returns its index.
    func addBlank() -> Int {
        entries.append(CustomIconEntry())
        CustomIconStore.save(entries)
        return entries.count - 1
    }

    func save() {
        CustomIconStore.save(entries)
    }
}

/// All Status Bar staging values in ONE object.
///
/// The old page kept ~20 @AppStorage properties in the page body and
/// one more inside a row view; every keystroke re-observed storage
/// from many places. Rows now take plain @Bindings into this store,
/// which writes through to UserDefaults once per change.
final class StatusBarStore: ObservableObject {
    private let ud = UserDefaults.standard

    @Published var masterOn: Bool { didSet { ud.set(masterOn, forKey: "sb-on") } }
    @Published var fullSignal: Bool { didSet { ud.set(fullSignal, forKey: "sb-fullsignal") } }
    @Published var sillyMode: Bool { didSet { ud.set(sillyMode, forKey: "sb-silly") } }
    @Published var timeText: String { didSet { ud.set(timeText, forKey: "sb-time") } }
    @Published var dateText: String { didSet { ud.set(dateText, forKey: "sb-date") } }
    @Published var crumbText: String { didSet { ud.set(crumbText, forKey: "sb-crumb") } }
    @Published var batteryDetail: String { didSet { ud.set(batteryDetail, forKey: "sb-battdetail") } }
    @Published var carrierText: String { didSet { ud.set(carrierText, forKey: "sb-carrier") } }
    @Published var badgeText: String { didSet { ud.set(badgeText, forKey: "sb-badge") } }
    @Published var carrier2Text: String { didSet { ud.set(carrier2Text, forKey: "sb-carrier2") } }
    @Published var badge2Text: String { didSet { ud.set(badge2Text, forKey: "sb-badge2") } }
    @Published var signalBars: Int { didSet { ud.set(signalBars, forKey: "sb-bars") } }
    @Published var signalBars2: Int { didSet { ud.set(signalBars2, forKey: "sb-bars2") } }
    @Published var wifiBars: Int { didSet { ud.set(wifiBars, forKey: "sb-wifibars") } }
    @Published var batteryCapacity: Int { didSet { ud.set(batteryCapacity, forKey: "sb-battcap") } }
    @Published var netType: Int { didSet { ud.set(netType, forKey: "sb-nettype") } }
    @Published var netType2: Int { didSet { ud.set(netType2, forKey: "sb-nettype2") } }
    @Published var numericCell: Bool { didSet { ud.set(numericCell, forKey: "sb-numcell") } }
    @Published var numericWifi: Bool { didSet { ud.set(numericWifi, forKey: "sb-numwifi") } }

    /// Set of hidden status-bar item indices, persisted as the same
    /// comma-separated "sb-hidden-items" string the old row used, so
    /// existing staging survives the redesign.
    @Published var hiddenItems: Set<Int> {
        didSet {
            ud.set(hiddenItems.sorted().map(String.init).joined(separator: ","),
                   forKey: "sb-hidden-items")
        }
    }

    init() {
        masterOn = ud.bool(forKey: "sb-on")
        fullSignal = ud.bool(forKey: "sb-fullsignal")
        sillyMode = ud.bool(forKey: "sb-silly")
        timeText = ud.string(forKey: "sb-time") ?? ""
        dateText = ud.string(forKey: "sb-date") ?? ""
        crumbText = ud.string(forKey: "sb-crumb") ?? ""
        batteryDetail = ud.string(forKey: "sb-battdetail") ?? ""
        carrierText = ud.string(forKey: "sb-carrier") ?? ""
        badgeText = ud.string(forKey: "sb-badge") ?? ""
        carrier2Text = ud.string(forKey: "sb-carrier2") ?? ""
        badge2Text = ud.string(forKey: "sb-badge2") ?? ""
        signalBars = ud.object(forKey: "sb-bars") as? Int ?? 4
        signalBars2 = ud.object(forKey: "sb-bars2") as? Int ?? 4
        wifiBars = ud.object(forKey: "sb-wifibars") as? Int ?? 3
        batteryCapacity = ud.object(forKey: "sb-battcap") as? Int ?? 100
        netType = ud.object(forKey: "sb-nettype") as? Int ?? 0
        netType2 = ud.object(forKey: "sb-nettype2") as? Int ?? 0
        numericCell = ud.bool(forKey: "sb-numcell")
        numericWifi = ud.bool(forKey: "sb-numwifi")
        let raw = ud.string(forKey: "sb-hidden-items") ?? ""
        hiddenItems = Set(raw.split(separator: ",").compactMap { Int($0) })
    }
}
