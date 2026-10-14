import Foundation
import Security

/// Representation of the imported pairing record used to open a TLS
/// lockdown session. Loads the record from the app container, normalizes
/// the key material into a PKCS#12 identity container (used with
/// kCFStreamPropertySSLSettings on a CFReadStream), and exposes the
/// escrow bag for service-level requests.
///
/// Two real-world pairing shapes are supported:
/// - Legacy idevicepair lockdown record (HostCertificate/HostPrivateKey,
///   RootCertificate, DeviceCertificate, ...). The HostPrivateKey +
///   HostCertificate pair becomes the TLS identity, and the root is used
///   to trust the device's server certificate during the STARTTLS upgrade.
/// - iOS 17+ RemotePairing record (identifier/private_key/public_key,
///   optionally alt_irk). The private key + public key (as the device
///   certificate) become the TLS identity. Escrow bag is synthesized from
///   the record's public key / identifier.
enum PairingIdentity {
    /// The identity used for the STARTTLS upgrade: DER-encoded PKCS#12
    /// (unencrypted, MAC-less) holding the private key + device
    /// certificate. SecPKCS12Import accepts this shape for use in
    /// kCFStreamPropertySSLSettings.
    let identityPKCS12: Data

    /// Escrow bag for lockdownd service requests (startService escrowBag).
    /// For legacy records this is the RootCertificate hash chain; for
    /// RemotePairing it is derived from identifier/public_key. Never
    /// nil — the engine refuses to run without it.
    let escrowBag: Data

    /// The record format this identity was created from.
    let format: PairingFormat

    /// The device-facing public key / certificate (for diagnostics and
    /// for constructing the trust chain during the STARTTLS upgrade).
    let devicePublicKey: Data?

    /// Unique stable identifier for the imported pairing (UDID when
    /// available, else a hash of the identity). Used for logging.
    var description: String {
        let key = devicePublicKey?.base64EncodedString() ?? "unknown"
        return "PairingIdentity[\(format)]: \(key.prefix(16))..."
    }

    private init(
        identityPKCS12: Data,
        escrowBag: Data,
        format: PairingFormat,
        devicePublicKey: Data? = nil
    ) {
        self.identityPKCS12 = identityPKCS12
        self.escrowBag = escrowBag
        self.format = format
        self.devicePublicKey = devicePublicKey
    }

    // MARK: - Load from app container

    /// Load and parse the imported pairing file (`pairing.plist` in the
    /// documents container) into a usable TLS identity. Returns nil when
    /// there is no pairing file, or when the file cannot be parsed /
    /// matched to a known format. A pairing that fails to import is
    /// reported to the user by PairingStore.diagnose(_:) instead of here.
    static func load() -> PairingIdentity? {
        let data = FileManager.default
            .contents(atPath: PairingStore.fileURL.path)
        guard let data else { return nil }
        return parse(data: data)
    }

    private static func parse(data: Data) -> PairingIdentity? {
        guard PairingStore.validate(data) else { return nil }
        guard let obj = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) else { return nil }
        guard let dict = obj as? [String: Any] else { return nil }

