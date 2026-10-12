import Foundation

/// The pairing record the user imports once; the app stores it in its
/// own container and uses it to open the local lockdown session for
/// the backup/restore engine.
///
/// Two real-world shapes exist:
/// - legacy idevicepair lockdown records (DeviceCertificate /
///   HostPrivateKey / RootCertificate, ...), and
/// - iOS 17+ RemotePairing records (identifier, private_key,
///   public_key, alt_irk — no certificates at all).
///
/// Nothing here talks to the device yet: import + validation only. The
/// loopback restore engine is wired behind this store once its
/// verification spike passes.
enum PairingStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairing.plist")
    }

    static var isImported: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Format-agnostic validation, ala GoldenNugget's
    /// `PairingRecord.usable`: a non-empty top-level plist dict is a
    /// usable record. Requiring a fixed key list here is what used to
    /// reject every iOS 17+ RemotePairing file (identifier /
    /// private_key / public_key / alt_irk carry no DeviceCertificate,
    /// HostPrivateKey or RootCertificate) — the import accepted the
    /// file, and the next launch reported "no pairing record".
    /// Exactly backwards, and invisible. Whether the bytes are a
    /// *recognised* record is the engine's answer when it uses them;
    /// this asserts only what it can assert alone.
    static func validate(_ data: Data) -> Bool {
        guard let obj = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return false }
        return !dict.isEmpty
    }

    static func save(_ data: Data) throws {
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
