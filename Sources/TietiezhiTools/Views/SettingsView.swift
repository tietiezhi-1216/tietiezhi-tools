import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store: PluginStore
    @ObservedObject private var permissions: HostPermissionCenter
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    init(store: PluginStore) {
        self.store = store
        permissions = store.permissions
    }

    var body: some View {
        TabView(selection: $permissions.settingsPage) {
            generalSettings.tabItem { Label("通用", systemImage: "gearshape") }.tag(HostSettingsPage.general)
            PermissionManagementView(store: store, permissions: permissions)
                .tabItem { Label("权限管理", systemImage: "hand.raised") }.tag(HostSettingsPage.permissions)
        }
        .frame(width: 640, height: 440)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private var generalSettings: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
                }
            }
            Section("关于") {
                LabeledContent("应用", value: "Tietiezhi Tools")
                LabeledContent(
                    "版本",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                        ?? HostInfo.version)
                Link("GitHub 项目与插件仓库", destination: HostInfo.repository)
            }
        }.formStyle(.grouped)
    }
}

struct PermissionManagementView: View {
    @ObservedObject var store: PluginStore
    @ObservedObject var permissions: HostPermissionCenter

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let request = permissions.pendingRequest {
                    let missing = request.permissions.contains { permissions.status($0) != .authorized }
                    Text(missing ? "「\(request.pluginName)」需要授权" : "已就绪，请返回「\(request.pluginName)」重试")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Button {
                        permissions.pendingRequest = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("关闭提示").accessibilityLabel("关闭权限提示")
                }
                Spacer(minLength: 0)
                Button {
                    permissions.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("刷新权限状态").accessibilityLabel("刷新权限状态")
            }
            .padding(.horizontal, 24).padding(.top, 16)

            Form {
                Section {
                    ForEach(permissions.drivers, id: \.descriptor.id) { driver in
                        PermissionRow(store: store, permissions: permissions, descriptor: driver.descriptor)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .controlSize(.regular)
        .accessibilityIdentifier("host.permissions")
    }
}

private struct PermissionRow: View {
    @ObservedObject var store: PluginStore
    @ObservedObject var permissions: HostPermissionCenter
    let descriptor: HostPermissionDescriptor
    @ViewState private var showingInfo = false

    var body: some View {
        let status = permissions.status(descriptor.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: descriptor.symbol)
                    .font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
                    .accessibilityHidden(true)
                Text(descriptor.title).font(.callout)
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("查看用途").accessibilityLabel("\(descriptor.title)用途")
                .popover(isPresented: $showingInfo) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(descriptor.title).font(.headline)
                        Text(descriptor.summary).font(.callout).foregroundStyle(.secondary)
                        if !usages.isEmpty {
                            Divider()
                            ViewThatFits(in: .vertical) {
                                usageList
                                ScrollView { usageList }
                            }.frame(maxHeight: 180)
                        }
                        Button("在系统设置中管理") { permissions.openSettings(descriptor.id) }
                            .font(.callout)
                    }
                    .padding(20).frame(width: 320)
                }
                Spacer(minLength: 8)
                Text(status.title).font(.callout)
                    .foregroundStyle(status == .authorized ? Color.green : Color.secondary)
                    .frame(width: 82, alignment: .trailing)
                if status == .notDetermined || status == .notGranted, permissions.messages[descriptor.id] == nil {
                    Button(permissions.requesting == descriptor.id ? "请求中…" : "授权…") {
                        Task { await permissions.request(descriptor.id) }
                    }.disabled(permissions.requesting != nil)
                        .accessibilityIdentifier("host.permission.\(descriptor.id.rawValue).request")
                        .frame(width: 88, alignment: .trailing)
                } else {
                    Button("系统设置") { permissions.openSettings(descriptor.id) }
                        .accessibilityIdentifier("host.permission.\(descriptor.id.rawValue).settings")
                        .frame(width: 88, alignment: .trailing)
                }
            }
            .frame(minHeight: 38)
            if let message = permissions.messages[descriptor.id] {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
        }
    }

    private struct Usage: Identifiable {
        let id: String
        let text: String
    }
    private var usageList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(usages, id: \.id) { usage in
                Text(usage.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var usages: [Usage] {
        store.installed.compactMap { plugin in
            guard
                let declaration = permissions.declarations(for: plugin.manifest).first(where: { $0.id == descriptor.id }
                )
            else {
                return nil
            }
            let state = plugin.isEnabled ? "" : " · 插件已停用"
            return Usage(
                id: plugin.id,
                text: "\(plugin.manifest.name)：\(declaration.reason)\(declaration.isOptional ? "（可选功能）" : "")\(state)")
        }
    }
}
