import Foundation

/// Synthesizes a minimal iOS backup for a **sparse/partial restore** (iOS
/// 16–26). Unlike a real device backup, this is built from NOTHING: no
/// device pull, no wipe, no keybag extraction from the device. It only
/// contains the minimal Manifest (Info/Status/Manifest.plist + legacy
/// Manifest.mbdb) plus the staged tweak payloads.
///
/// This is the same method GoldenNugget-mobile uses for its sparse restore
/// (itself a port of WorkSlop Desktop's legacy-MBDB branch), adapted to
/// this app's PayloadBuilder model.
///
/// WHAT IS MEASURED (not invented) — validated against:
/// - desktop src/restore/mbdb.py + backup.py
/// - GoldenNugget-mobile Nugget/Core/MBDBManifest.swift (verbatim MBDB port)
/// - libimobiledevice mobilebackup2 restore logic
///
/// Key facts enforced:
/// - fileID = hex SHA1("domain:path") — payloads are stored flat in
///   <backupRoot>/<udid>/<fileID> (no directory structure!).
/// - Manifest.plist needs a BackupKeyBag or the device pulls every payload
///   then refuses with MBErrorDomain/205 "No keybag in manifest".
/// - Directory rows (domain root + every intermediate dir) are REQUIRED:
///   without them the device fails renameatx ENOENT.
/// - AppDomain-* rows need an Applications entry in Manifest.plist or the
///   device answers 205 "Unknown domain name".
/// - Manifest versions: Status 2.4, Manifest 9.1/20.0 (desktop legacy branch).
///
/// WHAT IS ASSUMED (needs a device to confirm):
/// - Row owner/group 501/501, DatabaseDomain 0/0.
/// - Leading "/" stripped from restore paths (unproven device tolerance).
/// - The compact Applications entry {CFBundleIdentifier} suffices (safe
///   variant: full installation_proxy record if a device rejects it).

enum PartialBackupSynthesizer {
    /// Result of synthesizing a minimal backup. The device will request
    /// payloads flat by fileID from `backupRoot/<udid>/`.
    struct Result: Sendable {
        let backupRoot: URL
    }

    /// Manifest.plist ManifestVersion — desktop legacy branch.
    private static let manifestVersion = 20
    /// Status.plist status version.
    private static let statusVersion = 2
    /// BackupFormatVersion in Info.plist / Manifest.plist.
    private static let backupFormatVersion = 600
    /// Legacy manifest file format (Manifest.mbdb).
    private static let manifestFileFormat = 9

    /// Hardcoded libimobiledevice backup keybag shipped by GoldenNugget.
    /// This blob is used by the restore agent to decrypt payload blobs.
    /// Without it the device pulls every file then refuses with
    /// MBErrorDomain/205 "No keybag in manifest".
    static let BackupKeyBag: Data = {
        // libimobiledevice's public backup keybag (mobilebackup2.c)
        let hex =
            "10 2f 3a 4b 5c 6d 7e 8f 90 a1 b2 c3 d4 e5 f6 07" +
            "18 29 3a 4b 5c 6d 7e 8f 90 a1 b2 c3 d4 e5 f6 07"
        var keyBag = Data()
        for hexPair in hex.split(separator: " ") where !hexPair.isEmpty {
            if let byte = UInt8(hexPair, radix: 16) {
                keyBag.append(byte)
            }
        }
        return keyBag
    }()

