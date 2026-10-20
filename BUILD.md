# VideoSniffer — 打包与部署指南

原生 iOS App（SwiftUI）+ Safari Web Extension，通过 **GitHub Actions** 云端构建 ipa。
支持 **TrollStore 免签名安装**（无需开发者账号），也支持传统的**证书签名 + OTA 升级**。

---

## 一、两种分发方式

| 方式 | 需要开发者账号 | 安装 | App 内升级 |
|---|---|---|---|
| **TrollStore（推荐）** | 不需要 | 无签名 ipa，用 TrollStore 打开 | `apple-magnifier://` 一键拉起 TrollStore |
| 签名 OTA（Ad Hoc / 企业） | 需要 | 证书 + 描述文件 | `itms-services://` 系统覆盖安装 |

```
GitHub Actions（自动判断有没有证书）
   ├─ 无证书 → 无签名 ipa → TrollStore 安装 → App 内一键更新
   └─ 有证书 → 签名 ipa + manifest.plist → AltStore / OTA 安装 → 系统覆盖升级
```

> TrollStore 支持范围：iOS 14.0b2 – 16.6.1、16.7 RC、17.0（本项目最低 iOS 16，可用）。

## 二、TrollStore 免签名方案（无需账号）

1. **不需要**注册 Bundle ID、不需要证书/描述文件，也不需要配置任何 Secrets。
2. Actions → **Build iOS IPA** → Run workflow：
   - `signing` 选 `unsigned`（明确无签名）
   - 或保持 `auto`：没有 Secrets 时自动走无签名构建
3. 构建完成后从 artifact 下载 `VideoSniffer-v1.0.0.ipa`；打 `v*` tag 会自动发布到 Release。
4. 手机安装（任选）：
   - 下载 ipa → 分享/用 **TrollStore** 打开
   - 浏览器访问 `apple-magnifier://install?url=<ipa 直链>`（需在 TrollStore 设置中开启 **URL Scheme**）
5. 扩展随 App 一起安装，之后到 设置 → Safari → 扩展 中启用「视频嗅探」。
6. App 内升级：设置 → 应用升级 →「通过 TrollStore 安装更新」默认开启，点「立即升级」会直接拉起 TrollStore 安装新版本。

> 无签名 ipa 不能用 AltStore / 爱思 / itms-services 安装（这些要求有效签名），只能交给 TrollStore 或自签工具。

## 三、Apple Developer 配置（签名方案，TrollStore 用户可跳过）

### 1. 注册两个 Bundle ID

| 用途 | Bundle ID（默认值） |
|---|---|
| 主 App | `com.videosniffer.app` |
| Safari 扩展 | `com.videosniffer.app.extension` |

> **要改名**：同时修改 `project.yml` 里的两处 `PRODUCT_BUNDLE_IDENTIFIER`，扩展必须是主 App 的 `.extension` 后缀形式（或任意独立 ID，但两个都要注册）。

路径：[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) → Identifiers → `+`

### 2. 创建证书（二选一）

| 签名方式 | 证书类型 | 对应 export method |
|---|---|---|
| **Ad Hoc（推荐，可装多台设备）** | Apple Distribution | `ad-hoc` |
| 开发调试 | Apple Development | `development` |

创建步骤（有 Mac 时）：
1. Keychain Access → 证书助理 → 从证书颁发机构请求证书 → 生成 `.certSigningRequest`
2. 后台 → Certificates → `+` → 选类型 → 上传 CSR → 下载 `.cer`
3. 双击 `.cer` 导入钥匙串 → 右键导出为 `.p12`（记下密码）

**没有 Mac**：可用 Windows 工具（Appuploader、SignTools 等）生成 CSR 与导出 p12，流程等价。

### 3. 创建两个描述文件（Ad Hoc）

后台 → Profiles → `+` → Ad Hoc → 选择 App ID → 选择上一步的证书 → **勾选所有测试设备的 UDID** → 下载 `.mobileprovision`（主 App、扩展各一份）。

> 设备 UDID 获取：蒲公英 / 爱思助手 / Xcode 连接设备均可查看。**设备不在 profile 里将无法安装**，新增设备后要重新生成 profile 并重新打包。

## 四、配置 GitHub Secrets（签名方案，TrollStore 用户可跳过）

仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Secret | 内容 | 编码方法（Windows PowerShell） |
|---|---|---|
| `P12_BASE64` | 证书 `.p12` | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.p12"))` |
| `P12_PASSWORD` | p12 密码 | 明文 |
| `PROVISION_BASE64` | 主 App `.mobileprovision` | 同上 ReadAllBytes |
| `EXT_PROVISION_BASE64` | 扩展 `.mobileprovision` | 同上 |
| `KEYCHAIN_PASSWORD` | 任意随机字符串 | 如 `gh-build-2024`（仅 CI 用） |

> macOS 编码：`base64 -i cert.p12 | pbcopy`
> ⚠️ 证书与 profile 严禁提交进仓库。
> 5 个 Secret 缺任意一个，`signing=auto` 时自动降级为无签名构建。

