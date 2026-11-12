# Tietiezhi Microphone（macOS 14+）

本项目独立实现的 HAL 虚拟麦克风，用于外设共享插件。不是 Oink 驱动，也不包含或依赖其 GPL 代码。参考的是公开产品行为；音频驱动基础采用 [libASPL](https://github.com/gavv/libASPL)，MIT / Apple 示例代码许可。

## 构建

```bash
./scripts/build-sharing-microphone.sh
# 可选：同时构建两种驱动架构（主应用本身仍按 build-app.sh 的本机架构构建）
TIETIEZHI_AUDIO_ARCHS="arm64 x86_64" ./scripts/build-sharing-microphone.sh
```

仅需 Xcode / 命令行工具的 C++17 编译器，不需要 CMake、Homebrew。首次下载固定 libASPL 提交 `633e0f70203edd87d320fc5a3cae901e1363aac5` 并验证归档 SHA-256 `204fdbff5ebb02fb485479be905a00f2147c6a283f40ced50c4029c4acfe8baf`。上游的 `LICENSE`、`LICENSE.apple2012`、`LICENSE.apple2020` 随驱动保留。下载缓存位于 `.build/sharing-microphone/`。

构建运行无安装、无麦克风访问的环形缓冲测试，以及仅在测试进程加载驱动的设备标识、隐藏 Feed UID 查询和流格式测试，不注册 HAL、不启动 I/O。使用与主应用相同的 `TIETIEZHI_SIGNING_IDENTITY` / `.signing-identity`；无身份时临时签名。公开分发需 Developer ID 与公证；临时签名或本地自签名不保证在其他 Mac 上加载。`build-app.sh` 将驱动与此安装脚本打包到应用的 `Contents/Resources/PeripheralAudio/`；普通 `swift build` 不构建驱动。

## 安装或卸载（接收端）

关闭使用虚拟麦克风的应用，在终端**主动**执行：

```bash
sudo ./Tools/SharingMicrophone/install.sh install "dist/SharingMicrophone/TietiezhiMicrophone.driver"
# 或使用发行应用内的脚本（路径包含空格时加引号）
sudo "/path/to/PeripheralAudio/install.sh" install
# 卸载
sudo ./Tools/SharingMicrophone/install.sh uninstall
```

脚本仅修改固定 `/Library/Audio/Plug-Ins/HAL/TietiezhiMicrophone.driver`，先在 root 私有目录复制、验证签名和标识，再替换；旧包移入系统应用支持目录下的备份，不留在 HAL。脚本不执行下载包内的代码、不改 TCC、不自动关闭安全功能、不重启 `coreaudiod`，也不修改默认音频设备。安装或移除后请在方便时**重启 Mac**，避免打断当前通话。若驱动被系统拒绝，请使用合规签名/公证版本，不要关闭 SIP 或 Gatekeeper。

应用没有可以由远端调用的管理员安装接口；安装不由插件启用、配对或网络消息触发。插件卸载只停止共享，不擅自删除系统驱动；驱动使用以上脚本独立卸载。

## 设备与数据流

- 可见输入：`Tietiezhi Microphone`，UID `com.tietiezhi.tools.microphone.input.v1`。
- 隐藏输出：`Tietiezhi Microphone Feed`，UID `com.tietiezhi.tools.microphone.feed.v1`，不可设为默认输出。
- 单声道 48 kHz Float32 PCM。混合后的 Feed 写入有界、无锁、带标签的原子环形缓冲；每个输入客户端有独立游标，欠载补零，不重放旧声音；积压时追上实时位置。
- 两个独立设备使应用可以查询**输入设备** `DeviceIsRunningSomewhere`，不会把自身 Feed 输出误判为麦克风消费者。只有消费者运行、接收选项开启且对端明确允许时才传输实体麦克风。

当前是首版自适应丢帧/补零缓冲，不承诺专业音频时钟同步、无损网络传输或样本精确延迟。需要通过真实双机会议、多个消费者、睡眠恢复和长期稳定性验证；本机单元测试不等同于 HAL 加载或双机验收。
