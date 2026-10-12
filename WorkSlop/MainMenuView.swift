import SwiftUI

/// The single menu. One row with the settings gear — tapping it
/// opens the full table of every tweak and feature.
///
/// Screenshot runs can deep-link straight to a screen with
/// `-DemoScreen <name>` (home|settings|statusbar|posterboard);
/// normal launches always start on the menu.
enum DemoRoute: Hashable {
    case settings
    case statusBar
    case posterBoard
}

struct MainMenuView: View {
    let demoScreen: String?
    @State private var path: [DemoRoute] = []

    init(demoScreen: String? = nil) {
        self.demoScreen = demoScreen
    }

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: DemoRoute.self) { route in
                switch route {
                case .settings: AllFeaturesView()
                case .statusBar: StatusBarDetailView()
                case .posterBoard: PosterBoardFilesView()
                }
            }
        }
        .onAppear {
            // Screenshot/demo deep link only; never on a real tap-through.
            guard path.isEmpty, let s = demoScreen else { return }
            switch s {
            case "settings": path = [.settings]
            case "statusbar": path = [.settings, .statusBar]
            case "posterboard": path = [.settings, .posterBoard]
            default: break
            }
        }
    }
}