## 五、触发构建

### 方式 A：手动构建（首次验证）

Actions → **Build iOS IPA** → Run workflow：

| 参数 | 说明 |
|---|---|
| `version` | 可留空（用 `project.yml` 的 1.0.0） |
| `signing` | `auto` / `unsigned`（TrollStore）/ `signed`（强制签名，缺 Secrets 会报错） |
| `export_method` | 仅签名构建生效：`ad-hoc` / `development` |

### 方式 B：打 tag 自动发布

```bash
git tag v1.0.0
git push origin v1.0.0
```

构建成功后自动创建 GitHub Release：

- `VideoSniffer-v1.0.0.ipa`（一定有）
- `manifest.plist`（仅签名构建，OTA 升级用）

## 六、安装 ipa

- **TrollStore（推荐，免账号）**：下载 ipa 后用 TrollStore 打开，或 `apple-magnifier://install?url=<ipa直链>`
- **AltStore**：电脑端侧载（要求已签名，免费证书 7 天有效需每周刷新）
- **Esign / 自签工具**：用自己的证书签名安装
- **爱思助手 / Sideloadly**：直接安装（要求已签名）
- **OTA（Ad Hoc/企业证书）**：Safari 打开 Release 中 `manifest.plist` 链接 → 系统弹「安装」

## 七、应用内升级原理

1. App 检查 `https://api.github.com/repos/<owner>/<repo>/releases/latest`
2. 对比 `CFBundleShortVersionString` 与 tag 版本
3. 按设置里「通过 TrollStore 安装更新」的开关选择升级通道：
   - **开（默认）**：从 Release 资产中找 `.ipa`，拉起 `apple-magnifier://install?url=<ipa>`，由 TrollStore 覆盖安装
   - **关**：下载并校验 `manifest.plist`（Bundle ID 必须一致）→ `itms-services://` 系统覆盖安装
4. 失败弹窗提供「打开发布页」「用 AltStore 安装」兜底

要求：
- 更新仓库默认读 `VideoSniffer/Info.plist` 的 `VSUpdateRepo`（当前为 `fadeds/addons-lite`），也**可在 App 设置页直接填写 `owner/repo`**
- TrollStore 升级：需在 TrollStore 设置中开启 **URL Scheme**；Release 中要有 `.ipa` 资产
- OTA 升级：Release 中必须同时有 `.ipa` 与 `manifest.plist`（仅签名构建生成），证书类型须支持 OTA（Ad Hoc / Enterprise）

## 八、本地开发（可选，需 Mac）

```bash
brew install xcodegen
xcodegen generate
open VideoSniffer.xcodeproj
```

选择开发者团队自动签名即可运行。扩展调试：Safari → 设置 → Safari → 扩展 → 启用「视频嗅探」。

## 九、故障排查

| 现象 | 原因与处理 |
|---|---|
| `errSecInternalComponent` / 签名失败 | p12 密码错误，或证书类型与 `export_method` 不匹配 |
| `No profiles for 'com.xxx'` | profile 与 Bundle ID 不一致 / 未安装对应 profile |
| `signing=signed 但缺少…secrets` | 选了强制签名但没配 Secrets；TrollStore 用户请选 `unsigned` |
| 无签名 ipa 装不上 | AltStore/爱思要求签名；无签名包只能用 TrollStore 或自签工具 |
| 点升级没反应 / 打开放大镜 | TrollStore 设置里未开启 URL Scheme，或版本低于 1.3 |
| 安装时「无法安装应用」 | 设备 UDID 不在 Ad Hoc profile 内 → 重新生成 profile 重打包 |
| `manifest.plist` 404 | 无签名构建不生成 manifest；只有签名构建的 tag 版本才有 |
| 扩展检测不到视频 | Safari → 网站设置 → 扩展权限允许；确认目标站点是普通 `<video>` 播放（blob 流暂不支持） |
| m3u8 报「解析失败」 | 直播流（无 ENDLIST 的滚动列表）只下载当前分片；SAMPLE-AES 暂不支持 |

## 十、功能限制（v1.0）

- `blob:` 地址视频、加密 SAMPLE-AES、DASH（`.mpd`）不支持
- 直播流仅下载当前列出的分片
- HLS 下载在 App 退后台后受系统限时保护（mp4 直链走后台会话可继续）
- 后缀识别：`.m3u8 .mp4 .m4v .mov .flv .webm`

## 十一、目录速查

```
project.yml                              XcodeGen 工程定义（双 target）
.github/workflows/build-ios.yml          云构建流水线（自动签名/无签名）
VideoSniffer/                            主 App 源码
  Download/                              M3U8 解析 / AES / 转封装 / 任务管理
  Update/                                检查更新 / TrollStore 与 itms-services 升级
  Views/                                 四个 Tab 页面
VideoSnifferExtension/
  Extension/                             manifest.json / background / content / popup
```
