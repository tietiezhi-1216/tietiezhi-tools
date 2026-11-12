#if DEBUG
// Explicit, temporary acceptance-test instrumentation. Not compiled into release builds.
// Never grants OS permissions, invokes installers, or stores recorded audio.
@preconcurrency import AVFoundation
import AppKit
import AudioToolbox
import Foundation

struct SharingAcceptanceRequest: Decodable {
    enum Action: String, Decodable {
        case start, connect, keyboard, offerMicrophone, receiveMicrophone
        case switchControl, returnLocal, testWindow, input, probe, stopProbe, savePairingKey, stop
    }
    let id: UUID
    let action: Action
    var enabled: Bool?
    var host: String?
    var port: String?
    var microphoneUID: String?
    var packets: [SharingInputPacket]?
}

@MainActor final class SharingAcceptance {
    private weak var store: PluginStore?
    private let controller: PeripheralSharingController
    private let directory: URL
    private var timer: Timer?
    private let expires = Date().addingTimeInterval(600)
    private var lastCommand: UUID?
    private var lastError: String?
    private var window: NSWindow?
    private var target: SharingAcceptanceTarget?
    private let probe = SharingAcceptanceProbe()
    private var controlDeadline: Date?
    private var microphoneDeadline: Date?
    private var probeDeadline: Date?
    private var previousControl = PeripheralSharingController.ControlState.local
    private var lastReport = Date.distantPast

