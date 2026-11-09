# Tietiezhi Tools

一个简洁的原生 macOS 插件工具箱。**Swift 6 + SwiftUI，macOS 14+，无第三方依赖，MIT 开源。**

首页是插件商店；功能通过 ZIP 插件包安装。所有插件源码、商店目录和下载包统一放在[同一个 GitHub 仓库](https://github.com/tietiezhi-1216/tietiezhi-tools)中。

## 使用

```bash
git clone https://github.com/tietiezhi-1216/tietiezhi-tools.git
cd tietiezhi-tools
./scripts/run.sh
```

需要支持 Swift 6 的 Xcode Command Line Tools 或 Xcode 16+。未安装命令行工具时，先运行 `xcode-select --install`。

1. 在首页“插件商店”中安装 **全局快捷键**。
2. 在侧边栏打开插件，点击“添加操作”。
3. 选择应用、填写网址或 macOS 快捷指令名称，也可以选择“显示主面板”。
4. 点击录制按钮，按下自己喜欢的组合键，再保存。

快捷键至少包含 `⌘`、`⌥` 或 `⌃`；不绑定时也可手动执行。重复绑定会被拒绝，系统注册失败会在操作旁显示原因。应用不会自动占用某个默认组合键。

关闭主窗口后，应用继续在菜单栏运行，快捷键仍有效；可以从菜单栏重新打开面板。退出应用会释放全部快捷键。本版不自动设置登录启动。

商店支持搜索、安装、升级、启停、卸载，也可以点击“从 ZIP 安装…”导入离线包。升级保留用户配置；卸载会删除该插件本地配置。网络不可用时，已安装的插件仍然可用。

## 首个插件

**全局快捷键 v1.0.0** 提供四种操作：

| 操作 | 行为 |
| --- | --- |
| 打开应用 | 选择本机 `.app`，启动或切到前台 |
| 打开网址 | 通过默认浏览器打开 HTTP / HTTPS 网址 |
| 运行快捷指令 | 调用 macOS「快捷指令」中的同名指令 |
| 显示主面板 | 唤起工具箱；窗口关闭后可重新打开 |

更复杂的自动化可以放在系统“快捷指令”中，再从本插件绑定快捷键调用。运行结果由快捷指令自身展示，应用只负责发起调用。

## 插件架构

主程序保留插件商店、安装与存储、通用配置界面、全局热键注册和动作执行能力。插件通过统一清单贡献操作模板，宿主不根据插件 ID 写特殊业务页面。

**API v1 是声明式插件格式**，目前提供上述四类动作，不加载任意 Swift 二进制、JavaScript 或 Shell 脚本。新增现有能力范围内的插件无需重新编译主程序；引入全新的原生能力需要扩展宿主 API。

商店从 `Plugins/catalog.json` 获取列表，下载 GitHub Release 中的 ZIP 后验证 SHA-256。安装器只读取 ZIP 中的清单，不将压缩包解压到磁盘，也不执行安装脚本。插件包上限 2 MB，清单上限 256 KB。

规范与发布方法见 [Plugins/README.md](Plugins/README.md)。本地插件配置保存在：

```text
~/Library/Application Support/com.tietiezhi.tools/Plugins/
```

该目录不在源码仓库中，用户选择的应用路径和快捷键不会随代码发布。

## 开发与验证

### 原生界面与 Liquid Glass

主窗口采用 `hiddenTitleBar` 与全尺寸内容，不显示独立的标题条或工具栏，保留原生红黄绿按钮。左侧顶部预留 64 pt 窗口按钮区域，按钮距左侧 20 pt、顶部 26 pt，导航从其下方开始；原生按钮宿主仅覆盖左侧，避免挡住正文控件。顶部空白区和页面头部可拖动窗口。

侧边栏固定为 224 pt，始终显示且不可拖动调整；主窗口仍支持正常调整尺寸。右侧内容统一使用 28 pt 水平边距。安装、搜索、添加操作等控件在各页面上方保持可见。

窗口采用低透色的中性材质：深色模式以石墨黑为底，浅色模式使用对应的浅灰色，侧栏与正文只有轻微明暗差。原生 `underWindowBackground` 背景保留少量桌面层次，避免壁纸颜色大幅染色。玻璃效果集中在搜索与操作控件；Xcode 26+（或包含 macOS 26+ SDK 的命令行工具）构建时使用官方 `glassEffect`、`.glass` / `.glassProminent`，配合收敛的圆角、选中态细边缘和蓝色重点操作。开启系统“减少透明度”或增加对比度时提高背景遮罩的不透明度。macOS 14–15 或旧 SDK 构建保留兼容样式。

设计依据：[Apple Liquid Glass 采用指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[材质规范](https://developer.apple.com/design/human-interface-guidelines/materials)。

### 构建

```bash
swift build
swift test
./scripts/build-app.sh release
python3 scripts/package-plugins.py --tag v0.2.0 --write-catalog
```

构建结果位于 `dist/debug/Tietiezhi Tools.app` 或 `dist/release/Tietiezhi Tools.app`。终端脚本使用当前 Mac 的架构和本地临时签名，适合开发；未启用 App Sandbox / Hardened Runtime，也没有 Developer ID 签名或公证。

Xcode 开发入口：

```bash
open TietiezhiTools.xcodeproj
```

选择 `TietiezhiTools` scheme 和 `My Mac` 后按 `⌘R`。Xcode Target 保留 App Sandbox / Hardened Runtime，并声明网络下载、用户选择文件读取和应用级书签权限。正式分发需配置自己的签名、图标和公证。

Swift Package 与 Xcode 工程共用 `Sources/TietiezhiTools`。新增宿主源码时，请同时将文件添加到 Xcode target；测试通过 Swift Package 执行。GitHub Actions 验证测试、插件打包和 Xcode 构建。

发布完成后，可额外执行真实 GitHub 下载与安装检查：

```bash
TIETIEZHI_NETWORK_TEST=1 swift test --filter downloadFromPublishedGitHubCatalog
```

## 目录

```text
Sources/TietiezhiTools/
├── App/         # 窗口、菜单栏和统一外观
├── Models/      # 应用外观设置
├── Plugins/     # 插件规范、目录、ZIP 安装和配置存储
├── Runtime/     # 通用动作执行与 Carbon 全局热键
└── Views/       # 原生商店、插件配置、录制器与设置
Plugins/         # 所有插件源码及统一商店目录
Tests/           # 安装、校验、热键事件与窗口布局回归检查
Resources/       # Info.plist 与沙盒权限
scripts/         # 本地构建与插件打包
```
