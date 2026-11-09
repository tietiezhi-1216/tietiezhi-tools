import Foundation

enum HostInfo {
    static let version = "0.2.0"
    static let repository = URL(string: "https://github.com/tietiezhi-1216/tietiezhi-tools")!
    static let catalog = URL(string: "https://raw.githubusercontent.com/tietiezhi-1216/tietiezhi-tools/main/Plugins/catalog.json")!
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

    func validate() throws {
        guard schemaVersion == 1 else { throw PluginError.invalid("不支持这个插件格式，请更新主程序。") }
        guard id.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)+$"#, options: .regularExpression) != nil,
              id.utf8.count <= 100 else { throw PluginError.invalid("插件标识不合法。") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              summary.count <= 1000, !author.isEmpty,
              Version(version) != nil, let minimum = Version(minimumHostVersion),
              minimum <= Version(HostInfo.version)! else { throw PluginError.invalid("插件信息无效，或需要更高版本的主程序。") }
        guard repository.scheme == "https", repository.host == "github.com",
              repository.user == nil, repository.password == nil,
              repository.pathComponents.count == 3 else { throw PluginError.invalid("插件源码必须来自 GitHub 仓库。") }
        guard !actions.isEmpty, Set(actions).count == actions.count,
              templates.count <= 100, Set(templates.map(\.id)).count == templates.count,
              templates.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && $0.title.count <= 100 && actions.contains($0.action) }) else {
            throw PluginError.invalid("插件的操作声明无效。")
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

    var title: String {
        switch self {
        case .openApplication: "打开应用"
        case .openURL: "打开网址"
        case .runShortcut: "运行快捷指令"
        case .showMainWindow: "显示主面板"
        }
    }

    var symbol: String {
        switch self {
        case .openApplication: "app"
        case .openURL: "link"
        case .runShortcut: "command.square"
        case .showMainWindow: "macwindow"
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
        case .showMainWindow: break
        }
    }
}

struct CommandTemplate: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let action: ActionKind
}

struct PluginCommand: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var title: String
    var action: ActionKind
    var target = ""
    var applicationBookmark: Data?
    var hotKey: HotKey?
    var isEnabled = true

    var isConfigured: Bool { (try? action.validateTarget(target)) != nil }

    func validate(allowedActions: [ActionKind]) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 100,
              allowedActions.contains(action) else { throw PluginError.invalid("请输入名称，并选择插件支持的操作。") }
        try action.validateTarget(target)
        try hotKey?.validate()
    }
}

struct InstalledPlugin: Codable, Equatable, Sendable, Identifiable {
    var manifest: PluginManifest
    var isEnabled = true
    var commands: [PluginCommand]
    var installedAt = Date()
    var id: String { manifest.id }
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
        guard downloadURL.scheme == "https", downloadURL.host == "github.com",
              downloadURL.user == nil, downloadURL.password == nil,
              downloadURL.path.hasPrefix("/tietiezhi-1216/tietiezhi-tools/releases/download/"),
              downloadURL.pathExtension == "zip", sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              Version(version) != nil, !id.isEmpty, !name.isEmpty else {
            throw PluginError.invalid("插件下载地址或校验信息无效。")
        }
    }
}
