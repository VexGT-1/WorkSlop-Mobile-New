import SwiftUI

/// Settings: version/device info, credits, license.
/// English only (user order 2026-10-13): the in-app language picker
/// was removed and the app pins AppleLanguages to English at launch
/// (see WorkSlopApp). Localizable.xcstrings is left untouched.
struct SettingsView: View {
    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                LabeledContent("Version", value: "15.0")
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
            } header: {
                Text("Info")
            }

            Section {
                LabeledContent("Developer", value: "adnan.120hz")
                Link("TikTok @adnan.120hz", destination: URL(string: "https://www.tiktok.com/@adnan.120hz")!)
                Text("iOS 18 icon pack: catwithabaloon (v2.0)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Credits")
            }

            Section {
                Text("WorkSlop Mobile is free software, licensed under the GNU General Public License v3.0 or later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("Read the full license (GPL-3.0)",
                     destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            } header: {
                Text("License")
            }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
