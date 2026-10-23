import SwiftUI
import Photos

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct FileListView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var files: [FileInfo] = []
    @State private var playing: IdentifiableURL?
    @State private var alertMessage: String?
    @State private var showPhotoAlert = false

    struct FileInfo: Identifiable {
        let url: URL
        let name: String
        let size: Int64
        let created: Date
        var id: String { url.path }
    }

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    emptyState
                } else {
                    fileList
                }
            }
            .navigationTitle("文件")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { reload() }
            .refreshable { reload() }
            .sheet(item: $playing) { item in
                PlayerView(url: item.url)
            }
            .alert("提示", isPresented: $showPhotoAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private var fileList: some View {
        List {
            Section {
                ForEach(files) { file in
                    FileRow(file: file)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playing = IdentifiableURL(url: file.url)
                        }
                        .contextMenu {
                            Button {
                                playing = IdentifiableURL(url: file.url)
                            } label: {
                                Label("播放", systemImage: "play")
                            }

                            ShareLink(item: file.url) {
                                Label("分享 / 存到文件", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                Task { await saveToPhotos(file) }
                            } label: {
                                Label("存到相册", systemImage: "photo.on.rectangle")
                            }

                            Button(role: .destructive) {
                                delete(file)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } footer: {
                Text("文件同时可通过「文件」App → 我的 iPhone → 视频嗅探 访问")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("还没有下载的视频")
                .font(.headline)
            Text("下载完成后会出现在这里")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 操作

    private func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: Storage.downloadsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            return
        }

        files = urls
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory != true
            }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return FileInfo(
                    url: url,
                    name: url.lastPathComponent,
                    size: Int64(values?.fileSize ?? 0),
                    created: values?.creationDate ?? .distantPast
                )
            }
            .sorted { $0.created > $1.created }
    }

    private func delete(_ file: FileInfo) {
        try? FileManager.default.removeItem(at: file.url)
        manager.forgetFile(named: file.name)
        reload()
    }

    @MainActor
    private func saveToPhotos(_ file: FileInfo) async {
        let status = await Self.requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            alertMessage = "没有相册权限，请到 系统设置 → 隐私 → 照片 中允许"
            showPhotoAlert = true
            return
        }

        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file.url)
            }) { success, _ in
                continuation.resume(returning: success)
            }
        }

        if success {
            alertMessage = "已保存到相册"
        } else {
            alertMessage = "保存失败（视频编码可能不被相册支持）"
        }
        showPhotoAlert = true
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

// MARK: - 文件行

private struct FileRow: View {
    let file: FileListView.FileInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(Storage.formatBytes(file.size))
                    Text(file.created, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        let lower = file.name.lowercased()
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") { return "film" }
        if lower.hasSuffix(".ts") { return "film.stack" }
        if lower.hasSuffix(".m3u8") { return "list.bullet.rectangle" }
        return "doc"
    }
}
