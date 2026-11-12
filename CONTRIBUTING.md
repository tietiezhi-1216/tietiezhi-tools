# 为 Untitled 开发与共享插件

欢迎提交任何用途的插件，也欢迎围绕同一需求提供不同实现。接收依据是可维护的接口、可说明的行为与可复用的源码。用户自行选择安装什么，开发者可以保留私有插件、独立发布，或 fork 后继续开发。

## 通过 Pull Request 协作

从 main 创建功能分支；外部贡献者可先 fork。只向自己的分支推送，再向本仓库 main 创建 PR，不直接向 main 推送。main 要求 `verify` 检查通过、分支与 main 同步、讨论已解决，并禁止强推与删除；维护者通过 GitHub 合并 PR，agents 不代替维护者自行合并。

```bash
git switch -c feat/my-plugin
# 修改、验证并提交
git push -u origin feat/my-plugin
# 然后在 GitHub 创建 Pull Request
```

PR CI 执行名称/版本检查、自动测试、Swift Package / Xcode 构建和插件打包，并提供可下载的审查产物。来自 fork 的 PR 不获取发布密钥。应用代码、资源或驱动变更需要递增宿主版本与 build number；插件清单变更递增插件版本。

合并到 main 后，GitHub Actions 对新版本自动发布应用与插件、核验下载并部署插件商店目录。纯文档等变更不重发同版本资产。配置与中断恢复见 [CI/CD 与发布](docs/RELEASING.md)。

## 实现方式

已有宿主能力可通过 manifest v2 组合成独立 ZIP。全新的原生能力连同服务、provider 与测试提交到宿主，再由清单启用。任意 Swift 动态库、JavaScript、Shell、agent 执行器不是当前 ZIP 支持的格式；扩展运行时须同步实现协议、权限和停止机制。

```bash
python3 scripts/new-plugin.py my-plugin --id dev.alice.my-plugin --name "My Plugin" --author alice
```

此命令生成可安装、能执行“打开主面板”的示例。开发流程见 [项目 skill](.agents/skills/untitled-plugin-development/SKILL.md)，协议见 [Plugins/README.md](Plugins/README.md)。

## 提交内容

| 内容 | 要求 |
| --- | --- |
| 源码 | 清单放 `Plugins/<slug>/`；原生实现放自己的业务模块，注册 provider，不扩大通用渲染器的业务职责 |
| 清单 | v2、唯一稳定的命名空间 ID、三段版本号、准确最低宿主版本、实际使用的 actions / permissions / ui |
| README | 用途、步骤、平台要求、权限用途、数据与网络行为、密钥存储、升级与卸载、实际验证及限制 |
| LICENSE | 共享代码提供允许再分发与修改的明确许可，保留作者与第三方许可；仓库内未单列 LICENSE 的插件沿用根目录 MIT |
| 验证 | 行为变更验证成功、失败、升级和资源释放；涉及设备、媒体或双 Mac 时说明真机验证范围 |
| 性能 | 每个插件说明资源消耗、限制、缓存与停止行为；高开销功能记录基线、峰值、CPU / 耗时及反复启停后的回收，未测项写明 |
| 发行包 | 根目录仅 manifest.json、README.md、LICENSE；不含构建目录、用户配置、密钥或个人数据 |

只做 macOS，不要求维护其他系统。部署最低 macOS 14，使用新 API 时声明版本并提供明确的不可用状态或降级。

## 安装与独立分发

```bash
# 仓库内单个插件，只生成本地产物
python3 scripts/package-plugins.py --tag v1.0.0 --plugin my-plugin

# 插件自行托管源码与 GitHub Release
python3 scripts/package-plugins.py --tag v1.0.0 \
  --plugin /path/to/my-plugin --repository alice/my-plugin
```

独立目录必须带 README 和 LICENSE。打包器优先使用插件自己的许可，不改写成宿主的 MIT。用户可通过商店“从 ZIP 安装…”导入；独立分享不必先进入中央商店。当前源码地址和商店下载地址支持 HTTPS GitHub 仓库与 GitHub Release，离线 ZIP 可自行传递。

中央目录由 CI/CD 在 `plugin-catalog` 分支部署，提供准确 ID、版本、下载地址和 SHA-256。宿主核对校验值、包身份、宿主能力和清单。打包只写本地目录；main 中的 `Plugins/catalog.json` 保留给旧版客户端，不手工改写。独立插件通过 PR 提交目录来源配置，CI 验证其包后收录。

修改已发布包要发布新版本。升级沿用 ID 并保留配置；独立 fork 换新 ID，避免覆盖原插件。复制代码保留作者与许可；加入宿主编译的代码遵循宿主 MIT 及其依赖的许可条件。

## 权限与高能力插件

插件可以涉及文件、网络、设备、输入、自动化和系统集成。权限用途、来源和停止方法要具体，系统授权由宿主统一处理。高权限 helper 或完全接管遵循 [权限与执行规范](docs/PERMISSIONS.md)，说明已实现部分与待新增的运行时。已有授权范围内的后续操作不重复确认；范围扩展或缺少实际必需信息时再请求用户输入。

## 性能与资源

所有插件都遵循 [性能开发与排查](docs/PERFORMANCE.md)。轻量插件确认空闲和停用后没有持续工作；图像、模型、音视频、设备共享与大批量处理等高开销插件明确输入、并发和缓存上限，并提供可复现的测量。先用宿主基线与单插件对照定位，再用 Allocations / Memory Graph、Time Profiler、GPU / I/O 工具找到代码原因。修改后在同样负载下复测；不能用“无崩溃”或“0 leaks”替代性能证据。

## PR 说明

描述需求、操作后的行为、插件 ID / 版本、协议变化和验证结果。新增权限或网络服务说明触发时机、目的地和停止方式；资源密集路径或性能变更给出测量环境、前后数据和未测项。小改动简短说明即可，文档不强求测试。避免混入个人配置或无关的大型产物。
