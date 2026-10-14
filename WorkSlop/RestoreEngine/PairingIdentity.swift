import Foundation

// MARK: - Pairing identity

/// Pairing record yang diimpor user. Bisa 2 format:
/// - Legacy idevicepair (iOS <17): DeviceCertificate / HostPrivateKey / RootCertificate
/// - iOS 17+ RemotePairing: identifier / private_key / public_key / alt_irk
///
/// Digunakan buat handshake TLS ke lockdownd & buat escrow bag mobilebackup2.
/// Mirip: libimobiledevice's lockdownd pairing identity + GoldenNugget's RemotePairing.

enum PairingFormat {
    case legacy        // legacy lockdown record
    case remotePairing // iOS 17+ RemotePairing
}

struct PairingIdentity: Sendable {
    /// Format record yang dikenali
    let format: PairingFormat

    /// Identifier device (UDID / HostID / RemotePairing identifier)
    let identifier: String?

    /// Private key PEM deranged / PKCS#1 RSAPrivateKey / PKCS#8 PrivateKeyInfo
    let privateKey: Data

    /// Public key (opsional, biasanya dipake untuk verifikasi)
    let publicKey: Data?

    /// Alternate IRK — iOS 17+ RemotePairing, buat encrypted communication
    let altIrk: Data?

    /// Escrow bag = identity info yang dipake lockdown startService / backup2.
    /// Shape:
    /// - Legacy: DER-encoded { DeviceCertificate, HostPrivateKey, ... }
    /// - iOS 17+: PEM base64 dari identifier + private key (mirip libimobiledevice
    ///   LockdownIdentity / RemotePairingRecord.identifier).
    ///
    /// Ini yang "paling rawan": format beda tiap iOS version. Fallback ke PEM
    /// identifier+key biar kompatibel di sebagian besar kondisi.
    let escrowBag: Data

    // MARK: - Parsing

    /// Load pairing record dari file pairing.plist di app container.
    /// Returns nil kalau file gak ada / gak valid.
    static func load() -> PairingIdentity? {
        guard PairingStore.isImported,
              let data = try? Data(contentsOf: PairingStore.fileURL),
              PairingStore.validate(data) else {
            return nil
        }
        return PairingIdentity(data: data)
    }

    init?(data: Data) {
        guard let obj = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
              !obj.isEmpty else { return nil }

        // Kenali format dulu biar tau field mana yang ada
        switch PairingStore.format(of: data) {
        case .remotePairing:
            self.init(remotePairingDict: obj)
        case .legacy:
            self.init(legacyDict: obj)
        case nil:
            return nil
        }
    }

    // MARK: - iOS 17+ RemotePairing

    private init?(remotePairingDict: [String: Any]) {
        guard let identifier = remotePairingDict["identifier"] as? String,
              !identifier.isEmpty,
              let privateKeyPEM = remotePairingDict["private_key"] as? String,
              let publicKeyPEM = remotePairingDict["public_key"] as? String,
              let privateKey = PEM.privateKey(from: privateKeyPEM),
              let publicKey = PEM.publicKey(from: publicKeyPEM) else {
            return nil
        }

        let altIrk = remotePairingDict["alt_irk"]
            as? String
            .flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        self.format = .remotePairing
        self.identifier = identifier
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.altIrk = altIrk

        // Escrow bag: PEM-encoded identifier + private key.
        // Mirip: https://github.com/libimobiledevice/libimobiledevice/blob/master/lockdown/lockdown_private.h
        // LockdownIdentity / RemotePairingRecord.identifier yang dipake start_service escrow bag.
        var escrow = Data()
        if let idData = identifier.data(using: .utf8) {
            escrow.append(Data([UInt8(idData.count)]) + idData)
        }
        escrow.append(privateKey)
        self.escrowBag = escrow
    }

    // MARK: - Legacy lockdown record

    private init?(legacyDict: [String: Any]) {
        guard let hostID = legacyDict["HostID"] as? String,
              !hostID.isEmpty,
              let privateKeyPEM = legacyDict["HostPrivateKey"] as? String
            ?? legacyDict["private_key"] as? String,
              let privateKey = PEM.privateKey(from: privateKeyPEM),
              let certDER = legacyDict["DeviceCertificate"] as? String
            ?? legacyDict["HostCertificate"] as? String
            ?? legacyDict["RootCertificate"] as? String,
              let cert = PEM.certificate(from: certDER) else {
            return nil
        }

        self.format = .legacy
        self.identifier = hostID
        self.privateKey = privateKey
        self.publicKey = nil
        self.altIrk = nil

        // Escrow bag legacy: PKCS#12-like identity (device cert + host key)
        // Mirip: libimobiledevice LockdownIdentity _identityFromKeychain /
        // pair-record HostIdentity yang dipake start_service.
        self.escrowBag = PKCS12Identity.make(hostID: hostID, cert: cert, key: privateKey)
    }

    // MARK: - Convenience

    /// True kalau record ini bisa dipake buat TLS handshake lockdownd
    var isUsable: Bool {
        switch format {
        case .remotePairing: return identifier != nil && !privateKey.isEmpty
        case .legacy: return identifier != nil && !privateKey.isEmpty && !escrowBag.isEmpty
        }
    }

