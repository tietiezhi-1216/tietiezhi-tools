import AppKit
import SwiftUI

struct SharingPluginView: View {
    @ObservedObject var controller: PeripheralSharingController
    @EnvironmentObject private var store: PluginStore
    var keyAvailable: () -> Bool = { SharingPairingKey.load() != nil }
    @ViewState private var hasKey = false
    @ViewState private var showSettings = false
    @ViewState private var editingKey = false
    @ViewState private var replaceKey = false
    @ViewState private var unpair = false
    @ViewState private var keyDraft = ""
    @ViewState private var notice = ""
    @ViewState private var manualHost = UserDefaults.standard.string(forKey: "sharing.lastPeerHost") ?? ""
    private let manualPort = UserDefaults.standard.string(forKey: "sharing.lastPeerPort") ?? String(SharingTransport.defaultPort)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                SharingLayoutEditor(
                    localName: Host.current().localizedName ?? "这台 Mac",
                    remoteName: controller.peerName ?? controller.rememberedPeerName ?? "另一台 Mac",
                    peerOffset: Binding(get: { controller.layoutOffset }, set: { controller.setLayoutOffset($0) }),
                    localAspect: controller.localAspect, peerAspect: controller.peerAspect,
                    localPixels: controller.localPixels, peerPixels: controller.peerPixels,
                    isConnected: controller.peerName != nil, canEdit: controller.control == .local,
                    controllingRemote: controller.control == .controlling)
                    .help("拖动设备自由排列；拖动画布平移，双指缩放")
                if let inputStatus = controller.inputStatus {
                    Text(inputStatus).font(.caption).foregroundStyle(.orange)
                } else if controller.peerKeyboardMouseEnabled == false {
                    Text("对端键鼠共享已暂停，请在那台 Mac 重新开启“共享”。").font(.caption).foregroundStyle(.orange)
                }
            }.padding(.bottom, 12)
        }
        .onAppear { hasKey = keyAvailable() }
        .sheet(isPresented: $showSettings) { connectionSettings }
        .confirmationDialog("更换配对码？另一台 Mac 也需要更新。", isPresented: $replaceKey) {
            Button("生成新配对码", role: .destructive) { generateKey() }
        }
        .confirmationDialog("解除本机配对？", isPresented: $unpair) {
            Button("解除配对", role: .destructive) {
                run { controller.stopUserSession(); try SharingPairingKey.delete(); hasKey = false; keyDraft = ""; notice = "已解除配对。" }
            }
        }
        .panelRegion("sharing.dashboard")
    }
    private var header: some View {
        HStack(spacing: 12) {
            Label(controller.isRunning && !controller.keyboardMouseEnabled ? "本机已暂停" : (controller.peerKeyboardMouseEnabled == false ? "对端已暂停" : (controller.peerName != nil ? "已连接" : (controller.isRunning ? "等待连接" : "未连接"))), systemImage: "circle.fill")
                .font(.callout).foregroundStyle(controller.isRunning && (!controller.keyboardMouseEnabled || controller.peerKeyboardMouseEnabled == false) ? Color.orange : (controller.peerName != nil ? .green : .secondary))
            Spacer()
            if !hasKey { Button("配对设备") { showSettings = true }.buttonStyle(.borderedProminent) }
            Toggle("共享", isOn: Binding(get: { controller.isRunning && controller.keyboardMouseEnabled }, set: { enabled in
                run { if enabled { try controller.startUserSession() } else { controller.stopUserSession() } }
            })).toggleStyle(.switch).disabled(!hasKey)
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .help("连接设备").accessibilityLabel("连接设备")
        }.panelRegion("sharing.layout.header")
    }
    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("连接设备").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { showSettings = false }.keyboardShortcut(.defaultAction)
            }
            if let name = controller.peerName {
                HStack { Label(name, systemImage: "desktopcomputer").lineLimit(1); Spacer(); Button("断开") { controller.disconnect() } }
            } else {
                HStack {
                    TextField("对端地址", text: $manualHost).textFieldStyle(.roundedBorder)
                    Button("连接") { run { try controller.connectUserSelected(host: manualHost, port: manualPort); showSettings = false } }
                        .disabled(!hasKey || manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !controller.peers.isEmpty {
                    ForEach(controller.peers) { peer in
                        HStack {
                            Label(peer.name, systemImage: "desktopcomputer").lineLimit(1)
                            Spacer()
                            Button("连接") { run { try controller.connect(peer); showSettings = false } }.disabled(!controller.isRunning)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Label(hasKey ? "已配对" : "设备配对", systemImage: "key")
                Spacer()
                if hasKey {
                    Menu {
                        Button("复制配对码") { copyKey() }
                        Button("输入其他配对码") { editingKey.toggle() }.disabled(controller.isRunning)
                        Button("生成新配对码") { replaceKey = true }.disabled(controller.isRunning)
                        Button("解除配对", role: .destructive) { unpair = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                }
            }
            if !hasKey || editingKey {
                HStack {
                    SecureField("粘贴配对码", text: $keyDraft).textFieldStyle(.roundedBorder)
                    Button("保存") { run { try SharingPairingKey.save(keyDraft); keyDraft = ""; hasKey = true; editingKey = false; notice = "已配对。" } }
                        .disabled(keyDraft.isEmpty || controller.isRunning)
                }.disabled(controller.isRunning)
                if !hasKey { Button("生成配对码") { generateKey() }.disabled(controller.isRunning) }
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 460)
    }
    private func run(_ body: () throws -> Void) { do { try body() } catch { store.handleExecutionError(error) } }
    private func generateKey() {
        run { try SharingPairingKey.save(SharingPairingKey.generate()); hasKey = true; notice = "复制配对码，在另一台 Mac 保存即可。" }
    }
    private func copyKey() {
        guard let key = SharingPairingKey.load() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
        let changeCount = NSPasteboard.general.changeCount
        notice = "已复制，仅分享给可信设备。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
        }
    }
}
