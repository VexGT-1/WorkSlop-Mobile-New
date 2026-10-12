import SwiftUI

/// App root: one menu, one gear. Shared state lives here and is
/// passed down through the environment — rows never own storage.
/// The user's accent color tints the whole app.
struct ContentView: View {
    let demoScreen: String?
    @AppStorage("appAccent") private var appAccentRaw = "blue"
    @StateObject private var selection = SelectionStore()
    @StateObject private var status = StatusStore()

    init(demoScreen: String? = nil) {
        self.demoScreen = demoScreen
    }

    var body: some View {
        MainMenuView(demoScreen: demoScreen)
            .environmentObject(selection)
            .environmentObject(status)
            .tint((AppAccent(rawValue: appAccentRaw) ?? .blue).color)
    }
}
