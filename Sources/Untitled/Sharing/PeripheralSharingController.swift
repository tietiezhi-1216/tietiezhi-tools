import AppKit
import AVFoundation
import Carbon
import Combine
import Foundation
import Network
@preconcurrency import ApplicationServices

@MainActor final class PeripheralSharingController: ObservableObject {
    static let pluginID = "app.untitled.peripheral-sharing"
    enum ControlState: String { case local = "本机", requesting = "等待对端", controlling = "控制远端", receiving = "由远端控制" }
    @Published private(set) var isRunning = false
    @Published private(set) var peers: [SharingTransport.Peer] = []
    @Published private(set) var peerName: String?
    @Published private(set) var control: ControlState = .local
    @Published private(set) var keyboardMouseEnabled = false
    @Published private(set) var microphoneOffered = false
    @Published private(set) var wantsRemoteMicrophone = false
    @Published private(set) var isSendingMicrophone = false
    @Published private(set) var isReceivingMicrophone = false
    @Published private(set) var remoteMicrophoneAvailable = false
    @Published private(set) var audioDevices: [SharingAudioDevice] = []
    @Published var status = "未启动；安装或启用插件不会自动监听网络。"
    @Published var microphoneStatus = "麦克风共享已关闭"
    @Published var edge: SharingEdge { didSet { defaults.set(edge.rawValue, forKey: "sharing.edge"); input.edge = edge } }
    @Published var edgeSwitching: Bool { didSet { defaults.set(edgeSwitching, forKey: "sharing.edgeSwitching"); input.edgeSwitching = edgeSwitching } }
    @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: "sharing.microphoneUID"); stopCapture(); captureAttempted = false } }
    var requirePermissions: (Set<HostPermissionID>) throws -> Void = { _ in throw PluginError.invalid("请先启用外设共享插件。") }
    var isAllowed: () -> Bool = { false }
    var reportError: (Error) -> Void = { _ in }
    let transport = SharingTransport()
    #if DEBUG
    var acceptanceAllowsInput: (() -> Bool)?
    var acceptanceMicrophoneStatistics: [String: Any] { capture.mailbox.statistics() }
    var acceptanceInputStatistics: [String: Any] {
        ["appliedPackets": input.appliedPacketCount, "replayedEvents": input.replayedEventCount,
         "postEventAccess": CGPreflightPostEventAccess()]
    }
    #endif
    private(set) var sentAudioFrames = 0
    private(set) var receivedAudioFrames = 0
    private let input = SharingInput()
    private let capture = SharingMicrophoneCapture()
    private let sink = SharingMicrophoneSink()
    private let defaults: UserDefaults
    private let deviceID: String
    private var timer: Timer?
    private var observers: [AnyCancellable] = []
    private var lastReceived = Date()
    private var lastTick = Date.distantPast
    private var pendingSince: Date?
    private var controlGranted = false
    private var demandSent = false
    private var peerDemand = false
    private var captureAttempted = false
    private var lastMicrophonePacket = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        edge = SharingEdge(rawValue: defaults.string(forKey: "sharing.edge") ?? "right") ?? .right
        edgeSwitching = defaults.object(forKey: "sharing.edgeSwitching") as? Bool ?? true
        microphoneUID = defaults.string(forKey: "sharing.microphoneUID") ?? ""
        deviceID = defaults.string(forKey: "sharing.deviceID") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "sharing.deviceID")
        input.edge = edge; input.edgeSwitching = edgeSwitching
        input.send = { [weak self] packet in self?.transport.send(.init(kind: .input, input: packet)) }
        input.requestControl = { [weak self] fraction in self?.requestControl(fraction: fraction) }
        input.returnLocal = { [weak self] in self?.returnToLocal() }
        input.physicalStateChanged = { [weak self] in
            // Finish delivery of the local key/button-up before changing the tap's routing.
            DispatchQueue.main.async { [weak self] in self?.activateControlWhenNeutral() }
        }
        transport.peersChanged = { [weak self] in self?.peers = $0 }
        transport.listening = { [weak self] port in self?.status = "正在监听 TCP \(port)；可自动发现同网段设备，或按 IP / VPN 地址连接。" }
        transport.failed = { [weak self] in self?.stop(reason: $0) }
        transport.connected = { [weak self] in
            guard let self else { return }
            self.lastReceived = Date(); self.status = "已加密连接，正在确认对端…"
            self.transport.send(.init(kind: .hello, version: 1, deviceID: self.deviceID, name: String((Host.current().localizedName ?? "Mac").prefix(80))))
        }
        transport.received = { [weak self] in self?.receive($0) }
        transport.disconnected = { [weak self] reason in
            guard let self else { return }
            self.clearSession()
            self.status = reason ?? (self.isRunning ? "已断开，等待手动连接" : "已停止")
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.stop(reason: "设备睡眠或会话已锁定，共享已停止。") }
            })
        }
        observers.append(DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked")).sink { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "锁屏后共享已停止；解锁后请手动启动。") }
        })
    }
    var hasDriver: Bool { SharingAudioDevices.device(SharingAudioDevices.inputUID) != nil && SharingAudioDevices.device(SharingAudioDevices.feedUID) != nil }
    var serviceName: String { "\(Host.current().localizedName ?? "Mac") · \(deviceID.prefix(6))" }
    func refreshDevices() { audioDevices = SharingAudioDevices.hardwareInputs(); objectWillChange.send() }
    func start(key: String? = nil, localOnly: Bool = false) throws {
        guard isAllowed() else { throw PluginError.invalid("请先安装并启用外设共享插件。") }
        guard !isRunning else { return }
        guard let key = key ?? SharingPairingKey.load() else { throw PluginError.invalid("请先生成配对密钥，并在另一台 Mac 中粘贴同一密钥。") }
        try transport.start(key: SharingPairingKey.decode(key), name: serviceName, localOnly: localOnly)
        isRunning = true; lastTick = .distantPast; status = "正在发现局域网设备；仅接受持有同一密钥的对端。"
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func stop(reason: String = "已停止，共享设备与网络监听均已释放。") {
        timer?.invalidate(); timer = nil
        returnToLocal(); transport.stop(); clearSession(); input.stop()
        isRunning = false; keyboardMouseEnabled = false; microphoneOffered = false; wantsRemoteMicrophone = false
        status = reason
    }
    func connect(_ peer: SharingTransport.Peer) throws {
        guard isRunning, isAllowed() else { throw PluginError.invalid("请先启动共享。") }
        try transport.connect(peer.endpoint); status = "正在认证 \(peer.name)…"
    }
    func connect(host: String, port: String) throws {
        guard isRunning, isAllowed() else { throw PluginError.invalid("请先启动共享。") }
        let endpoint = try SharingManualEndpoint.parse(host: host, port: port)
        try transport.connect(endpoint); status = "正在认证 \(host)…"
    }
    func disconnect() { returnToLocal(); transport.disconnect() }
    func setKeyboardMouse(_ value: Bool) throws {
        guard isRunning, isAllowed() else { throw PluginError.invalid("请先启动共享。") }
        if value {
            try requirePermissions([.accessibility, .inputMonitoring])
            guard !IsSecureEventInputEnabled() else { throw PluginError.invalid("系统正在安全输入模式中，请退出密码输入后重试。") }
            try input.start()
        } else { returnToLocal(); input.stop() }
        keyboardMouseEnabled = value; input.canSwitch = value && peerName != nil
    }
    func setMicrophoneOffered(_ value: Bool) {
        microphoneOffered = value; captureAttempted = false
        if !value { stopCapture() }
        updateMicrophone()
    }
    func setWantsRemoteMicrophone(_ value: Bool) {
        wantsRemoteMicrophone = value
        updateMicrophone()
    }
    func retryMicrophone() { captureAttempted = false; refreshDevices(); updateMicrophone() }
    func toggleControl() {
        if control != .local { returnToLocal() } else { requestControl(fraction: 0.5) }
    }
    private func requestControl(fraction: Double) {
        guard isRunning, isAllowed(), keyboardMouseEnabled, peerName != nil, control == .local else { return }
        do { try requirePermissions([.accessibility, .inputMonitoring]) }
        catch { reportError(error); return }
        control = .requesting; pendingSince = Date(); controlGranted = false; input.canSwitch = false
        transport.send(.init(kind: .begin, edge: edge, position: fraction))
    }
    func returnToLocal() {
        if control != .local { transport.send(.init(kind: .end)) }
        input.reset(); control = .local; pendingSince = nil; controlGranted = false
        input.canSwitch = keyboardMouseEnabled && peerName != nil
    }
    private func rejectControlRequest() {
        let wasLocal = control == .local
        returnToLocal()
        if wasLocal { transport.send(.init(kind: .end)) }
    }
    private func activateControlWhenNeutral() {
        guard control == .requesting, controlGranted, input.isNeutral, peerName != nil, keyboardMouseEnabled else { return }
        do {
            guard isRunning, isAllowed(), !IsSecureEventInputEnabled() else { throw PluginError.invalid("共享已停止或系统进入安全输入模式。") }
            try requirePermissions([.accessibility, .inputMonitoring])
            control = .controlling; pendingSince = nil; controlGranted = false; input.capture()
        } catch { returnToLocal(); reportError(error) }
    }
    private func clearSession() {
        input.reset(); control = .local; pendingSince = nil; controlGranted = false; input.canSwitch = false
        peerName = nil; remoteMicrophoneAvailable = false; peerDemand = false; demandSent = false
        sentAudioFrames = 0; receivedAudioFrames = 0
        stopCapture(); sink.stop(); isReceivingMicrophone = false; captureAttempted = false
    }
    private func receive(_ message: SharingMessage) {
        guard isRunning, isAllowed() else { stop(); return }
        lastReceived = Date()
        if message.kind == .hello {
            guard peerName == nil, message.deviceID != deviceID else { disconnect(); status = "拒绝重复连接或连接到本机。"; return }
            peerName = message.name; status = "已通过密钥认证：\(message.name ?? "Mac")"
            input.canSwitch = keyboardMouseEnabled; updateMicrophone(); return
        }
        guard peerName != nil else { disconnect(); status = "对端尚未完成设备握手。"; return }
        switch message.kind {
        case .begin:
            guard keyboardMouseEnabled, control == .local, input.isNeutral, let edge = message.edge, let position = message.position else {
                rejectControlRequest(); return
            }
            do {
                try requirePermissions([.accessibility, .inputMonitoring])
                guard !IsSecureEventInputEnabled() else { rejectControlRequest(); return }
                control = .receiving; input.canSwitch = false; input.receive(edge: edge, fraction: position)
                transport.send(.init(kind: .accepted))
            } catch { rejectControlRequest(); reportError(error) }
        case .accepted:
            guard control == .requesting else { rejectControlRequest(); return }
            controlGranted = true; activateControlWhenNeutral()
        case .end:
            input.reset(); control = .local; pendingSince = nil; controlGranted = false; input.canSwitch = keyboardMouseEnabled
        case .input:
            #if DEBUG
            if control == .receiving, let gate = acceptanceAllowsInput, !gate() { returnToLocal(); return }
            #endif
            if control == .receiving, keyboardMouseEnabled, let packet = message.input { input.apply(packet) }
        case .micDemand:
            let demand = message.enabled == true
            if demand != peerDemand { peerDemand = demand; captureAttempted = false; updateMicrophone() }
        case .micState:
            remoteMicrophoneAvailable = message.enabled == true
            if !remoteMicrophoneAvailable { sink.stop(); isReceivingMicrophone = false }
        case .audio:
            guard wantsRemoteMicrophone, demandSent, remoteMicrophoneAvailable, let data = message.audio else { return }
            if !sink.isRunning {
                do { try sink.start() } catch { microphoneStatus = error.localizedDescription; setWantsRemoteMicrophone(false); return }
            }
            sink.append(data); receivedAudioFrames += data.count / 4
            if isReceivingMicrophone != sink.isRunning { isReceivingMicrophone = sink.isRunning }
        default: break
        }
    }
    private func stopCapture() {
        let wasSending = isSendingMicrophone
        capture.stop(); isSendingMicrophone = false
        if wasSending { transport.send(.init(kind: .micState, enabled: false)) }
    }
    private func updateMicrophone() {
        guard isRunning, peerName != nil else { return }
        let demand = wantsRemoteMicrophone && hasDriver && SharingAudioDevices.isInUse
        if demand != demandSent {
            demandSent = demand; transport.send(.init(kind: .micDemand, enabled: demand))
            if !demand { sink.stop(); isReceivingMicrophone = false }
        }
        if wantsRemoteMicrophone && !hasDriver { microphoneStatus = "接收端尚未安装虚拟麦克风驱动" }
        else if wantsRemoteMicrophone && !demand { microphoneStatus = "等待应用使用 Untitled Microphone 输入" }
        if microphoneOffered && peerDemand {
            if !capture.isRunning && !captureAttempted {
                captureAttempted = true
                do {
                    try requirePermissions([.microphone])
                    try capture.start(uid: microphoneUID); isSendingMicrophone = true
                    lastMicrophonePacket = Date()
                    transport.send(.init(kind: .micState, enabled: true)); microphoneStatus = "正在将实体麦克风同步给对端"
                } catch {
                    stopCapture(); transport.send(.init(kind: .micState, enabled: false))
                    microphoneStatus = error.localizedDescription; reportError(error)
                }
            }
        } else {
            stopCapture(); captureAttempted = false
            if !wantsRemoteMicrophone { microphoneStatus = microphoneOffered ? "允许共享；等待对端应用使用" : "麦克风共享已关闭" }
        }
        if isReceivingMicrophone { microphoneStatus = "远端声音 → Untitled Microphone（不会播放到扬声器）" }
    }
    private func tick() {
        guard isRunning else { return }
        guard isAllowed() else { stop(reason: "插件已停用，共享已释放。"); return }
        if isSendingMicrophone {
            let packets = capture.mailbox.drain()
            if !packets.isEmpty { lastMicrophonePacket = Date() }
            for packet in packets {
                transport.send(.init(kind: .audio, audio: packet)); sentAudioFrames += packet.count / 4
            }
            if Date().timeIntervalSince(lastMicrophonePacket) > 2 {
                stopCapture(); captureAttempted = true
                microphoneStatus = "麦克风启动后未收到音频帧，已停止采集；请检查设备后重试。"
            }
        }
        if let pendingSince, Date().timeIntervalSince(pendingSince) > 2 { returnToLocal(); status = "对端未启用键鼠或切换超时，已返回本机。" }
        guard Date().timeIntervalSince(lastTick) >= 1 else { return }
        lastTick = Date()
        if transport.isConnected {
            if Date().timeIntervalSince(lastReceived) > 5 { disconnect(); status = "连接超时，已释放键鼠和麦克风。"; return }
            transport.send(.init(kind: .ping))
        }
        if keyboardMouseEnabled && (!AXIsProcessTrusted() || !CGPreflightListenEventAccess() || IsSecureEventInputEnabled()) {
            returnToLocal(); input.stop(); keyboardMouseEnabled = false; status = "输入权限被撤销或进入安全输入模式，键鼠共享已暂停。"
        }
        if isSendingMicrophone && (AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !capture.isRunning || SharingAudioDevices.device(capture.deviceUID ?? "") == nil) {
            stopCapture(); captureAttempted = true; microphoneStatus = "麦克风不可用；请检查权限或设备后点击重试。"
        }
        if sink.isRunning && !sink.isRoutingToFeed { sink.stop(); isReceivingMicrophone = false; wantsRemoteMicrophone = false; microphoneStatus = "音频路由变化，已安全停止接收。" }
        updateMicrophone()
    }
}
