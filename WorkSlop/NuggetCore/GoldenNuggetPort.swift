import Foundation
import CryptoKit

// MARK: - GoldenNugget-mobile port (verbatim, verified-readable parts)
//
// Ported from https://github.com/adnan120hz/GoldenNugget-mobile (fork of
// goldennugget-team/goldennugget-mobile), files read in full via the
// GitHub API on 2026-10-14:
//   - Nugget/Core/TweakModel.swift   (TweakValue, TweakSpec shape,
//     TweakVersion PEP-440 compare, isCompatible)
//   - Nugget/Core/TweakDomainMap.swift (verbatim, whole file)
//   - Nugget/Core/TweakCatalog.swift (TweakFileLocation, TweakSection,
//     TweakKind enums + first specs — the FILE is generated and long; the
//     full 98-spec table needs the upstream file copied in directly)
//   - Nugget/Core/TweakInjector.swift (TweakRowProfile, measured rows)
//   - Nugget/Core/HostManifests.swift (backupKeyBag base64 — verbatim)
//
// Everything below that was NOT fully readable upstream is marked
// `// TODO(GN-PORT)` instead of being invented.

// MARK: - TweakValue (TweakModel.swift)

/// A plist scalar a tweak can carry. Ported from GN TweakModel.swift.
enum GN_TweakValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var plistObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        }
    }

    var display: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        }
    }
}

// MARK: - TweakFileLocation / TweakSection / TweakKind (TweakCatalog.swift)

/// Absolute device path a tweak writes to. Ported from GN TweakCatalog.swift.
enum GN_TweakFileLocation: String, CaseIterable, Sendable {
    case featureflags = "/var/preferences/FeatureFlags/Global.plist"
    case springboard = "/var/Managed Preferences/mobile/com.apple.springboard.plist"
    case footnote = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/SharedDeviceConfiguration.plist"
    case airdrop = "/var/Managed Preferences/mobile/com.apple.sharingd.plist"
    case nanoregistry = "/var/mobile/Library/Preferences/com.apple.NanoRegistry.plist"
    case statusBarOverridesArchive = "/var/mobile/Library/SpringBoard/StatusBarOverrides.archive"
    case globalPreferences = "/var/Managed Preferences/mobile/.GlobalPreferences.plist"
    case globalPreferencesHomeDomain = "/var/mobile/Library/Preferences/.GlobalPreferences.plist"
    case appStore = "/var/Managed Preferences/mobile/com.apple.AppStore.plist"
    case backboardd = "/var/Managed Preferences/mobile/com.apple.backboardd.plist"
    case coreMotion = "/var/Managed Preferences/mobile/com.apple.CoreMotion.plist"
    case pasteboard = "/var/Managed Preferences/mobile/com.apple.Pasteboard.plist"
    case notes = "/var/Managed Preferences/mobile/com.apple.mobilenotes.plist"
    case uikit = "/var/Managed Preferences/mobile/com.apple.UIKit.plist"
    case disabledDaemons = "/var/db/com.apple.xpc.launchd/disabled.plist"
    case screentime = "/var/mobile/Library/Preferences/com.apple.ScreenTimeAgent.plist"
}

/// Tweaks-page section, raw values match GN's Section enum.
enum GN_TweakSection: String, CaseIterable, Sendable {
    case liquidGlass = "Liquid Glass"
    case springboard = "SpringBoard"
    case internalOptions = "Internal Options"
    case daemons = "Daemons to Disable"
}

/// The UI editor a spec wants. Matches GN's Kind enum.
enum GN_TweakKind: Sendable {
    case toggle
    case text
    case number
}

// MARK: - TweakSpec (TweakModel.swift)

/// One registry-defined tweak, field for field with GN's TweakSpec.
struct GN_TweakSpec: Sendable {
    let id: String
    let section: GN_TweakSection
    let title: String
    let location: GN_TweakFileLocation
    let key: String
    let value: GN_TweakValue
    let kind: GN_TweakKind
    let minValue: Double
    let maxValue: Double
    let step: Double
    let minVersion: String?
    let maxVersion: String?
    let iphoneOnly: Bool
    let ipadOnly: Bool
    let disabled: Bool
    let detail: String?
    let multiValues: [String: GN_TweakValue]?

    var writesWholeDict: Bool { multiValues != nil }

    /// The verdict of GN's `is_tweak_compatible` (src/gui/ios/compat.py:11).
    func isCompatible(deviceVersion: String, isIPhone: Bool) -> Bool {
        if disabled { return false }
        if !deviceVersion.isEmpty {
            if let minVersion,
               let cmp = GN_TweakVersion.compare(deviceVersion, minVersion), cmp < 0 { return false }
            if let maxVersion,
               let cmp = GN_TweakVersion.compare(deviceVersion, maxVersion), cmp > 0 { return false }
        }
        if iphoneOnly && !isIPhone { return false }
        if ipadOnly && isIPhone { return false }
        return true
    }
}