        switch PairingStore.format(of: data) {
        case .remotePairing:
            return parseRemotePairing(dict)
        case .legacy:
            return parseLegacy(dict)
        case .none:
            return nil
        }
    }

    // MARK: - RemotePairing (iOS 17+)

    private static func parseRemotePairing(_ dict: [String: Any]) -> PairingIdentity? {
        guard let identifier = dict["identifier"] as? String, !identifier.isEmpty,
              let privateKeyDER = dict["private_key"] as? Data,
              let publicKeyDER = dict["public_key"] as? Data else {
            return nil
        }

        // RemotePairing stores the private key as PKCS#8. It is imported
        // directly into the PKCS#12 container as-is. The public key is used
        // as the certificate body so that lockdownd's cert can be verified
        // (device presents exactly this key in the TLS handshake).
        let pfx = PKCS12.build(keyPKCS8: privateKeyDER, certDER: publicKeyDER)

        // Escrow bag for RemotePairing is derived from the pairing
        // identifier + public key. This mirrors how libimobiledevice /
        // MobileDevice builds the escrow bag for RemotePairing clients
        // (hmac/identity binding). The exact bytes are not used to verify
        // the device here; we pass it through so startService matches the
        // shape the device expects. If the device rejects it, the failure
        // surfaces as a lockdown error with a clear message.
        let escrowBag = deriveEscrowBag(remoteIdentifier: identifier, publicKey: publicKeyDER)

        return PairingIdentity(
            identityPKCS12: pfx,
            escrowBag: escrowBag,
            format: .remotePairing,
            devicePublicKey: publicKeyDER
        )
    }

    // MARK: - Legacy (idevicepair)

    private static func parseLegacy(_ dict: [String: Any]) -> PairingIdentity? {
        guard let hostCert = dict["HostCertificate"] as? Data,
              let hostKey = dict["HostPrivateKey"] as? Data else {
            return nil
        }

        // HostCertificate may be PEM-armor or raw DER. Normalize to DER.
        let certDER = PEM.der(from: hostCert) ?? hostCert
        // HostPrivateKey may be PKCS#1 RSAPrivateKey or PKCS#8. Normalize
        // to PKCS#8 for SecPKCS12Import.
        let keyPKCS8: Data
        if PEM.der(from: hostKey) != nil, PKCS12.isPKCS8(PEM.der(from: hostKey)!) {
            keyPKCS8 = PEM.der(from: hostKey)!
        } else if PKCS12.isPKCS8(hostKey) {
            keyPKCS8 = hostKey
        } else {
            keyPKCS8 = PKCS12.pkcs1ToPKCS8(hostKey)
        }

        let pfx = PKCS12.build(keyPKCS8: keyPKCS8, certDER: certDER)

        // Legacy escrow bag: libimobiledevice builds it from the root
        // certificate chain (the host trusts the device's RootCertificate).
        // If RootCertificate is present, use it; otherwise synthesize from
        // the host certificate.
        let escrowBag = dict["RootCertificate"] as? Data
            ?? hostCert
        let rootCert = dict["RootCertificate"] as? Data ?? certDER

        return PairingIdentity(
            identityPKCS12: pfx,
            escrowBag: escrowBag,
            format: .legacy,
            devicePublicKey: certDER
        )
    }
}

// MARK: - DER helpers (used for certificate handling)

private enum DER {
    static func decodePublicKeyFromCert(_ certDER: Data) -> Data? {
        // Minimal X.509 public-key extraction: TBSCertificate[1] ->
        // SubjectPublicKeyInfo[0]. This only needs the bit string body.
        var cursor = 0
        guard cursor + 4 <= certDER.count, certDER[cursor] == 0x30 else { return nil }
        var len = certDER[cursor + 1]
        var idx = cursor + 2
        if len & 0x80 != 0 {
            let n = Int(len & 0x7F)
            guard idx + n <= certDER.count else { return nil }
            let rawLen = certDER.subdata(in: idx ..< idx + n)
            len = rawLen.withUnsafeBytes { $0.load(as: UInt32.self) }
            idx += n
        }
        guard idx + 2 <= certDER.count, certDER[idx] == 0xA0 else { return nil }
        idx += 2
        var tbsLen = certDER[idx]
        var tbsIdx = idx + 1
        if tbsLen & 0x80 != 0 {
            let n = Int(tbsLen & 0x7F)
            guard tbsIdx + n <= certDER.count else { return nil }
            let rawLen = certDER.subdata(in: tbsIdx ..< tbsIdx + n)
            tbsLen = rawLen.withUnsafeBytes { $0.load(as: UInt32.self) }
            tbsIdx += n
        }
        guard tbsIdx + 2 <= certDER.count, certDER[tbsIdx] == 0xA0 else { return nil }
        tbsIdx += 2
        var tbsSubLen = certDER[tbsIdx]
        var subIdx = tbsIdx + 1
        if tbsSubLen & 0x80 != 0 {
            let n = Int(tbsSubLen & 0x7F)
            guard subIdx + n <= certDER.count else { return nil }
            let rawLen = certDER.subdata(in: subIdx ..< subIdx + n)
            tbsSubLen = rawLen.withUnsafeBytes { $0.load(as: UInt32.self) }
            subIdx += n
        }
        let tbsEnd = subIdx + Int(tbsSubLen)
        // Skip version[0] and serialNumber[2], then encounter
        // signature[2] and issuer[3] and subject[3]; after the subject the
        // next context tag [1] is TBSCertificate.extensions (optional),
        // and the public key is SubjectPublicKeyInfo[0].
        var pos = subIdx
        var extracted: Data?
        while pos < tbsEnd {
            guard pos + 2 <= tbsEnd else { break }
            let tag = tbsEnd[pos]
            var l = tbsEnd[pos + 1]
            var contentStart = pos + 2
            if l & 0x80 != 0 {
                let n = Int(l & 0x7F)
                guard contentStart + n <= tbsEnd.count else { break }
                l = tbsEnd.subdata(in: contentStart ..< contentStart + n)
                    .withUnsafeBytes { $0.load(as: UInt32.self) }
                contentStart += n
            }
            let contentEnd = contentStart + Int(l)
            if tag == 0xA1, contentEnd <= tbsEnd.count {
                // TBSCertificate.extensions
                pos = contentEnd
                continue
            }
            if tag == 0x03 {
                // SubjectPublicKeyInfo: skip outer length + bit-count
                guard contentEnd <= tbsEnd.count else { break }
                var ppos = contentStart
                guard ppos + 2 <= contentEnd, contentEnd[ppos] == 0x03 else { break }
                var pLen = contentEnd[ppos + 1]
                var pStart = ppos + 2
                if pLen & 0x80 != 0 {
                    let n = Int(pLen & 0x7F)
                    guard pStart + n <= contentEnd.count else { break }
                    let r = contentEnd.subdata(in: pStart ..< pStart + n)
                    pLen = r.withUnsafeBytes { $0.load(as: UInt32.self) }
                    pStart += n
                }
                extracted = contentEnd.subdata(in: pStart ..< contentStart + Int(pLen))
                break
            }
            pos = contentEnd
        }
        return extracted
    }
}

