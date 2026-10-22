import SwiftUI

struct VideoListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showManualInput = false
    @State private var manualURL = ""
    @State private var manualReferer = ""

    var body: some View {
        NavigationStack {
            Group {
                if appState.pendingVideos.isEmpty {
                    emptyState
                } else {
                    pendingList
                }
            }
            .navigationTitle("待下载")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !appState.pendingVideos.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            appState.pasteFromClipboard()
                        } label: {
                            Label("从剪贴板添加", systemImage: "doc.on.clipboard")
                        }
                        Button {
                            showManualInput = true
                        } label: {
                            Label("手动输入链接", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showManualInput) {
                manualInputSheet
            }
        }
    }

    // MARK: - 列表

    private var pendingList: some View {
        List {
            Section {
                ForEach(appState.pendingVideos) { video in
                    VideoRow(video: video) {
                        appState.enqueue(video)
                    }
                }
                .onDelete { offsets in
                    appState.removePending(at: offsets)
                }
            } footer: {
                Text("下拉可编辑删除；点击右侧按钮开始下载")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "safari")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("暂无待下载视频")
                .font(.headline)
            Text("在 Safari 中复制视频链接后点下方按钮导入；\nSafari 扩展仅正常签名安装时可用")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button {
                appState.pasteFromClipboard()
            } label: {
                Label("从剪贴板添加链接", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - 手动输入

    private var manualInputSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/video.m3u8", text: $manualURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("视频直链")
                } footer: {
                    Text("支持 m3u8 / mp4 等 HTTP(S) 链接")
                }

                Section {
                    TextField("https://example.com/page", text: $manualReferer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Referer（可选）")
                } footer: {
                    Text("报 HTTP 403/439 时填写视频所在网页地址")
                }
            }
            .navigationTitle("手动添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        manualURL = ""
                        manualReferer = ""
                        showManualInput = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let trimmed = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let referer = manualReferer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let url = URL(string: trimmed),
                           url.scheme?.hasPrefix("http") == true {
                            appState.addPending(
                                VideoInfo(
                                    url: trimmed,
                                    referer: referer.isEmpty ? nil : referer,
                                    source: .manual
                                )
                            )
                            manualURL = ""
                            manualReferer = ""
                            showManualInput = false
                        } else {
                            appState.showToast("链接格式不正确")
                        }
                    }
                    .disabled(manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - 行

private struct VideoRow: View {
    let video: VideoInfo
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(video.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(video.kind.label)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(badgeColor)

                    Text(video.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }

    private var badgeColor: Color {
        switch video.kind {
        case .hls: return .orange
        case .mp4: return .green
        case .flv: return .blue
        case .webm: return .purple
        case .other: return .gray
        }
    }
}
