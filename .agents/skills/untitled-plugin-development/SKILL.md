---
name: untitled-plugin-development
description: Create, modify, debug, and package plugins for the Untitled macOS app. Covers manifest v2, native UI providers, permission integration, lifecycle cleanup, and independent ZIP distribution in this repository.
---

# Untitled Plugin Development

工作目录是 Untitled 仓库根目录。先读 [AGENTS.md](../../../AGENTS.md)；协议以 [Plugins/README.md](../../../Plugins/README.md) 和实际 Swift 校验器为准，贡献规则见 [CONTRIBUTING.md](../../../CONTRIBUTING.md)。仅开发 macOS。

## 选择实现方式

- **组合已有能力**：在 `Plugins/<slug>/` 修改 manifest v2、README 和可选 LICENSE。可独立发布 ZIP，无需重编译宿主。
- **新增原生能力**：在 `Sources/Untitled/<Feature>/` 实现服务与 `PluginUIProvider`，由 `App/PluginComposition.swift` 注册；同时维护 Xcode 源文件引用。原生代码随宿主编译，ZIP 仍只声明能力和布局。
- **脚本、动态可执行扩展、agent 接管**：当前没有这种运行时。按 [权限与执行规范](../../../docs/PERMISSIONS.md) 实现真正的执行边界、停止机制与授权路径；不要把可执行文件塞进现有 ZIP 或添加无实际作用的开关。

## 开发

1. 检查 `git status --short`，保留用户现有改动。读相关清单，以及 `Plugins/PluginManifest.swift`、`Plugins/PluginUIRegistry.swift`、`Runtime/HostPermissions.swift` 中涉及的接口；这些 Swift 路径均相对 `Sources/Untitled/`。
2. 新插件可运行脚手架；它生成可安装、可打开主面板的示例，随后按需求替换业务内容：

   ```bash
   python3 scripts/new-plugin.py my-plugin --id dev.alice.my-plugin --name "My Plugin" --author alice
   ```

3. 使用作者自己的稳定 ID。组件与命令采用 `<namespace>.<name>`，由清单选择槽位。新动作同步 `ActionKind`、执行分发、provider 的 requiredActions 和 JSON Schema。不要在通用渲染器中按插件 ID 插入业务页面。
4. 通过绑定当前插件的 `context.permissions` 检查实际所需权限。新增系统能力在宿主注册 driver，检查 Info.plist 和两条构建路径的 entitlement。安装、启用或打开设置不自动启动采集或控制。原生模块同进程运行，不能把这些检查描述成进程隔离。
5. 服务按需创建；禁用、卸载、退出、权限失效和异常中断释放自身资源。耗时任务可取消，失败不覆盖已有配置与输出。按现有默认模板初始化机制保留用户修改、删除和快捷键。
6. 更新 README 中的用途、平台版本、数据位置、外部服务、权限、清理行为、依赖许可和实际验证。发布过的清单变更要递增插件版本，新增能力声明正确的最低宿主版本。
7. 按 [性能规范](../../../docs/PERFORMANCE.md) 检查每个插件的空闲与停止后开销。高资源路径先定义预算，再用固定输入测量宿主基线、单插件峰值和多轮回收；结合 Instruments 或命令行快照定位持有链、热点、队列、GPU 与 I/O。README 记录实际数据、缓存 / 并发上限和未测项；修复无界增长、停用后持续工作的回归后再交付。

## 验证与交付

协议或生命周期变更覆盖成功、拒绝、升级保留配置与停止清理；纯文档不添加测试。测试数据用临时目录，测试权限用 fake driver，不申请用户实际系统权限。

```bash
swift test --no-parallel
python3 scripts/package-plugins.py --tag v1.0.0 --plugin my-plugin
./scripts/build-app.sh debug
```

AppKit 焦点测试串行运行。TestingMacros 兼容命令及 Xcode 构建见 [开发说明](../../../docs/DEVELOPMENT.md)。增加原生源码后验证 Swift Package 与 Xcode target 均收录；缺少 Xcode 时明确报告未验证这一项。

独立发布可指定 `--repository alice/my-plugin`；`--plugin` 也接受仓库外插件目录，这时必须附带自己的 LICENSE。默认只生成本地 ZIP 和目录，不更新在线商店。对应 Release 资产确已发布并可下载后才使用 `--write-catalog`；已发布同版本资产保持不变。

交付说明写明文件、构建产物、验证及仍需真机验收的部分。除非任务包含发布，不自动上传 Release、推送代码或安装系统驱动。
