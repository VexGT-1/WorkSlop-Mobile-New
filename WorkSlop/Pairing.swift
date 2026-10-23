import Foundation
import UniformTypeIdentifiers

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
/// Pairing record format, detected from the record's keys.
enum PairingFormat: Sendable {
    /// Classic idevicepair lockdown record (HostID + certificate/key material).
    case legacy
    /// iOS 17+ RemotePairing record (identifier / private_key / public_key / alt_irk).
    case remotePairing
}

enum PairingStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairing.plist")
    }

    /// Types offered in the file picker. .mobiledevicepairing is declared in
    /// Info.plist (conforms to a property list); `.data` catches extensionless
    /// or oddly named exports, which are then validated by content.
    static var importTypes: [UTType] {
        var types: [UTType] = [.propertyList, .xmlPropertyList, .binaryPropertyList]
        if let mdp = UTType("com.apple.mobiledevicepairing") ?? UTType(filenameExtension: "mobiledevicepairing") {
            types.append(mdp)
        }
        types.append(.data)
        return types
    }

    /// Reads a file picked with .fileImporter. Takes the security scope and
    /// goes through NSFileCoordinator, so a file still in iCloud Drive is
    /// downloaded first instead of failing as unreadable.
    static func readPicked(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            result = try? Data(contentsOf: readURL)
        }
        return result ?? (try? Data(contentsOf: url))
    }

    static var isImported: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Detects which known pairing-record shape the data has, or nil when
    /// it matches neither. Two real-world shapes exist:
    /// - legacy idevicepair lockdown records (HostID + DeviceCertificate /
    ///   HostPrivateKey / RootCertificate / RootPrivateKey / SystemBUID), and
    /// - iOS 17+ RemotePairing records (identifier, private_key,
    ///   public_key, alt_irk — no certificates at all).
    ///
    /// History: a fixed key list once rejected every iOS 17+ RemotePairing
    /// file (they carry no DeviceCertificate/HostPrivateKey/RootCertificate)
    /// — the import accepted nothing and the next launch reported "no
    /// pairing record". Exactly backwards, and invisible. The fix is not
    /// "accept anything non-empty" either (that let garbage .plists through
    /// and moved the failure to handshake time): it is to recognise BOTH
    /// known shapes explicitly and reject the rest with a reason.
    static func format(of data: Data) -> PairingFormat? {
        guard let obj = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil),
              let dict = obj as? [String: Any], !dict.isEmpty else { return nil }

        // iOS 17+ RemotePairing: identifier + private_key + public_key
        // (alt_irk is optional).
        let hasIdentifier = (dict["identifier"] as? String)?.isEmpty == false
        if hasIdentifier && dict["private_key"] != nil && dict["public_key"] != nil {
            return .remotePairing
        }

        // Legacy lockdown record: HostID plus certificate/key material.
        let hasHostID = (dict["HostID"] as? String)?.isEmpty == false
        let hasCertMaterial = dict["DeviceCertificate"] != nil
            || dict["HostCertificate"] != nil
            || dict["RootCertificate"] != nil
            || dict["HostPrivateKey"] != nil
            || dict["RootPrivateKey"] != nil
        if hasHostID && hasCertMaterial {
            return .legacy
        }
        // Lenient tail: very old minimal records with HostID + SystemBUID
        // but no embedded certs (certs fetched at pair time).
        if hasHostID && (dict["SystemBUID"] as? String)?.isEmpty == false {
            return .legacy
        }
        return nil
    }

    /// Format-agnostic validation: the data must be one of the two known
    /// pairing-record shapes. Unknown/empty/garbage plists are rejected
    /// here — at import time — instead of failing later in the handshake.
    static func validate(_ data: Data) -> Bool {
        format(of: data) != nil
    }

    /// Human-readable reason why `validate` failed, for the import UI.
    /// Never returns an empty string.
    static func diagnose(_ data: Data) -> String {
        guard let obj = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) else {
            return "That file is not a property list at all — export a fresh pairing file and try again."
        }
        guard let dict = obj as? [String: Any] else {
            return "That file is a plist, but not a dictionary — a pairing record must be a key/value plist."
        }
        if dict.isEmpty {
            return "That pairing file is empty — export a fresh one and try again."
        }
        let keys = dict.keys.sorted().joined(separator: ", ")
        let hasIdentifier = (dict["identifier"] as? String)?.isEmpty == false
        let hasHostID = (dict["HostID"] as? String)?.isEmpty == false
        if hasIdentifier {
            return "That looks like a RemotePairing file, but it is missing " +
                "private_key or public_key (found keys: \(keys)). " +
                "Re-export the pairing file and try again."
        }
        if hasHostID {
            return "That looks like a lockdown pairing file, but it carries no " +
                "certificate/key material (found keys: \(keys)). " +
                "Re-pair the device and export a fresh file."
        }
        return "That plist is not a recognised pairing record " +
            "(found keys: \(keys)). It must be either a lockdown pairing " +
            "file (HostID + certificates) or an iOS 17+ RemotePairing file " +
            "(identifier + private_key + public_key)."
    }

    static func save(_ data: Data) throws {
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
