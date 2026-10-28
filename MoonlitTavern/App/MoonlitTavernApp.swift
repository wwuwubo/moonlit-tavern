import SwiftUI

@main
struct MoonlitTavernApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.models)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
        }
        .onChange(of: scenePhase) { _, phase in
            state.handleScenePhase(phase)
        }
    }
}
