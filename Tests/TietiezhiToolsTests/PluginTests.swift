import AppKit
import Carbon
import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import TietiezhiTools

@Suite(.serialized)
struct PluginTests {
    @Test func archiveRoundTripAndChecksum() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = manifest()
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        let archive = try zip(directory, files: ["manifest.json"])
        let hash = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        #expect(try PluginArchive.read(archive, expectedSHA256: hash) == manifest)
        #expect(throws: PluginError.self) { try PluginArchive.read(archive, expectedSHA256: String(repeating: "0", count: 64)) }
    }

    @Test func rejectUnexpectedArchiveFilesAndInflatedManifest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONEncoder().encode(manifest()).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("#!/bin/sh\necho unexpected".utf8).write(to: directory.appendingPathComponent("install.sh"))
        let unsafe = try zip(directory, files: ["manifest.json", "install.sh"])
        #expect(throws: PluginError.self) { try PluginArchive.read(unsafe) }
        try FileManager.default.removeItem(at: unsafe)
        try Data(repeating: 32, count: 300_000).write(to: directory.appendingPathComponent("manifest.json"))
        let inflated = try zip(directory, files: ["manifest.json"])
        #expect(throws: PluginError.self) { try PluginArchive.read(inflated) }
    }

    @Test func rejectTraversalAndUnsupportedManifests() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = directory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: directory.appendingPathComponent("outside.txt"))
        try JSONEncoder().encode(manifest()).write(to: child.appendingPathComponent("manifest.json"))
        let archive = try zip(child, files: ["manifest.json", "../outside.txt"])
        #expect(throws: PluginError.self) { try PluginArchive.read(archive) }
        #expect(throws: PluginError.self) { try manifest(id: "../escape").validate() }
        #expect(throws: PluginError.self) { try manifest(minimumHostVersion: "99.0.0").validate() }
        #expect(Version("0.10.0")! > Version("0.9.9")!)
        #expect(Version("1.0") == nil)
    }

    @Test func restrictActionTargets() throws {
        #expect(throws: PluginError.self) { try ActionKind.openURL.validateTarget("file:///etc/passwd") }
        #expect(throws: PluginError.self) { try ActionKind.openURL.validateTarget("javascript:alert(1)") }
        #expect(throws: PluginError.self) { try ActionKind.openApplication.validateTarget("/bin/sh") }
        #expect(throws: PluginError.self) { try HotKey(keyCode: 0, modifiers: UInt32(shiftKey), key: "A").validate() }
        try ActionKind.openURL.validateTarget("https://example.com")
    }

    @Test func actionNamesFollowTheCurrentTarget() throws {
        var command = PluginCommand(action: .openApplication)
        #expect(command.title == "打开应用")
        command.target = "/Applications/Safari.app"
        #expect(command.title == "打开 Safari")
        command.target = "/Applications/Visual Studio Code.app"
        #expect(command.title == "打开 Visual Studio Code")

        command.action = .openURL
        command.target = "https://example.com/"
        #expect(command.title == "打开 example.com")
        command.target = "  https://example.com/work?view=team#today \n"
        #expect(command.title == "打开 example.com/work?view=team#today")

        command.action = .runShortcut
        command.target = " 下班 \n"
        #expect(command.title == "运行快捷指令：下班")
        command.action = .showMainWindow
        #expect(command.title == "显示主面板")
        command.target = ""
        try command.validate(allowedActions: [.showMainWindow])
    }

    @Test func legacyNamesAreIgnoredWithoutChangingBindings() throws {
        let original = PluginCommand(
            action: .openApplication, target: "/Applications/Safari.app",
            applicationBookmark: Data([1, 2, 3]),
            hotKey: HotKey(keyCode: 17, modifiers: UInt32(controlKey | optionKey), key: "T"),
            isEnabled: false
        )
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy["title"] = "之前手动取的名字"
        let decoded = try JSONDecoder().decode(PluginCommand.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded == original)
        #expect(decoded.title == "打开 Safari")

        var edited = decoded
        edited.target = "/System/Applications/Notes.app"
        #expect(edited.title == "打开 Notes")
        #expect(edited.id == original.id)
        #expect(edited.hotKey == original.hotKey)
        #expect(edited.applicationBookmark == original.applicationBookmark)
        #expect(edited.isEnabled == original.isEnabled)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
        #expect(saved["title"] == nil)
    }

    @Test @MainActor func installConfigureUpdateDisableAndUninstall() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory)
        try store.installManifest(manifest())
        #expect(store.installed.count == 1)
        #expect(store.installed[0].commands.isEmpty)
        let command = PluginCommand(action: .showMainWindow)
        try store.saveCommand(command, pluginID: manifest().id)
        try store.installManifest(manifest(version: "1.1.0"))
        #expect(store.installed[0].commands == [command])
        #expect(store.installed[0].manifest.version == "1.1.0")
        #expect(throws: PluginError.self) { try store.installManifest(manifest(version: "1.0.0")) }
        store.setEnabled(false, pluginID: manifest().id)
        let reloaded = PluginStore(directory: directory)
        #expect(reloaded.installed.first?.isEnabled == false)
        #expect(reloaded.installed.first?.commands == [command])
        var executionCount = 0
        store.showMainWindow = { executionCount += 1 }
        await store.execute(command, pluginID: manifest().id)
        #expect(executionCount == 0)
        store.setEnabled(true, pluginID: manifest().id)
        await store.execute(command, pluginID: manifest().id)
        #expect(executionCount == 1)
        store.uninstall(manifest().id)
        #expect(store.installed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test @MainActor func rejectDuplicateBindingsAndReleaseOnDisable() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory)
        try store.installManifest(manifest())
        let key = HotKey(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), key: "F19")
        let first = PluginCommand(action: .showMainWindow, hotKey: key)
        try store.saveCommand(first, pluginID: manifest().id)
        #expect(store.hotKeyErrors.isEmpty)
        let second = PluginCommand(action: .showMainWindow, hotKey: key)
        #expect(throws: PluginError.self) { try store.saveCommand(second, pluginID: manifest().id) }
        #expect(store.installed[0].commands.count == 1)
        store.setEnabled(false, pluginID: manifest().id)
        let competitor = HotKeyManager()
        defer { competitor.clear() }
        try competitor.register(key) {}
        store.setEnabled(true, pluginID: manifest().id)
        #expect(store.hotKeyErrors[first.id] != nil)
        store.uninstall(manifest().id)
        #expect(store.hotKeyErrors.isEmpty)
    }

    @Test @MainActor func nativeHotKeyEventDispatch() async throws {
        _ = NSApplication.shared
        let manager = HotKeyManager()
        defer { manager.clear() }
        var count = 0
        try manager.register(HotKey(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), key: "F19")) { count += 1 }
        var event: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
        let hotKeyEvent = try #require(event)
        defer { ReleaseEvent(hotKeyEvent) }
        var identifier = EventHotKeyID(signature: 0x54545A48, id: 1)
        #expect(SetEventParameter(hotKeyEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
        #expect(SendEventToEventTarget(hotKeyEvent, GetApplicationEventTarget()) == noErr)
        #expect(count == 1)
    }

    @Test @MainActor func preserveUnreadableConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("broken.json")
        let data = Data("not-json".utf8)
        try data.write(to: file)
        let store = PluginStore(directory: directory)
        #expect(store.errorMessage != nil)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TIETIEZHI_NETWORK_TEST"] == "1"))
    @MainActor func downloadFromPublishedGitHubCatalog() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory)
        await store.refreshCatalog()
        #expect(store.catalogError == nil)
        #expect(!store.catalog.isEmpty)
        for entry in store.catalog {
            await store.install(entry)
            #expect(store.errorMessage == nil)
            let installed = try #require(store.installed.first { $0.id == entry.id })
            #expect(installed.manifest.version == entry.version)
            try store.uiRegistry.validate(installed.manifest)
        }
    }

    @Test @MainActor func nativePanelLayoutKeepsRegionsSeparate() async throws {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        defer { app.appearance = originalAppearance }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for longText in [false, true] {
            let store = PluginStore(directory: directory.appendingPathComponent(longText ? "long" : "normal"))
            let plugin = PluginManifest(
                schemaVersion: 1, id: "com.tietiezhi.layout", name: longText ? String(repeating: "长标题", count: 20) : "全局快捷键",
                version: "1.0.0", summary: longText ? String(repeating: "验证窄窗口中说明换行后仍然能看到全部操作。", count: 20) : "使用快捷键打开应用、打开网址或显示主面板。",
                author: "Tests", repository: HostInfo.repository, minimumHostVersion: "0.2.0",
                actions: [.showMainWindow, .openURL], templates: []
            )
            try store.installManifest(plugin)
            let command = PluginCommand(
                action: longText ? .openURL : .showMainWindow,
                target: longText ? "https://example.com/" + String(repeating: "very-long-path/", count: 20) : ""
            )
            try store.saveCommand(command, pluginID: plugin.id)
            let observation = PanelBoundsObservation()
            let root = ContentView(initialSelection: plugin.id)
                .environmentObject(store)
                .onPreferenceChange(PanelLayoutBoundsKey.self) { frames in
                    MainActor.assumeIsolated { observation.frames = frames }
                }
            let host = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 1040, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                app.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 1040, height: 720), NSSize(width: 880, height: 580)] {
                    window.setContentSize(size)
                    Self.settleLayout(host, window: window)
                    let frames = observation.frames
                    let bounds = try #require(frames["panel.root"])
                    let sidebar = try #require(frames["panel.sidebar"])
                    let controls = try #require(frames["panel.windowControls"])
                    let navigation = try #require(frames["navigation.__store__"])
                    let header = try #require(frames["panel.header"])
                    let heading = try #require(frames["panel.heading"])
                    let title = try #require(frames["panel.title"])
                    let icon = try #require(frames["plugin.header.icon"])
                    let enabled = try #require(frames["plugin.header.enabled"])
                    let more = try #require(frames["plugin.header.more"])
                    let info = try #require(frames["plugin.header.info"])
                    let settings = try #require(frames["panel.settings"])
                    let toolbar = try #require(frames["plugin.toolbar"])
                    let row = try #require(frames["command.\(command.id.uuidString)"])
                    #expect(abs(bounds.width - host.bounds.width) < 1)
                    #expect(abs(bounds.height - host.bounds.height) < 1)
                    #expect(abs(sidebar.width - 224) < 1)
                    #expect(controls.maxY <= navigation.minY)
                    #expect(header.minX >= sidebar.maxX)
                    #expect(header.contains(heading))
                    #expect(heading.contains(title))
                    #expect(heading.contains(icon))
                    #expect(abs(icon.width - PanelLayout.iconSize) < 1)
                    #expect(abs(icon.height - PanelLayout.iconSize) < 1)
                    #expect(icon.maxX + 15 <= title.minX)
                    #expect(frames["plugin.summary"] == nil)
                    #expect(header.height <= 100)
                    #expect(heading.contains(enabled))
                    #expect(heading.contains(more))
                    #expect(heading.contains(info))
                    #expect(sidebar.contains(settings))
                    #expect(enabled.maxX + 15 <= more.minX)
                    #expect(more.maxX + 15 <= info.minX)
                    #expect(settings.minY > navigation.maxY)
                    #expect(abs(more.width - 28) < 1)
                    #expect(abs(more.height - 28) < 1)
                    #expect(header.maxY <= toolbar.minY + 1)
                    #expect(toolbar.maxY <= row.minY + 1)
                    for region in [sidebar, controls, navigation, header, heading, title, icon, enabled, more, info, settings, toolbar, row] {
                        #expect(bounds.contains(region))
                    }
                    #expect(window.styleMask.contains(.fullSizeContentView))
                    #expect(window.titleVisibility == .hidden)
                    #expect(window.titlebarAppearsTransparent)
                    #expect(window.titlebarSeparatorStyle == .none)
                    #expect(window.toolbar == nil)
                    #expect(!window.isOpaque)
                    #expect(window.isMovableByWindowBackground)
                    var expectedX: CGFloat = 20
                    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                        let button = try #require(window.standardWindowButton(kind))
                        let buttonFrame = host.convert(button.bounds, from: button)
                        #expect(controls.contains(buttonFrame))
                        #expect(abs(buttonFrame.minX - expectedX) < 1)
                        #expect(abs(buttonFrame.minY - 26) < 1)
                        #expect(!header.intersects(buttonFrame))
                        #expect(!navigation.intersects(buttonFrame))
                        expectedX = buttonFrame.maxX + 8
                    }
                    if let close = window.standardWindowButton(.closeButton),
                       let container = close.superview?.superview,
                       let frame = container.superview {
                        #expect(container.frame.width <= sidebar.width)
                        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                            let button = try #require(window.standardWindowButton(kind))
                            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                            let hit = try #require(frame.hitTest(center))
                            #expect(hit === button || hit.isDescendant(of: button))
                        }
                        let headerPoint = host.convert(NSPoint(x: host.bounds.maxX - 44, y: 48), to: nil)
                        let headerHit = try #require(frame.hitTest(headerPoint))
                        #expect(!headerHit.isDescendant(of: container))
                    }
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                        #expect(Self.hasDesktopBackdrop(host))
                    }
                }
            }
        }
    }

    @MainActor private static func settleLayout(_ host: NSView, window: NSWindow) {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    @MainActor private static func hasDesktopBackdrop(_ view: NSView) -> Bool {
        if let effect = view as? NSVisualEffectView,
           effect.blendingMode == .behindWindow, effect.material == .underWindowBackground {
            return true
        }
        return view.subviews.contains { hasDesktopBackdrop($0) }
    }

    @MainActor private final class PanelBoundsObservation {
        var frames: [String: CGRect] = [:]
    }

    private func manifest(id: String = "com.tietiezhi.test", version: String = "1.0.0", minimumHostVersion: String = "0.2.0") -> PluginManifest {
        PluginManifest(schemaVersion: 1, id: id, name: "测试插件", version: version, summary: "Test", author: "Tests",
                       repository: HostInfo.repository, minimumHostVersion: minimumHostVersion,
                       actions: [.showMainWindow, .openURL], templates: [CommandTemplate(id: "panel", title: "主面板", action: .showMainWindow)])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TietiezhiToolsTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func zip(_ directory: URL, files: [String]) throws -> URL {
        let process = Process()
        let url = directory.appendingPathComponent("plugin.zip")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", url.path] + files
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PluginError.invalid("Failed to create test ZIP") }
        return url
    }
}