// MARK: - TweakVersion (TweakModel.swift)

/// PEP 440-style dotted compare, ported from GN TweakModel.swift.
enum GN_TweakVersion {
    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        var out: [Int] = []
        for part in parts {
            guard let n = Int(part) else { break }
            out.append(n)
        }
        return out.isEmpty ? nil : out
    }

    static func compare(_ lhs: String, _ rhs: String) -> Int? {
        guard var a = components(lhs), var b = components(rhs) else { return nil }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return 0
    }
}

// MARK: - TweakDomainMap (TweakDomainMap.swift, verbatim)

/// Absolute device path → backup domain, ported from GN's
/// src/restore/path_mapping.py via Nugget/Core/TweakDomainMap.swift.
enum GN_TweakDomainMap {
    private struct Rule {
        let prefix: String
        let domain: String
        let isContainer: Bool
    }

    private static let rules: [Rule] = [
        Rule(prefix: "/var/Managed Preferences/", domain: "ManagedPreferencesDomain", isContainer: false),
        Rule(prefix: "/var/root/", domain: "RootDomain", isContainer: false),
        Rule(prefix: "/var/preferences/", domain: "SystemPreferencesDomain", isContainer: false),
        Rule(prefix: "/var/MobileDevice/", domain: "MobileDeviceDomain", isContainer: false),
        Rule(prefix: "/var/mobile/", domain: "HomeDomain", isContainer: false),
        Rule(prefix: "/var/db/", domain: "DatabaseDomain", isContainer: false),
        Rule(prefix: "/var/containers/Shared/SystemGroup/",
             domain: "SysSharedContainerDomain-", isContainer: true),
        Rule(prefix: "/var/containers/Data/SystemGroup/",
             domain: "SysContainerDomain-", isContainer: true),
    ]

    struct Destination: Equatable, Sendable {
        let domain: String
        let relativePath: String
    }

    /// `split_path_into_domain`. Returns nil when no prefix matches.
    static func split(path: String) -> Destination? {
        for rule in rules where path.hasPrefix(rule.prefix) {
            let rest = String(path.dropFirst(rule.prefix.count))
            guard rule.isContainer else {
                return Destination(domain: rule.domain, relativePath: rest)
            }
            if let slash = rest.firstIndex(of: "/") {
                let group = String(rest[rest.startIndex..<slash])
                let remainder = String(rest[rest.index(after: slash)...])
                return Destination(domain: rule.domain + group, relativePath: remainder)
            }
            return Destination(domain: rule.domain + rest, relativePath: "")
        }
        return nil
    }
}

// MARK: - TweakRowProfile (TweakInjector.swift, measured rows)

/// The row shape the device writes for one backup domain. Ported from GN
/// TweakInjector.swift (measured off the device's own backup rows).
struct GN_TweakRowProfile {
    let fileOwner: Int
    let fileGroup: Int
    let fileProtectionClass: Int
    let fileExceptionPublisher: String?
    let dirOwner: Int
    let dirGroup: Int
    let dirProtectionClass: Int
    let rootOwner: Int
    let rootGroup: Int
    let rootProtectionClass: Int
    let carriesDigest: Bool
    let verified: Bool
    let note: String

    /// Protection classes used by GN's MBFileBlob constants.
    static let PROTECTION_CLASS_FILE = 1
    static let PROTECTION_CLASS_DIR = 2
    static let PROTECTION_CLASS_SYSTEM_FILE = 4

    static func forDomain(_ domain: String) -> GN_TweakRowProfile {
        if domain.hasPrefix("AppDomain") { return .appContainer }
        if domain.hasPrefix("SysSharedContainerDomain") || domain.hasPrefix("SysContainerDomain") {
            return .systemContainer
        }
        switch domain {
        case "ManagedPreferencesDomain": return .managedPreferences
        case "HomeDomain": return .homeDomain
        case "SystemPreferencesDomain": return .systemPreferences
        case "DatabaseDomain": return .database
        default: return .unmeasured
        }
    }
}