    static func pluginDirectoryForLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--sharing-acceptance") else { return nil }
        do {
            guard arguments.indices.contains(index + 1) else { throw PluginError.invalid("缺少验收目录。") }
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try validateDirectory(directory, caches: caches)
            let plugins = directory.appendingPathComponent("Plugins", isDirectory: true)
            if !FileManager.default.fileExists(atPath: plugins.path) {
                try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try validateOwnedFile(plugins, directory: true)
            return plugins
        } catch {
            // A malformed debug invocation must not fall back to loading the user's regular plugins/hotkeys.
            FileHandle.standardError.write(Data("Invalid private sharing acceptance directory.\n".utf8))
            exit(64)
        }
    }
    static func validateDirectory(_ directory: URL, caches: URL) throws {
        let root = caches.appendingPathComponent("com.tietiezhi.tools/SharingAcceptance", isDirectory: true).standardizedFileURL
        let url = directory.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path else {
            throw PluginError.invalid("验收目录必须是本应用缓存下的独立目录，且不能包含符号链接。")
        }
        try validateOwnedFile(url, directory: true)
    }
    static func validateOwnedFile(_ url: URL, directory: Bool = false) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attrs[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw PluginError.invalid("验收目录/文件必须由当前用户拥有，且不允许组或其他用户访问。")
        }
    }
    init(store: PluginStore, directory: URL) throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try Self.validateDirectory(directory, caches: caches)
        self.directory = directory.standardizedFileURL
        self.store = store
        controller = store.peripheralSharing(for: PeripheralSharingController.pluginID)
        controller.acceptanceAllowsInput = { [weak self] in
            guard let self, let window = self.window else { return false }
            return window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        try report()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        controller.stop(); probe.stop()
        window?.close(); window = nil
        try? report()
    }
    private func pairingKey() throws -> String {
        let url = directory.appendingPathComponent("pairing-key")
        try Self.validateOwnedFile(url)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128 else {
            throw PluginError.invalid("验收配对文件大小无效。")
        }
        let key = try String(contentsOf: url, encoding: .utf8)
        _ = try SharingPairingKey.decode(key)
        return key
    }
    private func execute(_ request: SharingAcceptanceRequest) throws {
        guard let store else { throw PluginError.invalid("宿主已关闭。") }
        switch request.action {
        case .start: try controller.start(key: pairingKey())
        case .connect: try controller.connect(host: request.host ?? "", port: request.port ?? String(SharingTransport.defaultPort))
        case .keyboard: try controller.setKeyboardMouse(request.enabled == true)
        case .offerMicrophone:
            if let uid = request.microphoneUID { controller.microphoneUID = uid }
            controller.setMicrophoneOffered(request.enabled == true)
        case .receiveMicrophone: controller.setWantsRemoteMicrophone(request.enabled == true)
        case .switchControl:
            controlDeadline = Date().addingTimeInterval(4)
            controller.toggleControl()
        case .returnLocal: controller.returnToLocal()
        case .testWindow: showTarget()
        case .input:
            guard controller.control == .controlling, let packets = request.packets, packets.count <= 40 else {
                throw PluginError.invalid("仅已获双方允许的限时控制会话可发送验收输入，最多 40 个事件。")
            }
            for packet in packets { try packet.validate() }
            for packet in packets { controller.transport.send(.init(kind: .input, input: packet)) }
        case .probe:
            try store.permissionClient(for: PeripheralSharingController.pluginID).require([.microphone])
            try probe.start()
            probeDeadline = Date().addingTimeInterval(5)
        case .stopProbe: probe.stop(); probeDeadline = nil
        case .savePairingKey: try SharingPairingKey.save(pairingKey())
        case .stop:
            controller.stop(); probe.stop(); controlDeadline = nil; probeDeadline = nil
        }
    }
    private func tick() {
        guard Date() < expires else { stop(); return }
        if controller.control != .local && previousControl == .local && controlDeadline == nil {
            controlDeadline = Date().addingTimeInterval(5)
        }
        previousControl = controller.control
        if let controlDeadline, Date() >= controlDeadline { controller.returnToLocal(); self.controlDeadline = nil }
        if controller.isSendingMicrophone && microphoneDeadline == nil { microphoneDeadline = Date().addingTimeInterval(5) }
        if let microphoneDeadline, Date() >= microphoneDeadline { controller.setMicrophoneOffered(false); self.microphoneDeadline = nil }
        if let probeDeadline, Date() >= probeDeadline { probe.stop(); self.probeDeadline = nil }
        let commandURL = directory.appendingPathComponent("command.json")
        if FileManager.default.fileExists(atPath: commandURL.path) {
            do {
                try Self.validateOwnedFile(commandURL)
                guard let size = try commandURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536 else {
                    throw PluginError.invalid("验收请求过大。")
                }
                let request = try JSONDecoder().decode(SharingAcceptanceRequest.self, from: Data(contentsOf: commandURL))
                if request.id != lastCommand {
                    lastCommand = request.id; lastError = nil
                    do { try execute(request) }
                    catch { lastError = error.localizedDescription; store?.handleExecutionError(error) }
                }
            } catch { lastError = error.localizedDescription }
        }
        if Date().timeIntervalSince(lastReport) >= 0.5 {
            lastReport = Date(); try? report()
        }
    }
    private func showTarget() {
        if let window { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        let frame = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: .init(x: frame.midX - 210, y: frame.midY - 130, width: 420, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tietiezhi · 限时外设验收（不保存输入或声音）"
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        let target = SharingAcceptanceTarget()
        window.contentView = target; window.makeFirstResponder(target)
        self.target = target; self.window = window
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        window.initialFirstResponder = target
        window.makeFirstResponder(target)
    }
    private func report() throws {
        store?.permissions.refresh()
        var permissions: [String: String] = [:]
        for driver in store?.permissions.drivers ?? [] {
            permissions[driver.descriptor.id.rawValue] = store?.permissions.status(driver.descriptor.id).title
        }
        var value: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updatedAt": Date().timeIntervalSince1970,
            "expiresAt": expires.timeIntervalSince1970,
            "lastCommand": lastCommand?.uuidString ?? "",
            "error": lastError ?? "",
            "running": controller.isRunning,
            "port": Int(controller.transport.port?.rawValue ?? 0),
            "peer": controller.peerName ?? "",
            "control": controller.control.rawValue,
            "keyboardEnabled": controller.keyboardMouseEnabled,
            "inputStatistics": controller.acceptanceInputStatistics,
            "microphoneOffered": controller.microphoneOffered,
            "microphoneInputStatistics": controller.acceptanceMicrophoneStatistics,
            "remoteMicrophoneEnabled": controller.wantsRemoteMicrophone,
            "sendingMicrophone": controller.isSendingMicrophone,
            "receivingMicrophone": controller.isReceivingMicrophone,
            "sentAudioFrames": controller.sentAudioFrames,
            "receivedAudioFrames": controller.receivedAudioFrames,
            "driverAvailable": controller.hasDriver,
            "virtualInputInUse": SharingAudioDevices.isInUse,
            "permissions": permissions,
            "status": controller.status,
            "microphoneStatus": controller.microphoneStatus,
            "probe": probe.levels.snapshot(),
            "hardwareInputs": SharingAudioDevices.hardwareInputs().map { ["uid": $0.id, "name": $0.name] },
            "pluginInstalled": store?.installed.contains(where: { $0.id == PeripheralSharingController.pluginID && $0.isEnabled }) == true,
        ]
        if let window, let target {
            let point = window.convertPoint(toScreen: .init(x: target.bounds.midX, y: target.bounds.midY))
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            value["target"] = ["x": point.x, "y": top - point.y, "keyDownCodes": target.keyDownCodes,
                               "keyUpCodes": target.keyUpCodes, "mouseDowns": target.mouseDowns, "mouseUps": target.mouseUps,
                               "unmarkedKeys": target.unmarkedKeys,
                               "targetFocused": window.firstResponder === target,
                               "responder": String(describing: type(of: window.firstResponder as Any)),
                               "isKey": window.isKeyWindow, "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier]
        }
        if let cursor = CGEvent(source: nil)?.location { value["cursor"] = ["x": cursor.x, "y": cursor.y] }
        let destination = directory.appendingPathComponent("status.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

@MainActor private final class SharingAcceptanceTarget: NSView {
    private(set) var keyDownCodes: [UInt16] = []
    private(set) var keyUpCodes: [UInt16] = []
    private(set) var mouseDowns = 0
    private(set) var mouseUps = 0
    private(set) var unmarkedKeys = 0
    override var acceptsFirstResponder: Bool { true }
    private func isTest(_ event: NSEvent) -> Bool { event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SharingInput.replayMarker }
    override func keyDown(with event: NSEvent) {
        if isTest(event), keyDownCodes.count < 40 { keyDownCodes.append(event.keyCode); needsDisplay = true }
        else { unmarkedKeys += 1 }
    }
    override func keyUp(with event: NSEvent) { if isTest(event), keyUpCodes.count < 40 { keyUpCodes.append(event.keyCode) } }
    override func mouseDown(with event: NSEvent) {
        if isTest(event) { window?.makeFirstResponder(self); mouseDowns += 1; needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) { if isTest(event) { mouseUps += 1 } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let message = "外设共享自动验收窗口\n仅统计带验收标记的固定按键和点击\n按键：\(keyDownCodes.count)   点击：\(mouseDowns)\n不记录普通用户输入，不保存声音"
        (message as NSString).draw(in: bounds.insetBy(dx: 24, dy: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
    }
}

private final class SharingAcceptanceLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var sumSquares = 0.0
    private var peak = 0.0
    func reset() { lock.lock(); defer { lock.unlock() }; count = 0; sumSquares = 0; peak = 0 }
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        var squares = 0.0, maximum = 0.0
        for index in 0..<Int(buffer.frameLength) {
            let value = Double(samples[index]); if !value.isFinite { continue }
            squares += value * value; maximum = max(maximum, abs(value))
        }
        lock.lock(); count += Int(buffer.frameLength); sumSquares += squares; peak = max(peak, maximum); lock.unlock()
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["frames": count, "rms": count == 0 ? 0 : sqrt(sumSquares / Double(count)), "peak": peak]
    }
}

@MainActor private final class SharingAcceptanceProbe {
    let levels = SharingAcceptanceLevels()
    private var engine: AVAudioEngine?
    func start() throws {
        stop(); levels.reset()
        guard let device = SharingAudioDevices.device(SharingAudioDevices.inputUID) else { throw PluginError.invalid("虚拟麦克风尚未由系统加载。") }
        let engine = AVAudioEngine()
        guard let unit = engine.inputNode.audioUnit else { throw PluginError.invalid("无法创建虚拟输入探针。") }
        var id = device.objectID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw PluginError.invalid("无法选择虚拟输入；探针不会回退到实体麦克风。")
        }
        let format = engine.inputNode.outputFormat(forBus: 0), levels = self.levels
        guard format.channelCount > 0, format.sampleRate > 0 else { throw PluginError.invalid("虚拟输入格式不可用。") }
        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in levels.consume(buffer) }
        do { try engine.start() }
        catch { engine.inputNode.removeTap(onBus: 0); engine.stop(); throw error }
        var current: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr, current == id else {
            engine.inputNode.removeTap(onBus: 0); engine.stop(); throw PluginError.invalid("虚拟输入探针路由校验失败。")
        }
        self.engine = engine
    }
    func stop() {
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
    }
}
#endif
