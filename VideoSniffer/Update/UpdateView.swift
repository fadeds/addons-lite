import SwiftUI
import UIKit

struct UpdateSection: View {
    @ObservedObject var checker: UpdateChecker

    @AppStorage(UpdateChecker.repoKey) private var repoOverride = ""
    @AppStorage(UpdateChecker.prereleaseKey) private var includePrerelease = false
    @AppStorage("update_use_trollstore") private var useTrollStore = true

    @State private var pendingInfo: UpdateInfo?
    @State private var showUpgradeError = false
    @State private var upgradeErrorMessage = ""
    @State private var fallbackInfo: UpdateInfo?
    @State private var altStoreFallback: URL?

    var body: some View {
        Section {
            LabeledContent("当前版本", value: checker.currentVersion)

            Toggle("包含 Beta 版本", isOn: $includePrerelease)

            Toggle("通过 TrollStore 安装更新", isOn: $useTrollStore)

            if !checker.isRepoConfigured || !repoOverride.isEmpty {
                TextField("更新仓库 (owner/repo)", text: $repoOverride)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.footnote)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        Task { await checker.checkNow() }
                    } label: {
                        if checker.phase == .checking {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("检查中…")
                            }
                        } else {
                            Text("检查更新")
                        }
                    }
                    .disabled(checker.phase == .checking)

                    Spacer()

                    statusLabel
                }

                if case .failed(let message) = checker.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if case .available(let info) = checker.phase {
                    Text("新版本 \(info.version) 已就绪")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let date = checker.lastCheckDate {
                    Text("上次检查：\(date, style: .relative) 前")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("应用升级")
        } footer: {
            Text(footerText)
        }
        .onChange(of: checker.phase) { phase in
            if case .available(let info) = phase {
                pendingInfo = info
            }
        }
        .alert(item: $pendingInfo) { info in
            Alert(
                title: Text("发现新版本 \(info.version)"),
                message: Text(notesText(info)),
                primaryButton: .default(Text("立即升级")) {
                    Task { await performUpgrade(info) }
                },
                secondaryButton: .cancel(Text("稍后")) {
                    checker.dismiss(info)
                }
            )
        }
        .alert("升级失败", isPresented: $showUpgradeError) {
            if let url = fallbackInfo?.htmlURL {
                Button("打开发布页") {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
            if let altStoreURL = altStoreFallback {
                Button("用 AltStore 安装") {
                    UIApplication.shared.open(altStoreURL, options: [:], completionHandler: nil)
                }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(upgradeErrorMessage)
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private var statusLabel: some View {
        switch checker.phase {
        case .idle:
            Text("未检查")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            EmptyView()
        case .upToDate(let current):
            Label("已是最新 (\(current))", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .available:
            Label("有新版本", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var footerText: String {
        if checker.isRepoConfigured {
            return "更新源：GitHub \(checker.configuredRepo)（Release 需包含 ipa 与 manifest.plist 资产）"
        }
        return "填写 GitHub 仓库（owner/repo）以启用应用内升级"
    }

    private func notesText(_ info: UpdateInfo) -> String {
        let trimmed = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "（发布者未填写更新说明）" }
        if trimmed.count > 800 {
            return String(trimmed.prefix(800)) + "…"
        }
        return trimmed
    }

    // MARK: - 升级

    @MainActor
    private func performUpgrade(_ info: UpdateInfo) async {
        if useTrollStore {
            altStoreFallback = nil
            if let ipa = info.ipaAssetURL,
               let trollURL = ManifestInstaller.trollStoreInstallURL(ipaURL: ipa) {
                let opened = await UIApplication.shared.open(trollURL, options: [:])
                if opened { return }
            }
            fallbackInfo = info
            upgradeErrorMessage = "未能拉起 TrollStore。请在 TrollStore 设置中开启 URL Scheme，或到发布页下载 ipa 后用 TrollStore 打开。"
            showUpgradeError = true
            return
        }

        guard let manifestURL = info.manifestAssetURL else {
            if let url = info.htmlURL {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return
        }

        do {
            try await ManifestInstaller.startUpgrade(manifestURL: manifestURL)
        } catch {
            fallbackInfo = info
            if let ipa = info.ipaAssetURL {
                altStoreFallback = ManifestInstaller.altStoreInstallURL(ipaURL: ipa)
            } else {
                altStoreFallback = nil
            }
            upgradeErrorMessage = error.localizedDescription
            showUpgradeError = true
        }
    }
}
