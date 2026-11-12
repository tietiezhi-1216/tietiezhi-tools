import AppKit
import Carbon
import Testing
@testable import TietiezhiTools

@Suite(.serialized)
struct CaptureWorkflowTests {
    private func manifest() throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json")))
    }
    @Test func pixPinGlobalDefaultsAreExactAndConflictsAreNotStolen() throws {
        let manifest = try manifest()
        try manifest.validate()
        var plugin = InstalledPlugin(manifest: manifest, commands: [])
        let conflicts = plugin.initializeDefaultCommands(occupiedHotKeys: ["18:4096"])
        #expect(conflicts == ["区域截图"])
        let expected: [ActionKind: String] = [.captureDelayed: "18:2048", .captureAndCopy: "18:6144", .pinClipboard: "19:4096", .restorePin: "20:4096", .cyclePinGroup: "50:4096"]
        #expect(plugin.commands.count == 6)
        #expect(plugin.commands.first { $0.action == .captureRegion }?.hotKey == nil)
        for (action, identity) in expected { #expect(plugin.commands.first { $0.action == action }?.hotKey?.identity == identity) }
    }
    @Test func upgradingPreservesCustomClearedDisabledAndDeletedDefaults() throws {
        var legacy = PluginCommand(action: .captureRegion, hotKey: HotKey(keyCode: 15, modifiers: UInt32(cmdKey), key: "R"), isEnabled: false)
        legacy.target = ""
        var plugin = InstalledPlugin(manifest: try manifest(), commands: [legacy])
        #expect(plugin.initializeDefaultCommands().isEmpty)
        #expect(plugin.commands.first?.id == legacy.id)
        #expect(plugin.commands.first?.hotKey == legacy.hotKey)
        #expect(plugin.commands.first?.isEnabled == false)
        let pinIndex = try #require(plugin.commands.firstIndex { $0.action == .pinClipboard })
        plugin.commands[pinIndex].hotKey = nil
        plugin.commands.removeAll { $0.action == .restorePin }
        let saved = plugin.commands
        _ = plugin.initializeDefaultCommands()
        #expect(plugin.commands == saved)
        let decoded = try JSONDecoder().decode(InstalledPlugin.self, from: JSONEncoder().encode(plugin))
        #expect(decoded == plugin)
        #expect(plugin.initializeDefaultCommands(restoring: true).isEmpty)
        #expect(plugin.commands.count == 6)
        #expect(plugin.commands.first { $0.action == .captureRegion }?.hotKey?.identity == "18:4096")
    }
    @Test func restoringSwappedDefaultsDoesNotReportFalseConflicts() throws {
        var plugin = InstalledPlugin(manifest: try manifest(), commands: [])
        plugin.initializeDefaultCommands()
        let first = plugin.commands[0].hotKey
        plugin.commands[0].hotKey = plugin.commands[1].hotKey
        plugin.commands[1].hotKey = first
        #expect(plugin.initializeDefaultCommands(restoring: true).isEmpty)
        #expect(Set(plugin.commands.compactMap { $0.hotKey?.identity }).count == 6)
    }
    @Test @MainActor func localBindingsAreScopedAndClearedBindingsPersist() throws {
        let name = "CaptureShortcutsTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureShortcutSettings(defaults: defaults)
        #expect(settings.action(keyCode: 49, modifiers: 0, scope: .editor) == .hideToolbar)
        #expect(settings.action(keyCode: 49, modifiers: 0, scope: .pin) == .pinAnnotate)
        #expect(settings.binding(.redo)?.identity == "16:256")
        #expect(settings.binding(.clearMarks)?.identity == "6:768")
        #expect(throws: PluginError.self) { try settings.set(CaptureShortcutAction.copy.defaultKey, for: .save) }
        try settings.set(nil, for: .copy)
        #expect(CaptureShortcutSettings(defaults: defaults).binding(.copy) == nil)
        settings.restoreDefaults()
        #expect(settings.binding(.copy) == CaptureShortcutAction.copy.defaultKey)
        for scope in [CaptureShortcutScope.editor, .pin] {
            let keys = CaptureShortcutAction.allCases.filter { $0.scopes.contains(scope) }.compactMap { settings.binding($0)?.identity }
            #expect(Set(keys).count == keys.count)
        }
    }
    @Test @MainActor func closedPinsRestoreInOrderAndGroupsSurviveRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PinTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try CaptureImage.context(width: 100, height: 80)
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let manager = CapturePinManager(directory: folder, displaysWindows: false)
        let first = try manager.create(#require(context.makeImage()), text: "hello")
        let second = try manager.create(#require(context.makeImage()))
        manager.toggleAll()
        #expect(manager.records.allSatisfy { $0.isOpen }) // Hidden is not closed.
        manager.close(first); manager.close(second)
        try manager.restoreLastClosed()
        #expect(manager.record(second)?.isOpen == true && manager.record(first)?.isOpen == false)
        let group = manager.createGroup(name: "工作")
        manager.move(second, to: group)
        manager.toggle(second, \.locked); manager.toggle(second, \.clickThrough)
        let restored = CapturePinManager(directory: folder, displaysWindows: false)
        #expect(restored.activeGroupID == group)
        #expect(restored.record(second)?.locked == true)
        #expect(restored.record(second)?.clickThrough == true)
        #expect(restored.record(first)?.text == "hello")
        restored.mergeGroupIntoDefault(group)
        #expect(restored.records.count == 2 && restored.groups.count == 1)
        #expect(restored.records.allSatisfy { $0.groupID == CapturePinGroup.defaultID })
        restored.deactivate()
        #expect(restored.record(second)?.isOpen == true)
    }
    @Test @MainActor func markMovementClearAndSpotlightAreUndoableAndExported() throws {
        let context = try CaptureImage.context(width: 200, height: 120)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let document = CaptureDocument(image: try #require(context.makeImage()))
        document.add(CaptureMark(tool: .cover, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: .black, width: 2))
        document.moveMark(at: 0, by: CGSize(width: 50, height: 0))
        #expect(NSBitmapImageRep(cgImage: document.image).colorAt(x: 20, y: 20)!.brightnessComponent > 0.95)
        #expect(NSBitmapImageRep(cgImage: document.image).colorAt(x: 70, y: 20)!.brightnessComponent < 0.05)
        document.clearMarks(); #expect(document.marks.isEmpty)
        document.undo(); #expect(document.marks.count == 1)
        document.removeMark(at: 0); document.undo(); #expect(document.marks.count == 1)
        document.clearMarks()
        document.add(CaptureMark(tool: .spotlight, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)], color: .red, width: 2))
        let pixels = NSBitmapImageRep(cgImage: document.image)
        #expect(pixels.colorAt(x: 20, y: 20)!.brightnessComponent > 0.95)
        #expect(pixels.colorAt(x: 100, y: 90)!.brightnessComponent < 0.6)
    }
    @Test func redactionMapsVisionCoordinatesAndDoesNotMarkOrdinaryText() throws {
        let text = CaptureText(lines: [RecognizedLine(text: "hello@example.com", rect: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1)),
            RecognizedLine(text: "Ordinary text", rect: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.1))], codes: [])
        let regions = CaptureRecognition.sensitiveTextRegions(text, size: CGSize(width: 1000, height: 500))
        #expect(regions.count == 1)
        let rect = try #require(regions.first)
        #expect(rect.minX == 96 && abs(rect.minY - 96) < 0.01)
        #expect(rect.width == 408 && abs(rect.height - 58) < 0.01)
        let memory = CaptureRegionMemory(displayID: 1, rect: CGRect(x: 90, y: 10, width: 40, height: 40))
        #expect(try memory.clamped(to: CGSize(width: 100, height: 100)) == CGRect(x: 90, y: 10, width: 10, height: 40))
        #expect(throws: PluginError.self) { try memory.clamped(to: CGSize(width: 50, height: 50)) }
    }
}
