import Foundation

enum HostInfo {
    static let name = "Untitled"
    static let version = "0.10.5"
    static let bundleIdentifier = "com.untitled.app"
    static let repository = URL(string: "https://github.com/tietiezhi-1216/untitled")!
    static let catalog = URL(string: "https://raw.githubusercontent.com/tietiezhi-1216/untitled/main/Plugins/catalog.json")!
}

/// A plugin may keep its own source repository and release independently of the host.
private enum GitHubPluginSource {
    static func hasValidOrigin(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil &&
            url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    static func isRepository(_ url: URL) -> Bool {
        hasValidOrigin(url) && url.path.range(
            of: #"^/[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*/?$"#,
            options: .regularExpression) != nil
    }

    static func isReleaseArchive(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard hasValidOrigin(url), parts.count == 7,
              parts[3] == "releases", parts[4] == "download",
              !parts.contains("."), !parts.contains(".."), url.pathExtension == "zip"
        else { return false }
        return [parts[1], parts[2]].allSatisfy {
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        }
    }
}

enum PluginError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

struct PluginManifest: Codable, Equatable, Sendable, Identifiable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let summary: String
    let author: String
    let repository: URL
    let minimumHostVersion: String
    let actions: [ActionKind]
    let templates: [CommandTemplate]
    var ui: PluginInterface?
    var permissions: [PluginPermissionDeclaration]?

    func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw PluginError.invalid("不支持这个插件格式，请更新主程序。") }
        if schemaVersion == 2 {
            guard let ui, let minimum = Version(minimumHostVersion), minimum >= Version("0.4.0")! else {
                throw PluginError.invalid("v2 插件需要界面声明与 0.4.0 或更高版本的宿主。")
            }
            try ui.validate()
        } else if ui != nil { throw PluginError.invalid("声明界面槽位时需要使用插件协议 v2。") }
        if schemaVersion == 2, let minimum = Version(minimumHostVersion), minimum >= Version("0.5.0")!, permissions == nil {
            throw PluginError.invalid("此版本的插件必须声明 permissions；无需系统权限时使用空数组。")
        }
        if let permissions {
            guard schemaVersion == 2, let minimum = Version(minimumHostVersion), minimum >= Version("0.5.0")!,
                  permissions.count <= 32, Set(permissions.map(\.id)).count == permissions.count,
                  permissions.allSatisfy({
                      $0.id.rawValue.count <= 100 &&
                      $0.id.rawValue.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil &&
                      !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.reason.count <= 240
                  }) else { throw PluginError.invalid("插件权限声明无效，或未指定 0.5.0 及以上宿主。") }
        }
        guard id.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)+$"#, options: .regularExpression) != nil,
              id.utf8.count <= 100 else { throw PluginError.invalid("插件标识不合法。") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              summary.count <= 1000, !author.isEmpty,
              Version(version) != nil, let minimum = Version(minimumHostVersion),
              minimum <= Version(HostInfo.version)! else { throw PluginError.invalid("插件信息无效，或需要更高版本的主程序。") }
        guard GitHubPluginSource.isRepository(repository) else {
            throw PluginError.invalid("插件源码地址必须是 HTTPS GitHub 仓库地址。")
        }
        guard !actions.isEmpty, Set(actions).count == actions.count,
              templates.count <= 100, Set(templates.map(\.id)).count == templates.count,
              templates.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && $0.title.count <= 100 && actions.contains($0.action) }) else {
            throw PluginError.invalid("插件的操作声明无效。")
        }
        if actions.contains(where: { [.toggleDoubaoDictation, .holdDoubaoDictation, .cancelDoubaoDictation].contains($0) }),
           minimum < Version("0.9.8")! {
            throw PluginError.invalid("豆包语音输入需要 0.9.8 或更高版本宿主。")
        }
        if templates.contains(where: { $0.defaultHotKey != nil || $0.installByDefault != nil }) {
            guard minimum >= Version("0.6.0")! else { throw PluginError.invalid("默认动作声明需要 0.6.0 或更高版本宿主。") }
        }
        var defaultKeys = Set<String>()
        for template in templates {
            if let key = template.defaultHotKey {
                try key.validate()
                guard template.installByDefault == true, defaultKeys.insert(key.identity).inserted else {
                    throw PluginError.invalid("默认快捷键必须属于默认动作，且不能重复。")
                }
            }
            if template.installByDefault == true { try template.action.validateTarget("") }
        }
    }
}

