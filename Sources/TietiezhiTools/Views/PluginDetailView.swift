import SwiftUI

struct PluginDetailView: View {
    @EnvironmentObject private var store: PluginStore
    @ViewState private var editingCommand: PluginCommand?
    @ViewState private var confirmUninstall = false
    let pluginID: String

    var body: some View {
        if let plugin = store.installed.first(where: { $0.id == pluginID }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: PanelLayout.itemSpacing) {
                    PanelIcon(symbol: "puzzlepiece.extension")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("版本 \(plugin.manifest.version)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("启用插件", isOn: Binding(
                                get: { plugin.isEnabled },
                                set: { store.setEnabled($0, pluginID: pluginID) }
                            ))
                            .toggleStyle(.switch).controlSize(.small)
                        }
                        Text(plugin.manifest.summary)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(PanelLayout.contentInset)

                PanelDivider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(plugin.commands) { command in
                            commandRow(command, plugin: plugin)
                            if command.id != plugin.commands.last?.id { PanelDivider() }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if plugin.commands.isEmpty {
                        ContentUnavailableView(
                            "还没有操作", systemImage: "keyboard",
                            description: Text("点击“添加操作”，选择应用或要执行的事情。")
                        )
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PanelActionBar {
                    Menu {
                        ForEach(plugin.manifest.templates) { template in
                            Button(template.title) {
                                editingCommand = PluginCommand(title: template.title, action: template.action)
                            }
                        }
                        if plugin.manifest.templates.isEmpty {
                            ForEach(plugin.manifest.actions, id: \.self) { action in
                                Button(action.title) {
                                    editingCommand = PluginCommand(title: action.title, action: action)
                                }
                            }
                        }
                    } label: {
                        Label("添加操作", systemImage: "plus")
                    }
                    .fixedSize()
                    Spacer(minLength: 16)
                    Link("源码", destination: plugin.manifest.repository)
                        .foregroundStyle(.secondary)
                    Button("卸载…", role: .destructive) { confirmUninstall = true }
                }
            }
            .navigationTitle(plugin.manifest.name)
            .sheet(item: $editingCommand) { command in
                CommandEditor(pluginID: pluginID, command: command, actions: plugin.manifest.actions)
                    .environmentObject(store)
            }
            .confirmationDialog("卸载「\(plugin.manifest.name)」？", isPresented: $confirmUninstall) {
                Button("卸载", role: .destructive) { store.uninstall(pluginID) }
            } message: {
                Text("将移除该插件的本地配置，并释放全部快捷键。")
            }
        }
    }

    private func commandRow(_ command: PluginCommand, plugin: InstalledPlugin) -> some View {
        HStack(spacing: PanelLayout.itemSpacing) {
            PanelIcon(symbol: command.action.symbol)
            VStack(alignment: .leading, spacing: 6) {
                Text(command.title).font(.headline)
                Text(command.action.title + (command.isEnabled ? "" : " · 已停用"))
                    .font(.callout).foregroundStyle(.secondary)
                if let error = store.hotKeyErrors[command.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PanelLayout.itemSpacing)
            Text(command.hotKey?.display ?? "未设快捷键")
                .font(.callout.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { Task { await store.execute(command, pluginID: pluginID) } } label: {
                    Image(systemName: "play")
                }
                .help("执行 \(command.title)")
                .disabled(!plugin.isEnabled || !command.isEnabled || !command.isConfigured)
                Button("编辑") { editingCommand = command }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, PanelLayout.contentInset)
        .padding(.vertical, PanelLayout.rowInset)
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("删除操作", role: .destructive) { store.removeCommand(command.id, pluginID: pluginID) }
        }
    }
}
