import SwiftUI

@main
struct VideoSnifferApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.downloadManager)
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
                .task {
                    await appState.onLaunch()
                }
        }
    }
}
