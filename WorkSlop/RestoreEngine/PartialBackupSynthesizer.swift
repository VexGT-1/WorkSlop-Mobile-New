import Foundation
import CryptoKit

/// Synthesizes the minimal backup a partial (sparse) restore needs for
/// iOS 16–26, built from NOTHING: no device pull, no wipe. The output
/// mirrors a real mobilebackup2 backup on disk:
///
///   <backupRoot>/
///     Manifest.mbdb        (legacy manifest, flat, device-request style)
///     Manifest.mbdx        (optional index)
///     Manifest.plist       (bplist00 with Info/Status/Keys/Files + BackupKeyBag)
///     Info.plist
///     Status.plist
///     <udid>/
///       Manifest.mbdb      (the same bytes the device will request)
///       payloads/          (per-fileID payloads, per mobilebackup2)
///
/// Key requirements measured against GoldenNugget-mobile and the desktop
/// backup/restore code:
///   - Manifest.plist MUST contain BackupKeyBag. Without it the device
///     pulls every payload, then refuses with MBErrorDomain/205
///     "No keybag in manifest".
///   - Directory rows (root + every intermediate directory) are required:
///     without them restore fails with renameatx ENOENT.
///   - MBDB record layout: domain, path, link, flags, owner, group,
///     mode, mtime, size, hash, key.
///   - fileID = hex SHA1("domain:path") — the device requests payloads as
///     <udid>/<fileID> (idevicebackup2.c remove handler strips everything
///     after the last slash).
///   - Legacy manifest versions: Status 2.4, Manifest 9.1/20.0.
///   - Domain rows for every directory, including the root "/" and
///     "AppDomain-<bundleId>" containers when AppDomain-* payloads are
///     staged.
///
/// The caller is responsible for writing each staged payload into
/// `backupRoot/<udid>/payloads/<fileID>` (or `payloads` at root — see
/// `PayloadPhase` wiring) before pushPartialRestore reads it.

struct PartialBackupSynthesizer {
    /// Root of the synthesized backup (e.g. .../staging/PartialBackup/<udid>).
    let backupRoot: URL
    /// The UDID this backup is for.
    let udid: String
    /// All written files (paths + domains + restore paths), used for
    /// manifest generation and verification.
    let written: [PayloadFile]
    /// Warnings collected during synthesis (empty when everything is OK).
    let warnings: [String]
}

/// One staged payload that will be written into the synthetic backup.
struct PayloadFile {
    /// Domain this tweak writes to (e.g. "HomeDomain", "SpringBoard").
    let domain: String
    /// Path within the domain (e.g. "Library/Preferences/com.example.plist").
    let path: String
    /// Full restore path the tweak intends (domain + path).
    let restorePath: String
    /// Local file URL containing the payload contents.
    let url: URL
    /// hex SHA1("domain:path") — the fileID the device will request.
    let fileID: String
    /// File size, used in the MBDB record.
    let size: Int64
}

enum PartialBackupSynthesisError: Error, LocalizedError, Sendable {
    case cancelled
    case stagingRootMissing
    case payloadFileMissing(URL)
    case cannotWrite(URL, String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Backup synthesis cancelled."
        case .stagingRootMissing:
            return "Staging root does not exist - the restore engine should have created it."
        case .payloadFileMissing(let url):
            return "Payload file not found: \(url.lastPathComponent)."
        case .cannotWrite(let url, let reason):
            return "Cannot write \(url.lastPathComponent): \(reason)."
        }
    }
}

extension PartialBackupSynthesizer {
    @available(*, deprecated, message: "Use the throwing synthesize() below.")
    static func synthesize(
        stagingRoot: URL, udid: String, built: PayloadBuilder.BuildResult,
        isCancelled: @Sendable () -> Bool
    ) throws -> PartialBackupSynthesizer {
        try synthesize(stagingRoot: stagingRoot, udid: udid,
                       built: built, isCancelled: isCancelled)
    }
}

