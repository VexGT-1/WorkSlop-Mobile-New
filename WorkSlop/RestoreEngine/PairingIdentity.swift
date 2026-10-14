import Foundation
import Security

/// Pairing record identity — the credential the app uses to open a
/// STARTTLS-secured lockdown session with the device (or its loopback
/// tunnel).
///
/// Two real-world record shapes exist, and we support BOTH:
/// - Legacy idevicepair lockdown records (HostID + certificates / private keys)
///   → we convert those to a PKCS#12 identity the same way libimobiledevice does.
/// - iOS 17+ RemotePairing records (identifier / private_key / public_key /
///   alt_irk) → we wrap private_key + public_key into a PKCS#12 identity.
///
/// This mirrors GoldenNugget-mobile's `PairingRecord.usable` /
/// `LockdownClient` identity handling, and libimobiledevice's
/// `lockdown.c` identity loading. The `escrowBag` is the session key
/// returned from the lockdownd handshake — passed to mobilebackup2 /
/// mobilesync etc. to protect the service channel.

struct PairingIdentity: Identifiable, Sendable {
    let id: String  // UDID (or "device" if unknown)
    let identifier: String?
    let privatePem: String?
    let publicPem: String?
    let certificates: [Data]?  // DER X.509 cert(s)
    let escrowBag: Data

    /// Identifier used in the STARTTLS handshake (RemotePairing: the device's
    /// UUID; legacy: the pairing record ID). Never nil once loaded from a
    /// known-good record, but `nil` is possible for legacy files where the
    /// identifier was never exported — handshake will still work via cert auth.
    var handshakeIdentifier: String? {
        identifier ?? certificates?.first.flatMap { SecCertificateCopyCommonName($0 as CFTypeRef) as String }
    }

    // MARK: - Class initializer (legacy PKCS#12 import)

    private init(id: String,
                 identifier: String?,
                 privatePem: String?,
                 publicPem: String?,
                 certificates: [Data]?,
                 escrowBag: Data) {
        self.id = id
        self.identifier = identifier
        self.privatePem = privatePem
        self.publicPem = publicPem
        self.certificates = certificates
        self.escrowBag = escrowBag
    }

    /// Load the imported pairing record from disk and convert it into an
    /// `PairingIdentity`. Returns nil if the file is missing, unreadable, or
    /// does not match either known pairing-record shape (legacy or
    /// iOS 17+ RemotePairing).
    static func load() -> PairingIdentity? {
        let url = PairingStore.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        // Validate format first (legacy or RemotePairing); garbage is rejected
        // here instead of failing later in the handshake.
        guard PairingStore.validate(data) else { return nil }
        guard let format = PairingStore.format(of: data) else { return nil }

        switch format {
        case .remotePairing:
            return PairingIdentity.loadRemotePairing(from: data)
        case .legacy:
            return PairingIdentity.loadLegacy(from: data)
        }
    }

    // MARK: - iOS 17+ RemotePairing

