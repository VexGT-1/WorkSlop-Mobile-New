import SwiftUI

/// App accent color. One color at a time — this is not the old
/// 3-UI theme system; the icon stays blue, only the tint changes.
enum AppAccent: String, CaseIterable, Identifiable {
    case blue, purple, green, orange, red, pink
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .pink: return .pink
        }
    }

    var label: String {
        switch self {
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .green: return "Green"
        case .orange: return "Orange"
        case .red: return "Red"
        case .pink: return "Pink"
        }
    }
}

/// In-app language. Sets AppleLanguages; iOS applies it on the next
/// cold start — the note below says so instead of pretending
/// it is instant.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, id, vi
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .id: return "Indonesia"
        case .vi: return "Tiếng Việt"
        }
    }

    /// nil = follow the system language.
    var appleCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .id: return "id"
        case .vi: return "vi"
        }
    }

    func apply() {
        let ud = UserDefaults.standard
        ud.set(rawValue, forKey: "appLanguage")
        if let code = appleCode {
            ud.set([code], forKey: "AppleLanguages")
        } else {
            ud.removeObject(forKey: "AppleLanguages")
        }
        ud.synchronize()
    }
}

struct SettingsView: View {
    @AppStorage("appAccent") private var appAccentRaw = "blue"
    @AppStorage("appLanguage") private var appLanguageRaw = "system"
    @State private var languageNote: String?

    private var accent: AppAccent {
        AppAccent(rawValue: appAccentRaw) ?? .blue
    }
    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .system
    }

    var body: some View {
        List {
            Section("Appearance") {
                HStack {
                    Label("App color", systemImage: "paintpalette")
                    Spacer()
                    ForEach(AppAccent.allCases) { option in
                        Button {
                            appAccentRaw = option.rawValue
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .strokeBorder(.primary, lineWidth: accent == option ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.label)
                    }
                }
                .accessibilityIdentifier("app-color-picker")

                Picker(selection: $appLanguageRaw) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                } label: {
                    Label("Language", systemImage: "globe")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("language-picker")
                .onChange(of: appLanguageRaw) { _ in
                    language.apply()
                    languageNote = "Language saved. Restart the app to apply it."
                }
                if let languageNote {
                    Text(languageNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Info") {
                LabeledContent("Version", value: "14.0")
                LabeledContent("This device's iOS", value: DeviceInfoEx.fullVersion)
                Text("iOS 26 and below: Partial restore (sparse restore, no wipe). iOS 27: Full backup → modify → restore with all data - the WorkSlop Desktop method.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Find My must be OFF before an apply and back ON afterwards - same rule as the desktop.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("A running restore cannot be cancelled mid-flight. If it stalls, turn off the VPN tunnel, then force-restart (Volume Up, Volume Down, hold Side button).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("This app cannot reboot your iPhone. After an apply you restart manually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Credits") {
                LabeledContent("Developer", value: "adnan.120hz")
                Link("TikTok @adnan.120hz", destination: URL(string: "https://www.tiktok.com/@adnan.120hz")!)
                Text("UI reference: Nugget UI")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("iOS 18 icon pack: catwithabaloon (v2.0)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("License") {
                Text("WorkSlop Mobile is free software, licensed under the GNU General Public License v3.0 or later - the same license as the Nugget project it descends from.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("Read the full license (GPL-3.0)",
                     destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