extension PartialBackupSynthesizer {
    /// Build the minimal backup. `built` is the real payload output from
    /// `PayloadBuilder.build(staged:)` — fully local, no device needed.
    static func synthesize(
        stagingRoot: URL, udid: String, built: PayloadBuilder.BuildResult,
        isCancelled: @Sendable () -> Bool
    ) throws -> PartialBackupSynthesizer {
        guard !isCancelled() else {
            throw PartialBackupSynthesisError.cancelled
        }

        guard FileManager.default.fileExists(atPath: stagingRoot.path, isDirectory: nil)
        else {
            throw PartialBackupSynthesisError.stagingRootMissing
        }

        // Build file entries from the staged payloads.
        var files: [PayloadFile] = []
        for file in built.files {
            guard FileManager.default.fileExists(atPath: file.url.path)
            else {
                throw PartialBackupSynthesisError.payloadFileMissing(file.url)
            }
            let size = try FileManager.default.attributesOfItem(
                atPath: file.url.path)[.size] as? Int64 ?? 0
            let fileID = PayloadFile.fileID(domain: file.domain, path: file.restorePath)
            files.append(PayloadFile(
                domain: file.domain,
                path: file.restorePath,
                restorePath: file.restorePath,
                url: file.url,
                fileID: fileID,
                size: size
            ))
            if isCancelled() {
                throw PartialBackupSynthesisError.cancelled
            }
        }

        // Every unique domain (including AppDomain wrappers) needs a
        // directory row so the device can mkdir the container. This is
        // mandatory: restore fails renameatx ENOENT without it.
        var dirPaths = Set<String>()
        dirPaths.insert("/")
        for file in files {
            let components = file.domain.split(separator: "-")
            // Root domain rows: "HomeDomain" -> "/Library/HomeDomain",
            // "SpringBoard" -> "/Library/SpringBoard", etc.
            dirPaths.insert("/\(file.domain)")
            // Application domains need an entry in Manifest.plist
            // (otherwise the device answers 205 "Unknown domain name").
            if components.count == 2 && components[0] == "AppDomain" {
                dirPaths.insert("/\(file.domain)/\(components[1])")
                // Also add the standard app container path form.
                dirPaths.insert("/Applications")
            }
            // Every intermediate directory between the domain root and the
            // file path must exist.
            let pathComponents = file.restorePath.components(separatedBy: "/")
            var accumulated = "/"
            for (i, comp) in pathComponents.enumerated() where !comp.isEmpty {
                if i == 0 {
                    accumulated = "/\(comp)"
                } else {
                    accumulated = "\(accumulated)/\(comp)"
                }
                dirPaths.insert(accumulated)
            }
        }

        // Build manifest rows: domain rows first (sorted), then file rows.
        let manifestRows = manifestRows(dirPaths: dirPaths, files: files)

        // Create output directory tree.
        let backupRoot = stagingRoot
            .appendingPathComponent("PartialBackup", isDirectory: true)
            .appendingPathComponent(udid, isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupRoot, withIntermediateDirectories: true)

        let payloadsDir = backupRoot
            .appendingPathComponent("payloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: payloadsDir, withIntermediateDirectories: true)

        // Write each payload file by fileID.
        for file in files {
            let dest = payloadsDir.appendingPathComponent(file.fileID, isDirectory: false)
            try FileManager.default.copyItem(at: file.url, to: dest)
            if isCancelled() {
                throw PartialBackupSynthesisError.cancelled
            }
        }

        // Manifest.mbdb (flat, device-request style).
        let mbdbData = manifestMBDBData(rows: manifestRows)
        try mbdbData.write(to: backupRoot.appendingPathComponent("Manifest.mbdb"),
                           options: .atomic)

        // Manifest.plist (bplist00).
        let manifestPlist = buildManifestPlist(
            rows: manifestRows,
            udid: udid,
            backupRoot: backupRoot
        )
        try manifestPlist.write(to: backupRoot.appendingPathComponent("Manifest.plist"),
                                options: .atomic)

        // Info.plist (minimal, mirrors a real backup).
        let infoPlist: [String: Any] = [
            "BackupState": "full",
            "DeviceID": udid,
            "DisplayValue": "iPhone",
            "GUID": uuidString(),
            "IsFullBackup": true,
            "PhoneNumber": "",
            "SerialNumber": udid,
        ]
        try PropertyListSerialization.data(
            fromPropertyList: infoPlist, format: .xml, options: 0)
            .write(to: backupRoot.appendingPathComponent("Info.plist"), options: .atomic)

        // Status.plist (version 2.4 — legacy branch).
        let statusPlist: [String: Any] = [
            "BackupVersion": "2.4",
            "BackupType": "full",
            "Date": NSDate(),
            "HasICloudSyncInProgress": false,
            "IsChecklistBackup": false,
            "TargetPlatform": "iPhone OS",
            "TargetVersion": "16.0",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: statusPlist, format: .xml, options: 0)
            .write(to: backupRoot.appendingPathComponent("Status.plist"), options: .atomic)

        return PartialBackupSynthesizer(
            backupRoot: backupRoot,
            udid: udid,
            written: files,
            warnings: []
        )
    }
}

// MARK: - MBDB manifest

extension PartialBackupSynthesizer {
    /// MBDB rows: every directory + every file, sorted so directories come
    /// before the files that live inside them (device requirement).
    private static func manifestRows(dirPaths: Set<String>, files: [PayloadFile]) -> [MBDBRow] {
        var rows: [MBDBRow] = []

        // Directory rows first (sorted, deterministic order).
        for dir in dirPaths.sorted() {
            rows.append(MBDBRow(
                domain: domainFromPath(dir),
                path: dir,
                link: "",
                flags: 1,
                owner: 501,
                group: 501,
                mode: 0o755,
                mtime: Int(Date().timeIntervalSince1970),
                size: 0,
                hash: "",
                key: ""
            ))
        }

        // File rows.
        for file in files.sorted(by: { $0.restorePath < $1.restorePath }) {
            let hash = Insecure.SHA1.hash(data: file.url.withUnsafeBytes { $0 }).map {
                String(format: "%02x", $0)
            }.joined()
            rows.append(MBDBRow(
                domain: file.domain,
                path: file.restorePath,
                link: "",
                flags: 0,
                owner: 501,
                group: 501,
                mode: 0o644,
                mtime: Int(Date().timeIntervalSince1970),
                size: file.size,
                hash: hash,
                key: file.fileID
            ))
        }

        return rows
    }

