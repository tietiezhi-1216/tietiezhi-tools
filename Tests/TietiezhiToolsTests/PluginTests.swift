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

    @Test @MainActor func installConfigureUpdateDisableAndUninstall() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory)
        try store.installManifest(manifest())
        #expect(store.installed.count == 1)
        #expect(store.installed[0].commands.isEmpty)
        let command = PluginCommand(title: "主面板", action: .showMainWindow)
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
        let first = PluginCommand(title: "第一个", action: .showMainWindow, hotKey: key)
        try store.saveCommand(first, pluginID: manifest().id)
        #expect(store.hotKeyErrors.isEmpty)
        let second = PluginCommand(title: "第二个", action: .showMainWindow, hotKey: key)
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
        let entry = try #require(store.catalog.first)
        await store.install(entry)
        #expect(store.errorMessage == nil)
        #expect(store.installed.first?.id == entry.id)
        #expect(store.installed.first?.manifest.version == entry.version)
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
                actions: [.showMainWindow], templates: []
            )
            try store.installManifest(plugin)
            let command = PluginCommand(title: longText ? String(repeating: "操作名称", count: 20) : "显示主面板", action: .showMainWindow)
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
                    let summary = try #require(frames["plugin.summary"])
                    let toolbar = try #require(frames["plugin.commands.toolbar"])
                    let row = try #require(frames["command.\(command.id.uuidString)"])
                    #expect(abs(sidebar.width - 224) < 1)
                    #expect(controls.maxY <= navigation.minY)
                    #expect(header.minX >= sidebar.maxX)
                    #expect(header.maxY <= summary.minY + 1)
                    #expect(summary.maxY <= toolbar.minY + 1)
                    #expect(toolbar.maxY <= row.minY + 1)
                    for region in [sidebar, controls, navigation, header, summary, toolbar, row] {
                        #expect(bounds.contains(region))
                    }
                    #expect(window.styleMask.contains(.fullSizeContentView))
                    #expect(window.titleVisibility == .hidden)
                    #expect(window.titlebarAppearsTransparent)
                    #expect(window.titlebarSeparatorStyle == .none)
                    #expect(window.toolbar == nil)
                    #expect(!window.isOpaque)
                    #expect(window.isMovableByWindowBackground)
                    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                        let button = try #require(window.standardWindowButton(kind))
                        let buttonFrame = host.convert(button.bounds, from: button)
                        #expect(controls.contains(buttonFrame))
                        #expect(!header.intersects(buttonFrame))
                        #expect(!navigation.intersects(buttonFrame))
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
           effect.blendingMode == .behindWindow, effect.material == .sidebar {
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
