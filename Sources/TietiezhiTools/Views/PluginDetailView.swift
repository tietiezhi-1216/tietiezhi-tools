import SwiftUI

struct PluginDetailView: View {
    @EnvironmentObject private var store: PluginStore
    @ViewState private var editingCommand: PluginCommand?
    @ViewState private var confirmUninstall = false
    let pluginID: String

    var body: some View {
        if let plugin = store.installed.first(where: { $0.id == pluginID }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: PanelLayout.itemSpacing) {
                    PanelIcon(symbol: "puzzlepiece.extension")
                    Text(plugin.manifest.summary)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(plugin.manifest.summary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("启用", isOn: Binding(
                        get: { plugin.isEnabled },
                        set: { store.setEnabled($0, pluginID: pluginID) }
                    ))
                    .toggleStyle(.switch).controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("启用插件")
                    Menu {
                        Link("查看源码", destination: plugin.manifest.repository)
                        Divider()
                        Button("卸载插件…", role: .destructive) { confirmUninstall = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 20, height: 24)
                    }
                    .menuIndicator(.hidden)
                    .panelGlassButton(circular: true)
                    .help("插件更多操作")
                    .accessibilityLabel("插件更多操作")
                }
                .padding(.horizontal, PanelLayout.contentInset)
                .padding(.vertical, 20)
                .accessibilityElement(children: .contain)
                .panelRegion("plugin.summary")

                PanelDivider()

                HStack {
                    Text("操作").font(.headline)
                    Spacer()
                    Menu {
                        ForEach(plugin.manifest.templates) { template in
                            Button(template.title) {
                                editingCommand = PluginCommand(action: template.action)
                            }
                        }
                        if plugin.manifest.templates.isEmpty {
                            ForEach(plugin.manifest.actions, id: \.self) { action in
                                Button(action.title) {
                                    editingCommand = PluginCommand(action: action)
                                }
                            }
                        }
                    } label: {
                        Label("添加操作", systemImage: "plus")
                    }
                    .panelGlassButton(prominent: true)
                    .fixedSize()
                }
                .padding(.horizontal, PanelLayout.contentInset)
                .frame(height: 58)
                .accessibilityElement(children: .contain)
                .panelRegion("plugin.commands.toolbar")

                PanelDivider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(plugin.commands) { command in
                            commandRow(command, plugin: plugin)
                            if command.id != plugin.commands.last?.id { PanelDivider() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if plugin.commands.isEmpty {
                        ContentUnavailableView(
                            "还没有操作", systemImage: "keyboard",
                            description: Text("点击右上方“添加操作”，选择应用或要执行的事情。")
                        )
                    }
                }

                Text("关闭主窗口后快捷键仍然有效，退出应用后停止。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, PanelLayout.contentInset)
                    .frame(height: 44, alignment: .leading)
            }
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
                Text(command.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(command.title)
                Text(commandDescription(command) + (command.isEnabled ? "" : " · 已停用"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                if let error = store.hotKeyErrors[command.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PanelLayout.itemSpacing)
            Text(command.hotKey?.display ?? "未设快捷键")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
            HStack(spacing: 8) {
                Button { Task { await store.execute(command, pluginID: pluginID) } } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .frame(width: 16)
                }
                .help("执行 \(command.title)")
                .accessibilityLabel("执行 \(command.title)")
                .disabled(!plugin.isEnabled || !command.isEnabled || !command.isConfigured)
                Button("编辑") { editingCommand = command }
            }
            .panelGlassButton()
            .fixedSize()
        }
        .padding(.horizontal, PanelLayout.contentInset)
        .padding(.vertical, PanelLayout.rowInset)
        .accessibilityElement(children: .contain)
        .panelRegion("command.\(command.id.uuidString)")
        .contextMenu {
            Button("删除操作", role: .destructive) { store.removeCommand(command.id, pluginID: pluginID) }
        }
    }

    private func commandDescription(_ command: PluginCommand) -> String {
        switch command.action {
        case .openApplication:
            "打开应用"
        case .openURL:
            command.target.isEmpty ? "尚未设置网址" : command.target
        case .runShortcut:
            "运行 macOS 快捷指令"
        case .showMainWindow:
            "将工具箱主窗口带到前台"
        }
    }
}