extension GN_TweakRowProfile {
    static let appContainer = GN_TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_FILE,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_DIR,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_DIR,
        carriesDigest: false, verified: true,
        note: "AppDomain-* rows, as delivered by BackupInjector.inject")

    static let systemContainer = GN_TweakRowProfile(
        fileOwner: -2, fileGroup: -2, fileProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: -2, dirGroup: -2, dirProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_DIR,
        carriesDigest: false, verified: true,
        note: "SysSharedContainerDomain rows, as delivered by BackupInjector.injectSystemPlist")

    static let managedPreferences = GN_TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true, verified: false,
        note: "ManagedPreferencesDomain rows")

    static let homeDomain = GN_TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_DIR,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_DIR,
        carriesDigest: true, verified: false,
        note: "HomeDomain rows")

    static let systemPreferences = GN_TweakRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: nil,
        dirOwner: 0, dirGroup: 0, dirProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true, verified: false,
        note: "SystemPreferencesDomain rows")

    static let database = GN_TweakRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 0, dirGroup: 0, dirProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true, verified: false,
        note: "DatabaseDomain rows")

    /// A domain this port has not measured a row for yet.
    static let unmeasured = GN_TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: nil,
        dirOwner: 501, dirGroup: 501, dirProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_DIR,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: GN_TweakRowProfile.PROTECTION_CLASS_DIR,
        carriesDigest: true, verified: false,
        note: "UNMEASURED domain rows — defaults from Tweak.__init__ (501/501)")
}

// MARK: - BackupKeyBag (HostManifests.swift, verbatim base64)

/// GN HostManifests.backupKeyBag — libimobiledevice's public hardcoded
/// backup keybag (src/restore/backup.py:244). 1336 bytes decoded. Without
/// it the device pulls every payload then refuses with MBErrorDomain/205
/// "No keybag in manifest".
enum GN_HostManifests {
    static let backupKeyBag = Data(base64Encoded: backupKeyBagBase64)!
    private static let backupKeyBagBase64 =
        """
        VkVSUwAAAAQAAAAFVFlQRQAAAAQAAAABVVVJRAAAABDud41d1b9NBICR1BH9JfVtSE1DSwAAACgAAAAAAAAAAAAAAAAAAAAA\
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAV1JBUAAAAAQAAAAAU0FMVAAAABRY5Ne2bthGQ5rf4O3gikep1e6tZUlURVIAAAAE\
        AAAnEFVVSUQAAAAQB7R8awiGR9aba1UuVahGPENMQVMAAAAEAAAAAVdSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAo\
        N3kQAJloFg+ukEUY+v5P+dhc/Welw/oucsyS40UBh67ZHef5ZMk9UVVVSUQAAAAQgd0cg0hSTgaxR3PVUbcEkUNMQVMAAAAE\
        AAAAAldSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAoMiQTXx0SJlyrGJzdKZQ+SfL124w+2Tf/3d1R2i9yNj9zZCHN\
        JhnorVVVSUQAAAAQf7JFQiBOS12JDD7qwKNTSkNMQVMAAAAEAAAAA1dSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAo\
        SEelorROJA46ZUdwDHhMKiRguQyqHukotrxhjIfqiZ5ESBXX9txi51VVSUQAAAAQfF0G/837QLq01xH9+66vx0NMQVMAAAAE\
        AAAABFdSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAol0BvFhd5bu4Hr75XqzNf4g0fMqZAie6OxI+x/pgm6Y95XW17\
        N+ZIDVVVSUQAAAAQimkT2dp1QeadMu1KhJKNTUNMQVMAAAAEAAAABVdSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo\
        2N2DZarQ6GPoWRgTiy/tdjKArOqTaH0tPSG9KLbIjGTOcLodhx23xFVVSUQAAAAQQV37JVZHQFiKpoNiGmT6+ENMQVMAAAAE\
        AAAABldSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAofe2QSvDC2cV7Etk4fSBbgqDx5ne/z1VHwmJ6NdVrTyWi80Sy\
        869DM1VVSUQAAAAQFzkdH+VgSOmTj3yEcfWmMUNMQVMAAAAEAAAAB1dSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo\
        7kLYPQ/DnHBERGpaz37eyntIX/XzovsS0mpHW3SoHvrb9RBgOB+WblVVSUQAAAAQEBpgKOz9Tni8F9kmSXd0sENMQVMAAAAE\
        AAAACFdSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo5mxVoyNFgPMzphYhm1VG8Fhsin/xX+r6mCd9gByF5SxeolAI\
        T/ICF1VVSUQAAAAQrfKB2uPSQtWh82yx6w4BoUNMQVMAAAAEAAAACVdSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo\
        5iayZBwcRa1c1MMx7vh6lOYux3oDI/bdxFCW1WHCQR/Ub1MOv+QaYFVVSUQAAAAQiLXvK3qvQza/mea5inss/0NMQVMAAAAE\
        AAAACldSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAoD2wHX7KriEe1E31z7SQ7/+AVymcpARMYnQgegtZD0Mq2U55u\
        xwNr2FVVSUQAAAAQ/Q9feZxLS++qSe/a4emRRENMQVMAAAAEAAAAC1dSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo\
        cYda2jyYzzSKggRPw/qgh6QPESlkZedgDUKpTr4ZZ8FDgd7YoALY1g==
        """
}