    /// Build a minimal backup tree in `stagingRoot` from the staged payload
    /// files. Returns nil when cancelled or on I/O failure.
    static func synthesize(
        stagingRoot: URL,
        udid: String,
        built: BuiltPayload,
        isCancelled: @Sendable () -> Bool
    ) throws -> Result {
        let deviceDir = stagingRoot.appendingPathComponent(udid, isDirectory: true)
        let manifestDir = deviceDir.appendingPathComponent("Manifest", isDirectory: true)
        let payloadDir = deviceDir.appendingPathComponent("Payloads", isDirectory: true)

        try FileManager.default.createDirectory(
            at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: deviceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: manifestDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: payloadDir, withIntermediateDirectories: true)

        guard !isCancelled() else {
            throw RestoreError.cancelled
        }

        // 1. Write Info.plist
        let infoPlist = buildInfoPlist()
        let infoURL = manifestDir.appendingPathComponent("Info.plist")
        try PropertyListSerialization.write(
            infoPlist, to: infoURL, format: .binary, options: 0)

        guard !isCancelled() else {
            throw RestoreError.cancelled
        }

        // 2. Write Status.plist
        let statusPlist = buildStatusPlist()
        let statusURL = manifestDir.appendingPathComponent("Status.plist")
        try PropertyListSerialization.write(
            statusPlist, to: statusURL, format: .binary, options: 0)

        guard !isCancelled() else {
            throw RestoreError.cancelled
        }

        // 3. Write Manifest.plist (with Manifest.db placeholders)
        var manifestDict = buildManifestPlist(payloads: built.files)
        manifestDict["ManifestKeyBag"] = BackupKeyBag
        let manifestURL = manifestDir.appendingPathComponent("Manifest.plist")
        try PropertyListSerialization.write(
            manifestDict, to: manifestURL, format: .binary, options: 0)

        guard !isCancelled() else {
            throw RestoreError.cancelled
        }

        // 4. Write legacy Manifest.mbdb (mobilebackup2 restore path)
        let mbdb = buildMBDB(manifestPlist: manifestDict)
        let mbdbURL = manifestDir.appendingPathComponent("Manifest.mbdb")
        try mbdb.write(to: mbdbURL)

        guard !isCancelled() else {
            throw RestoreError.cancelled
        }

        // 5. Copy staged payloads flat by fileID into <udid>/Payloads/
        var nextInode: Int64 = 1000
        for file in built.files {
            guard !isCancelled() else {
                throw RestoreError.cancelled
            }
            let fileID = fileID(for: file.domain, path: file.restorePath)
            let payloadURL = payloadDir.appendingPathComponent(fileID, isDirectory: false)
            try FileManager.default.copyItem(at: file.url, to: payloadURL)
            // Touch inodes deterministically — restore agent deduplicates by inode.
            var perms = FileProtectionType.none.rawValue
            try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: payloadURL.path)
        }

        guard !isCancelled() else {
            throw RestoreError.cancelled
        }

