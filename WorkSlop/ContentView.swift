import SwiftUI

/// App root: one menu, one gear. Shared state lives here and is
/// passed down through the environment — rows never own storage.
struct ContentView: View {
    @StateObject private var selection = SelectionStore()
    @StateObject private var status = StatusStore()

    var body: some View {
        MainMenuView()
            .environmentObject(selection)
            .environmentObject(status)
    }
}