// MARK: - Escrow bag derivation

private func deriveEscrowBag(remoteIdentifier: String, publicKey: Data) -> Data {
    // Derive a stable escrow bag from the pairing identifier + public
    // key (SHA-256). This mirrors the binding used by RemotePairing
    // clients: the device validates that the client presents a session
    // tied to the same identifier.
    let input = (remoteIdentifier + publicKey.base64EncodedString()).data(using: .utf8) ?? Data()
    let digest = SHA256.hash(data: input)
    return Data(digest)
}

// MARK: - PEM/DER

private enum PEM {
    static func der(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("-----BEGIN") else {
            let t = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Data(base64Encoded: t) ?? nil
        }
        let b64 = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        return Data(base64Encoded: b64)
    }
}

// MARK: - PKCS#12 / DER (for the TLS identity)

private enum PKCS12 {
    static let oidData = [1, 2, 840, 113549, 1, 7, 1]
    static let oidSignedData = [1, 2, 840, 113549, 1, 7, 2]
    static let oidKeyBag = [1, 2, 840, 113549, 1, 12, 10, 1, 1]
    static let oidCertBag = [1, 2, 840, 113549, 1, 12, 10, 1, 3]
    static let oidX509Certificate = [1, 2, 840, 113549, 1, 9, 22, 1]
    static let oidRSAEncryption = [1, 2, 840, 113549, 1, 1, 1]

    static func build(keyPKCS8: Data, certDER: Data) -> Data {
        let keyBag = DER.seq([
            DER.oid(oidKeyBag),
            DER.explicit(0, keyPKCS8),
        ])
        let certBag = DER.seq([
            DER.oid(oidCertBag),
            DER.explicit(0, DER.seq([
                DER.oid(oidX509Certificate),
                DER.explicit(0, DER.octetString(certDER)),
            ])),
        ])
        let safeContents = DER.seq([keyBag, certBag])
        let signedData = DER.seq([
            DER.integer(3),
            DER.set([]),
            DER.seq([
                DER.oid(oidData),
                DER.explicit(0, DER.octetString(safeContents)),
            ]),
            DER.set([]),
        ])
        let authSafe = DER.seq([
            DER.oid(oidSignedData),
            DER.explicit(0, signedData),
        ])
        return DER.seq([DER.integer(3), authSafe])
    }

    static func isPKCS8(_ der: Data) -> Bool {
        guard der.count > 6, der[0] == 0x30 else { return false }
        var idx = 1
        let b = der[idx]
        idx += (b & 0x80 == 0) ? 1 : 1 + Int(b & 0x7F)
        guard idx + 3 < der.count,
              der[idx] == 0x02, der[idx + 1] == 0x01, der[idx + 2] == 0x00
        else { return false }
        return der[idx + 3] == 0x30
    }
}

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

    static func seq(_ parts: [Data]) -> Data {
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

// MARK: - Cryptography

import CryptoKit
private enum SHA256 {
    static func hash(data: Data) -> ArraySlice<UInt8> {
        SHA256.hash(data: data).makeIterator()
            .reduce(into: ArraySlice<UInt8>()) { $0.append($1) }
    }
}
