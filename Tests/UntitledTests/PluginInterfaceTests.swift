import AppKit
import Combine
import SwiftUI
import Testing

@testable import Untitled

@Suite(.serialized) struct PluginInterfaceTests {
    @Test @MainActor func officialPluginsDeclareTheirOwnLayout() throws {
        let registry = PluginComposition.makeUIRegistry()
        for name in ["global-shortcuts", "screenshot", "peripheral-sharing"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Plugins/\(name)/manifest.json"))
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            try manifest.validate()
            try registry.validate(manifest)
            #expect(registry.interface(for: manifest) == manifest.ui)
            #expect(manifest.ui?.items(in: .headerLeading).first?.component == "host.icon")
        }
    }

    @Test func rejectsInvalidSlotsReferencesAndCycles() throws {
        let valid = PluginInterface(slots: ["content": [.component("body", "demo.body")]])
        try valid.validate()
        var ui = valid
        ui.slots["unknown"] = []
        #expect(throws: PluginError.self) { try ui.validate() }
        ui = valid
        ui.version = 99
        #expect(throws: PluginError.self) { try ui.validate() }
        ui = valid
        ui.slots["header.leading"] = [.component("body", "demo.header")]
        #expect(throws: PluginError.self) { try ui.validate() }
        ui = valid
        ui.slots["content"] = [.init(id: "missing", kind: .panel, panel: "missing")]
        #expect(throws: PluginError.self) { try ui.validate() }
        ui = valid
        ui.panels = [
            .init(
                id: "loop", title: "Loop",
                slots: [
                    "content": [.init(id: "recursive", kind: .tabs, panels: ["loop"])]
                ])
        ]
        #expect(throws: PluginError.self) { try ui.validate() }
        ui = valid
        ui.slots["menuBar"] = [.component("menuComponent", "demo.body")]
        #expect(throws: PluginError.self) { try ui.validate() }
        ui = valid
        ui.panels = [.init(id: "both", title: "Both", component: "demo.body", slots: ["content": []])]
        #expect(throws: PluginError.self) { try ui.validate() }
    }

