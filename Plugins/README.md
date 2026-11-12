# 插件开发协议 v2

本仓库接收各种用途的插件，清单放在 `Plugins/<plugin>/`；插件也可以有独立源码仓库与 GitHub Release。0.10.0+ 首页商店读取 CI 部署分支中的 `plugin-catalog/catalog.json` 并核对 SHA-256，用户也可以直接安装离线 ZIP。包根目录仅允许 `manifest.json`、`README.md`、`LICENSE`。

开发流程见[项目 skill](../.agents/skills/untitled-plugin-development/SKILL.md)，共享与二次开发要求见[贡献规范](../CONTRIBUTING.md)，高权限和完全接管的实现边界见[权限规范](../docs/PERMISSIONS.md)。

0.4.0 起，插件声明自己的界面布局。宿主提供槽位、组件注册、命令分发、面板路由、安装与存储；不根据插件 ID 或动作类型决定 v2 插件的页面。参考完整的[截图清单](screenshot/manifest.json)、[快捷键清单](global-shortcuts/manifest.json)及 [JSON Schema](manifest-schema.json)。

每个插件都需遵循[性能规范](../docs/PERFORMANCE.md)，说明资源开销与停止后的清理；高内存或高计算负载功能需定义预算并记录可复现的基线、峰值和回收结果。不能将宿主整体占用直接当作单个插件的占用。

## 清单

| 字段 | 用途 |
| --- | --- |
| `schemaVersion` | 新插件使用 `2`；`1` 包通过兼容适配器继续使用 |
| `id` | 唯一标识，小写字母、数字、点和连字符 |
| `name` / `summary` / `author` | 商店和插件信息 |
| `version` / `minimumHostVersion` | 三段数字；v2 最低宿主为 `0.4.0` |
| `repository` | 插件真实的 HTTPS GitHub 源码仓库；同仓库插件使用 `https://github.com/tietiezhi-1216/untitled` |
| `actions` | 允许使用的动作能力，无重复项 |
| `templates` | 用户添加操作时的模板，包含 `id`、`title`、`action` |
| `permissions` | 0.5.0+ 插件显式声明所需权限；无需权限时为 `[]` |
| `ui` | 界面协议：`version: 1`、可选 SF Symbol `icon`、`slots` 和 `panels` |

支持动作：`openApplication`、`openURL`、`runShortcut`、`showMainWindow`、`captureRegion`、`captureWindow`、`captureScreen`、`captureScrolling`、`captureRecording`、`pinClipboard`、`togglePins`、`captureHistory`。安装、注册界面或加载清单不会执行这些动作；显式声明的默认操作会在安装时注册快捷键。

0.9.0+ 另支持 `sharePeripherals`、`switchPeripheralControl`、`stopPeripheralSharing`，由独立 `SharingPluginUIProvider` 注册 `sharing.dashboard` / `sharing.status` 组件和 `sharing.toggle` / `sharing.switch` / `sharing.stop` 命令。参阅[外设共享清单](peripheral-sharing/manifest.json)与[双机使用说明](peripheral-sharing/README.md)。原生服务按插件身份惰性创建、通过自身的宿主权限客户端检查权限；安装或启用不启动共享，禁用、卸载或退出立即释放。虚拟音频驱动独立于声明式 ZIP，安装只能由本机用户明确执行。

## 通用槽位

每个槽位是有序数组，省略或空数组即不显示；只有根布局 `content` 必须非空。数组顺序就是显示顺序。

| 槽位 | 位置 |
| --- | --- |
| `header.leading` / `header.trailing` | 页面顶部左右两侧 |
| `toolbar.leading` / `toolbar.trailing` | 内容上方的左右操作区 |
| `content` | 主内容，组件可自行处理滚动、网格、表单和编辑器 |
| `footer.leading` / `footer.trailing` | 页面底部两侧 |
| `menuBar` | 系统菜单栏里的插件子菜单 |

插件可以自行选择标题、图标、启停、更多、简介、设置按钮的位置。宿主组件不会自动插入；不声明就不显示。应用级设置始终在侧边栏底部和 macOS 应用菜单中，不占用插件槽位。

每个元素必须有全局唯一 `id` 和一种 `kind`：

| `kind` | 声明 |
| --- | --- |
| `component` | `component: "命名空间.组件"` |
| `button` | `command` 或 `panel` 二选一，可加 `title`、`symbol`、`style` |
| `menu` | `title` 与 `items`，内部支持按钮与子菜单 |
| `panel` | 在 `content` 内嵌一个已定义的 `panel` |
| `tabs` | 在 `content` 放置分段页面切换，`panels` 为面板 ID 数组 |

命令按钮默认使用命令提供的动态名称和图标，例如录屏中的“停止录屏”。`title` / `symbol` 可覆盖默认值；仅图标的面板按钮省略 `title`。`style` 可选 `plain`、`standard`（默认）、`prominent`。菜单栏只支持命令按钮和菜单。

