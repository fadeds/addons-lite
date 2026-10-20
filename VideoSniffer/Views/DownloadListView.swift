import SwiftUI

struct DownloadListView: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        NavigationStack {
            Group {
                if manager.tasks.isEmpty {
                    emptyState
                } else {
                    taskList
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清理完成") {
                        manager.clearFinished()
                    }
                    .disabled(!manager.tasks.contains { !$0.isActive })
                }
            }
        }
    }

    private var taskList: some View {
        List {
            ForEach(manager.tasks) { task in
                TaskRow(task: task)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("没有下载任务")
                .font(.headline)
            Text("在「待下载」中选择视频开始")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 任务行

private struct TaskRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let task: DownloadTaskRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.video.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(task.stateLabel)
                    .font(.caption)
                    .foregroundStyle(stateColor)
            }

            if task.isActive {
                ProgressView(value: task.progress)
                HStack {
                    Text(String(format: "%.0f%%", task.progress * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let total = task.totalBytes {
                        Text(byteText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if task.state == .completed {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let name = task.fileName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else if let error = task.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if !task.isActive {
                HStack(spacing: 16) {
                    if task.state == .failed || task.state == .cancelled {
                        Button {
                            manager.retry(id: task.id)
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        manager.remove(id: task.id, deleteFile: false)
                    } label: {
                        Label("移除", systemImage: "trash")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            if task.isActive {
                Button(role: .destructive) {
                    manager.cancel(id: task.id)
                } label: {
                    Label("取消", systemImage: "xmark")
                }
            } else {
                Button(role: .destructive) {
                    manager.remove(id: task.id, deleteFile: task.state == .completed)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            if task.state == .failed || task.state == .cancelled {
                Button {
                    manager.retry(id: task.id)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
    }

    private var byteText: String {
        let received = Storage.formatBytes(task.receivedBytes ?? 0)
        let total = Storage.formatBytes(task.totalBytes ?? 0)
        return "\(received) / \(total)"
    }

    private var stateColor: Color {
        switch task.state {
        case .queued: return .secondary
        case .downloading, .remuxing: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}
