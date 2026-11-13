import AppKit

@MainActor
enum ActionExecutor {
    static func execute(_ command: PluginCommand, showMainWindow: () -> Void,
                        peripheralAction: (ActionKind) throws -> Void = { _ in throw PluginError.invalid("外设共享插件尚未准备好。") },
                        dictationAction: (ActionKind) throws -> Void = { _ in throw PluginError.invalid("语音输入插件尚未准备好。") },
                        screenshotAction: (ActionKind) async throws -> Void = { _ in throw PluginError.invalid("截图插件尚未准备好。") }) async throws {
        try command.action.validateTarget(command.target)
        switch command.action {
        case .openApplication:
            try await withApplicationURL(for: command) { url in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
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
        case .sharePeripherals, .switchPeripheralControl, .stopPeripheralSharing:
            try peripheralAction(command.action)
        case .toggleDoubaoDictation, .holdDoubaoDictation, .cancelDoubaoDictation:
            try dictationAction(command.action)
        default:
            try await screenshotAction(command.action)
        }
    }

    static func applicationBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            // Developer ID / ad-hoc builds may not be able to issue a sandbox extension.
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    static func withApplicationURL(for command: PluginCommand, perform: (URL) async throws -> Void) async throws {
        try ActionKind.openApplication.validateTarget(command.target)
        if let bookmark = command.applicationBookmark {
            let options: [URL.BookmarkResolutionOptions] = [
                [.withSecurityScope, .withoutUI], .withoutUI
            ]
            for option in options {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, options: option, relativeTo: nil,
                                        bookmarkDataIsStale: &stale) else { continue }
                // A stale bookmark can still resolve to an existing app after an update or move.
                if try await useApplicationURL(url, perform: perform) { return }
            }
        }
        // A broken or incompatible bookmark must not block an otherwise accessible app.
        if try await useApplicationURL(URL(fileURLWithPath: command.target), perform: perform) { return }
        throw PluginError.invalid("找不到或无法访问这个应用，请点击「编辑」重新选择。")
    }

    private static func useApplicationURL(_ url: URL, perform: (URL) async throws -> Void) async throws -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue, Bundle(url: url) != nil else { return false }
        try await perform(url)
        return true
    }
}
