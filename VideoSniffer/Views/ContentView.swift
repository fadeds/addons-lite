import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloadManager: DownloadManager

    var body: some View {
        ZStack(alignment: .top) {
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

            if let url = appState.playingFileURL {
                PlayerHost(url: url)
                    .id(url)
                    .zIndex(1)
                    .ignoresSafeArea(edges: appState.playerMode == .full ? .all : [])
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.toast)
    }
}

private struct PlayerHost: View {
    let url: URL

    @EnvironmentObject private var appState: AppState
    @State private var windowOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let mode = appState.playerMode
            let size = PlayerLayout.size(mode: mode, container: geo.size)
            let limit = PlayerLayout.dragLimit(mode: mode, container: geo.size, window: size)

            ZStack(alignment: .top) {
                PlayerView(url: url)
                    .frame(width: size.width, height: size.height)
                    .modifier(
                        WindowDragModifier(
                            offset: $windowOffset,
                            enabled: mode == .mini,
                            limit: limit
                        )
                    )
                    .padding(.top, mode == .mini ? 8 : 0)
                    .frame(
                        width: geo.size.width,
                        height: geo.size.height,
                        alignment: mode == .full ? .center : .top
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