struct Version: Comparable, Equatable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

enum ActionKind: String, Codable, CaseIterable, Sendable {
    case openApplication
    case openURL
    case runShortcut
    case showMainWindow
    case sharePeripherals, switchPeripheralControl, stopPeripheralSharing
    case toggleDoubaoDictation, holdDoubaoDictation, cancelDoubaoDictation
    case captureRegion, captureWindow, captureScreen, captureScrolling, captureRecording
    case pinClipboard, togglePins, captureHistory
    case captureDelayed, captureAndCopy, captureLastRegion
    case restorePin, closePins, hideOtherPins, togglePinClickThrough, cyclePinGroup, pinFiles, toggleCaptureHotKeys

    var isScreenshotAction: Bool {
        switch self {
        case .openApplication, .openURL, .runShortcut, .showMainWindow, .sharePeripherals, .switchPeripheralControl, .stopPeripheralSharing,
             .toggleDoubaoDictation, .holdDoubaoDictation, .cancelDoubaoDictation: false
        default: true
        }
    }

    var title: String {
        switch self {
        case .openApplication: "打开应用"
        case .openURL: "打开网址"
        case .runShortcut: "运行快捷指令"
        case .showMainWindow: "显示主面板"
        case .sharePeripherals: "启动或停止外设共享"
        case .switchPeripheralControl: "切换键鼠控制目标"
        case .stopPeripheralSharing: "停止全部外设共享"
        case .toggleDoubaoDictation: "开始或结束豆包听写"
        case .holdDoubaoDictation: "按住说话（豆包）"
        case .cancelDoubaoDictation: "取消豆包听写"
        case .captureRegion: "区域截图"
        case .captureWindow: "窗口截图"
        case .captureScreen: "全屏截图"
        case .captureScrolling: "滚动长截图"
        case .captureRecording: "开始或停止录屏"
        case .pinClipboard: "剪贴板贴图"
        case .togglePins: "隐藏或显示贴图"
        case .captureHistory: "打开截图历史"
        case .captureDelayed: "自定义 / 延时截图"
        case .captureAndCopy: "截图并复制"
        case .captureLastRegion: "重复上次截图区域"
        case .restorePin: "恢复上次关闭的贴图"
        case .closePins: "关闭所有贴图"
        case .hideOtherPins: "隐藏或显示其他贴图"
        case .togglePinClickThrough: "切换贴图鼠标穿透"
        case .cyclePinGroup: "切换贴图组"
        case .pinFiles: "文件贴图"
        case .toggleCaptureHotKeys: "暂停或恢复截图快捷键"
        }
    }

    var symbol: String {
        switch self {
        case .openApplication: "app"
        case .openURL: "link"
        case .runShortcut: "command.square"
        case .showMainWindow: "macwindow"
        case .sharePeripherals: "network"
        case .switchPeripheralControl: "keyboard"
        case .stopPeripheralSharing: "stop.circle"
        case .toggleDoubaoDictation: "mic"
        case .holdDoubaoDictation: "mic.fill"
        case .cancelDoubaoDictation: "xmark.circle"
        case .captureRegion: "viewfinder"
        case .captureWindow: "macwindow"
        case .captureScreen: "display"
        case .captureScrolling: "scroll"
        case .captureRecording: "record.circle"
        case .pinClipboard: "pin"
        case .togglePins: "eye"
        case .captureHistory: "clock"
        case .captureDelayed: "timer"
        case .captureAndCopy: "doc.on.clipboard"
        case .captureLastRegion: "viewfinder.rectangular"
        case .restorePin: "pin.circle"
        case .closePins: "xmark.rectangle.on.rectangle"
        case .hideOtherPins: "eye.slash"
        case .togglePinClickThrough: "cursorarrow.rays"
        case .cyclePinGroup: "square.stack.3d.up"
        case .pinFiles: "photo.on.rectangle.angled"
        case .toggleCaptureHotKeys: "keyboard"
        }
    }