`ui.panels` 中每个面板有 `id`、`title`，并选择 `component` 或 `slots` 二选一。面板内也能组合上述槽位（不含 `menuBar`）；可选 `width` 320–1200、`height` 240–900，默认 660 × 560。面板按钮的 `presentation` 支持：

- `sheet`：打开插件内的设置或配置弹窗，默认方式。
- `popover`：锚定按钮的浮层。
- `inline`：切换已有分段页，或在主内容打开面板并提供返回。

例如，插件可以自行把设置按钮放在顶部，把操作列表放进内容区：

```json
{
  "version": 1,
  "icon": "puzzlepiece.extension",
  "slots": {
    "header.leading": [{"id": "title", "kind": "component", "component": "host.identity"}],
    "header.trailing": [{"id": "configure", "kind": "button", "symbol": "gearshape", "panel": "preferences", "presentation": "sheet"}],
    "toolbar.trailing": [{"id": "add", "kind": "component", "component": "host.addCommand"}],
    "content": [{"id": "list", "kind": "component", "component": "host.commands"}]
  },
  "panels": [{"id": "preferences", "title": "插件配置", "component": "host.commands"}]
}
```

安装前会校验槽位、全局唯一 ID、注册引用、能力要求、面板循环及深度。最多 160 个元素、24 个面板、12 个分段页，菜单嵌套最多 3 层；内嵌面板最多 8 层，每个面板展开后的内容最多 1024 项。清单上限 256 KB，ZIP 上限 2 MB。未知组件/命令或未声明所需动作时拒绝安装并保留已有配置。

## 组件与命令注册

原生模块实现 `PluginUIProvider`，在应用组合入口 `App/PluginComposition.swift` 注册。渲染器只访问注册表；新增原生界面不需要给 `ContentView` 添加插件分支。

```swift
struct ExampleProvider: PluginUIProvider {
    func register(in registry: PluginUIRegistry) {
        registry.component("example.panel", requiredActions: [.showMainWindow]) { context in
            AnyView(ExampleView(pluginID: context.pluginID))
        }
        registry.command("example.show", requiredActions: [.showMainWindow], presentation: { _ in
            .init(title: "打开面板", symbol: "macwindow")
        }) { context in
            context.store.showMainWindow()
        }
    }
}
```

`PluginUIContext` 提供插件 ID、当前配置、宿主服务和面板导航。组件获得同一 `PluginStore` 环境对象；命令运行时再次检查插件启停、声明的能力和动态可用状态。命令可提供 `updates` publisher，让录屏状态等在所有槽位及菜单栏中同步刷新。设置面板在插件停用后仍可打开，执行命令会被禁用。

| 内置组件 | 用途 / 所需动作 |
| --- | --- |
| `host.icon` / `host.identity` | 插件图标、名称和版本 |
| `host.enabled` / `host.more` / `host.info` | 启停、源码/卸载、简介浮层 |
| `host.commandHeading` / `host.addCommand` / `host.commands` / `host.commandStatus` | 操作标题、添加、列表、状态提示 |
| `capture.history` / `capture.status` | 截图历史、数量；需要 `captureHistory` |
| `capture.preferences` | 截图设置；需要 `captureRegion` |

命令：`host.openPlugin`；`capture.region`、`capture.window`、`capture.screen`、`capture.scrollVertical`、`capture.scrollHorizontal`、`capture.record`、`capture.pinClipboard`、`capture.togglePins`、`capture.history`、`capture.importImage`。分别需要相应截图动作；导入需要 `captureRegion`。

当前 ZIP 是声明式扩展包，可自由组合已注册的原生能力与界面。新增全新的原生组件或命令需实现 provider 并随宿主编译；本版不动态加载 Swift 二进制、JavaScript 或 Shell。v1 包只在兼容适配器中生成旧版布局，v2 原样采用清单中的布局。

## 宿主权限服务（0.5.0+）

系统权限只授予主应用。插件清单声明用途，主应用统一查询状态、说明权限用途、请求授权和打开系统隐私设置。插件界面不提供独立的系统授权按钮，也不直接调用 TCC / AVFoundation 的授权 API。

```json
"permissions": [
  {"id": "system.screenRecording", "reason": "截图和录屏"},
  {"id": "system.camera", "reason": "录屏摄像头画中画", "optional": true}
]
```

显式声明需要 `minimumHostVersion: "0.5.0"` 或更高；此版本及以上的插件必须包含 `permissions`。最多 32 项，ID 无重复，每项用途 1–240 字。`optional` 表示按功能选项使用，默认 false；所有权限仍然在实际操作时检查，不会因为安装或启用插件就请求授权。旧包通过原生能力的兼容声明继续使用。

