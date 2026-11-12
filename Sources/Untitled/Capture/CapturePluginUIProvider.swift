import Combine
import SwiftUI

extension PluginManifest {
    // Capability lifecycle check; this never selects a v2 plugin's layout.
    var hasCaptureCapability: Bool { actions.contains(where: \.isScreenshotAction) }
}

struct CapturePluginUIProvider: PluginUIProvider {
    func register(in registry: PluginUIRegistry) {
        registry.component("capture.history", requiredActions: [.captureHistory]) { context in
            AnyView(CaptureHistoryView(pluginID: context.pluginID, capture: context.store.screenshots))
        }
        registry.component("capture.pins", requiredActions: [.pinClipboard]) { context in
            AnyView(CapturePinsView(manager: context.store.screenshots.pinManager))
        }
        registry.component("capture.preferences", requiredActions: [.captureRegion]) { context in
            AnyView(ScreenshotSettingsView(mouse: context.store.screenshots.globalMouse, capture: context.store.screenshots))
        }
        registry.component("capture.status", requiredActions: [.captureHistory]) { context in
            AnyView(CaptureStatusView(capture: context.store.screenshots))
        }
        let actions: [(String, ActionKind)] = [
            ("region", .captureRegion), ("window", .captureWindow), ("screen", .captureScreen),
            ("scrollVertical", .captureScrolling), ("scrollHorizontal", .captureScrolling),
            ("record", .captureRecording), ("pinClipboard", .pinClipboard),
            ("togglePins", .togglePins), ("history", .captureHistory),
            ("delayed", .captureDelayed), ("copy", .captureAndCopy), ("repeatRegion", .captureLastRegion),
            ("restorePin", .restorePin), ("closePins", .closePins), ("hideOtherPins", .hideOtherPins),
            ("clickThrough", .togglePinClickThrough), ("cycleGroup", .cyclePinGroup), ("pinFiles", .pinFiles),
            ("toggleHotKeys", .toggleCaptureHotKeys),
        ]
        for (name, action) in actions {
            registry.command(
                "capture.\(name)", requiredActions: [action],
                presentation: { context in
                    let capture = context.store.screenshots
                    let title: String =
                        switch name {
                        case "scrollVertical": "纵向长截图"
                        case "scrollHorizontal": "横向长截图"
                        case "record": capture.isRecording ? "停止录屏" : "录屏"
                        case "pinClipboard": "剪贴板贴图"
                        case "toggleHotKeys": context.store.captureHotKeysPaused ? "恢复截图快捷键" : "暂停截图快捷键"
                        default: action.title
                        }
                    return .init(
                        title: title,
                        symbol: name == "record" && capture.isRecording ? "stop.circle.fill" : action.symbol,
                        isEnabled: !capture.busy)
                },
                updates: { context in
                    context.store.screenshots.objectWillChange.eraseToAnyPublisher()
                }
            ) { context in
                if name == "scrollVertical" || name == "scrollHorizontal" {
                    UserDefaults.standard.set(
                        name == "scrollVertical" ? StitchAxis.vertical.rawValue : StitchAxis.horizontal.rawValue,
                        forKey: "capture.scrollAxis")
                }
                try await context.store.performScreenshot(action, pluginID: context.pluginID)
            }
        }
        registry.command(
            "capture.importImage", requiredActions: [.captureRegion],
            presentation: { context in
                .init(title: "导入…", symbol: "square.and.arrow.down", isEnabled: !context.store.screenshots.busy)
            }, updates: { $0.store.screenshots.objectWillChange.eraseToAnyPublisher() }
        ) { context in
            context.store.screenshots.importImage()
        }
    }

    func legacyInterface(for manifest: PluginManifest) -> PluginInterface? {
        // Only v1 packages need this compatibility adapter. v2 uses its own declaration verbatim.
        guard manifest.schemaVersion == 1, manifest.actions.contains(.captureRegion),
            manifest.actions.contains(.captureHistory)
        else { return nil }
        var ui = PluginUIRegistry.legacyCommands
        ui.icon = "camera.viewfinder"
        ui.slots[PluginUISlot.headerTrailing.rawValue, default: []].append(
            PluginUIItem(
                id: "preferencesButton", kind: .button, symbol: "gearshape",
                panel: "preferences", presentation: .sheet)
        )
        ui.slots[PluginUISlot.toolbarLeading.rawValue] = [
            .command("region", "capture.region"), .command("record", "capture.record"),
        ].filter { item in
            item.command != "capture.record" || manifest.actions.contains(.captureRecording)
        }
        ui.slots[PluginUISlot.toolbarTrailing.rawValue] = [.command("import", "capture.importImage")]
        ui.slots[PluginUISlot.content.rawValue] = [
            PluginUIItem(id: "pages", kind: .tabs, panels: ["history", "shortcuts"])
        ]
        ui.slots[PluginUISlot.footerLeading.rawValue] = [.component("status", "capture.status")]
        ui.panels = [
            .init(id: "history", title: "历史记录", component: "capture.history"),
            .init(
                id: "shortcuts", title: "快捷键",
                slots: [
                    PluginUISlot.toolbarLeading.rawValue: [.component("shortcutHeading", "host.commandHeading")],
                    PluginUISlot.toolbarTrailing.rawValue: [.component("shortcutAdd", "host.addCommand")],
                    PluginUISlot.content.rawValue: [.component("shortcutCommands", "host.commands")],
                    PluginUISlot.footerLeading.rawValue: [.component("shortcutStatus", "host.commandStatus")],
                ]),
            .init(id: "preferences", title: "截图设置", component: "capture.preferences"),
        ]
        ui.slots[PluginUISlot.menuBar.rawValue] = manifest.actions.filter(\.isScreenshotAction).compactMap { action in
            actionsReference(action).map { .command("menu.\(action.rawValue)", $0) }
        }
        return ui
    }

    private func actionsReference(_ action: ActionKind) -> String? {
        switch action {
        case .captureRegion: "capture.region"
        case .captureWindow: "capture.window"
        case .captureScreen: "capture.screen"
        case .captureScrolling: "capture.scrollVertical"
        case .captureRecording: "capture.record"
        case .pinClipboard: "capture.pinClipboard"
        case .togglePins: "capture.togglePins"
        case .captureHistory: "capture.history"
        default: nil
        }
    }
}
