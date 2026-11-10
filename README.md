# Tietiezhi Tools

一个简洁的原生 macOS 插件工具箱。**Swift 6 + SwiftUI，macOS 14+，无第三方依赖，MIT 开源。**

首页是插件商店；功能通过 ZIP 插件包安装。所有插件源码、商店目录和下载包统一放在[同一个 GitHub 仓库](https://github.com/tietiezhi-1216/tietiezhi-tools)中。

## 使用

0.5.0 将系统授权集中到「应用设置 → 权限管理」：屏幕录制、辅助功能、输入监控、摄像头和麦克风统一查询、请求和管理，并显示插件用途。插件缺少权限时通过宿主接口打开该页面，用户确认授权后再执行功能；进入插件、安装插件或开启业务选项不会请求权限。更改和撤销系统权限通过对应的 macOS 隐私设置完成。

0.3.0 新增[截图插件](Plugins/screenshot/README.md)：全局截图快捷键、区域/窗口/全屏、多显示器、置顶贴图、箭头/文字/马赛克/实色遮挡等标注、横纵滚动长图、录屏与 GIF、本地 OCR/条码、系统翻译、CSV/XLSX 表格、LaTeX 公式、Word/Markdown/可搜索 PDF 文档导出。复杂图像识别可选接入自己的视觉模型，密钥保存在钥匙串，发送图片前须确认。录屏和系统翻译需要 macOS 15+，macOS 26+ 另支持本地文档结构识别。

在商店安装「截图」，进入插件的「快捷键」页绑定操作。首次截图/录屏需要屏幕录制权限；导入图片、标注、OCR 和贴图可先使用。窗口关闭后，仍可用全局快捷键或菜单栏调用；退出前会结束并保存正在进行的录屏。详细功能、权限及边界见插件说明。

```bash
git clone https://github.com/tietiezhi-1216/tietiezhi-tools.git
cd tietiezhi-tools
./scripts/run.sh
```

源码构建需要 Xcode 26+，或包含 macOS 26+ SDK 的 Swift 6 命令行工具；运行截图等基础功能仍支持 macOS 14+。未安装命令行工具时，先运行 `xcode-select --install`。

1. 在首页“插件商店”中安装 **全局快捷键**。
2. 在侧边栏打开插件，点击“添加操作”。
3. 选择应用、填写网址或 macOS 快捷指令名称，也可以选择“显示主面板”。
4. 点击录制按钮，按下自己喜欢的组合键，再保存。

操作名称自动由“动作 + 目标”生成，例如“打开 Safari”“打开 example.com”“运行快捷指令：下班”，无需手动命名；更换目标时会自动更新。已有配置中的旧名称会被忽略，快捷键、操作 ID 和其他配置保持不变。

快捷键至少包含 `⌘`、`⌥` 或 `⌃`；不绑定时也可手动执行。重复绑定会被拒绝，系统注册失败会在操作旁显示原因。应用不会自动占用某个默认组合键。

关闭主窗口后，应用继续在菜单栏运行，快捷键仍有效；可以从菜单栏重新打开面板。退出应用会释放全部快捷键。本版不自动设置登录启动。

商店支持搜索、安装、升级、启停、卸载，也可以点击“从 ZIP 安装…”导入离线包。升级保留用户配置；卸载会删除该插件本地配置。网络不可用时，已安装的插件仍然可用。

## 首个插件

**全局快捷键 v1.2.0** 提供四种操作：

| 操作 | 行为 |
| --- | --- |
| 打开应用 | 选择本机 `.app`，启动或切到前台 |
| 打开网址 | 通过默认浏览器打开 HTTP / HTTPS 网址 |
| 运行快捷指令 | 调用 macOS「快捷指令」中的同名指令 |
| 显示主面板 | 唤起工具箱；窗口关闭后可重新打开 |

更复杂的自动化可以放在系统“快捷指令”中，再从本插件绑定快捷键调用。运行结果由快捷指令自身展示，应用只负责发起调用。

## 插件架构

0.4.0 引入 **插件开发协议 v2**：顶部左右、操作区左右、主内容、底部左右、系统菜单栏均为通用槽位。插件通过自己的清单选择组件、按钮、菜单、分段页及设置面板的布局，宿主不再根据插件类型选择业务页面。应用设置单独放在侧边栏底部；插件齿轮由插件自行声明。

原生能力通过 `PluginUIProvider` 注册，统一渲染器负责槽位、能力校验、动态命令状态以及 sheet / popover / inline 面板路由。ZIP 可以组合已注册的能力，新增全新的原生组件需要随宿主编译；本版不动态加载 Swift 二进制、JavaScript 或 Shell。旧 v1 插件继续通过兼容适配器使用。
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
python3 scripts/package-plugins.py --tag v0.5.0 --write-catalog
```

构建结果位于 `dist/debug/Tietiezhi Tools.app` 或 `dist/release/Tietiezhi Tools.app`。终端脚本使用当前 Mac 的架构和本地临时签名，适合开发；未启用 App Sandbox / Hardened Runtime，也没有 Developer ID 签名或公证。

Xcode 开发入口：

```bash
open TietiezhiTools.xcodeproj
```

选择 `TietiezhiTools` scheme 和 `My Mac` 后按 `⌘R`。Xcode Target 保留 App Sandbox / Hardened Runtime，并声明网络访问、用户选择文件读写、应用级书签以及可选摄像头/麦克风权限；实际使用时仍需系统授权。正式分发需配置自己的签名、图标和公证。

Swift Package 与 Xcode 工程共用 `Sources/TietiezhiTools`。新增宿主源码时，请同时将文件添加到 Xcode target；测试通过 Swift Package 执行。GitHub Actions 验证测试、插件打包和 Xcode 构建。

发布完成后，可额外执行真实 GitHub 下载与安装检查：

```bash
TIETIEZHI_NETWORK_TEST=1 swift test --filter downloadFromPublishedGitHubCatalog
```

## 目录

```text
Sources/TietiezhiTools/
├── App/         # 窗口、菜单栏和统一外观
├── Capture/     # 截图、编辑、贴图、滚动拼接、录制、OCR 与文档导出
├── Models/      # 应用外观设置
├── Plugins/     # 插件规范、目录、ZIP 安装和配置存储
├── Runtime/     # 通用动作执行与 Carbon 全局热键
└── Views/       # 原生商店、插件配置、录制器与设置
Plugins/         # 所有插件源码及统一商店目录
Tests/           # 安装、校验、热键、布局、图像处理、拼接、识别和媒体导出检查
Resources/       # Info.plist 与沙盒权限
scripts/         # 本地构建与插件打包
```
