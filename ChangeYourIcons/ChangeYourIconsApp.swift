import SwiftUI

@main
struct ChangeYourIconsApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}
