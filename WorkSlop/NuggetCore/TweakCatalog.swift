import Foundation

// PORT from GoldenNugget-mobile (Nugget/Core/TweakCatalog.swift)
// https://github.com/goldennugget-team/goldennugget-mobile
// Source of truth: GoldenNugget's src/tweaks/registry.py + basic_plist_locations.py.
//
// This is the data half of the tweak port. TweakModel.swift carries the types
// (TweakSpec/TweakValue); this file carries the FileLocation enum, the Section
// enum, the Kind enum, and the registry array itself.

/// An absolute device path a tweak writes to. Ported from GoldenNugget's
/// FileLocation enum; TweakDomainMap turns it into (domain, relativePath).
enum TweakFileLocation: String, CaseIterable, Sendable {
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

/// A tweaks-page section. Raw values match GoldenNugget's Section enum.
enum TweakSection: String, CaseIterable, Identifiable, Sendable {
    case liquidGlass = "Liquid Glass"
    case springboard = "SpringBoard"
    case internalOptions = "Internal Options"
    case daemons = "Daemons to Disable"
    var id: String { rawValue }
}

/// The UI editor a spec wants. Matches GoldenNugget's Kind enum.
enum TweakKind: Sendable {
    case toggle
    case text
    case number
}

/// Every registry-defined tweak, in the reference's own order.
///
/// Iteration order is load-bearing: the compiler merges several tweaks into
/// one plist, and GoldenNugget iterates `tweaks` in this same order, so a
/// later key wins exactly as it does upstream. Do not sort this array.
enum TweakCatalog {
    static let all: [TweakSpec] = [
        // — Liquid Glass (registry order preserved) —
        TweakSpec(
            id: "ForceSolariumFallback",
            section: .liquidGlass,
            title: "Force Solarium Fallback",
            location: .globalPreferences,
            key: "SolariumForceFallback",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "26.0",
            maxVersion: "26.99",
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Forces the older Solarium rendering path instead of the newer one. Useful for troubleshooting or for devices where the current Solarium engine misbehaves on iOS 26.",
            multiValues: nil
        ),
        TweakSpec(
            id: "IgnoreSolariumLinkedOnCheck",
            section: .liquidGlass,
            title: "Ignore Solarium Linked-On Check",
            location: .globalPreferences,
            key: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "26.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Ignores the compile-time (linked-on) SDK version check for Solarium, allowing Liquid Glass features to run that would otherwise be gated by the SDK an app was built with.",
            multiValues: nil
        ),
        TweakSpec(
            id: "ForceSolariumIntelligence",
            section: .liquidGlass,
            title: "Force Solarium Intelligence",
            location: .globalPreferences,
            key: "SolariumForceIntelligence",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Forces the experimental Solarium 'Intelligence' rendering features (adaptive, machine-driven effects) on iOS 27 where they are not enabled by default.",
            multiValues: nil
        ),
        TweakSpec(
            id: "ForceEnhancedSpeculars",
            section: .liquidGlass,
            title: "Force Enhanced Speculars",
            location: .globalPreferences,
            key: "SolariumForceEnhancedSpeculars",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Enables the enhanced specular (highlight and reflection) rendering pass that is normally only used on the most capable devices.",
            multiValues: nil
        ),
        TweakSpec(
            id: "UISolariumFallback",
            section: .liquidGlass,
            title: "UI Solarium Fallback",
            location: .globalPreferences,
            key: "UISolariumForceFallback",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Forces UIKit to use the fallback Solarium path when rendering UI. Can fix broken or glitchy system UI on some iOS 27 devices.",
            multiValues: nil
        ),
        TweakSpec(
            id: "IgnoreSolariumHardwareCheck",
            section: .liquidGlass,
            title: "Ignore Solarium Hardware Check",
            location: .globalPreferences,
            key: "com.apple.SwiftUI.IgnoreSolariumHardwareCheck",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Disables the hardware capability check for Solarium, enabling Liquid Glass effects on devices officially considered too weak.",
            multiValues: nil
        ),
        TweakSpec(
            id: "IgnoreSolariumOptOut",
            section: .liquidGlass,
            title: "Ignore Solarium Opt-Out",
            location: .globalPreferences,
            key: "com.apple.SwiftUI.IgnoreSolariumOptOut",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Ignores an app's explicit opt-out from Solarium, forcing Liquid Glass rendering even where the app requested the legacy appearance.",
            multiValues: nil
        ),
    ]

    /// `all` plus the daemon group carrier spec. This is what the compiler
    /// iterates — not `all` — so the launchd disabled.plist rides the same
    /// compile/apply path as the registry tweaks.
    static var allWithDaemons: [TweakSpec] {
        all + [DaemonGroups.launchdSpec]
    }
}