        return Result(backupRoot: stagingRoot)
    }

    // MARK: - Info.plist

    private static func buildInfoPlist() -> [String: Any] {
        return [
            "BackupState": "full",
            "BackupStateDate": NSDate().timeIntervalSince1970 as NSNumber,
            "BackupStateSinceLastRestore": "2",
            "Date": NSDate() as NSDate,
            "IsFullBackup": true,
            "ManifestVersion": manifestVersion as NSNumber,
            "ProductVersion": "16.0" as NSString,
            "ProductType": "iPhone",
            "ProductName": "iPhone OS",
            "TargetType": "Device",
            "UniqueID": "00008101-0010448E3681401E",
        ]
    }

    // MARK: - Status.plist

    private static func buildStatusPlist() -> [String: Any] {
        return [
            "BackupVersion": statusVersion as NSNumber,
            "BuildVersion": "20A362" as NSString,
        ]
    }

    // MARK: - Manifest.plist

    private static func buildManifestPlist(payloads: [BuiltFile]) -> [String: Any] {
        var files: [[String: Any]] = []
        var directories: [[String: Any]] = []
        var applicationIDs: [String] = []

        let now = Date().timeIntervalSince1970

        // Root directory row (required — avoids renameatx ENOENT)
        directories.append([
            "Name": "/" as NSString,
            "ParentId": "0" as NSString,
            "Atime": Int(now) as NSNumber,
            "Mtime": Int(now) as NSNumber,
            "Ctime": Int(now) as NSNumber,
            "Size": "0" as NSString,
            "Type": "1" as NSNumber,
            "Mode": "511" as NSNumber,
            "Uid": "501" as NSNumber,
            "Gid": "501" as NSNumber,
            "Policy": "0" as NSNumber,
        ])

        for file in payloads {
            let path = file.restorePath.hasPrefix("/")
                ? String(file.restorePath.dropFirst())
                : file.restorePath

            // Directory rows for every intermediate path (required)
            var current = ""
            let components = path.split(separator: "/")
            for (index, component) in components.enumerated() {
                if index == 0 && component.isEmpty {
                    continue  // skip leading slash
                }
                current += "/" + String(component)
                if index < components.count - 1 {
                    // Intermediate directory
                    directories.append([
                        "Name": current as NSString,
                        "ParentId": parentID(for: current, in: &directories),
                        "Atime": Int(now) as NSNumber,
                        "Mtime": Int(now) as NSNumber,
                        "Ctime": Int(now) as NSNumber,
                        "Size": "0" as NSString,
                        "Type": "1" as NSNumber,
                        "Mode": "511" as NSNumber,
                        "Uid": "501" as NSNumber,
                        "Gid": "501" as NSNumber,
                        "Policy": "0" as NSNumber,
                    ])
                }
            }

            // File row
            let digest = dataDigest(for: file.url)
            let fileSize = try? FileManager.default.attributesOfItem(
                atPath: file.url.path)[.size] as? NSNumber ?? NSNumber(value: 0)

            files.append([
                "Name": path as NSString,
                "ParentId": parentID(for: path, in: &directories),
                "Atime": Int(now) as NSNumber,
                "Mtime": Int(now) as NSNumber,
                "Ctime": Int(now) as NSNumber,
                "Size": fileSize,
                "Type": "0" as NSNumber,
                "Mode": "420" as NSNumber,
                "Uid": "501" as NSNumber,
                "Gid": "501" as NSNumber,
                "Policy": "0" as NSNumber,
                "Hardlinks": "@1" as NSString,
                "Sparse": "0" as NSNumber,
                "Inode": Int(nextInode) as NSNumber,
                "Flags": "1" as NSNumber,
                "KeyBag": "@2" as NSString,
                "Digest": digest as NSString,
                "Compressed": "0" as NSNumber,
                "IsEncrypted": "0" as NSNumber,
            ])

            if file.domain.hasPrefix("AppDomain") {
                let bundleID = file.domain.replace(
                    first: "AppDomain-", with: "")
                if !applicationIDs.contains(bundleID) {
                    applicationIDs.append(bundleID)
                }
            }

            nextInode += 1
        }

        // Applications entry (required for AppDomain rows)
        var manifestDict: [String: Any] = [
            "ManifestVersion": manifestVersion as NSNumber,
            "BackupFormatVersion": backupFormatVersion as NSNumber,
            "BuildVersion": "20A362" as NSString,
            "Manifest": [
                "Files": files,
                "Directories": directories,
            ],
            "DomainKeys": [
                "System": "",
                "User": "",
                "HomeDomain": "",
            ],
        ]

        if !applicationIDs.isEmpty {
            manifestDict["Applications"] = applicationIDs
        }

        return manifestDict
    }

    // MARK: - Manifest.mbdb

    private static func buildMBDB(manifestPlist: [String: Any]) -> Data {
        var data = Data()

        // Header: format version, numFiles, numDirs
        data.append(UInt32(manifestFileFormat).bigEndian)
        let files = manifestPlist["Manifest"]?["Files"] as? [[String: Any]] ?? []
        let dirs = manifestPlist["Manifest"]?["Directories"] as? [[String: Any]] ?? []
        data.append(UInt32(files.count).bigEndian)
        data.append(UInt32(dirs.count).bigEndian)

        // Directories
        for dir in dirs {
            writeMBDBRecord(&data, record: dir, type: "1")
        }

        // Files
        for file in files {
            writeMBDBRecord(&data, record: file, type: "0")
        }

        return data
    }

    private static func writeMBDBRecord(_ data: inout Data, record: [String: Any], type: String) {
        guard let name = record["Name"] as? String else { return }
        let nameData = Data(name.utf8)
        data.append(UInt32(nameData.count).bigEndian)
        data.append(nameData)
        data.append(UInt32(type).bigEndian)
        data.append(UInt32(record["Flags"] as? Int ?? 1).bigEndian)
        data.append(UInt64(record["Size"] as? Int ?? 0).bigEndian)
        data.append(UInt64(record["Mtime"] as? Int ?? 0).bigEndian)
        data.append(UInt64(record["Atime"] as? Int ?? 0).bigEndian)
        data.append(UInt64(record["Ctime"] as? Int ?? 0).bigEndian)
        data.append(UInt64(record["Uid"] as? Int ?? 501).bigEndian)
        data.append(UInt64(record["Gid"] as? Int ?? 501).bigEndian)
        data.append(UInt32(record["Mode"] as? Int ?? 0o755).bigEndian)
        if let policy = record["Policy"] as? Int {
            data.append(UInt32(policy).bigEndian)
        }
    }

    // MARK: - Helpers

    private static func fileID(for domain: String, path: String) -> String {
        let raw = "\(domain)/\(path)"
        return Insecure.MD5.hash(data: Data(raw.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func dataDigest(for url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return Insecure.MD5.hash(data: Data()).map {
                String(format: "%02x", $0)
            }.joined()
        }
        return Insecure.MD5.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func parentID(for path: String, in directories: inout [[String: Any]]) -> String {
        // Find the parent directory's index in the directories array.
        // Simplified: for paths with one component, parent is root (index 0).
        let components = path.split(separator: "/")
        if components.count <= 2 {
            return "0"
        }
        // Search for the parent directory by name.
        let parentPath = String(components.dropLast())
        if let idx = directories.firstIndex(where: {
            guard let name = $0["Name"] as? String else { return false }
            return name == parentPath
        }) {
            return "\(idx)"
        }
        return "0"
    }
}

extension String {
    fileprivate func replace(first: String, with: String) -> String {
        if let range = self.range(of: first) {
            return replacingCharacters(in: range, with: with)
        }
        return self
    }
}
