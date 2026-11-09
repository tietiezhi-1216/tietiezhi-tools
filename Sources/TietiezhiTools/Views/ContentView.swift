import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewState private var selection: String

    init(initialSelection: String = "__store__") {
        _selection = ViewState(wrappedValue: initialSelection)
    }

    private var selectedPlugin: InstalledPlugin? {
        store.installed.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: PanelLayout.sidebarWidth)
            Divider()
                .opacity(0.45)
            VStack(spacing: 0) {
                pageHeader
                Group {
                    if let plugin = selectedPlugin {
                        PluginDetailView(pluginID: plugin.id)
                    } else {
                        PluginStoreView { selection = $0 }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelPalette.content(scheme).opacity(contentBackgroundOpacity))
        }
        .frame(minWidth: 880, minHeight: 580)
        .background {
            if reduceTransparency {
                PanelPalette.window(scheme)
            } else {
                ZStack {
                    PanelWindowBackdrop()
                    PanelPalette.window(scheme).opacity(0.96)
                }
            }
        }
        .background {
            PanelWindowChromeAccessor()
                .allowsHitTesting(false)
        }
        .panelRegion("panel.root")
        .coordinateSpace(name: PanelLayout.coordinateSpace)
        .ignoresSafeArea(.container, edges: .top)
        .controlSize(.regular)
        .onAppear {
            let action = openWindow
            store.showMainWindow = {
                action(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: PanelLayout.windowControlsHeight)
                .contentShape(Rectangle())
                .panelWindowDragArea()
                .panelRegion("panel.windowControls")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    navigationItem("插件商店", symbol: "square.grid.2x2", id: "__store__")
                    Text("已安装")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 22)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(store.installed) { plugin in
                        navigationItem(
                            plugin.manifest.name,
                            symbol: plugin.isEnabled ? "puzzlepiece.extension" : "pause.circle",
                            id: plugin.id
                        )
                    }
                    if store.installed.isEmpty {
                        Text("安装的插件会显示在这里")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            Text("Tietiezhi Tools")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
        }
        .frame(maxHeight: .infinity)
        .panelNavigationSurface()
        .accessibilityElement(children: .contain)
        .panelRegion("panel.sidebar")
    }

    private func navigationItem(_ title: String, symbol: String, id: String) -> some View {
        Button { selection = id } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(selection == id ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(title)
            }
                .font(.system(size: 13, weight: selection == id ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selection == id ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
                .background(
                    selection == id ? Color.primary.opacity(0.065) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(selection == id ? 0.06 : 0), lineWidth: 1 / displayScale)
                }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
        .panelRegion("navigation.\(id)")
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedPlugin?.manifest.name ?? "插件商店")
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                    Text(selectedPlugin.map { "\($0.manifest.author) · 版本 \($0.manifest.version)" }
                         ?? "发现并安装你的常用工具")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .panelWindowDragArea()

                if let plugin = selectedPlugin {
                    PluginHeaderControls(plugin: plugin)
                        .id(plugin.id)
                }

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 18, height: 18)
                }
                .panelGlassButton(circular: true)
                .help("设置（⌘,）")
                .accessibilityLabel("设置")
            }
            .panelRegion("panel.heading")

            if let plugin = selectedPlugin {
                Text(plugin.manifest.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(plugin.manifest.summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelWindowDragArea()
                    .panelRegion("plugin.summary")
            }
        }
        .padding(.horizontal, PanelLayout.contentInset)
        .padding(.vertical, 24)
        .frame(minHeight: 96)
        .accessibilityElement(children: .contain)
        .panelRegion("panel.header")
    }

    private var contentBackgroundOpacity: Double {
        if reduceTransparency { return 1 }
        return contrast == .increased ? 1 : 0.98
    }
}
