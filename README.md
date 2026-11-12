<p align="center">
  <img src="Resources/Brand/ReadmeIcon.svg" width="112" height="112" alt="Untitled 黑白裂变图标">
</p>

<h1 align="center">Untitled</h1>

<p align="center">
  <strong>软件由你定义。</strong><br>
  让 agent 实现想要的功能，以插件安装、定制和分享。
</p>

<p align="center">
  <a href="#开始使用"><img src="https://img.shields.io/badge/macOS-14%2B-24292f?labelColor=57606a" alt="macOS 14 及以上"></a>
  <a href="docs/DEVELOPMENT.md"><img src="https://img.shields.io/badge/Swift-6-24292f?labelColor=57606a" alt="Swift 6"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-24292f?labelColor=57606a" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://github.com/tietiezhi-1216/untitled/releases">下载预览版</a> ·
  <a href="AGENTS.md">Agent 开发入口</a> ·
  <a href="Plugins/README.md">插件文档</a> ·
  <a href="CONTRIBUTING.md">参与贡献</a>
</p>

---

Untitled 是由用户通过 agents 持续定制的原生 macOS 软件。宿主负责插件安装、界面组合、配置、权限和生命周期；你决定它做什么，以及如何适合自己的习惯。

| 从想法到自己的软件 | 怎么做 |
| --- | --- |
| **创造** | 描述需求，让 agent 实现功能；从一个小工作流开始，持续修改 |
| **选择** | 按需安装、启停、升级或卸载插件，支持在线商店和离线 ZIP |
| **分享** | 开放源码、fork 和二次开发；可提交到本仓库，也可在自己的仓库独立分发 |

## 开始使用

### 下载安装

下载 [Untitled 的 macOS 安装包](https://github.com/tietiezhi-1216/untitled/releases)，在 Release 中选择对应架构的 ZIP，解压后将 `Untitled.app` 拖入“应用程序”目录。

| 发行信息 | 说明 |
| --- | --- |
| 版本 | [Releases](https://github.com/tietiezhi-1216/untitled/releases) 中提供版本、更新内容与已知限制 |
| 平台 | 仅支持 macOS，最低 macOS 14；安装包名称和 BUILD-INFO 标明架构 |
| 签名 | 每个 Release 明确列出 Developer ID / 临时签名与 Apple 公证状态；预览版不保证通过 Gatekeeper |
| 校验与验收 | 每个 Release 附 SHA256SUMS.txt 和 BUILD-INFO.json；[构建与测试](https://github.com/tietiezhi-1216/untitled/actions/workflows/ci.yml)及真机范围可查 |

录屏和系统翻译需要 macOS 15+，本地文档结构识别需要 macOS 26+。系统权限在实际使用相关功能时由用户授权。

### 从源码运行

```bash
git clone https://github.com/tietiezhi-1216/untitled.git
cd untitled
./scripts/run.sh
```

构建需要 macOS 26+ SDK 和 Swift 6 工具链，推荐 Xcode 26+；未安装命令行工具时先运行 `xcode-select --install`。构建结果是 `dist/debug/Untitled.app`，详细步骤见[开发说明](docs/DEVELOPMENT.md)。

### 选择插件

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

## 一起开发

从功能分支或 fork 发起 Pull Request，CI 自动完成测试、Swift Package / Xcode 构建与插件包验证，并提供审查产物。main 受到保护，不直接推送；维护者合并后，CI/CD 自动发布新版本和插件目录。同版本公开资产不覆盖。

默认自动发布明确标注的预览版；正式 Developer ID 签名与 Apple 公证需要维护者配置 GitHub secrets。流程、配置和失败恢复见 [CI/CD 与发布](docs/RELEASING.md)。

## 开发资料

| 你想做什么 | 从这里开始 |
| --- | --- |
| 让 agent 理解项目 | [AGENTS.md](AGENTS.md) · [插件开发 skill](.agents/skills/untitled-plugin-development/SKILL.md) |
| 实现、组合与打包插件 | [插件协议](Plugins/README.md) · [开发说明](docs/DEVELOPMENT.md) |
| 贡献、fork 或独立分发 | [贡献规范](CONTRIBUTING.md) |
| 接入系统权限或设计完全接管 | [权限与执行规范](docs/PERMISSIONS.md) |
| 排查高内存和高开销 | [性能规范](docs/PERFORMANCE.md)：资源预算、内存 / CPU / GPU / I/O 与回归验证 |
| 通过 PR 协作与自动发布 | [CI/CD 与发布](docs/RELEASING.md) · [身份与数据迁移](docs/MIGRATION.md) |
| 使用品牌资源 | [品牌与图标](docs/BRANDING.md)：选定原图、圆角展示与 ICNS 生成 |

宿主采用 [MIT License](LICENSE)。插件与第三方依赖保留各自许可。包、模块、工程与可执行文件统一为 `Untitled`，Bundle ID 为 `app.untitled`；已有用户升级见[身份与数据迁移](docs/MIGRATION.md)。
