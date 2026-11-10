import SwiftUI

struct HostPluginUIProvider: PluginUIProvider {
    func register(in registry: PluginUIRegistry) {
        registry.component("host.icon") { context in
            AnyView(
                PanelIcon(symbol: context.interface?.icon ?? "puzzlepiece.extension").panelRegion("plugin.header.icon"))
        }
        registry.component("host.identity") { context in
            AnyView(PluginIdentityView(context: context))
        }
        for (name, control) in [("enabled", PluginHeaderControl.enabled), ("more", .more), ("info", .info)] {
            registry.component("host.\(name)") { context in
                AnyView(PluginHostControl(context: context, control: control))
            }
        }
        registry.component("host.commandHeading") { _ in AnyView(Text("操作").font(.headline)) }
        registry.component("host.addCommand") { context in AnyView(PluginAddCommandView(pluginID: context.pluginID)) }
        registry.component("host.commands") { context in AnyView(PluginDetailView(pluginID: context.pluginID)) }
        registry.component("host.commandStatus") { _ in
            AnyView(Text("关闭主窗口后快捷键仍然有效，退出应用后停止。").font(.caption).foregroundStyle(.secondary))
        }
        registry.command("host.openPlugin", presentation: { _ in .init(title: "打开插件", symbol: "macwindow") }) {
            context in
            context.store.requestedPluginID = context.pluginID
            context.store.showMainWindow()
        }
    }
}

private struct PluginIdentityView: View {
    let context: PluginUIContext
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(context.plugin?.manifest.name ?? "")
                .font(.system(size: 22, weight: .semibold)).lineLimit(1)
            Text(context.plugin.map { "\($0.manifest.author) · 版本 \($0.manifest.version)" } ?? "")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).panelWindowDragArea().panelRegion("panel.title")
    }
}

private struct PluginHostControl: View {
    @EnvironmentObject private var store: PluginStore
    let context: PluginUIContext
    let control: PluginHeaderControl
    var body: some View {
        if let plugin = store.installed.first(where: { $0.id == context.pluginID }) {
            PluginHeaderControlView(control: control, plugin: plugin)
        }
    }
}
