import SwiftUI

/// The single menu. One row with the settings gear — tapping it
/// opens the full table of every tweak and feature.
struct MainMenuView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AllFeaturesView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .accessibilityIdentifier("menu-settings")
                } header: {
                    Text("v14.0 \u{2022} Mobile")
                } footer: {
                    Text("\(DeviceStatus.modelOrDash) \u{2022} \(DeviceInfoEx.versionWithBuild)")
                }
            }
            .navigationTitle("WorkSlop")
        }
    }
}
