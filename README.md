<p align="center"><img src="Resources/Brand/AppIcon.png" width="104" alt="Untitled 裂变图标"></p>

# Untitled

**软件由你定义。**

想要一个功能，就让 agent 把它做出来。把它装进自己的软件，按习惯修改，再把插件分享给其他人，让他们继续创造。

Untitled 为这种开发方式提供一个原生 macOS 应用：稳定的宿主、可选择的插件、开放的源码，以及持续生长的功能。你可以从自己需要的一小部分开始，逐渐把软件变成适合自己的样子。

## 按自己的需要创造

- **功能自由生长**：截图、自动化或完全不同的新想法，都可以通过插件实现。
- **自己选择安装**：插件可安装、启停、升级和卸载；支持从商店或离线 ZIP 安装。
- **自己掌握源码**：修改实现、fork、二次开发，或只保留在自己的机器上。
- **自由分享**：本仓库接受各种用途的插件，开发者也能用自己的仓库与 Release 独立分发。
- **专注 macOS**：Swift 6 + SwiftUI / AppKit，运行最低 macOS 14，直接使用原生系统能力。

品牌名 Untitled 表示用途由你定义。黑白「裂变」图标保留混沌、无序和不断变化的感觉。

## 使用

```bash
git clone https://github.com/tietiezhi-1216/untitled.git
cd untitled
./scripts/run.sh
```

构建需要 macOS 26+ SDK 和 Swift 6 工具链，推荐 Xcode 26+；未安装命令行工具时先运行 `xcode-select --install`。构建结果是 `dist/debug/Untitled.app`。运行版本要求按插件区分：例如录屏、系统翻译需要 macOS 15+，本地文档结构识别需要 macOS 26+。

首页选择插件安装，或点击“从 ZIP 安装…”导入他人分享的包。打开插件后使用其界面、操作或快捷键。关闭主窗口后应用继续在菜单栏运行；退出会释放快捷键并结束相关任务。已安装的本地能力可离线使用，外部服务按插件自身要求工作。

仓库里已有几个可修改的示例，具体功能与限制放在各自说明中：

| 插件 | 用途 |
| --- | --- |
| [全局快捷键](Plugins/global-shortcuts/README.md) | 打开应用、网址、系统快捷指令与主面板 |
| [截图](Plugins/screenshot/README.md) | 截图、编辑、贴图、录屏与本地识别等工作流 |
| [外设共享](Plugins/peripheral-sharing/README.md) | 双 Mac 键鼠与按需麦克风共享；完整双机验收范围见插件说明 |

## 让 agent 开发插件

用你熟悉的 coding agent 打开仓库，让它读取 [AGENTS.md](AGENTS.md) 和 [插件开发 skill](.agents/skills/untitled-plugin-development/SKILL.md)，然后描述想要的行为。例如：

> 为 Untitled 开发一个插件，实现我需要的工作流；按项目规范提供源码、权限说明和可安装的 ZIP。

也可以自己从一个可工作的最小插件开始：

```bash
python3 scripts/new-plugin.py my-plugin \
  --id dev.alice.my-plugin --name "My Plugin" --author alice
python3 scripts/package-plugins.py --tag v1.0.0 --plugin my-plugin
```

它会生成打开主面板的示例。把需求实现进去，更新说明，再将 ZIP 安装到本机验证。已有能力可以直接组合；新增原生能力通过 provider 接入宿主并重新构建。

## 插件与分发

| 扩展方式 | 当前支持 |
| --- | --- |
| manifest v2 组合宿主能力与界面槽位 | 支持，声明式 ZIP 可独立安装和分享 |
| 新增 Swift 原生功能 | 支持，通过 PluginUIProvider 注册，随宿主编译 |
| 独立 GitHub 源码与 Release、自己的许可证 | 支持，中央目录也可收录独立发布的包 |
| 通用可执行扩展与 agent 完全接管 | 已制定实现要求，当前尚无通用运行时和开关 |

ZIP 根目录只含 `manifest.json`、`README.md`、`LICENSE`，不会执行安装脚本。宿主校验包格式、兼容性、已注册能力及目录包的 SHA-256。升级保留用户配置；卸载删除该插件本地配置。开发协议见 [Plugins/README.md](Plugins/README.md)，贡献与二次开发规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。

独立分发示例：

```bash
python3 scripts/package-plugins.py --tag v1.0.0 \
  --plugin /path/to/my-plugin --repository alice/my-plugin
```

## 权限与用户控制

宿主以非 App Sandbox 方式构建，可按需求接入 macOS 的文件、网络、输入、设备及系统自动化能力。屏幕录制、辅助功能、输入监控、摄像头和麦克风已统一接入“应用设置 → 权限管理”；其他能力按具体功能扩展。

系统权限由 macOS 和用户决定。完全磁盘访问或完全接管并不因安装软件而自动开启；完全接管的执行范围、身份、持续授权、停止与撤销机制已写入 [权限与执行规范](docs/PERMISSIONS.md)。

## 开发资料

- [AGENTS.md](AGENTS.md)：未来 agents 的项目入口。
- [插件开发 skill](.agents/skills/untitled-plugin-development/SKILL.md)：实现、验证与独立打包流程。
- [贡献规范](CONTRIBUTING.md)与[插件协议](Plugins/README.md)：共享、二次开发与兼容约定。
- [开发说明](docs/DEVELOPMENT.md)：构建、签名、Xcode、界面与验证。
- [性能规范](docs/PERFORMANCE.md)：每个插件的资源预算、内存 / CPU / GPU / I/O 排查与回归验证。
- [品牌与图标](docs/BRANDING.md)：选定原图、ICNS 生成与兼容标识。

宿主采用 [MIT License](LICENSE)。插件与第三方依赖保留各自许可。为兼容现有用户，技术标识与数据目录仍沿用 `com.tietiezhi.tools`，内部 Swift module / Xcode scheme 仍为 `TietiezhiTools`。
