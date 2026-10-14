import Foundation

// VERBATIM PORT from GoldenNugget-mobile (Nugget/Core/TweakModel.swift)
// https://github.com/goldennugget-team/goldennugget-mobile
// Source of truth for WorkSlop Mobile's tweak data layer.

/// A plist scalar a tweak can carry. Ported from GoldenNugget's TweakModel.
enum TweakValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// The object `PropertyListSerialization` should be handed for this value.
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

    /// Re-shape a value that came from outside (a preset) into what `spec` expects.
    func coerced(to spec: TweakSpec) -> TweakValue {
        switch spec.kind {
        case .toggle:
            switch self {
            case .bool(let b): return .bool(b)
            case .int(let i): return .bool(i != 0)
            case .double(let d): return .bool(d != 0)
            case .string(let s): return .bool((s as NSString).boolValue)
            }
        case .number:
            switch spec.value {
            case .double:
                switch self {
                case .int(let i): return .double(Double(i))
                case .double(let d): return .double(d)
                case .bool(let b): return .double(b ? 1 : 0)
                case .string(let s): return .double(Double(s) ?? 0)
                }
            default:
                switch self {
                case .int(let i): return .int(i)
                case .double(let d): return d == d.rounded() ? .int(Int(d)) : .double(d)
                case .bool(let b): return .int(b ? 1 : 0)
                case .string(let s):
                    if let i = Int(s) { return .int(i) }
                    if let d = Double(s) { return .double(d) }
                    return .int(0)
                }
            }
        case .text:
            return .string(display)
        }
    }
}

/// One registry-defined tweak, field for field with the reference `TweakSpec`.
struct TweakSpec: Sendable {
    let id: String
    let section: TweakSection
    let title: String
    let location: TweakFileLocation
    let key: String
    let value: TweakValue
    let kind: TweakKind
    let minValue: Double
    let maxValue: Double
    let step: Double
    let minVersion: String?
    let maxVersion: String?
    let iphoneOnly: Bool
    let ipadOnly: Bool
    let disabled: Bool
    let detail: String?
    let multiValues: [String: TweakValue]?

    var writesWholeDict: Bool { multiValues != nil }
}

/// The subset of `packaging.version.Version` the registry's bounds need.
enum TweakVersion {
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

extension TweakSpec {
    /// The verdict of the reference's `is_tweak_compatible` (compat.py:11).
    func isCompatible(deviceVersion: String, isIPhone: Bool) -> Bool {
        if disabled { return false }
        if !deviceVersion.isEmpty {
            if let minVersion,
               let cmp = TweakVersion.compare(deviceVersion, minVersion), cmp < 0 { return false }
            if let maxVersion,
               let cmp = TweakVersion.compare(deviceVersion, maxVersion), cmp > 0 { return false }
        }
        if iphoneOnly && !isIPhone { return false }
        if ipadOnly && isIPhone { return false }
        return true
    }
}

/// Live selection that mirrors GoldenNugget's `tweaks: dict[TweakID, Tweak]`.
struct TweakSelection: Sendable {
    private var values: [String: TweakValue] = [:]
    private var enabled: Set<String> = []

    mutating func setOn(_ id: String, _ on: Bool) {
        if on { enabled.insert(id) } else { enabled.remove(id) }
    }

    mutating func setValue(_ id: String, _ value: TweakValue) {
        values[id] = value
    }

    func isOn(_ spec: TweakSpec) -> Bool {
        enabled.contains(spec.id)
    }

    func value(for spec: TweakSpec) -> TweakValue? {
        values[spec.id] ?? spec.value
    }

    var enabledIDs: Set<String> { enabled }
}