    @Test @MainActor func legacyPackagesHaveAnExplicitCompatibilityAdapter() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 1; json["minimumHostVersion"] = "0.3.0"; json.removeValue(forKey: "ui"); json.removeValue(forKey: "permissions")
        json["templates"] = (json["templates"] as? [[String: Any]])?.map { template in
            var old = template; old.removeValue(forKey: "defaultHotKey"); old.removeValue(forKey: "installByDefault"); return old
        }
        let legacy = try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: json))
        let registry = PluginComposition.makeUIRegistry()
        try legacy.validate()
        try registry.validate(legacy)
        #expect(registry.interface(for: legacy).icon == "camera.viewfinder")
        #expect(registry.interface(for: legacy).panel("preferences")?.component == "capture.preferences")
        json["schemaVersion"] = 2; json["minimumHostVersion"] = "0.4.0"
        let missingUI = try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: PluginError.self) { try missingUI.validate() }
        #expect(registry.interface(for: missingUI).slots.isEmpty)
    }

    @Test @MainActor func validatesRegisteredComponentsAndCapabilitiesBeforeInstalling() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginComposition.makeUIRegistry()
        let store = PluginStore(directory: directory, uiRegistry: registry)
        let unknown = fixture(ui: .init(slots: ["content": [.component("body", "unknown.body")]]))
        #expect(throws: PluginError.self) { try store.installManifest(unknown) }
        let unauthorized = fixture(ui: .init(slots: ["content": [.component("history", "capture.history")]]))
        #expect(throws: PluginError.self) { try store.installManifest(unauthorized) }
        let unauthorizedCommand = fixture(
            ui: .init(slots: [
                "content": [.component("body", "host.commands")],
                "toolbar.leading": [.command("capture", "capture.region")],
            ]))
        #expect(throws: PluginError.self) { try store.installManifest(unauthorizedCommand) }
        #expect(store.installed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test @MainActor func providerExecutesOnlyExplicitEnabledCommandsAndUpgradeKeepsConfiguration() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = DemoProvider()
        let registry = PluginUIRegistry()
        registry.register(provider)
        let store = PluginStore(directory: directory, uiRegistry: registry)
        var manifest = fixture(ui: demoLayout)
        try store.installManifest(manifest)
        #expect(provider.executions == 0)
        #expect(provider.renders == 0)
        let command = PluginCommand(action: .showMainWindow)
        try store.saveCommand(command, pluginID: manifest.id)
        let navigation = PluginUINavigation()
        let context = PluginUIContext(pluginID: manifest.id, store: store, navigation: navigation)
        try await registry.execute("demo.run", context: context)
        #expect(provider.executions == 1)
        provider.available = false
        #expect(registry.commands["demo.run"]?.presentation(context).isEnabled == false)
        do {
            try await registry.execute("demo.run", context: context)
            Issue.record("Unavailable command executed")
        } catch {}
        provider.available = true
        store.setEnabled(false, pluginID: manifest.id)
        do {
            try await registry.execute("demo.run", context: context)
            Issue.record("Disabled plugin executed")
        } catch {}
        #expect(provider.executions == 1)
        // Changing only a manifest's slot arrangement needs no host UI change.
        let moved = manifest.ui?.slots.removeValue(forKey: "toolbar.trailing")
        manifest.ui?.slots["footer.trailing"] = moved
        try store.installManifest(manifest)
        #expect(store.installed.first?.commands == [command])
        #expect(store.installed.first?.isEnabled == false)
        let reloaded = PluginStore(directory: directory, uiRegistry: registry)
        #expect(reloaded.installed.first?.manifest.ui == manifest.ui)
        #expect(provider.executions == 1)
    }

    @Test @MainActor func panelsRouteToSheetsTabsAndInlineContent() {
        let navigation = PluginUINavigation()
        let ui = demoLayout
        navigation.open("preferences", presentation: .sheet, interface: ui)
        #expect(navigation.sheet?.id == "preferences")
        navigation.open("second", presentation: .inline, interface: ui)
        #expect(navigation.selectedTabs["pages"] == "second")
        #expect(navigation.inlinePanel == nil)
        navigation.open("preferences", presentation: .inline, interface: ui)
        #expect(navigation.inlinePanel == "preferences")
        navigation.open("missing", presentation: .sheet, interface: ui)
        #expect(navigation.sheet?.id == "preferences")
    }

    @Test @MainActor func arbitraryProviderControlsEverySlotWithoutScreenshotRouting() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginUIRegistry()
        let provider = DemoProvider()
        registry.register(provider)
        let store = PluginStore(directory: directory, uiRegistry: registry)
        let manifest = fixture(ui: demoLayout)
        try store.installManifest(manifest)
        let bounds = Bounds()
        let view = ContentView(initialSelection: manifest.id).environmentObject(store)
            .onPreferenceChange(PanelLayoutBoundsKey.self) { value in MainActor.assumeIsolated { bounds.frames = value }
            }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        let frames = bounds.frames
        let root = try #require(frames["panel.root"])
        for id in [
            "plugin.ui.customHeader", "plugin.ui.preferences", "plugin.ui.run",
            "plugin.ui.pages.tabs", "demo.body", "plugin.ui.customFooter",
        ] {
            #expect(root.contains(try #require(frames[id])))
        }
        #expect(frames["plugin.header.info"] == nil)
        #expect(frames["plugin.header.icon"] == nil)
        #expect(frames["capture.history"] == nil)
        #expect(provider.executions == 0)
        #expect(provider.renders > 0)
    }

    private var demoLayout: PluginInterface {
        PluginInterface(
            icon: "sparkles",
            slots: [
                "header.leading": [.component("customHeader", "demo.header")],
                "header.trailing": [
                    .init(
                        id: "preferences", kind: .button, symbol: "gearshape", panel: "preferences",
                        presentation: .sheet)
                ],
                "toolbar.trailing": [.command("run", "demo.run")],
                "content": [.init(id: "pages", kind: .tabs, panels: ["first", "second"])],
                "footer.leading": [.component("customFooter", "demo.footer")],
                "menuBar": [.command("menuRun", "demo.run")],
            ],
            panels: [
                .init(id: "first", title: "First", component: "demo.body"),
                .init(id: "second", title: "Second", component: "demo.body"),
                .init(id: "preferences", title: "Demo settings", component: "demo.preferences"),
            ])
    }
    private func fixture(ui: PluginInterface) -> PluginManifest {
        .init(
            schemaVersion: 2, id: "com.example.demo", name: "Demo", version: "1.0.0", summary: "Custom provider",
            author: "Tests", repository: HostInfo.repository, minimumHostVersion: "0.4.0",
            actions: [.showMainWindow], templates: [], ui: ui)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @MainActor private final class Bounds { var frames: [String: CGRect] = [:] }
    @MainActor private final class DemoProvider: PluginUIProvider {
        var executions = 0
        var renders = 0
        var available = true
        func register(in registry: PluginUIRegistry) {
            registry.component("demo.header") { _ in AnyView(Text("Custom header")) }
            registry.component("demo.footer") { _ in AnyView(Text("Custom footer")) }
            registry.component("demo.preferences") { _ in AnyView(Text("Custom preferences")) }
            registry.component("demo.body") { [self] _ in
                renders += 1
                return AnyView(
                    Text("Custom body").frame(maxWidth: .infinity, maxHeight: .infinity).panelRegion("demo.body"))
            }
            registry.command(
                "demo.run", requiredActions: [.showMainWindow],
                presentation: { [self] _ in
                    .init(title: "Run demo", symbol: "play", isEnabled: available)
                }
            ) { [self] _ in executions += 1 }
        }
    }
}
