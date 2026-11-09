import AppKit
import SwiftUI

@main
struct TietiezhiToolsApp: App {
    @NSApplicationDelegateAdaptor(CaptureAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @StateObject private var store = PluginStore()

    var body: some Scene {
        Window("Tietiezhi Tools", id: "main") {
            ContentView()
                .environmentObject(store)
                .onAppear { [store, appDelegate] in
                    appDelegate.prepareForQuit = { [weak store] in await store?.prepareForQuit() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)
        .onChange(of: appearance, initial: true) { _, appearance in
            // 在应用层统一更新窗口与 SwiftUI 内容；nil 会恢复系统外观继承。
            NSApplication.shared.appearance = appearance.appKitAppearance
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Tietiezhi Tools", systemImage: "wrench.and.screwdriver") {
            AppMenuView().environmentObject(store)
        }
    }
}

@MainActor final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    var prepareForQuit: (() async -> Void)?
    private var finishing = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForQuit else { return .terminateNow }
        guard !finishing else { return .terminateLater }
        finishing = true
        Task {
            await prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct AppMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: PluginStore

    var body: some View {
        Button("打开主面板") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("设置…") }
        if let plugin = store.screenshotPlugin {
            Divider()
            ForEach([ActionKind.captureRegion, .captureWindow, .captureScrolling, .captureRecording, .pinClipboard, .togglePins, .captureHistory], id: \.self) { action in
                Button(action.title) {
                    Task {
                        do { try await store.performScreenshot(action, pluginID: plugin.id) }
                        catch { store.errorMessage = error.localizedDescription; store.showMainWindow() }
                    }
                }
            }
        }
        Divider()
        Button("退出 Tietiezhi Tools") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
