# Untitled 身份迁移（0.10.0）

从这一版本开始，Swift Package、module、可执行文件、Xcode 工程 / target / scheme 均为 `Untitled`，测试模块为 `UntitledTests`。Bundle ID 为 `app.untitled`，自带插件使用 `app.untitled.*`，环境变量统一为 `UNTITLED_`。虚拟音频设备名为 `Untitled Microphone`，驱动为 `UntitledMicrophone.driver`。

旧产品身份不再用于新构建。为读取已有用户数据，旧值仅保存在 `Resources/Info.plist` 的 `UntitledIdentityMigration` 数据项中；运行时代码读取这份迁移表。仓库地址集中在 Project.json / Info.plist 元数据中，代码从元数据读取。真实 GitHub 账户路径、原始 LICENSE 署名和旧客户端的冻结目录属于历史或外部事实，不伪造改写。

## 数据

退出旧版后首次启动完整的 Untitled.app：

- 将旧偏好中尚未设置的项导入新域，保留已在 Untitled 中修改的设置；已有自定义导出路径保持有效。
- 新数据根目录不存在时，把旧 Application Support 根目录原地重命名为 `app.untitled`。这是同卷移动，避免复制大型历史媒体或模型；文件内容和相对路径不变。
- 转换自带插件的 ID 与配置文件名，保留命令 UUID、目标、快捷键、启停状态和默认模板记录。旧配置原文留在 `MigrationBackups/Plugins/`。转换失败保留文件并显示错误，不静默丢弃。
- 如果新旧根目录同时存在，不覆盖或自动合并它们，旧目录继续保留，并显示提示供用户检查和手动导入。
- 访问导出目录时迁移旧索引文件；新索引已存在时不覆盖。

迁移仅在带 Info.plist 的应用包中启动；直接运行 Swift Package 不承担已有应用数据的迁移。迁移期间不要同时运行旧新版。退回旧版需要先退出新版，再从保留的配置备份恢复或手动移回数据目录；不承诺双版本同时写入兼容。

Keychain 中的新服务采用新命名。只有新条目不存在、旧条目允许无交互读取时，才复制到新服务；保留旧条目，删除或主动重设新密钥后不再从旧项恢复。若 macOS 拒绝旧条目访问，在设置中重新输入 API 密钥或重新配对；不导出、不记录密钥，也不绕过系统访问控制。

## 系统权限与外设

Bundle ID 更改后，macOS 可能将其视为新应用。屏幕录制、辅助功能、输入监控、摄像头、麦克风等需要在实际使用时重新授权，迁移不会复制 TCC 数据或重置其他应用权限。

虚拟麦克风驱动不能由普通应用自动安装或改名。使用新版安装脚本显式安装；脚本在验证包后把通过签名和身份核验的旧驱动移到 HAL 外的备份，出现失败则恢复。安装后在方便时重启，再到会议 / 录音软件选择 `Untitled Microphone`。不自动重启音频或改变默认输入。

Bonjour 服务名和 TLS 配对上下文已改为 Untitled。共享两端应一起升级；旧新版不承诺互联。实际双机、驱动和性能验证范围仍以插件 README 为准。
