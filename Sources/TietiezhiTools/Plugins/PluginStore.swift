import AppKit
import Combine
import Foundation

@MainActor
final class PluginStore: ObservableObject {
    @Published private(set) var installed: [InstalledPlugin] = []
    @Published private(set) var catalog: [CatalogEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isInstalling = false
    @Published private(set) var catalogError: String?
    @Published private(set) var hotKeyErrors: [UUID: String] = [:]
    @Published private(set) var captureHotKeysPaused = false
    @Published var errorMessage: String?
    @Published var requestedPluginID: String?
    var showMainWindow: () -> Void = {}
    private let captureDirectory: URL?
    private var captureController: ScreenshotController?
    private var sharingControllers: [String: PeripheralSharingController] = [:]
    #if DEBUG
    private var sharingAcceptance: SharingAcceptance?
    func startSharingAcceptance(at directory: URL) throws {
        guard sharingAcceptance == nil else { return }
        sharingAcceptance = try SharingAcceptance(store: self, directory: directory)
    }
    #endif
    func peripheralSharing(for pluginID: String) -> PeripheralSharingController {
        if let controller = sharingControllers[pluginID] { return controller }
        let controller = PeripheralSharingController()
        controller.isAllowed = { [weak self] in
            self?.installed.contains(where: { $0.id == pluginID && $0.isEnabled && $0.manifest.actions.contains(.sharePeripherals) }) == true
        }
        controller.requirePermissions = { [weak self] ids in
            guard let self else { throw PluginError.invalid("宿主已关闭。") }
            try self.permissionClient(for: pluginID).require(ids)
        }
        controller.reportError = { [weak self] in self?.handleExecutionError($0) }
        sharingControllers[pluginID] = controller
        return controller
    }
    let uiRegistry: PluginUIRegistry
    let permissions: HostPermissionCenter
    var screenshots: ScreenshotController {
        if let captureController { return captureController }
        let controller = ScreenshotController(directory: captureDirectory)
        controller.reportError = { [weak self] in self?.errorMessage = $0 }
        if let error = controller.errorMessage { errorMessage = error }
        controller.canUseFeatures = { [weak self] in
            self?.installed.contains(where: { $0.isEnabled && $0.manifest.actions.contains(where: \.isScreenshotAction) }) == true
        }
        captureController = controller
        if let plugin = installed.first(where: { $0.isEnabled && $0.manifest.hasCaptureCapability }) {
            controller.configureGlobalMouse(permissions: permissionClient(for: plugin.id), allowed: { [weak self] in self?.captureHotKeysPaused == false && !HotKeyRecordingSession.isRecording })
        }
        controller.pinManager.activate()
        return controller
    }
    func prepareForQuit() async -> Bool {
        #if DEBUG
        sharingAcceptance?.stop(); sharingAcceptance = nil
        #endif
        for controller in sharingControllers.values { controller.stop() }
        let ready = await captureController?.prepareForQuit() ?? true
        if !ready { reloadHotKeys() }
        return ready
    }

    private let directory: URL
    private let hotKeys = HotKeyManager()
    private var recordingObserver: AnyCancellable?

    init(directory: URL? = nil, captureDirectory: URL? = nil, uiRegistry: PluginUIRegistry? = nil, permissions: HostPermissionCenter? = nil) {
        self.captureDirectory = captureDirectory
        self.uiRegistry = uiRegistry ?? PluginComposition.makeUIRegistry()
        self.permissions = permissions ?? PluginComposition.makePermissionCenter()
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tietiezhi.tools/Plugins", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let record = try JSONDecoder().decode(InstalledPlugin.self, from: Data(contentsOf: file))
                    try record.manifest.validate()
                    try self.uiRegistry.validate(record.manifest)
                    try self.permissions.validate(record.manifest)
                    guard file.lastPathComponent == record.id + ".json",
                          Set(record.commands.map(\.id)).count == record.commands.count else {
                        throw PluginError.invalid("插件配置标识不一致。")
                    }
                    for command in record.commands where command.isEnabled {
                        try command.validate(allowedActions: record.manifest.actions)
                    }
                    installed.append(record)
                } catch {
                    errorMessage = "部分插件配置无法读取，原文件已保留：\(file.lastPathComponent)\n\(error.localizedDescription)"
                }
            }
            reloadHotKeys()
        } catch { errorMessage = "无法读取插件目录：\(error.localizedDescription)" }
        recordingObserver = NotificationCenter.default.publisher(for: HotKeyRecordingSession.changed).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadHotKeys() }
        }
    }

    func refreshCatalog() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        catalogError = nil
        defer { isRefreshing = false }
        do {
            let data = try await Self.fetch(HostInfo.catalog, maximumBytes: 512 * 1024)
            let catalog = try JSONDecoder().decode(PluginCatalog.self, from: data)
            try catalog.validate()
            self.catalog = catalog.plugins
        } catch { catalogError = "无法加载插件商店：\(error.localizedDescription)" }
    }

    func install(_ entry: CatalogEntry) async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            try entry.validate()
            let data = try await Self.fetch(entry.downloadURL, maximumBytes: PluginArchive.maximumPackageSize)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            let manifest = try await Task.detached {
                try PluginArchive.read(temporary, expectedSHA256: entry.sha256)
            }.value
            guard manifest.id == entry.id, manifest.version == entry.version else {
                throw PluginError.invalid("插件包与商店记录不一致。")
            }
            try installManifest(manifest)
        } catch { errorMessage = "安装失败：\(error.localizedDescription)" }
    }

    func importPackage(_ url: URL) async {
        guard !isInstalling else { return }
        isInstalling = true
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            isInstalling = false
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let manifest = try await Task.detached { try PluginArchive.read(url) }.value
            try installManifest(manifest)
        } catch { errorMessage = "安装失败：\(error.localizedDescription)" }
    }

    func installManifest(_ manifest: PluginManifest) throws {
        try manifest.validate()
        try uiRegistry.validate(manifest)
        try permissions.validate(manifest)
        if var record = installed.first(where: { $0.id == manifest.id }) {
            guard Version(manifest.version)! >= Version(record.manifest.version)! else {
                throw PluginError.invalid("不能安装更早版本的插件。")
            }
            guard record.commands.allSatisfy({ manifest.actions.contains($0.action) }) else {
                throw PluginError.invalid("新版本不再支持部分已有操作，请先移除这些操作。")
            }
            sharingControllers[manifest.id]?.stop(reason: "插件升级后请手动重新启动共享。")
            record.manifest = manifest
            let conflicts = record.initializeDefaultCommands(occupiedHotKeys: occupiedHotKeys(excluding: manifest.id))
            try save(record)
            reportDefaultConflicts(conflicts)
        } else {
            var record = InstalledPlugin(manifest: manifest, commands: [])
            let conflicts = record.initializeDefaultCommands(occupiedHotKeys: occupiedHotKeys(excluding: manifest.id))
            try save(record)
            reportDefaultConflicts(conflicts)
        }
    }

    func restoreDefaultCommands(pluginID: String) throws {
        guard var record = installed.first(where: { $0.id == pluginID }) else { throw PluginError.invalid("插件已卸载。") }
        let conflicts = record.initializeDefaultCommands(occupiedHotKeys: occupiedHotKeys(excluding: pluginID), restoring: true)
        try save(record)
        reportDefaultConflicts(conflicts)
    }

    private func occupiedHotKeys(excluding pluginID: String) -> Set<String> {
        Set(installed.filter { $0.id != pluginID && $0.isEnabled }.flatMap(\.commands)
            .filter(\.isEnabled).compactMap { $0.hotKey?.identity })
    }

    private func reportDefaultConflicts(_ titles: [String]) {
        if !titles.isEmpty {
            errorMessage = "这些操作的默认快捷键已被占用，已保留原绑定；可在快捷键页重新设置：" + titles.joined(separator: "、")
        }
    }

    func setEnabled(_ enabled: Bool, pluginID: String) {
        guard var record = installed.first(where: { $0.id == pluginID }) else { return }
        record.isEnabled = enabled
        do { try save(record) } catch { errorMessage = error.localizedDescription }
        if !enabled { sharingControllers[pluginID]?.stop() }
        if record.manifest.hasCaptureCapability {
            if !enabled { screenshots.deactivate() }
            else { captureController?.pinManager.activate(); captureController?.objectWillChange.send() }
        }
    }

    func saveCommand(_ command: PluginCommand, pluginID: String) throws {
        guard var record = installed.first(where: { $0.id == pluginID }) else { throw PluginError.invalid("插件已卸载。") }
        try command.validate(allowedActions: record.manifest.actions)
        if command.isEnabled, record.isEnabled, let hotKey = command.hotKey {
            for plugin in installed where plugin.isEnabled {
                for other in plugin.commands where other.isEnabled && other.id != command.id {
                    if other.hotKey?.identity == hotKey.identity {
                        throw PluginError.invalid("\(hotKey.display) 已绑定到「\(other.title)」。")
                    }
                }
            }
        }
        if let index = record.commands.firstIndex(where: { $0.id == command.id }) { record.commands[index] = command }
        else { record.commands.append(command) }
        try save(record)
        if let failure = hotKeyErrors[command.id] {
            errorMessage = "操作已保存，但快捷键未生效：\(failure)"
        }
    }

    func removeCommand(_ commandID: UUID, pluginID: String) {
        guard var record = installed.first(where: { $0.id == pluginID }) else { return }
        record.commands.removeAll { $0.id == commandID }
        do { try save(record) } catch { errorMessage = error.localizedDescription }
    }

    func uninstall(_ pluginID: String) {
        guard installed.contains(where: { $0.id == pluginID }) else { return }
        do {
            if installed.first(where: { $0.id == pluginID })?.manifest.hasCaptureCapability == true { screenshots.deactivate() }
            sharingControllers.removeValue(forKey: pluginID)?.stop()
            try FileManager.default.removeItem(at: directory.appendingPathComponent(pluginID + ".json"))
            installed.removeAll { $0.id == pluginID }
            reloadHotKeys()
        } catch { errorMessage = "卸载失败：\(error.localizedDescription)" }
    }

    func execute(_ command: PluginCommand, pluginID: String) async {
        guard let plugin = installed.first(where: { $0.id == pluginID }), plugin.isEnabled, command.isEnabled,
              plugin.commands.contains(command), plugin.manifest.actions.contains(command.action) else { return }
        do {
            try await ActionExecutor.execute(command, showMainWindow: showMainWindow, peripheralAction: { [self] action in
                try performPeripheralAction(action, pluginID: pluginID)
            }) { [self] action in
                try await performScreenshot(action, pluginID: pluginID)
            }
        }
        catch { handleExecutionError(error) }
    }

    func performPeripheralAction(_ action: ActionKind, pluginID: String) throws {
        guard let plugin = installed.first(where: { $0.id == pluginID }), plugin.isEnabled,
              plugin.manifest.actions.contains(action), plugin.manifest.actions.contains(.sharePeripherals) else {
            throw PluginError.invalid("请先启用并授权外设共享插件。")
        }
        let controller = peripheralSharing(for: pluginID)
        switch action {
        case .sharePeripherals: if controller.isRunning { controller.stop() } else { try controller.start() }
        case .switchPeripheralControl: controller.toggleControl()
        case .stopPeripheralSharing: controller.stop()
        default: throw PluginError.invalid("不支持的外设共享操作。")
        }
    }

    func performScreenshot(_ action: ActionKind, pluginID: String) async throws {
        guard action.isScreenshotAction,
              let plugin = installed.first(where: { $0.id == pluginID }), plugin.isEnabled,
              plugin.manifest.actions.contains(action) else { throw PluginError.invalid("请先启用截图插件。") }
        if action == .toggleCaptureHotKeys {
            captureHotKeysPaused.toggle()
            reloadHotKeys()
            return
        }
        let client = permissionClient(for: pluginID)
        if !(action == .captureRecording && screenshots.isRecording) {
            try client.require(CapturePermissionRequirements.permissions(for: action))
        }
        screenshots.showHistory = { [weak self] in
            self?.requestedPluginID = pluginID
            self?.showMainWindow()
        }
        try await screenshots.perform(action, permissions: client)
    }

    func permissionClient(for pluginID: String) -> PluginPermissionClient {
        PluginPermissionClient { [weak self] ids in
            guard let self, let plugin = self.installed.first(where: { $0.id == pluginID }) else {
                throw PluginError.invalid("插件已卸载。")
            }
            try self.permissions.require(ids, for: plugin)
        }
    }

    func handleExecutionError(_ error: Error) {
        if error is HostPermissionError { return } // The host has already opened permission management.
        errorMessage = "执行失败：\(error.localizedDescription)"
        showMainWindow()
    }

    private func save(_ record: InstalledPlugin) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent(record.id + ".json"), options: .atomic)
        if let index = installed.firstIndex(where: { $0.id == record.id }) { installed[index] = record }
        else { installed.append(record) }
        installed.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        reloadHotKeys()
    }

    private func reloadHotKeys() {
        if let plugin = installed.first(where: { $0.isEnabled && $0.manifest.hasCaptureCapability }) {
            if let controller = captureController {
                controller.configureGlobalMouse(permissions: permissionClient(for: plugin.id), allowed: { [weak self] in self?.captureHotKeysPaused == false && !HotKeyRecordingSession.isRecording })
            } else if UserDefaults.standard.bool(forKey: "capture.mouse.enabled") { _ = screenshots }
        } else { captureController?.globalMouse.stop() }
        hotKeys.clear()
        hotKeyErrors = [:]
        guard !HotKeyRecordingSession.isRecording else { return }
        var identities = Set<String>()
        for plugin in installed where plugin.isEnabled {
            for command in plugin.commands where command.isEnabled {
                if captureHotKeysPaused, plugin.manifest.hasCaptureCapability, command.action != .toggleCaptureHotKeys { continue }
                guard let hotKey = command.hotKey else { continue }
                do {
                    try command.validate(allowedActions: plugin.manifest.actions)
                    guard identities.insert(hotKey.identity).inserted else {
                        throw PluginError.invalid("这个快捷键已绑定到其他操作。")
                    }
                    try hotKeys.register(hotKey) { [weak self] in
                        Task { await self?.execute(command, pluginID: plugin.id) }
                    }
                } catch { hotKeyErrors[command.id] = error.localizedDescription }
            }
        }
    }

    private static func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("TietiezhiTools/\(HostInfo.version)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw PluginError.invalid("服务器暂时无法提供下载，请稍后重试。")
        }
        guard response.expectedContentLength <= maximumBytes else { throw PluginError.invalid("下载文件超过大小限制。") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maximumBytes else { throw PluginError.invalid("下载文件超过大小限制。") }
        }
        return data
    }
}
