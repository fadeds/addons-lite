import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloadManager: DownloadManager

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            VideoListView()
                .tabItem {
                    Label("待下载", systemImage: "link")
                }
                .tag(0)

            DownloadListView()
                .tabItem {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .badge(downloadManager.activeCount)
                .tag(1)

            FileListView()
                .tabItem {
                    Label("文件", systemImage: "folder")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(3)
        }
        .overlay(alignment: .bottom) {
            if let toast = appState.toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 72)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.toast)
    }
}
