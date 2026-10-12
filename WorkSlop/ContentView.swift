import SwiftUI

/// App root: one menu, one gear. Shared state lives here and is
/// passed down through the environment — rows never own storage.
struct ContentView: View {
    let demoScreen: String?
    @StateObject private var selection = SelectionStore()
    @StateObject private var status = StatusStore()

    init(demoScreen: String? = nil) {
        self.demoScreen = demoScreen
    }

    var body: some View {
        MainMenuView(demoScreen: demoScreen)
            .environmentObject(selection)
            .environmentObject(status)
    }
}
