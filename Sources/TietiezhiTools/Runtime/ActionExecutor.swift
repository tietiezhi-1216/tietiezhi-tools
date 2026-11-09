import AppKit

@MainActor
enum ActionExecutor {
    static func execute(_ command: PluginCommand, showMainWindow: () -> Void) async throws {
        try command.action.validateTarget(command.target)
        switch command.action {
        case .openApplication:
            var url = URL(fileURLWithPath: command.target)
            if let bookmark = command.applicationBookmark {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw PluginError.invalid("应用位置已改变，请重新选择。") }
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path), Bundle(url: url) != nil else {
                throw PluginError.invalid("找不到这个应用，请重新选择。")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        case .openURL:
            guard let url = URL(string: command.target), NSWorkspace.shared.open(url) else {
                throw PluginError.invalid("无法打开网址。")
            }
        case .runShortcut:
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "run-shortcut"
            components.queryItems = [URLQueryItem(name: "name", value: command.target)]
            guard let url = components.url, NSWorkspace.shared.open(url) else {
                throw PluginError.invalid("无法打开「快捷指令」，请确认已安装并存在同名指令。")
            }
        case .showMainWindow:
            showMainWindow()
        }
    }
}
