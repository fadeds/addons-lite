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

    private static let barHeight: CGFloat = 38

    private static func miniWindowWidth(for screenWidth: CGFloat) -> CGFloat {
        min(max(screenWidth - 72, 0), 288)
    }

    private static func playerSize(for mode: PlayerMode, geoSize: CGSize, miniWidth: CGFloat) -> CGSize {
        switch mode {
        case .mini:
            return CGSize(width: miniWidth, height: miniWidth * 9 / 16 + barHeight)
        case .wide:
            let wideWidth = max(geoSize.width - 16, miniWidth)
            return CGSize(width: wideWidth, height: wideWidth * 9 / 16 + barHeight)
        case .full:
            return geoSize
        }
    }

    var body: some View {
        GeometryReader { geo in
            let mode = appState.playerMode
            let miniWidth = Self.miniWindowWidth(for: geo.size.width)
            let playerSize = Self.playerSize(for: mode, geoSize: geo.size, miniWidth: miniWidth)

            // 小窗拖动范围
            let maxOffsetX = max(0, (geo.size.width - miniWidth) / 2)
            let maxOffsetY = max(0, geo.size.height - miniWidth * 9 / 16 - Self.barHeight - 24)
            let offset = CGSize(
                width: min(max(windowOffset.width, -maxOffsetX), maxOffsetX),
                height: min(max(windowOffset.height, 0), maxOffsetY)
            )

            ZStack(alignment: .top) {
                // 宽窗模式：点空白处收回小窗
                if mode == .wide {
                    Color.black
                        .opacity(0.4)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { appState.playerMode = .mini }
                }

                PlayerView(
                    url: url,
                    windowOffset: Binding(
                        get: { windowOffset },
                        set: { newValue in
                            guard mode == .mini else { return }
                            windowOffset = CGSize(
                                width: min(max(newValue.width, -maxOffsetX), maxOffsetX),
                                height: min(max(newValue.height, 0), maxOffsetY)
                            )
                        }
                    )
                )
                .frame(width: playerSize.width, height: playerSize.height)
                .offset(
                    x: mode == .mini ? offset.width : 0,
                    y: mode == .mini ? 8 + offset.height : (mode == .wide ? 14 : 0)
                )
                .shadow(
                    color: mode == .full ? .clear : .black.opacity(0.35),
                    radius: mode == .full ? 0 : 12,
                    y: mode == .full ? 0 : 6
                )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: mode)
        }
    }
}
