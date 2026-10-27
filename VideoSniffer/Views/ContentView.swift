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

            // 偏移由 PlayerView 内部应用，宿主只持有状态。
            // 不做任何手势包裹：包裹式手势会和播放器内部的按钮抢触摸。
            //
            // 全屏时不给显式尺寸，直接撑满父容器：
            // 旋转后如果还在按 geo.size 算尺寸，视图可能仍是旋转前的竖屏大小，
            // 控制条被顶到可视区之外 —— 表现为"画面正常但按钮点不到"。
            PlayerView(
                url: url,
                windowOffset: windowOffset,
                windowOffsetLimit: limit,
                onWindowOffsetChange: { windowOffset = $0 }
            )
            .frame(
                width: mode == .mini ? size.width : nil,
                height: mode == .mini ? size.height : nil
            )
            // offset 必须放在尺寸 frame 之后：放在里面时命中区域会留在原位，
            // 内容却已经被移走，表现为"看得见但点不到"。
            .offset(
                x: mode == .mini ? windowOffset.width : 0,
                y: mode == .mini ? windowOffset.height : 0
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: mode == .mini ? .top : .center
            )
            .padding(.top, mode == .mini ? 8 : 0)
        }
    }
}