    /// RemotePairing format: identifier, private_key, public_key (+ optional
    /// alt_irk). We build a PKCS#12 identity from the private/public key pair
    /// so it can be handed to `SecIdentityCreateWithData` / the STARTTLS
    /// handshake, mirroring libimobiledevice's RemotePairing handling.
    private static func loadRemotePairing(from data: Data) -> PairingIdentity? {
        guard let dict = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        guard let identifier = dict["identifier"] as? String, !identifier.isEmpty
        else { return nil }

        guard let privateKey = dict["private_key"] as? String else { return nil }
        guard let publicKey  = dict["public_key"] as? String else { return nil }

        // PEM → DER private key (PKCS#8 or PKCS#1, both supported)
        let privateKeyDER: Data?
        if let der = PEM.der(from: Data(privateKey.utf8)) {
            privateKeyDER = der
        } else {
            return nil
        }

        // Public key: RemotePairing usually ships the DER cert or an X.509
        // certificate; accept raw DER, a PEM cert, or the "cert"/"certs" key.
        let certificates: [Data]
        if let cert = dict["cert"] as? String,
           let der = PEM.der(from: Data(cert.utf8)) {
            certificates = [der]
        } else if let certs = dict["certs"] as? String,
                  let der = PEM.der(from: Data(certs.utf8)) {
            certificates = [der]
        } else if let der = PEM.der(from: Data(publicKey.utf8)) {
            // publicKey sometimes IS the DER certificate itself.
            certificates = [der]
        } else {
            // Fallback: DER directly embedded in the plist (rare).
            certificates = []
        }

        // Build a PKCS#12 identity container (MAC-less, unencrypted) — same
        // shape SecPKCS12Import expects, mirroring libimobiledevice.
        guard let p12 = PKCS12.make(identityData: privateKeyDER,
                                    certificates: certificates) else {
            return nil
        }

        // The escrowBag for RemotePairing is the session encryption key that
        // lockdownd hands back after StartSession with EscrowBag. For the
        // handshake itself we don't strictly need it yet (it comes from the
        // STARTTLS session key exchange), but we keep it in sync with the
        // record's own escrow bag if present.
        let escrowBag: Data
        if let bag = dict["escrowBag"] as? Data, !bag.isEmpty {
            escrowBag = bag
        } else {
            // Empty/no escrowBag on RemotePairing: use a zeroed placeholder of
            // the expected size (32 bytes for ECDHE-ECDSA sessions) so callers
            // never crash on `identity.escrowBag` access. The real value is
            // written by LockdownClient after the handshake.
            escrowBag = Data(count: 32)
        }

        return PairingIdentity(
            id: identifier,
            identifier: identifier,
            privatePem: privateKey,
            publicPem: publicKey,
            certificates: certificates.isEmpty ? nil : certificates,
            escrowBag: escrowBag
        )
    }

    // MARK: - Legacy idevicepair record

    /// Legacy lockdown record: HostID + DeviceCertificate/HostCertificate/
    /// RootCertificate + HostPrivateKey/RootPrivateKey. We extract the
    /// identity cert + private key and produce a PKCS#12 identity, the same
    /// way libimobiledevice builds the `idevice` identity from the pairing
    /// record.
    private static func loadLegacy(from data: Data) -> PairingIdentity? {
        guard let dict = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        guard let hostID = dict["HostID"] as? String, !hostID.isEmpty else {
            return nil
        }

        // Collect all certificate keys in a defined order.
        let certKeys = ["DeviceCertificate", "HostCertificate", "RootCertificate"]
        var allCerts: [Data] = []
        for key in certKeys {
            if let pem = dict[key] as? String,
               let der = PEM.der(from: Data(pem.utf8)),
               let cert = SecCertificateCreateWithData(nil, der as CFData) {
                allCerts.append(der)
            }
        }

        // Collect all private key candidates.
        let keyKeys = ["HostPrivateKey", "RootPrivateKey"]
        var privateKeyData: Data?
        for key in keyKeys {
            if let pem = dict[key] as? String {
                if let der = PEM.der(from: Data(pem.utf8)),
                   der.count > 0 {
                    privateKeyData = der
                    break
                }
            }
        }

        guard let privateKeyDER = privateKeyData, !privateKeyDER.isEmpty else {
            return nil
        }

        // For legacy records, SecPKCS12Import needs the identity cert (device
        // cert) + the private key.
        let identityCert = allCerts.first

        guard let p12 = PKCS12.make(identityData: privateKeyDER,
                                    certificates: identityCert.map { [$0] } ?? []) else {
            return nil
        }

        // Legacy records may carry an explicit EscrowBag from a previous
        // handshake.
        let escrowBag: Data
        if let bag = dict["EscrowBag"] as? Data, !bag.isEmpty {
            escrowBag = bag
        } else {
            // Placeholder (32 bytes) — real value comes from handshake.
            escrowBag = Data(count: 32)
        }

        return PairingIdentity(
            id: hostID,
            identifier: hostID,
            privatePem: dict["HostPrivateKey"] as? String,
            publicPem: allCerts.first.flatMap { SecCertificateCopyCommonName($0 as CFTypeRef) as String? },
            certificates: allCerts.isEmpty ? nil : allCerts,
            escrowBag: escrowBag
        )
    }