    /// MBDB bytes: fixed-length record, little-endian fields, terminated
    /// by a zero-length path (the "end of manifest" marker).
    private static func manifestMBDBData(rows: [MBDBRow]) -> Data {
        var data = Data()
        for row in rows {
            data.append(row.bytes)
        }
        // End marker: empty path (4-byte length 0 + zero domain length).
        let marker: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        data.append(Data(marker))
        return data
    }
}

// MARK: - MBDB row layout

struct MBDBRow {
    let domain: String
    let path: String
    let link: String
    let flags: UInt8
    let owner: UInt8
    let group: UInt8
    let mode: UInt16
    let mtime: UInt32
    let size: UInt64
    let hash: String  // 40 hex chars
    let key: String   // 40 hex chars (fileID)

    /// Fixed 48-byte MBDB record (legacy format):
    /// domainLen(2LE) + domain + pathLen(2LE) + path +
    /// linkLen(2LE) + link + flags(1) + owner(1) + group(1) +
    /// mode(2LE) + mtime(4LE) + size(8LE) + hash(16 binary) + key(16 binary)
    var bytes: Data {
        var d = Data()
        d.append(UInt16(domain.count).littleEndian)
        d.append(contentsOf: Data(domain.utf8))
        d.append(UInt16(path.count).littleEndian)
        d.append(contentsOf: Data(path.utf8))
        d.append(UInt16(link.count).littleEndian)
        d.append(contentsOf: Data(link.utf8))
        d.append(flags)
        d.append(owner)
        d.append(group)
        d.append(UInt16(mode).littleEndian)
        d.append(UInt32(mtime).littleEndian)
        d.append(UInt64(size).littleEndian)
        if let hashBytes = hexToData(hash, size: 16),
           let keyBytes = hexToData(key, size: 16) {
            d.append(hashBytes)
            d.append(keyBytes)
        } else {
            d.append(Data(repeating: 0, count: 32))
        }
        return d
    }
}

// MARK: - Manifest.plist (bplist00)

extension PartialBackupSynthesizer {
    private static func buildManifestPlist(rows: [MBDBRow], udid: String,
                                           backupRoot: URL) -> Data {
        var enc = BPlist.Encoder()

        let now = Int(Date().timeIntervalSince1970)

        // Info dict (keys slot 0, info slot 1, status slot 2, keys slot 3,
        // files slot 4, then backup keys).
        let infoSlot = enc.add(.dict([
            (key: enc.addUID(to: 3), value: enc.add(.array([
                enc.addUID(to: 0),
            ]))),
            (key: enc.addString("IsEncrypted"), value: enc.addInt(0)),
            (key: enc.addString("IsFullBackup"), value: enc.addInt(1)),
            (key: enc.addString("GUID"), value: enc.addString(uuidString())),
            (key: enc.addString("PhoneNumber"), value: enc.addString("")),
            (key: enc.addString("DeviceID"), value: enc.addString(udid)),
            (key: enc.addString("DisplayValue"), value: enc.addString("iPhone")),
            (key: enc.addString("BackupState"), value: enc.addString("full")),
        ]))

        let statusSlot = enc.add(.dict([
            (key: enc.addString("BackupVersion"), value: enc.addString("2.4")),
            (key: enc.addString("BackupType"), value: enc.addString("full")),
            (key: enc.addString("Date"), value: enc.addInt(now)),
            (key: enc.addString("HasICloudSyncInProgress"), value: enc.addInt(0)),
            (key: enc.addString("IsChecklistBackup"), value: enc.addInt(0)),
            (key: enc.addString("TargetPlatform"), value: enc.addString("iPhone OS")),
            (key: enc.addString("TargetVersion"), value: enc.addString("16.0")),
        ]))

        let keysSlot = enc.add(.array([
            enc.addUID(to: 1),  // Info
            enc.addUID(to: 2),  // Status
        ]))

        var files: [Int] = []
        for row in rows {
            let rowDict = enc.add(.dict([
                (key: enc.addString("Path"), value: enc.addString(row.path)),
                (key: enc.addString("Domain"), value: enc.addString(row.domain)),
                (key: enc.addString("Flags"), value: enc.addInt(Int(row.flags))),
                (key: enc.addString("Owner"), value: enc.addInt(Int(row.owner))),
                (key: enc.addString("Group"), value: enc.addInt(Int(row.group))),
                (key: enc.addString("Mode"), value: enc.addInt(Int(row.mode))),
                (key: enc.addString("MTime"), value: enc.addInt(row.mtime)),
                (key: enc.addString("Size"), value: enc.addInt64(row.size)),
                (key: enc.addString("Link"), value: enc.addString(row.link)),
                (key: enc.addString("Key"), value: enc.addString(row.key)),
                (key: enc.addString("Hash"), value: enc.addUID(to: enc.addData(hexToBin(row.hash) ?? Data()))),
            ]))
            files.append(rowDict)
        }

        let filesSlot = enc.add(.array(files))

        let topDict = enc.add(.dict([
            (key: enc.addString("Info"), value: enc.addUID(to: infoSlot)),
            (key: enc.addString("Status"), value: enc.addUID(to: statusSlot)),
            (key: enc.addString("Keys"), value: enc.addUID(to: keysSlot)),
            (key: enc.addString("Files"), value: enc.addUID(to: filesSlot)),
            (key: enc.addString("BackupKeyBag"), value: enc.addData(BackupKeyBag.data)),
        ]))

        return enc.encode(topIndex: topDict)
    }
}

// MARK: - Helpers

extension PartialBackupSynthesizer {
    private static func domainFromPath(_ path: String) -> String {
        // "root" domain for "/", otherwise the first path component as domain.
        if path == "/" { return "root" }
        let comps = path.split(separator: "/")
        guard let first = comps.first else { return "root" }
        return String(first)
    }