当前宿主管理：`system.screenRecording`、`system.accessibility`、`system.inputMonitoring`、`system.camera`、`system.microphone`。全局热键采用 Carbon 注册，不需要输入监控或辅助功能授权。

插件只调用绑定到自身身份的客户端：

```swift
try context.permissions.require([.camera])
// 主应用验证插件是否启用、是否声明该权限，以及当前系统状态。
// 获准后才继续功能；缺少时会定位主应用的权限管理并抛出 HostPermissionError。
```

缺少权限时不会直接弹出系统授权框。主应用显示请求来源和状态，具体用途可通过信息按钮查看，用户点击「授权」才调用系统请求 API；拒绝或受限制时通过系统设置处理。授权后用户重新执行操作，不自动启动录屏或设备。不要捕获错误后继续读取受保护数据；宿主命令入口会统一处理权限错误。

业务选项（麦克风录制、画中画、按键显示等）保留在插件设置中；开启选项不会立刻请求系统权限。自动滚动在实际开启时请求辅助功能，手动滚动不需要。录屏停止操作不因权限被撤销而受阻。

`HostPermissionCenter` 接收 `HostPermissionDriver` 注册，驱动提供描述、状态查询、系统请求和设置跳转。新增系统能力由宿主注册驱动并检查必要的 Info.plist / entitlement；无需修改插件面板或统一权限管理界面。状态不持久化为“已授权”，返回应用或点击刷新时重新查询系统。未知、未声明或已停用插件的请求不会触发系统授权。

系统权限由 macOS 最终确认和撤销，主应用不修改 TCC 数据库。屏幕录制、辅助功能和输入监控的 preflight 只提供是否已授权，界面使用「未授权」而不推断是否曾拒绝。摄像头与麦克风采用系统的精确授权状态。参阅 Apple 的 [媒体授权状态](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:))、[辅助功能信任检查](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)、[输入监控请求](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess())。

## 发布

```bash
python3 scripts/package-plugins.py --tag v0.9.0
# 单个插件，可选独立 Release 仓库
python3 scripts/package-plugins.py --tag v1.0.0 --plugin my-plugin --repository alice/my-plugin
```

脚本默认只生成本地 ZIP 和 catalog，不上传、不修改在线目录。`--plugin` 可重复使用，支持插件目录或仓库内 slug；仓库外目录必须带自己的 README 与 LICENSE。优先采用插件自己的 LICENSE，仓库内未提供时才继承根 MIT。

开发通过功能分支和 Pull Request 交付；维护者合并后由 CI/CD 上传并验证发行资产，再部署 `plugin-catalog` 分支。独立包的目录记录通过 `Plugins/catalog-external.json` 提交。打包器只写本地输出，不再用 `--write-catalog` 改写 main。已发布的同版本资产不可替换；清单、说明或许可导致包变化时递增版本。

本地配置位于 `~/Library/Application Support/app.untitled/Plugins/<id>.json`。升级替换清单并保留用户操作与启停状态；禁用释放快捷键，卸载删除该插件配置。配置不会随源码发布。


### 默认动作（宿主 0.6.0+）

模板可选声明 `installByDefault: true` 和 `defaultHotKey: {"keyCode":18,"modifiers":4096,"key":"1"}`。键码使用 macOS 虚拟键码，修饰键使用 Carbon 位掩码；默认全局按键必须包含 ⌘、⌥ 或 ⌃。默认动作不能要求用户先填写目标。同一清单的默认组合键不能重复，声明这些字段时请设置 `minimumHostVersion` 至少为 `0.6.0`。

宿主安装或升级时按模板 ID 初始化一次；已编辑、清空、停用或删除的默认操作在后续升级中保持原样。旧配置会按动作匹配到模板，保留原操作 ID。冲突时不会覆盖其他操作，新动作不绑定并显示提示。`host.restoreDefaultCommands` 命令显式恢复默认模板，保留其他自建操作。此机制对所有插件通用。

截图新增组件 `capture.pins` 和命令 `capture.delayed`、`capture.copy`、`capture.repeatRegion`、`capture.restorePin`、`capture.cycleGroup`、`capture.closePins`、`capture.hideOtherPins`、`capture.clickThrough`、`capture.pinFiles`、`capture.toggleHotKeys`。它们仍由清单选择槽位，主应用不指定插件的面板布局。

## PR 与自动部署

插件源码、清单和独立目录来源通过 Pull Request 提交。CI 校验包及宿主兼容性；维护者合并后自动发布新版本并部署目录。main 中的 `Plugins/catalog.json` 是给旧客户端保留的冻结目录，不作为新版本目录来源。独立来源写入 `Plugins/catalog-external.json`，字段与 CatalogEntry 相同。详见 [CI/CD](../docs/RELEASING.md)。
