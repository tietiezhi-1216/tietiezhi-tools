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

    @Test @MainActor func hostInsetsTheRealSharingDashboardAtBothWindowSizes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [CGSize(width: 880, height: 580), CGSize(width: 1040, height: 720)] {
                let directory = temporary(), domain = "host-insets-\(UUID().uuidString)"
                let settings = UserDefaults(suiteName: domain)!
                settings.set("left", forKey: "sharing.edge")
                settings.set(try JSONEncoder().encode(SharingScreenPixels(width: 1920, height: 1080)), forKey: "sharing.peerPixels")
                defer { try? FileManager.default.removeItem(at: directory); settings.removePersistentDomain(forName: domain) }
                let controller = PeripheralSharingController(defaults: settings, screenPixels: .init(width: 2560, height: 1080))
                let registry = PluginUIRegistry(), provider = DemoProvider()
                registry.register(HostPluginUIProvider())
                provider.bodyOverride = AnyView(SharingPluginView(controller: controller, keyAvailable: { true }))
                registry.register(provider)
                let store = PluginStore(directory: directory, uiRegistry: registry)
                let ui = PluginInterface(slots: [
                    "header.leading": [.component("icon", "host.icon"), .component("identity", "host.identity")],
                    "header.trailing": [.component("enabled", "host.enabled"), .component("info", "host.info")],
                    "content": [.component("dashboard", "demo.body")], "footer.leading": [.component("status", "demo.footer")]
                ])
                let manifest = fixture(ui: ui, name: "外设共享")
                try store.installManifest(manifest)
                let view = ContentView(initialSelection: manifest.id).environmentObject(store).environment(\.colorScheme, scheme)
                try render(view, size: size) { frames, host in
                    let workspace = try #require(frames["plugin.workspace"]), safe = try #require(frames["plugin.content.bounds"])
                    let viewport = try #require(frames["plugin.content.viewport"]), canvas = try #require(frames["sharing.layout.editor"])
                    #expect(abs(safe.minX - workspace.minX - PanelLayout.contentInset) < 0.1)
                    #expect(abs(workspace.maxX - safe.maxX - PanelLayout.contentInset) < 0.1)
                    #expect(abs(safe.minY - viewport.minY - PanelLayout.contentVerticalInset) < 0.1)
                    #expect(abs(viewport.maxY - safe.maxY - PanelLayout.contentVerticalInset) < 0.1)
                    #expect(abs(canvas.minX - safe.minX) < 0.1 && abs(canvas.maxX - safe.maxX) < 0.1)
                    #expect(abs(try #require(frames["plugin.header.icon"]).minX - canvas.minX) < 0.1)
                    #expect(safe.contains(canvas))
                    #expect(!controller.isRunning && controller.transport.port == nil)
                    if scheme == .dark, size.width == 1040, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/untitled-host-insets-preview.png"))
                    }
                }
            }
        }
    }

    @Test @MainActor func oversizedOffsetContentCannotPaintIntoHostGutters() throws {
        let view = PluginContentViewport(forceInsets: true) {
            Color.red.frame(width: 2000, height: 2000).offset(x: -80, y: -80)
        }.background(Color.blue)
        try render(view, size: CGSize(width: 400, height: 240)) { frames, host in
            #expect(try #require(frames["plugin.content.bounds"]) == CGRect(x: 28, y: 16, width: 344, height: 208))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            for point in [CGPoint(x: 4, y: 120), CGPoint(x: 396, y: 120), CGPoint(x: 200, y: 4), CGPoint(x: 200, y: 236)] {
                let color = try #require(bitmap.colorAt(x: Int(point.x / 400 * CGFloat(bitmap.pixelsWide)), y: Int(point.y / 240 * CGFloat(bitmap.pixelsHigh)))?.usingColorSpace(.deviceRGB))
                #expect(color.blueComponent > color.redComponent + 0.5)
            }
            let middle = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(middle.redComponent > middle.blueComponent + 0.5)
        }
    }

    @Test @MainActor func nestedTabsAndSlotPanelsReceiveOnlyOneHostInset() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginUIRegistry(); registry.register(DemoProvider())
        let store = PluginStore(directory: directory, uiRegistry: registry)
        var ui = demoLayout
        ui.panels?[0] = .init(id: "first", title: "First", slots: [
            "toolbar.leading": [.component("nestedHeading", "demo.header")],
            "content": [.component("nestedBody", "demo.body")], "footer.leading": [.component("nestedFooter", "demo.footer")]
        ])
        let manifest = fixture(ui: ui); try store.installManifest(manifest)
        let view = ContentView(initialSelection: manifest.id).environmentObject(store)
        try render(view, size: CGSize(width: 1040, height: 720)) { frames, _ in
            let safe = try #require(frames["plugin.content.bounds"])
            #expect(safe.contains(try #require(frames["plugin.ui.pages.tabs"])))
            for id in ["plugin.panel.toolbar", "plugin.panel.content.bounds", "demo.body"] {
                let frame = try #require(frames[id])
                #expect(abs(frame.minX - safe.minX) < 0.1 && abs(frame.maxX - safe.maxX) < 0.1, "\(id): \(frame), safe: \(safe)")
            }
        }
    }

    @Test @MainActor func inlinePanelsReuseMarginsAndSheetsGetTheirOwnMargins() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginUIRegistry(); registry.register(DemoProvider())
        let store = PluginStore(directory: directory, uiRegistry: registry), ui = demoLayout
        let manifest = fixture(ui: ui); try store.installManifest(manifest)
        let navigation = PluginUINavigation(), context = PluginUIContext(pluginID: manifest.id, store: store, navigation: navigation)
        navigation.inlinePanel = "preferences"
        let inline = PluginUILayoutView(slots: ui.slots, context: context, root: true).environmentObject(store)
        try render(inline, size: CGSize(width: 660, height: 560)) { frames, _ in
            let safe = try #require(frames["plugin.content.bounds"]), body = try #require(frames["demo.preferences"])
            #expect(abs(safe.minX - 28) < 0.1 && abs(body.minX - safe.minX) < 0.1 && abs(body.maxX - safe.maxX) < 0.1)
        }
        let sheet = PluginPanelSheet(panelID: "preferences", context: context).environmentObject(store).environment(\.pluginContentHasInsets, true)
        try render(sheet, size: CGSize(width: 660, height: 560)) { frames, _ in
            let safe = try #require(frames["plugin.sheet.content.bounds"]), body = try #require(frames["demo.preferences"])
            #expect(abs(safe.minX - 28) < 0.1 && abs(safe.maxX - 632) < 0.1)
            #expect(abs(body.minX - safe.minX) < 0.1 && abs(body.maxX - safe.maxX) < 0.1)
            #expect(abs(try #require(frames["plugin.sheet.heading"]).minX - safe.minX) < 0.1)
        }
    }

    @Test @MainActor func hostCommandListDoesNotAddASecondPageMargin() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginUIRegistry(); registry.register(HostPluginUIProvider())
        let store = PluginStore(directory: directory, uiRegistry: registry)
        let ui = PluginInterface(slots: [
            "header.leading": [.component("icon", "host.icon"), .component("identity", "host.identity")],
            "toolbar.leading": [.component("heading", "host.commandHeading")],
            "content": [.component("commands", "host.commands")], "footer.leading": [.component("footer", "host.commandStatus")]
        ])
        let manifest = fixture(ui: ui); try store.installManifest(manifest)
        let command = PluginCommand(action: .showMainWindow); try store.saveCommand(command, pluginID: manifest.id)
        let view = ContentView(initialSelection: manifest.id).environmentObject(store)
        try render(view, size: CGSize(width: 880, height: 580)) { frames, _ in
            let safe = try #require(frames["plugin.content.bounds"]), row = try #require(frames["command.\(command.id.uuidString)"])
            #expect(abs(row.minX - safe.minX) < 0.1 && abs(row.maxX - safe.maxX) < 0.1)
        }
    }

    @MainActor private func render<V: View>(_ view: V, size: CGSize, verify: ([String: CGRect], NSView) throws -> Void) throws {
        let bounds = Bounds()
        let measured = view.coordinateSpace(name: PanelLayout.coordinateSpace).onPreferenceChange(PanelLayoutBoundsKey.self) { value in
            MainActor.assumeIsolated { bounds.frames = value }
        }
        let host = NSHostingView(rootView: measured)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try verify(bounds.frames, host)
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
    private func fixture(ui: PluginInterface, name: String = "Demo") -> PluginManifest {
        .init(
            schemaVersion: 2, id: "com.example.demo", name: name, version: "1.0.0", summary: "Custom provider",
            author: "Tests", repository: HostInfo.repository, minimumHostVersion: "0.4.0",
            actions: [.showMainWindow], templates: [], ui: ui)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @MainActor private final class Bounds { var frames: [String: CGRect] = [:] }
    @MainActor private final class DemoProvider: PluginUIProvider {
        var executions = 0
        var renders = 0
        var available = true
        var bodyOverride: AnyView?
        func register(in registry: PluginUIRegistry) {
            registry.component("demo.header") { _ in AnyView(Text("Custom header")) }
            registry.component("demo.footer") { _ in AnyView(Text("Custom footer")) }
            registry.component("demo.preferences") { _ in AnyView(Text("Custom preferences").frame(maxWidth: .infinity, maxHeight: .infinity).panelRegion("demo.preferences")) }
            registry.component("demo.body") { [self] _ in
                renders += 1
                return AnyView((bodyOverride ?? AnyView(Text("Custom body")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).panelRegion("demo.body"))
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
