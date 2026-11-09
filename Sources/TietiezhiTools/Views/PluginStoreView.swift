import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PluginStoreView: View {
    @EnvironmentObject private var store: PluginStore
    @ViewState private var search = ""
    let selectPlugin: (String) -> Void

    private var entries: [CatalogEntry] {
        store.catalog.filter { search.isEmpty || ($0.name + $0.summary).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PanelSearchField(text: $search)
                    .frame(maxWidth: 300)
                Spacer(minLength: 12)
                Button { Task { await store.refreshCatalog() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 22)
                }
                .help("刷新插件商店")
                .accessibilityLabel("刷新插件商店")
                .panelGlassButton(circular: true)
                .disabled(store.isRefreshing)
                Button(action: importPackage) {
                    Label("从 ZIP 安装…", systemImage: "square.and.arrow.down")
                }
                .panelGlassButton()
                .disabled(store.isInstalling)
            }
            .padding(.horizontal, PanelLayout.contentInset)
            .padding(.vertical, 18)
            .accessibilityElement(children: .contain)
            .panelRegion("store.controls")

            if let error = store.catalogError {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await store.refreshCatalog() } }
                }
                .padding(.horizontal, PanelLayout.contentInset)
                .padding(.bottom, 16)
            }

            PanelDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        pluginRow(entry)
                        if entry.id != entries.last?.id { PanelDivider() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if store.isRefreshing && store.catalog.isEmpty {
                    ProgressView("正在加载插件…")
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "暂无可用插件" : "没有找到插件",
                        systemImage: "puzzlepiece.extension",
                        description: Text(search.isEmpty ? "刷新商店，或从本地 ZIP 包安装。" : "试试其他关键词。")
                    )
                }
            }

            HStack(spacing: 12) {
                Link("打开插件仓库", destination: HostInfo.repository.appendingPathComponent("tree/main/Plugins"))
                Spacer()
                if store.isInstalling {
                    ProgressView().controlSize(.small)
                    Text("正在安装…").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, PanelLayout.contentInset)
            .frame(height: 52)
        }
        .task { if store.catalog.isEmpty { await store.refreshCatalog() } }
    }

    private func pluginRow(_ entry: CatalogEntry) -> some View {
        HStack(alignment: .center, spacing: PanelLayout.itemSpacing) {
            PanelIcon(symbol: "puzzlepiece.extension")
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name).font(.headline).lineLimit(1)
                Text(entry.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(entry.author) · v\(entry.version)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PanelLayout.itemSpacing)
            installButton(entry)
                .frame(width: PanelLayout.actionWidth)
        }
        .padding(.horizontal, PanelLayout.contentInset)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func installButton(_ entry: CatalogEntry) -> some View {
        if let installed = store.installed.first(where: { $0.id == entry.id }) {
            if Version(entry.version)! > Version(installed.manifest.version)! {
                Button("更新") { Task { await store.install(entry) } }
                    .panelGlassButton(prominent: true)
                    .disabled(store.isInstalling)
            } else {
                Button("打开") { selectPlugin(entry.id) }
                    .panelGlassButton()
            }
        } else {
            Button("安装") { Task { await store.install(entry) } }
                .panelGlassButton(prominent: true)
                .disabled(store.isInstalling)
        }
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.title = "选择插件 ZIP 包"
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await store.importPackage(url) }
        }
    }
}
