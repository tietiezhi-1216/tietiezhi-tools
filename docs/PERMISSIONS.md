# 权限与执行规范

Untitled 让用户按需求扩展 macOS 能力。宿主不启用 App Sandbox，原生模块可接入文件、网络、输入、设备、自动化与系统服务。Hardened Runtime、TCC、SIP、文件权限和系统签名要求继续按 macOS 规则工作；取消 App Sandbox 不会自动获得这些权限。

## 当前实现

| 能力 | 状态与入口 |
| --- | --- |
| 屏幕与系统音频录制、辅助功能、输入监控、摄像头、麦克风 | 已接入 HostPermissionCenter / SystemPermissionProvider |
| 文件选择、应用启动、HTTP(S) 链接、系统快捷指令 | 由已有原生动作执行，插件声明相应能力 |
| 局域网与虚拟麦克风 | 外设共享使用系统网络授权；HAL 驱动是独立、需用户安装的系统组件 |
| 完全磁盘访问、Apple Events、其他系统权限 | 按实际功能新增 driver / API / 用途声明；当前没有一键获取所有权限 |
| 外部可执行插件、内置 agent 执行器、完全接管 | 开发要求如下，当前没有通用运行时和模式开关 |

权限有三层：清单声明宿主能力，宿主检查插件身份与启用状态，macOS 决定受保护资源能否访问。已授权操作无需每次重新授权，执行前仍查询状态。

原生 provider 随宿主编译、同进程运行。broker 能约束经宿主接口发起的操作，不能隔离蓄意绕过接口的原生代码。发布和合并时按真正拥有宿主进程权限的代码审阅。

## 新增系统能力

1. 在 `HostPermissionID` 定义稳定 ID，在 `SystemPermissionProvider` 注册描述、状态查询、请求与系统设置入口。
2. 明确范围与目的，补充真实需要的 Info.plist、entitlement 或 helper；同步命令行打包与 Xcode，保持相同授权行为。
3. 清单声明权限与 reason，业务通过绑定插件身份的客户端调用 `require`。未知或未声明权限不能落到系统 API；关闭的可选能力不要求权限。
4. 状态以系统为准，不保存“永久已授权”。无法准确查询时显示未知或待用户处理，不通过读私密数据猜测授权。
5. 缺少权限定位宿主权限管理。拒绝、限制或撤销后停止受保护操作，保留恢复路径；停止与紧急返回始终可用。

安装、启用和打开页面不代表用户开始录屏、监听、远端控制或安装驱动。已授权动作可按约定触发方式执行，不增加重复确认层。

## 完全接管：新增运行时的交付要求

“完全接管”是用户把明确范围内的执行权委托给受信任插件或 agent。当前尚未实现本节模式，系统授权仍以 macOS 为准。

| 范围 | 实现要求 |
| --- | --- |
| 启用 | 显示执行者、工具范围、数据范围与有效期，由用户主动选择；允许在已授权范围内持续工作 |
| 身份 | 绑定插件 ID、代码身份或包校验值；新 fork、执行器或权限扩展不静默继承旧授权 |
| 工具 | 文件、进程、Shell、网络与跨应用控制有真实接口、结果和错误，不以开关文案代替运行时 |
| 范围 | 可选工作区、目录或用户明确授予的更广范围；独立 helper / XPC 按其真实身份处理权限 |
| 停止 | 有直接可操作的停止入口，取消任务、结束子进程、释放监听和连接，允许用户夺回控制 |
| 撤销 | 禁用、卸载、授权失效、退出和到期结束委托，不在重启后恢复被撤销任务 |
| 可检查性 | 记录操作来源、结果和错误供用户检查；普通日志不含密钥、配对信息与受保护内容 |
| 升级 | 保留配置；新增工具、范围扩展、执行身份变化需要可见的授权更新，普通修复不重置选择 |

代码执行协议、权限控制、安装升级、异常清理、界面与拒绝路径完成后，才能写为“支持”。现有声明式 ZIP 仍只允许清单与说明，不执行安装脚本。

## 系统依据

Apple 说明了[文件与完全磁盘访问、辅助功能、自动化的用户授权](https://support.apple.com/guide/security/secddd1d86a6/web)。媒体权限采用 [AVCaptureDevice 授权状态](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:))，辅助功能使用 [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)，输入监控使用 [CGRequestListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess())。系统状态不能由清单或模式开关替代。
