import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var downloadsSize: Int64 = 0
    @State private var toastText: String?

    var body: some View {
        NavigationStack {
            List {
                UpdateSection(checker: appState.updateChecker)

                storageSection

                aboutSection
            }
            .navigationTitle("设置")
            .onAppear {
                refreshSize()
            }
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            LabeledContent("已下载文件") {
                Text(Storage.formatBytes(downloadsSize))
            }
            LabeledContent("下载任务") {
                Text("\(appState.downloadManager.tasks.count)")
            }

            Button("清理临时文件", role: .destructive) {
                clearTemporary()
            }
        } header: {
            Text("存储")
        } footer: {
            Text("下载的视频也可通过「文件」App → 我的 iPhone → 视频嗅探 访问")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本") {
                Text(appState.updateChecker.currentVersion)
            }
            LabeledContent("Bundle ID") {
                Text(Bundle.main.bundleIdentifier ?? "-")
                    .font(.caption)
            }
            LabeledContent("URL Scheme") {
                Text("videosniffer://add")
                    .font(.caption)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("本应用仅供个人学习与研究使用。请勿用于下载受版权保护的内容，由此产生的责任由使用者自行承担。")
        }
    }

    // MARK: - 操作

    private func refreshSize() {
        downloadsSize = Storage.directorySize(Storage.downloadsURL)
    }

    private func clearTemporary() {
        let fm = FileManager.default

        // 1. .tmp 目录
        if let items = try? fm.contentsOfDirectory(
            at: Storage.tmpURL,
            includingPropertiesForKeys: nil
        ) {
            for item in items {
                try? fm.removeItem(at: item)
            }
        }

        // 2. 下载目录中的隐藏临时分片目录（异常退出残留）
        if let items = try? fm.contentsOfDirectory(
            at: Storage.downloadsURL,
            includingPropertiesForKeys: nil
        ) {
            for item in items where item.lastPathComponent.hasPrefix(".") {
                try? fm.removeItem(at: item)
            }
        }

        refreshSize()
        appState.showToast("临时文件已清理")
    }
}
