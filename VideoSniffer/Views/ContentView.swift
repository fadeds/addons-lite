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
        .overlay {
            if let url = appState.playingFileURL {
                PlayerHost(url: url)
                    .id(url)
                    .ignoresSafeArea(edges: appState.playerExpanded ? .all : [])
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
            let expanded = appState.playerExpanded
            let miniWidth = min(geo.size.width - 32, 300)
            let miniHeight = miniWidth * 9 / 16 + 38
            let width = expanded ? geo.size.width : miniWidth
            let height = expanded ? geo.size.height : miniHeight
            let maxOffsetX = max(0, (geo.size.width - miniWidth) / 2 - 8)
            let maxOffsetY = max(0, geo.size.height - miniHeight - 16)
            let offset = CGSize(
                width: min(max(windowOffset.width, -maxOffsetX), maxOffsetX),
                height: min(max(windowOffset.height, 0), maxOffsetY)
            )

            PlayerView(
                url: url,
                windowOffset: Binding(
                    get: { windowOffset },
                    set: { newValue in
                        windowOffset = CGSize(
                            width: min(max(newValue.width, -maxOffsetX), maxOffsetX),
                            height: min(max(newValue.height, 0), maxOffsetY)
                        )
                    }
                )
            )
            .frame(width: width, height: height)
            .position(
                x: expanded ? geo.size.width / 2 : geo.size.width / 2 + offset.width,
                y: expanded ? geo.size.height / 2 : 8 + miniHeight / 2 + offset.height
            )
            .shadow(
                color: expanded ? .clear : .black.opacity(0.35),
                radius: expanded ? 0 : 12,
                y: expanded ? 0 : 6
            )
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: expanded)
        }
        .onChange(of: appState.playerExpanded) { expanded in
            if expanded {
                windowOffset = .zero
            }
        }
    }
}