    /// UDID / device identifier yang bisa dipake buat nama staging dir
    var deviceIdentifier: String { identifier ?? "device" }
}

// MARK: - PEM / DER helpers

private enum PEM {
    /// Decode "-----BEGIN RSA PRIVATE KEY-----" / "BEGIN PRIVATE KEY-----" -> DER PKCS#8
    static func privateKey(from pem: String) -> Data? {
        let key = der(from: pem)
        guard key?.isEmpty == false else { return nil }

        // Kalau PKCS#1, konversi ke PKCS#8 dulu (SecPKCS12Import / CFNetwork mostly butuh PKCS#8)
        if PKCS12.isPKCS1(key!) {
            return PKCS12.pkcs1ToPKCS8(key!)
        }
        return key
    }

    /// Decode public key (BEGIN EC PUBLIC KEY / BEGIN PUBLIC KEY)
    static func publicKey(from pem: String) -> Data? {
        der(from: pem)
    }

    /// Decode certificate (BEGIN CERTIFICATE)
    static func certificate(from pem: String) -> Data? {
        der(from: pem)
    }

    static func der(from pem: String) -> Data? {
        guard let text = String(data: pem.data(using: .utf8)!, encoding: .utf8),
              text.contains("-----BEGIN") else {
            // Maybe already DER bytes stored as string? unlikely, but fallback
            return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let b64 = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined()
        return Data(base64Encoded: b64)
    }
}

// MARK: - PKCS#12 identity builder (legacy escrow bag)

/// Bangun PKCS#12 container (MAC-less, unencrypted) berisi:
/// device certificate + host private key.
/// Mirip: libimobiledevice LockdownIdentity _identityFromKeychain
/// dan GoldenNugget's escrow bag untuk start_service.
private enum PKCS12Identity {
    static let oidData = [1, 2, 840, 113549, 1, 7, 1]
    static let oidSignedData = [1, 2, 840, 113549, 1, 7, 2]
    static let oidKeyBag = [1, 2, 840, 113549, 1, 12, 10, 1, 1]
    static let oidCertBag = [1, 2, 840, 113549, 1, 12, 10, 1, 3]
    static let oidX509Certificate = [1, 2, 840, 113549, 1, 9, 22, 1]
    static let oidRSAEncryption = [1, 2, 840, 113549, 1, 1, 1]

    static func make(hostID: String, cert: Data, key: Data) -> Data {
        // Minimal DER writer (mirip PKCS12.swift di LockdownClient)
        func lengthPrefix(_ n: Int) -> Data {
            precondition(n >= 0)
            if n < 128 { return Data([UInt8(n)]) }
            var v = n, bytes: [UInt8] = []
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return Data([UInt8(0x80 | bytes.count)]) + Data(bytes)
        }
        func tlv(_ tag: UInt8, _ content: Data) -> Data {
            Data([tag]) + lengthPrefix(content.count) + content
        }
        func sequence(_ parts: [Data]) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
        func set(_ parts: [Data]) -> Data { tlv(0x31, parts.reduce(Data(), +)) }
        func integer(_ value: Int) -> Data {
            var v = value, bytes: [UInt8] = []
            repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
            while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return tlv(0x02, Data(bytes))
        }
        func octetString(_ data: Data) -> Data { tlv(0x04, data) }
        func oid(_ arcs: [Int]) -> Data {
            precondition(arcs.count >= 2)
            var body = Data([UInt8(40 * arcs[0] + arcs[1])])
            for arc in arcs.dropFirst(2) {
                var v = arc, tmp: [UInt8] = [UInt8(v & 0x7F)]
                v >>= 7
                while v > 0 {
                    tmp.insert(UInt8((v & 0x7F) | 0x80), at: 0)
                    v >>= 7
                }
                body += Data(tmp)
            }
            return tlv(0x06, body)
        }
        func explicit(_ n: UInt8, _ content: Data) -> Data { tlv(0xA0 | n, content) }

        let keyBag = sequence([
            oid(oidKeyBag),
            explicit(0, key),
        ])
        let certBag = sequence([
            oid(oidCertBag),
            explicit(0, sequence([
                oid(oidX509Certificate),
                explicit(0, octetString(cert)),
            ])),
        ])
        let safeContents = sequence([keyBag, certBag])
        let signedData = sequence([
            integer(3),
            set([]),
            sequence([
                oid(oidData),
                explicit(0, octetString(safeContents)),
            ]),
            set([]),
        ])
        let authSafe = sequence([
            oid(oidSignedData),
            explicit(0, signedData),
        ])
        return sequence([DER.integer(3), authSafe])
    }
}

/// Helper: cek apakah DER ini PKCS#1 RSAPrivateKey (untuk konversi ke PKCS#8)
extension PKCS12 {
    static func isPKCS1(_ der: Data) -> Bool {
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
    static func integer(_ value: Int) -> Data {
        var v = value, bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + lengthPrefix(content.count) + content
    }
    static func lengthPrefix(_ n: Int) -> Data {
        precondition(n >= 0)
        if n < 128 { return Data([UInt8(n)]) }
        var v = n, bytes: [UInt8] = []
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([UInt8(0x80 | bytes.count)]) + Data(bytes)
    }
}
