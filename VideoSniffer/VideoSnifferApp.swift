import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundCompletionBox.shared.handler = completionHandler
    }
}

@main
struct VideoSnifferApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