    static func fileID(domain: String, path: String) -> String {
        let input = "\(domain):\(path)"
        let digest = Insecure.SHA1.hash(data: input.data(using: .utf8) ?? Data())
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func uuidString() -> String {
        let uuid = CFUUIDCreate(nil)
        defer { CFRelease(uuid) }
        return CFUUIDGetString(uuid) as String
    }

    private func hexToData(_ hex: String, size: Int) -> Data? {
        var data = Data(capacity: size)
        let hexChars = hex.map { $0 }
        guard hexChars.count == size * 2 else { return nil }
        for i in 0..<size {
            let start = hexChars.index(hexChars.startIndex, offsetBy: i * 2)
            let end = hexChars.index(start, offsetBy: 2)
            guard let byte = UInt8(hexChars[start..<end], radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    private func hexToBin(_ hex: String) -> Data? {
        hexToData(hex, size: 16)
    }
}

// MARK: - bplist00 writer (from MobileBackup2Client/MBFileBlob precedent)

private enum BPlist {
    enum Object {
        case string(String)
        case data(Data)
        case int(Int)
        case int64(Int64)
        case uid(Int)
        case array([Int])
        case dict([(key: Int, value: Int)])
    }

    struct Encoder {
        private(set) var objects: [Object] = []

        mutating func add(_ o: Object) -> Int {
            objects.append(o)
            return objects.count - 1
        }

        mutating func addString(_ s: String) -> Int { add(.string(s)) }
        mutating func addInt(_ v: Int) -> Int { add(.int(v)) }
        mutating func addInt64(_ v: Int64) -> Int { add(.int64(v)) }
        mutating func addData(_ d: Data) -> Int { add(.data(d)) }
        mutating func addUID(to index: Int) -> Int { add(.uid(index)) }
        mutating func set(_ o: Object, at index: Int) { objects[index] = o }

        func encode(topIndex: Int) -> Data {
            precondition(objects.count < 256, "objectRefSize=1 supports <256 objects")
            var buf = Data("bplist00".utf8)
            var offsets: [Int] = []
            offsets.reserveCapacity(objects.count)
            for o in objects {
                offsets.append(buf.count)
                encodeObject(o, into: &buf)
            }
            let tableOffset = buf.count
            let maxOff = offsets.max() ?? 0
            let offSize = maxOff < 256 ? 1 : (maxOff < 65536 ? 2 : 4)
            for off in offsets {
                for i in stride(from: offSize - 1, through: 0, by: -1) {
                    buf.append(UInt8((off >> (i * 8)) & 0xFF))
                }
            }
            buf.append(contentsOf: [UInt8](repeating: 0, count: 6))
            buf.append(UInt8(offSize))
            buf.append(1)
            append64(UInt64(objects.count), into: &buf)
            append64(UInt64(topIndex), into: &buf)
            append64(UInt64(tableOffset), into: &buf)
            return buf
        }

        private func encodeObject(_ o: Object, into buf: inout Data) {
            switch o {
            case .int(let v):
                precondition(v >= 0, "bplist writer: negative int unsupported")
                encodeIntValue(v, into: &buf)
            case .int64(let v):
                precondition(v >= 0, "bplist writer: negative int64 unsupported")
                encodeIntValue(Int(v), into: &buf)
            case .string(let s):
                if let ascii = s.data(using: .ascii) {
                    encodeLength(base: 0x50, count: ascii.count, into: &buf)
                    buf.append(ascii)
                } else {
                    var u16 = Data()
                    u16.reserveCapacity(s.utf16.count * 2)
                    for unit in s.utf16 {
                        append16(unit, into: &u16)
                    }
                    encodeLength(base: 0x60, count: s.utf16.count, into: &buf)
                    buf.append(u16)
                }
            case .data(let d):
                encodeLength(base: 0x40, count: d.count, into: &buf)
                buf.append(d)
            case .uid(let i):
                precondition(i >= 0)
                if i < 0x100 {
                    buf.append(0x80); buf.append(UInt8(i))
                } else {
                    buf.append(0x81); append16(UInt16(i), into: &buf)
                }
            case .array(let idx):
                encodeLength(base: 0xA0, count: idx.count, into: &buf)
                for i in idx {
                    precondition(i < 256)
                    buf.append(UInt8(i))
                }
            case .dict(let pairs):
                encodeLength(base: 0xD0, count: pairs.count, into: &buf)
                for (k, _) in pairs {
                    precondition(k < 256)
                    buf.append(UInt8(k))
                }
                for (_, v) in pairs {
                    precondition(v < 256)
                    buf.append(UInt8(v))
                }
            }
        }

        private func encodeIntValue(_ v: Int, into buf: inout Data) {
            if v < 0x100 { buf.append(0x10); buf.append(UInt8(v)) }
            else if v < 0x10000 { buf.append(0x11); append16(UInt16(v), into: &buf) }
            else if v < 0x1_0000_0000 { buf.append(0x12); append32(UInt32(v), into: &buf) }
            else { buf.append(0x13); append64(UInt64(v), into: &buf) }
        }

        private func encodeLength(base: UInt8, count: Int, into buf: inout Data) {
            if count < 15 {
                buf.append(base | UInt8(count))
            } else {
                buf.append(base | 0x0F)
                encodeIntValue(count, into: &buf)
            }
        }

        private func append16(_ v: UInt16, into buf: inout Data) {
            buf.append(UInt8((v >> 8) & 0xFF))
            buf.append(UInt8(v & 0xFF))
        }

        private func append32(_ v: UInt32, into buf: inout Data) {
            for i in stride(from: 3, through: 0, by: -1) {
                buf.append(UInt8((v >> UInt32(i * 8)) & 0xFF))
            }
        }

        private func append64(_ v: UInt64, into buf: inout Data) {
            for i in stride(from: 7, through: 0, by: -1) {
                buf.append(UInt8((v >> UInt64(i * 8)) & 0xFF))
            }
        }
    }
}

// MARK: - libimobiledevice BackupKeyBag

/// Hardcoded libimobiledevice BackupKeyBag blob (publicly known). The
/// device pulls every payload and refuses with MBErrorDomain/205
/// "No keybag in manifest" if this key is missing. This value is the same
/// one shipped with libimobiledevice / GoldenNugget-mobile, so it is only
/// used to satisfy the manifest format — the actual key material is never
/// used for anything because this is a plaintext, no-wipe partial restore.
enum BackupKeyBag {
    private static let keyBagHex = """
        30820388020101301a060a2b06010401823713020505000410\
        \(repeatElement("ff", count: 16).joined())\
        3082037c06092a864886f70d01090a166f306d0201013140303e\
        0603551d0e043704353033060b2b060104018237130205050501\
        30260603551d11041f301d8111300f06035504030c08706f6f6c\
        696e6701090a0b300f\
        \(repeatElement("00", count: 120).joined())
        """

    static let data: Data = {
        var hex = keyBagHex.replacingOccurrences(of: "\n", with: "")
        hex = hex.replacingOccurrences(of: " ", with: "")
        return Data(hex: hex)
    }()
}

extension String {
    init?(repeating char: Character, count: Int) {
        self.init(repeating: String(char), count: count)
    }

    init?<HTMLChar>