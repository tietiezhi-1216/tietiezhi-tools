# Untitled · Agent 开发约定

Untitled 是由用户通过 agents 持续定制的原生 macOS 软件。功能以可选择、可安装、可共享和可二次开发的插件提供；宿主承担插件安装、界面组合、配置、权限和生命周期。需求没有预设的功能类别限制。

## 入口

- 插件开发、调试与打包：先读 [.agents/skills/untitled-plugin-development/SKILL.md](.agents/skills/untitled-plugin-development/SKILL.md)。这是随仓库分发的项目 skill。
- [Plugins/README.md](Plugins/README.md)：清单、UI 槽位、provider、默认动作和包格式。
- [CONTRIBUTING.md](CONTRIBUTING.md)：接收插件、独立分发、许可证和二次开发规则。
- [docs/PERMISSIONS.md](docs/PERMISSIONS.md)：权限及完全接管的实现要求。
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md)：每个插件的性能预算、内存 / CPU / GPU / I/O 排查与回归验证。
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)：构建、签名、界面约定及平台验证。

## 技术边界

- 只支持 macOS。Swift 6、SwiftUI / AppKit，部署最低 macOS 14；较新 API 保留相应 availability 检查。源码使用 macOS 26+ SDK，不增加其他系统适配层。
- 清单在 `Plugins/<slug>/`；通用协议与存储在 `Sources/Untitled/Plugins/`，系统接口在 `Runtime/`，组合入口在 `App/PluginComposition.swift`。
- 现有 `Capture/`、`Sharing/` 是原生能力模块。新业务使用自己的模块与 provider；通用渲染器只访问注册表，不按插件 ID 硬编码页面。
- 当前 ZIP 是声明式包，仅允许根目录 `manifest.json`、`README.md`、`LICENSE`。新增原生能力随宿主编译。任意代码加载、agent 执行器及完全接管是独立的运行时工作，未实现时不得宣称可用。
- 命令行与 Xcode 构建均不启用 App Sandbox，保留系统授权与 Hardened Runtime。系统能力通过统一 driver 和绑定插件身份的客户端接入。
- 原生 provider 同进程运行；权限声明是宿主接口约束，不是对恶意原生代码的隔离沙盒。共享与独立分发不代表自动获得系统权限。

## 实现与兼容

- 开始前看 `git status --short`。保留已有未提交改动，不用 reset、clean 或整文件回退覆盖其他工作。
- 产品、Swift Package / module、可执行文件、Xcode target / scheme 统一为 `Untitled`，Bundle ID 为 `app.untitled`，项目自带插件使用 `app.untitled.*`，环境变量使用 `UNTITLED_`。旧身份仅允许出现在 Info.plist 的迁移元数据和冻结的历史发行目录中；不作为新代码或新产物的标识。真实 GitHub 账户地址和原始许可证署名不伪造改写。
- 新插件使用自己的命名空间；fork 独立分发时换插件 ID，保留作者与许可。版本、模板 ID、命令 ID 稳定，升级不重置用户配置。
- 安装、启用、打开界面不自动启动采集、远端控制、安装 helper 或申请整套权限。长任务可取消；禁用、卸载和退出释放自身热键、监听、连接与任务。
- Swift 6 的 actor 和 Sendable 问题按真实所有权解决，不靠普遍添加 `@unchecked Sendable` 或忽略错误。
- 密钥放 Keychain；源码、清单、包和日志不含个人路径、配对信息或用户内容。错误提供恢复路径，输出与配置有原子替换或等效的失败保护。
- 新 Swift 文件同时加入 Xcode target。新增字段、动作、权限同步 Swift 校验、JSON Schema、说明和相关验证。
- 每个插件都检查空闲与停用后的开销；高内存、模型、图像、音视频、批处理等路径先定义输入、并发、缓存和队列预算，测量基线、峰值与释放后的多轮趋势。无界增长、停用后持续工作等回归先修复；未测指标明确标注，不凭编译或单元测试宣称性能合格。具体工具与复现记录见性能规范。

## 分支与 Pull Request

- 所有修改在功能分支进行，通过 Pull Request 提交到 `main`。不得直接推送 main，也不得在本地合并后绕过 PR 推送；不关闭保护规则来完成任务。
- 默认交付为可审查的 PR：说明行为、迁移与验证，等待必需的 `verify` 检查通过。用户明确要求只改本地时不推送。未经用户明确要求，不自行合并 PR。
- fork 贡献者向 main 发 PR。PR CI 只读、不接触发布密钥；不使用会执行不可信 PR 代码的高权限发布路径。
- 合并后由 GitHub Actions 自动构建、打包、发布新版本并部署插件目录；agents 不手工发布 Release，不向 main 提交生成目录。主应用的代码/资源/驱动变更递增版本与 build number；已发布的同版本资产不覆盖。

## 验证与发布

```bash
swift build
swift test --no-parallel
./scripts/build-app.sh debug
python3 scripts/package-plugins.py --tag v0.10.0
```

焦点测试串行运行，临时目录隔离配置，fake driver 隔离系统权限。按改动做必要验证；不为文案或低影响可逆变更编写镜像测试。只在相关改动、失败或未解决疑虑存在时扩大检查范围。

修改 `Resources/Brand/AppIcon.png` 后执行 `scripts/build-icon.sh`，同步 Xcode 使用的 `Resources/AppIcon.icns`。选定图形是黑白「裂变」，来源见 [品牌说明](docs/BRANDING.md)。

版本采用三段数字。打包默认只写 `dist/`，可选择单个插件和独立仓库。在线目录由合并后的 CI 在资产发布与下载验证后部署到 `plugin-catalog` 分支；main 中的 `Plugins/catalog.json` 仅服务旧版客户端，保持冻结。相同版本 ZIP 和 SHA-256 不重写。发布配置见 [CI/CD](docs/RELEASING.md)。报告真实完成的检查，不把编译通过当成真机跨设备验收通过。
