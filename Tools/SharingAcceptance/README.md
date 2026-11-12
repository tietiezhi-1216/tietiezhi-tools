# 私有双机验收工具

仅供维护者在获得设备所有者明确同意后使用。`SharingAcceptance.swift` 及命令入口只编译到 **DEBUG** 构建；发行版不包含该控制入口。工具不修改 TCC、不代填管理员密码、不安装驱动、不更改默认音频设备、不保存录音。

## 运行边界

- 用 `--sharing-acceptance <目录>` 显式启动调试应用；目录只能位于当前用户的 `~/Library/Caches/app.untitled/SharingAcceptance/<独立运行目录>`，归当前用户所有，权限为 `0700`，不允许符号链接。
- 验收使用目录下的独立 `Plugins/`，不加载用户原有截图插件或全局快捷键。配对文件 `pairing-key` 与 JSON 命令文件必须为当前用户拥有的 `0600` 普通文件。
- 临时配对密钥为随机 256 位值，经已验证主机身份的 SSH 传输，不能放在命令行参数、日志或仓库中。结束后删除两端临时密钥。
- 控制窗口只统计具有验收标记的固定按键与点击；不记录普通用户输入内容。只有该窗口处于前台且获得键盘焦点时，调试接收端才允许输入投递。
- 验收实例最长运行 10 分钟；控制会话最长 4–5 秒，麦克风采集与虚拟输入探针最长 5 秒。关闭、断线、超时均释放控制与音频。
- 所有真实键鼠/麦克风操作继续经过宿主权限客户端。系统显示“未授权”时必须停止该项测试，由用户在统一权限管理中授权。

## 操作脚本

在两端显式启动、导入插件并放置同一个临时配对文件后，在本机准备私有会话 JSON：

```json
{"local":"/Users/USER/Library/Caches/app.untitled/SharingAcceptance/RUN","remote":"/Users/USER/Library/Caches/app.untitled/SharingAcceptance/RUN"}
```

会话 JSON 也应为 `0600`。测试使用已配置且启用严格主机密钥验证的 SSH 别名：

```bash
python3 Tools/SharingAcceptance/run.py --session /path/to/private-session.json \
  --remote MY_SSH_ALIAS --peer PEER_VPN_IP --phase network
python3 Tools/SharingAcceptance/run.py --session /path/to/private-session.json \
  --remote MY_SSH_ALIAS --phase keyboard
python3 Tools/SharingAcceptance/run.py --session /path/to/private-session.json \
  --remote MY_SSH_ALIAS --microphone-uid EXPLICIT_PHYSICAL_DEVICE_UID --phase microphone
python3 Tools/SharingAcceptance/run.py --session /path/to/private-session.json \
  --remote MY_SSH_ALIAS --phase stop
```

`status.json` 仅包含权限、连接状态、事件计数及音频帧数/RMS/峰值，不包含配对密钥或音频采样。控制脚本按 UUID 等待命令确认；超时、被拒绝或未加载驱动不能算通过。

## 无本机输入授权的分层诊断

`SyntheticPeer.swift` 可单独和产品的 `SharingProtocol.swift`、`SharingTransport.swift` 编译，提供受同一 TLS-PSK 认证的测试对端：

```bash
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/Untitled/Sharing/SharingProtocol.swift \
  Sources/Untitled/Sharing/SharingTransport.swift \
  Tools/SharingAcceptance/SyntheticPeer.swift -o /path/to/SyntheticPeer
```

- `input` 模式不监听本机实体输入；只向**已在接收端明确允许键鼠控制**的产品实例发送固定模拟数据。该测试可以证明网络数据到真实 AppKit 输入投递，但**不能证明发送端物理键鼠捕获已通过**。
- `microphone` 模式不打开接收端任何麦克风；仅按需接收产品发送端提供的短时音频，并计算帧数、RMS 和峰值。该测试可以证明实体麦克风采集与跨机传输，但**不能代替虚拟 HAL 输入、会议软件或双向音频验收**。

编译工具的命令行为 `SyntheticPeer <私有目录> <对端地址> <TCP端口> <input|microphone>`。调用者仍需明确同意实际音频来源；真实采集由产品宿主执行权限检查。程序自身最长运行 25 秒，音频收到约 3 秒后请求停止，控制会话约 4 秒后归还。

## 回归重点

鼠标事件投递是异步的：一个网络批次内的点击必须使用接收端逻辑指针位置，而不是尚未更新的系统指针；绝对位置事件不能再次施加鼠标加速度。麦克风输入采用独立 AudioQueue，避免默认虚拟输出与 USB 输入设备不一致时 AVAudioEngine 没有输入回调；采集开始两秒仍无音频帧时必须停止并提示，而不是一直显示同步成功。

仍需用户配合完成：真实物理键鼠双向接力、屏幕边缘切换、按键修饰键/拖动、紧急返回、断网/睡眠/锁屏，以及安装驱动后的隐藏 Feed 路由、多个应用消费者与会议软件验收。
