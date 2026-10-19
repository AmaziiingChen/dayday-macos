# Dayday

一个把电脑上的日常工作整理成时间线、再生成日报的本地 macOS App。使用 Swift / SwiftUI 开发，数据保存在本机，AI 服务由你自己配置。

## 下载与安装

在 [Releases](https://github.com/AmaziiingChen/dayday-macos/releases) 下载 `Dayday-macOS-arm64.dmg`，打开后将 `Dayday.app` 拖入“应用程序”。也可下载 ZIP，解压后直接打开 App。

- Apple Silicon Mac，macOS 14 或更新版本。
- 当前为早期预览版，安装包采用 ad-hoc 签名，尚未经过 Apple 公证。首次打开可能需要在“系统设置 → 隐私与安全性”中允许打开。
- 使用电脑活动记录时，在 App 内按需启用采集，并授予 macOS 屏幕录制、辅助功能或输入监控权限。
- 使用 AI 时，在设置中填写模型地址、名称和自己的 API Key；模型服务费用由对应提供方收取。

## 能做什么

- 在“今日”查看前台应用、工作时段与 AI 视觉摘要，区分客观记录和模型推断。
- 结合工作记录、视觉摘要、独立工作备注和天气生成日报，支持编辑、保存版本和 Markdown 导出。
- 自定义上班、下班、日报生成时间，以及一天开始的时刻，默认从凌晨 04:00 划分工作日。
- 查看应用时长和键鼠聚合统计，使用菜单栏快速查看最近记录。
- 单独记录个人日记；日记正文和情绪不进入工作日报。
- 提供可选的 iPhone 健康数据伴侣项目，通过本地网络配对同步。

## 数据与模型

数据库位于 `~/Library/Application Support/Dayday/`。原始分辨率截图仅短暂保留在内存，允许的压缩视觉证据受保留策略和容量限制约束。键鼠统计不保存输入正文、按键顺序或可重放的鼠标轨迹。

启用视觉 AI 后，筛选后的图像和上下文会发送到你配置的模型服务；启用日报 AI 后，工作上下文会发送到对应服务。请根据自己的使用场景选择提供方。Release 版本的 API Key 存放在 macOS 钥匙串；Debug 开发版本使用本机开发偏好保存凭据。

当前仍在验证长时间运行的资源占用与不同模型的输出兼容性。视觉摘要可能受响应格式、网络和调用预算影响而落后于客观记录。健康伴侣需要完整 Xcode 和真实 iPhone 单独构建，本次 macOS 安装包不包含 iOS App。

## 从源码运行

本仓库包含已固定版本的 MarkEdit 源码，无需下载额外 Swift 包。

```sh
git clone https://github.com/AmaziiingChen/dayday-macos.git
cd dayday-macos
./scripts/run-local.sh
```

推荐使用完整 Xcode 和 XcodeGen：

```sh
brew install xcodegen
```

仅安装 Command Line Tools 时，启动脚本也支持使用本机 macOS 26 SDK 和 SwiftPM 编译；如果当前默认 SDK 不兼容，可用 `DAYDAY_SWIFT_SDK_PATH` 指定已有的兼容 SDK。完整 Xcode 路径使用新的 Liquid Glass 图标，Command Line Tools 路径使用仓库中的 PNG 图标。

无需创建 `.env` 即可启动，在 App 设置中配置模型即可。可选的本机开发变量见 [.env.example](.env.example)，真实密钥不要提交到 Git。

## 构建安装包

```sh
./scripts/package-app.sh
```

生成 `.build/distribution/Dayday-macOS-arm64.dmg`、ZIP 和 SHA-256 校验文件。该命令编译 Release App、移除调试符号并执行 ad-hoc 签名，不需要付费开发者账号；Apple 公证不包含在此流程中。

## 测试

```sh
./scripts/test
```

模块分为 `DaydayCore`、`DaydayStorage`、`DaydayCapture`、`DaydayUnderstanding`、`DaydayAI`、`DaydayIntegrations` 和 `DaydayApp`。核心领域逻辑、SQLite、采集、模型接口和界面投影均有对应测试；iPhone 伴侣位于 `HealthCompanion/`。

## 许可证

[MIT License](LICENSE)。第三方源码及研究来源见 [NOTICE](NOTICE) 与 [docs/external-sources](docs/external-sources/)。MarkEdit 保留其原始 MIT 许可证。
