import AppKit
import SwiftUI

@main
struct UntitledApp: App {
    @NSApplicationDelegateAdaptor(CaptureAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @StateObject private var store: PluginStore

    init() {
        let isolatedDirectory: URL?
        #if DEBUG
        isolatedDirectory = SharingAcceptance.pluginDirectoryForLaunch()
        #else
        isolatedDirectory = nil
        #endif
        let startupError: String?
        do {
            if isolatedDirectory == nil { try IdentityMigration.prepare() }
            startupError = nil
        } catch { startupError = "数据迁移未完成，原文件已保留：\(error.localizedDescription)" }
        _store = StateObject(wrappedValue: PluginStore(directory: isolatedDirectory, startupError: startupError))
    }

    var body: some Scene {
        Window(HostInfo.name, id: "main") {
            ContentView()
                .environmentObject(store)
                .onAppear { [store, appDelegate] in
                    appDelegate.prepareForQuit = { [weak store] in await store?.prepareForQuit() ?? true }
                    guard !appDelegate.handledLaunchArguments else { return }
                    appDelegate.handledLaunchArguments = true
                    if store.installed.contains(where: { $0.isEnabled && $0.manifest.hasCaptureCapability }) { store.screenshots.pinManager.activate() }
                    let arguments = ProcessInfo.processInfo.arguments
                    #if DEBUG
                    if let index = arguments.firstIndex(of: "--sharing-acceptance"), arguments.indices.contains(index + 1) {
                        do { try store.startSharingAcceptance(at: URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
                        catch { store.handleExecutionError(error) }
                    }
                    #endif
                    let package = arguments.firstIndex(of: "--install-plugin").flatMap { index in arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil }
                    let setup = arguments.firstIndex(of: "--sharing-setup").flatMap { index in arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil }
                    Task {
                        if let package { await store.importPackage(package) }
                        if let setup {
                            do { try store.startSharingSetup(at: setup) }
                            catch { store.handleExecutionError(error) }
                        } else if !arguments.contains("--sharing-acceptance") {
                            do { try store.restorePeripheralSharingSessionIfRequested() }
                            catch { store.handleExecutionError(error) }
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)
        .onChange(of: appearance, initial: true) { _, appearance in
            // 在应用层统一更新窗口与 SwiftUI 内容；nil 会恢复系统外观继承。
            NSApplication.shared.appearance = appearance.appKitAppearance
        }

        Settings {
            SettingsView(store: store)
        }

        MenuBarExtra(HostInfo.name, systemImage: "scribble") {
            AppMenuView().environmentObject(store)
        }
    }
}

@MainActor final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    var prepareForQuit: (() async -> Bool)?
    var handledLaunchArguments = false
    private var finishing = false
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An internal input-focus request must never reopen the main panel.
        !SharingNativeCursorFocus.capturingForInput
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForQuit else { return .terminateNow }
        guard !finishing else { return .terminateLater }
        finishing = true
        Task {
            let ready = await prepareForQuit()
            if !ready { finishing = false }
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}

private struct AppMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var store: PluginStore

    var body: some View {
        Button("打开主面板") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("设置…") }
        Button("权限管理…") {
            store.permissions.settingsPage = .permissions
            store.permissions.refresh()
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        ForEach(store.installed.filter { $0.isEnabled && !store.uiRegistry.interface(for: $0.manifest).items(in: .menuBar).isEmpty }) { plugin in
            Divider()
            PluginMenuContributions(plugin: plugin).environmentObject(store)
        }
        Divider()
        Button("退出 Untitled") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}


private struct PluginMenuContributions: View {
    @EnvironmentObject private var store: PluginStore
    @StateObject private var navigation = PluginUINavigation()
    let plugin: InstalledPlugin
    var body: some View {
        let context = PluginUIContext(pluginID: plugin.id, store: store, navigation: navigation)
        Menu(plugin.manifest.name) {
            ForEach(store.uiRegistry.interface(for: plugin.manifest).items(in: .menuBar)) { item in
                PluginSlotItemView(item: item, context: context, menuItem: true)
            }
        }
    }
}
