import SwiftUI

struct PluginDetailView: View {
    @EnvironmentObject private var store: PluginStore
    @ViewState private var editingCommand: PluginCommand?
    @ViewState private var confirmUninstall = false
    let pluginID: String

    var body: some View {
        if let plugin = store.installed.first(where: { $0.id == pluginID }) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("v\(plugin.manifest.version)").foregroundStyle(.secondary)
                        Spacer()
                        Toggle("启用插件", isOn: Binding(get: { plugin.isEnabled }, set: { store.setEnabled($0, pluginID: pluginID) }))
                            .toggleStyle(.switch).controlSize(.small)
                    }
                    Text(plugin.manifest.summary).foregroundStyle(.secondary)
                    Text("添加操作后，可手动执行，也可绑定全局快捷键。关闭主窗口后仍可使用；退出应用后停止。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(20)
                Divider()
                List {
                    ForEach(plugin.commands) { command in
                        HStack(spacing: 12) {
                            Image(systemName: command.action.symbol).frame(width: 20).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(command.title)
                                Text(command.action.title + (command.isEnabled ? "" : " · 已停用"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let error = store.hotKeyErrors[command.id] {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                }
                            }
                            Spacer()
                            Text(command.hotKey?.display ?? "未设快捷键")
                                .font(.callout.monospaced()).foregroundStyle(.secondary)
                            Button { Task { await store.execute(command, pluginID: pluginID) } } label: {
                                Image(systemName: "play")
                            }
                            .help("执行 \(command.title)")
                            .disabled(!plugin.isEnabled || !command.isEnabled || !command.isConfigured)
                            Button("编辑") { editingCommand = command }
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button("删除操作", role: .destructive) { store.removeCommand(command.id, pluginID: pluginID) }
                        }
                    }
                }
                .overlay {
                    if plugin.commands.isEmpty {
                        ContentUnavailableView("还没有操作", systemImage: "keyboard", description: Text("点击“添加操作”，选择应用或要执行的事情。"))
                    }
                }
                Divider()
                HStack {
                    Menu("添加操作") {
                        ForEach(plugin.manifest.templates) { template in
                            Button(template.title) { editingCommand = PluginCommand(title: template.title, action: template.action) }
                        }
                        if plugin.manifest.templates.isEmpty {
                            ForEach(plugin.manifest.actions, id: \.self) { action in
                                Button(action.title) { editingCommand = PluginCommand(title: action.title, action: action) }
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Link("源码", destination: plugin.manifest.repository)
                    Button("卸载…", role: .destructive) { confirmUninstall = true }
                }
                .padding(12)
            }
            .navigationTitle(plugin.manifest.name)
            .sheet(item: $editingCommand) { command in
                CommandEditor(pluginID: pluginID, command: command, actions: plugin.manifest.actions)
                    .environmentObject(store)
            }
            .confirmationDialog("卸载「\(plugin.manifest.name)」？", isPresented: $confirmUninstall) {
                Button("卸载", role: .destructive) { store.uninstall(pluginID) }
            } message: { Text("将移除该插件的本地配置，并释放全部快捷键。") }
        }
    }
}
