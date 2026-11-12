import AppKit
import SwiftUI

struct SharingPluginView: View {
    @ObservedObject var controller: PeripheralSharingController
    @EnvironmentObject private var store: PluginStore
    @ViewState private var keyDraft = ""
    @ViewState private var replaceKey = false
    @ViewState private var hasKey = false
    @ViewState private var notice = ""
    @ViewState private var showDriverHelp = false
    @ViewState private var manualHost = ""
    @ViewState private var manualPort = String(SharingTransport.defaultPort)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionCard
                keyboardCard
                microphoneCard
                pairingCard
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("仅用于你拥有或获授权的两台 Mac。配对密钥可授予远端控制能力，请勿发给不信任的人；无需云端账户。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 12)
        }
        .onAppear { hasKey = SharingPairingKey.load() != nil; controller.refreshDevices() }
        .confirmationDialog("生成新密钥会替换旧配对；另一台 Mac 也需更新密钥。", isPresented: $replaceKey) {
            Button("生成并替换配对密钥", role: .destructive) { generateKey() }
        }
        .sheet(isPresented: $showDriverHelp) { driverHelp }
    }
    private var connectionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    device("本机 Mac", symbol: "laptopcomputer", active: controller.control == .local)
                    Image(systemName: controller.peerName == nil ? "link.badge.plus" : "arrow.left.arrow.right").foregroundStyle(.secondary)
                    device(controller.peerName ?? "另一台 Mac", symbol: "desktopcomputer", active: controller.control != .local)
                    Spacer()
                    if controller.peerName != nil { Button("断开连接") { controller.disconnect() } }
                }
                Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if controller.isRunning && controller.peerName == nil {
                    if controller.peers.isEmpty {
                        Text("等待发现设备… 请让两台 Mac 接入同一局域网、保存同一配对密钥并启动共享。只需在其中一台点击连接。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("对端 IP / VPN / DNS 地址", text: $manualHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("端口", text: $manualPort).textFieldStyle(.roundedBorder).frame(width: 76)
                        Button("按地址连接") { run { try controller.connect(host: manualHost, port: manualPort) } }
                            .disabled(manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("跨网段或 VPN 不会自动发现；两端启动共享并保存同一密钥后，填写对端地址。默认 TCP 端口为 \(SharingTransport.defaultPort)，认证方式不变。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(controller.peers) { peer in
                        HStack {
                            Label(peer.name, systemImage: "desktopcomputer")
                            Spacer()
                            Button("连接") { run { try controller.connect(peer) } }
                        }
                    }
                }
            }.padding(8)
        } label: { Label("设备连接", systemImage: "network") }
    }
    private func device(_ name: String, symbol: String, active: Bool) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(active ? Color.accentColor : .secondary)
            Text(name).font(.callout.weight(.medium)).lineLimit(1)
        }.frame(maxWidth: 200)
    }
    private var keyboardCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("允许此连接共享键盘与鼠标", isOn: Binding(get: { controller.keyboardMouseEnabled }, set: { value in run { try controller.setKeyboardMouse(value) } }))
                    .disabled(!controller.isRunning)
                HStack {
                    Picker("另一台 Mac 在本机屏幕的", selection: $controller.edge) {
                        ForEach(SharingEdge.allCases) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 280)
                    Toggle("屏幕边缘切换", isOn: $controller.edgeSwitching)
                    Spacer()
                }.disabled(controller.control != .local)
                Text("两端均开启后，将鼠标推过屏幕边缘即可接力；在远端从进入的边缘移回可返回。本机实体键鼠操作可夺回控制。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("⌃⌥⌘K 切换控制   ·   ⌃⌥⌘Esc 紧急返回").font(.caption.monospaced())
                    Spacer()
                    Button(controller.control == .local ? "控制另一台 Mac" : "返回本机") { controller.toggleControl() }
                        .disabled(!controller.keyboardMouseEnabled || controller.peerName == nil)
                }
                Text("需要辅助功能与输入监控权限；安全输入、锁屏和登录界面不可控制。首版支持指针、点击、拖动、滚轮和标准按键，不转发多指手势或特殊媒体键。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        } label: { Label("键盘与鼠标 · \(controller.control.rawValue)", systemImage: "keyboard") }
    }
    private var microphoneCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("本机实体麦克风", selection: $controller.microphoneUID) {
                        Text("系统默认实体输入").tag("")
                        ForEach(controller.audioDevices) { Text($0.name).tag($0.id) }
                        if !controller.microphoneUID.isEmpty && !controller.audioDevices.contains(where: { $0.id == controller.microphoneUID }) {
                            Text("已选设备离线").tag(controller.microphoneUID)
                        }
                    }
                    Button("刷新") { controller.refreshDevices() }
                }
                Toggle("允许将本机麦克风同步给对端", isOn: Binding(get: { controller.microphoneOffered }, set: { controller.setMicrophoneOffered($0) }))
                    .disabled(!controller.isRunning)
                Toggle("在本机使用对端麦克风", isOn: Binding(get: { controller.wantsRemoteMicrophone }, set: { controller.setWantsRemoteMicrophone($0) }))
                    .disabled(!controller.isRunning || !controller.hasDriver)
                HStack {
                    Label(controller.microphoneStatus, systemImage: controller.isSendingMicrophone || controller.isReceivingMicrophone ? "mic.fill" : "mic.slash")
                        .foregroundStyle(controller.isSendingMicrophone || controller.isReceivingMicrophone ? Color.orange : .secondary)
                    Spacer()
                    Button("检查 / 重试") { controller.retryMicrophone() }
                }.font(.caption)
                Divider()
                HStack {
                    Label(controller.hasDriver ? "Untitled Microphone 已安装" : "接收端需要虚拟麦克风驱动", systemImage: "waveform")
                    Spacer()
                    Button("驱动与使用说明…") { showDriverHelp = true }
                }.font(.callout)
                Text("在接收端的会议或录音软件中选择 Untitled Microphone。只有应用实际使用该输入时才请求发送端采集；本机软件仍可同时使用实体麦克风。停止使用、关闭共享或断线会停止采集。不会修改系统默认输入，也不会将声音回放到扬声器。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        } label: { Label("麦克风同步", systemImage: "mic") }
    }
    private var pairingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(hasKey ? "配对密钥已保存在本机钥匙串" : "首次使用：在一台 Mac 生成密钥，复制到另一台保存")
                    .font(.callout)
                HStack {
                    SecureField("粘贴完整 64 位密钥", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("保存密钥") { run { try SharingPairingKey.save(keyDraft); keyDraft = ""; hasKey = true; notice = "已保存；两台 Mac 使用同一密钥后启动共享。" } }
                        .disabled(keyDraft.isEmpty)
                }.disabled(controller.isRunning)
                HStack {
                    Button("生成新密钥") { if hasKey { replaceKey = true } else { generateKey() } }.disabled(controller.isRunning)
                    Button("复制已保存密钥") { copyKey() }.disabled(!hasKey)
                    Button("解除配对", role: .destructive) {
                        run { controller.stop(); try SharingPairingKey.delete(); hasKey = false; keyDraft = ""; notice = "已删除本机配对密钥；另一台 Mac 请同时解除配对。" }
                    }.disabled(!hasKey)
                    Spacer()
                }
                Text("传输使用 TLS 1.2 PSK / AES-GCM 加密认证（256 位随机密钥），不是可猜测的短 PIN。请通过可信渠道传递；剪贴板中的密钥将在 60 秒后尝试清除。启动共享后不能修改密钥。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        } label: { Label("安全配对", systemImage: "lock.shield") }
    }
    private var driverHelp: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("虚拟麦克风驱动").font(.title2.weight(.semibold))
            Text("发送端采集实体麦克风不需要驱动；需要让应用选择远端麦克风的接收端才需安装。此驱动独立实现，采用 MIT 许可的 libASPL，不依赖 Oink。")
            Text("安装和卸载均需管理员权限。不会由发现设备、网络消息或启动共享自动触发；安装后请自行重启 Mac（不中断当前通话）。")
            Text("发行应用：点击下方按钮显示 PeripheralAudio 文件夹，在终端执行其中 install.sh 的 install 或 uninstall 操作。源码构建可先执行：")
            Text("./scripts/build-sharing-microphone.sh\nsudo ./Tools/SharingMicrophone/install.sh install \"dist/SharingMicrophone/UntitledMicrophone.driver\"")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("重启后，在本插件勾选“在本机使用对端麦克风”，再到目标应用选择 Untitled Microphone。发送端需允许共享并授权麦克风。驱动未安装或被系统拒绝时，键鼠共享仍可单独使用。")
            Text("公开分发驱动需要有效的 Developer ID 签名与公证；本地开发临时签名不保证在其他 Mac 上加载。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("显示驱动安装文件") {
                    guard let url = Bundle.main.resourceURL?.appendingPathComponent("PeripheralAudio"), FileManager.default.fileExists(atPath: url.path) else { notice = "当前运行的是源码二进制；请按说明先构建驱动。"; showDriverHelp = false; return }
                    NSWorkspace.shared.open(url)
                }
                Spacer()
                Button("完成") { showDriverHelp = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
    }
    private func run(_ body: () throws -> Void) {
        do { try body() } catch { store.handleExecutionError(error) }
    }
    private func generateKey() {
        run { try SharingPairingKey.save(SharingPairingKey.generate()); hasKey = true; notice = "已生成新密钥，点击复制后在另一台 Mac 保存。" }
    }
    private func copyKey() {
        guard let key = SharingPairingKey.load() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
        let changeCount = NSPasteboard.general.changeCount
        notice = "已复制配对密钥，请仅传给可信设备。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
        }
    }
}
