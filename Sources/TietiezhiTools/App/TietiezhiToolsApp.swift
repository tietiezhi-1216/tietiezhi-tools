import AppKit
import SwiftUI

@main
struct TietiezhiToolsApp: App {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @StateObject private var store = PluginStore()

    var body: some Scene {
        Window("Tietiezhi Tools", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1040, height: 720)
        .onChange(of: appearance, initial: true) { _, appearance in
            // 在应用层统一更新窗口与 SwiftUI 内容；nil 会恢复系统外观继承。
            NSApplication.shared.appearance = appearance.appKitAppearance
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Tietiezhi Tools", systemImage: "wrench.and.screwdriver") {
            AppMenuView()
        }
    }
}

private struct AppMenuView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开主面板") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 Tietiezhi Tools") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