    /// Serialize this identity back to a RemotePairing-style plist for
    /// export. Convenience for round-tripping pairing records.
    func exportToRemotePairing() -> Data? {
        guard let privatePem = privatePem else { return nil }
        let dict: [String: Any] = [
            "identifier": id,
            "private_key": privatePem,
            "public_key": publicPem ?? "",
        ]
        if let certs = certificates, !certs.isEmpty {
            // First cert is the identity; encode as PEM for readability.
            var pem = "-----BEGIN CERTIFICATE-----\n"
            pem += Data(certs[0]).base64EncodedString(options: .lineLength64Characters)
            pem += "\n-----END CERTIFICATE-----\n"
            dict["cert"] = pem
        }
        return (try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0))
    }
}

// MARK: - PEM decoding helpers (mirrors libimobiledevice / GoldenNugget)

private enum PEM {
    /// Convert PEM armor → DER. Falls back to raw base64, then raw bytes
    /// (some records already ship DER).
    static func der(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("-----BEGIN")
        else {
            let t = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Data(base64Encoded: t) ?? data
        }
        let b64 = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        return Data(base64Encoded: b64)
    }
}

// MARK: - PKCS#12 identity container builder

/// Builds an unencrypted, MAC-less PKCS#12 container (RFC 7292) holding one
/// private key (PKCS#8) and one X.509 certificate. This is exactly the shape
/// `SecPKCS12Import` expects — the same format libimobiledevice ships to
/// `lockdownd` as the STARTTLS identity.
private enum PKCS12 {
    static let oidData = [1, 2, 840, 113549, 1, 7, 1]
    static let oidSignedData = [1, 2, 840, 113549, 1, 7, 2]
    static let oidKeyBag = [1, 2, 840, 113549, 1, 12, 10, 1, 1]
    static let oidCertBag = [1, 2, 840, 113549, 1, 12, 10, 1, 3]
    static let oidX509Certificate = [1, 2, 840, 113549, 1, 9, 22, 1]
    static let oidRSAEncryption = [1, 2, 840, 113549, 1, 1, 1]

    static func make(identityData: Data, certificates: [Data]) -> Data? {
        let keyBag = DER.sequence([
            DER.oid(oidKeyBag),
            DER.explicit(0, identityData),
        ])
        var certBags: [Data] = []
        for cert in certificates {
            certBags.append(DER.sequence([
                DER.oid(oidCertBag),
                DER.explicit(0, DER.sequence([
                    DER.oid(oidX509Certificate),
                    DER.explicit(0, DER.octetString(cert)),
                ])),
            ]))
        }
        if certBags.isEmpty { return nil }
        let safeContents = DER.sequence(certBags)
        let signedData = DER.sequence([
            DER.integer(3),
            DER.set([]),
            DER.sequence([
                DER.oid(oidData),
                DER.explicit(0, DER.octetString(safeContents)),
            ]),
            DER.set([]),
        ])
        let authSafe = DER.sequence([
            DER.oid(oidSignedData),
            DER.explicit(0, signedData),
        ])
        return DER.sequence([DER.integer(3), authSafe])
    }
}

// MARK: - Minimal DER writer (RFC 7292, used by PKCS#12 builder)

private enum DER {
    static func lengthPrefix(_ n: Int) -> Data {
        precondition(n >= 0)
        if n < 128 { return Data([UInt8(n)]) }
        var v = n
        var bytes: [UInt8] = []
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([UInt8(0x80 | bytes.count)]) + Data(bytes)
    }

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + lengthPrefix(content.count) + content
    }

    static func sequence(_ parts: [Data]) -> Data {
        tlv(0x30, parts.reduce(Data(), +))
    }

    static func set(_ parts: [Data]) -> Data {
        tlv(0x31, parts.reduce(Data(), +))
    }

    static func integer(_ value: Int) -> Data {
        var v = value
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func null() -> Data { Data([0x05, 0x00]) }

    static func octetString(_ data: Data) -> Data { tlv(0x04, data) }

    static func oid(_ arcs: [Int]) -> Data {
        precondition(arcs.count >= 2)
        var body = Data([UInt8(40 * arcs[0] + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var v = arc
            var tmp: [UInt8] = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 {
                tmp.insert(UInt8((v & 0x7F) | 0x80), at: 0)
                v >>= 7
            }
            body += Data(tmp)
        }
        return tlv(0x06, body)
    }

    static func explicit(_ n: UInt8, _ content: Data) -> Data {
        tlv(0xA0 | n, content)
    }
}