    func validateTarget(_ target: String) throws {
        switch self {
        case .openApplication:
            guard target.hasPrefix("/"), URL(fileURLWithPath: target).pathExtension.lowercased() == "app" else {
                throw PluginError.invalid("请先选择一个应用。")
            }
        case .openURL:
            guard let url = URL(string: target), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw PluginError.invalid("请输入有效的 http 或 https 网址。")
            }
        case .runShortcut:
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, target.count <= 500 else {
                throw PluginError.invalid("请输入 macOS「快捷指令」中的名称。")
            }
        default: break
        }
    }
}

struct CommandTemplate: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let action: ActionKind
    var defaultHotKey: HotKey? = nil
    var installByDefault: Bool? = nil
}

struct PluginCommand: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var action: ActionKind
    var target = ""
    var applicationBookmark: Data?
    var hotKey: HotKey?
    var isEnabled = true
    var templateID: String? = nil

    // 名称由动作和目标派生；旧配置中的 title 字段由 Codable 自动忽略。
    var title: String {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return action.title }
        switch action {
        case .openApplication:
            let name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
            return "打开 \(name)"
        case .openURL:
            var destination = value
            for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) {
                destination = String(value.dropFirst(prefix.count))
                break
            }
            if let url = URL(string: value), url.path.isEmpty || url.path == "/",
               url.query == nil, url.fragment == nil, destination.hasSuffix("/") {
                destination.removeLast()
            }
            return "打开 \(destination)"
        case .runShortcut:
            return "运行快捷指令：\(value)"
        default:
            return action.title
        }
    }

    var isConfigured: Bool { (try? action.validateTarget(target)) != nil }

    func validate(allowedActions: [ActionKind]) throws {
        guard allowedActions.contains(action) else { throw PluginError.invalid("请选择插件支持的操作。") }
        try action.validateTarget(target)
        try hotKey?.validate()
    }
}

struct InstalledPlugin: Codable, Equatable, Sendable, Identifiable {
    var manifest: PluginManifest
    var isEnabled = true
    var commands: [PluginCommand]
    var installedAt = Date()
    var initializedDefaultTemplateIDs: [String]? = nil
    var id: String { manifest.id }

    /// Upgrade defaults once; user edits, cleared bindings and deleted defaults survive later upgrades.
    @discardableResult mutating func initializeDefaultCommands(
        occupiedHotKeys: Set<String> = [], restoring: Bool = false
    ) -> [String] {
        var initialized = Set(initializedDefaultTemplateIDs ?? [])
        var conflicts: [String] = []
        let restoringIDs = restoring ? Set(manifest.templates.filter { $0.installByDefault == true }.map(\.id)) : []
        for template in manifest.templates where template.installByDefault == true {
            guard restoring || !initialized.contains(template.id) else { continue }
            initialized.insert(template.id)
            var index = commands.firstIndex { $0.templateID == template.id }
            if index == nil, !restoring {
                index = commands.firstIndex { $0.templateID == nil && $0.action == template.action }
            }
            if let index, !restoring {
                commands[index].templateID = template.id
                continue
            }
            var command = index.map { commands[$0] } ?? PluginCommand(action: template.action)
            command.templateID = template.id
            command.action = template.action
            command.target = ""
            command.hotKey = template.defaultHotKey
            command.isEnabled = true
            if let key = command.hotKey,
               occupiedHotKeys.contains(key.identity) || commands.contains(where: {
                   $0.id != command.id && $0.isEnabled && !($0.templateID.map { restoringIDs.contains($0) } ?? false) && $0.hotKey?.identity == key.identity
               }) {
                conflicts.append(command.title)
                command.hotKey = nil
            }
            if let index { commands[index] = command } else { commands.append(command) }
        }
        initializedDefaultTemplateIDs = initialized.sorted()
        return conflicts
    }
}

struct PluginCatalog: Codable, Sendable {
    let schemaVersion: Int
    let plugins: [CatalogEntry]

    func validate() throws {
        guard schemaVersion == 1, plugins.count <= 500, Set(plugins.map(\.id)).count == plugins.count else {
            throw PluginError.invalid("插件目录格式无效。")
        }
        for entry in plugins { try entry.validate() }
    }
}

struct CatalogEntry: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let summary: String
    let author: String
    let downloadURL: URL
    let sha256: String

    func validate() throws {
        guard GitHubPluginSource.isReleaseArchive(downloadURL),
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              Version(version) != nil, !id.isEmpty, !name.isEmpty else {
            throw PluginError.invalid("插件下载地址或校验信息无效。")
        }
    }
}
