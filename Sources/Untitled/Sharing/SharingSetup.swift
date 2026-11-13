import AppKit
import CryptoKit
import Foundation

struct SharingSetupProfile: Decodable {
    let version: Int
    let pairingKey: String
    let peerName: String
    var peerHost: String?
    var peerPort: String?
    let edge: SharingEdge

    func validate() throws {
        guard version == 1, !peerName.isEmpty, peerName.count <= 80 else { throw PluginError.invalid("设备配对配置无效。") }
        _ = try SharingPairingKey.decode(pairingKey)
        if let peerHost, !peerHost.isEmpty { _ = try SharingManualEndpoint.parse(host: peerHost, port: peerPort ?? String(SharingTransport.defaultPort)) }
    }
    var fingerprint: String {
        guard let key = try? SharingPairingKey.decode(pairingKey) else { return "" }
        return SHA256.hash(data: key).prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// One-shot, visible setup. No control inbox, no microphone actions and no permission grants.
/// A private setup file only takes effect after a human approves the in-app confirmation.
@MainActor final class SharingSetupSession {
    private weak var store: PluginStore?
    private let controller: PeripheralSharingController
    private let directory: URL
    private var timer: Timer?
    private var phase = "awaiting-confirmation"
    private var setupError = ""
    private var peerHost: String?
    private var peerPort = String(SharingTransport.defaultPort)
    private var peerName = ""
    private var lastAttempt = Date.distantPast
    private var connectDeadline = Date.distantPast
    private var hasConnected = false

    static func readProfile(_ url: URL, caches: URL) throws -> SharingSetupProfile {
        let root = caches.appendingPathComponent("com.untitled.app/SharingSetup", isDirectory: true).standardizedFileURL
        let directory = url.deletingLastPathComponent().standardizedFileURL
        guard directory.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw PluginError.invalid("配对配置必须来自本应用的独立私有缓存目录。")
        }
        for (path, type) in [(directory, FileAttributeType.typeDirectory), (url, .typeRegular)] {
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attrs[.type] as? FileAttributeType == type,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let permissions = attrs[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0 else {
                throw PluginError.invalid("配对配置及目录必须归当前用户所有，且不允许其他用户访问。")
            }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw PluginError.invalid("配对配置过大。") }
        let profile = try JSONDecoder().decode(SharingSetupProfile.self, from: data)
        try profile.validate()
        return profile
    }
    init(store: PluginStore, profileURL: URL) throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let profile = try Self.readProfile(profileURL, caches: caches)
        self.store = store
        directory = profileURL.deletingLastPathComponent()
        controller = store.peripheralSharing(for: PeripheralSharingController.pluginID)
        peerName = profile.peerName; peerHost = profile.peerHost; peerPort = profile.peerPort ?? peerPort
        try report()
    }
    func confirmAndStart(profileURL: URL) throws {
        guard let store else { return }
        let profile = try Self.readProfile(profileURL, caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
        defer { try? FileManager.default.removeItem(at: profileURL) }
        let alert = NSAlert()
        alert.messageText = "配置与“\(profile.peerName)”的键鼠共享？"
        alert.informativeText = "两台设备的校验码应相同：\n\(profile.fingerprint)\n\n允许后会保存本次配对密钥（如已有则替换），启动本次共享会话并检查键鼠权限。不会启动麦克风、安装驱动或设置登录启动。可随时从插件停止，⌃⌥⌘Esc 返回本机。"
        alert.addButton(withTitle: "允许并启动")
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { phase = "cancelled"; try report(); return }
        guard store.installed.contains(where: { $0.id == PeripheralSharingController.pluginID }) else {
            throw PluginError.invalid("请先安装外设共享插件。")
        }
        try SharingPairingKey.save(profile.pairingKey)
        store.setEnabled(true, pluginID: PeripheralSharingController.pluginID)
        controller.edge = profile.edge
        UserDefaults.standard.set(profile.peerName, forKey: "sharing.lastPeerName")
        UserDefaults.standard.set(true, forKey: "sharing.inputDesired")
        UserDefaults.standard.set(profile.peerHost ?? "", forKey: "sharing.lastPeerHost")
        UserDefaults.standard.set(peerPort, forKey: "sharing.lastPeerPort")
        store.requestedPluginID = PeripheralSharingController.pluginID
        phase = "starting"
        do { try controller.startUserSession() }
        catch { setupError = error.localizedDescription; store.handleExecutionError(error) }
        connectDeadline = Date().addingTimeInterval(120)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        try report()
    }
    func stopReporting() { timer?.invalidate(); timer = nil }
    private func tick() {
        if controller.peerName != nil { hasConnected = true; phase = controller.keyboardMouseEnabled ? "ready" : "connected-needs-input-permission" }
        else if controller.isRunning { phase = "waiting-for-peer" }
        else { phase = "stopped" }
        // Only one side dials, and only during this explicitly requested startup.
        // Never resume automatically after sleep/lock/disconnect.
        if !hasConnected, controller.isRunning, controller.transport.port != nil,
           let peerHost, !peerHost.isEmpty, Date() < connectDeadline, Date().timeIntervalSince(lastAttempt) > 4 {
            lastAttempt = Date()
            do { try controller.connect(host: peerHost, port: peerPort) } catch { /* Native status explains waiting/failure. */ }
        }
        try? report()
    }
    private func report() throws {
        store?.permissions.refresh()
        var permissions: [String: String] = [:]
        for driver in store?.permissions.drivers ?? [] { permissions[driver.descriptor.id.rawValue] = store?.permissions.status(driver.descriptor.id).title }
        let value: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier, "appPath": Bundle.main.bundleURL.path,
            "updatedAt": Date().timeIntervalSince1970, "phase": phase, "error": setupError,
            "configuredPeer": peerName, "peer": controller.peerName ?? "", "port": Int(controller.transport.port?.rawValue ?? 0),
            "running": controller.isRunning, "keyboardEnabled": controller.keyboardMouseEnabled,
            "control": controller.control.rawValue, "edge": controller.edge.rawValue,
            "sentInputPackets": controller.sentInputPackets, "receivedInputPackets": controller.receivedInputPackets,
            "permissions": permissions, "postEventAccess": CGPreflightPostEventAccess(),
            "status": controller.status, "microphoneOffered": controller.microphoneOffered,
            "sendingMicrophone": controller.isSendingMicrophone,
            "pluginInstalled": store?.installed.contains(where: { $0.id == PeripheralSharingController.pluginID && $0.isEnabled }) == true,
        ]
        let url = directory.appendingPathComponent("status.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
