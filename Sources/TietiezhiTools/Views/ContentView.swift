import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.openWindow) private var openWindow
    @ViewState private var selection: String? = "__store__"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("插件商店", systemImage: "square.grid.2x2")
                    .tag("__store__")
                Section("已安装") {
                    ForEach(store.installed) { plugin in
                        Label(plugin.manifest.name, systemImage: plugin.isEnabled ? "puzzlepiece.extension" : "pause.circle")
                            .tag(plugin.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            Group {
                if let plugin = store.installed.first(where: { $0.id == selection }) {
                    PluginDetailView(pluginID: plugin.id)
                } else {
                    PluginStoreView { selection = $0 }
                }
            }
            .toolbar {
                SettingsLink { Label("设置", systemImage: "gearshape") }
                    .help("设置（⌘,）")
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            let action = openWindow
            store.showMainWindow = {
                action(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}
