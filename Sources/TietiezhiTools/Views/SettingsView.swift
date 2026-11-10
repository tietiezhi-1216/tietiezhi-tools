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
        .frame(width: 700, height: 620)
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
        Form {
            Section {
                Text("系统权限统一授予 Tietiezhi Tools，插件按声明使用。只在你点击授权时请求；更改或撤销请前往系统隐私设置。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if let request = permissions.pendingRequest {
                        let missing = request.permissions.contains { permissions.status($0) != .authorized }
                        Text(
                            missing
                                ? "「\(request.pluginName)」需要下列权限，请授权后重新执行。" : "所需权限已就绪，请返回「\(request.pluginName)」重新执行。"
                        )
                        .font(.callout.weight(.medium))
                        Spacer()
                        Button("完成") { permissions.pendingRequest = nil }
                    } else {
                        Text("已安装插件的使用用途会显示在对应权限下方。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button("刷新状态") { permissions.refresh() }
                }
            }
            ForEach(permissions.drivers, id: \.descriptor.id) { driver in
                permissionSection(driver.descriptor)
            }
        }
        .formStyle(.grouped)
        .controlSize(.regular)
        .accessibilityIdentifier("host.permissions")
    }

    private func permissionSection(_ descriptor: HostPermissionDescriptor) -> some View {
        let status = permissions.status(descriptor.id)
        let requested = permissions.pendingRequest?.permissions.contains(descriptor.id) == true
        return Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: descriptor.symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(
                    width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(descriptor.title).font(.headline)
                        if requested { Text("当前需要").font(.caption).foregroundStyle(.tint) }
                    }
                    Text(descriptor.summary).font(.caption).foregroundStyle(.secondary)
                    Text(status.title).font(.caption).foregroundStyle(
                        status == .authorized ? Color.green : Color.secondary)
                }
                Spacer(minLength: 8)
                if status == .notDetermined || status == .notGranted {
                    Button(permissions.requesting == descriptor.id ? "请求中…" : "授权…") {
                        Task { await permissions.request(descriptor.id) }
                    }.disabled(permissions.requesting != nil)
                        .accessibilityIdentifier("host.permission.\(descriptor.id.rawValue).request")
                }
                Button("系统设置") { permissions.openSettings(descriptor.id) }
                    .accessibilityIdentifier("host.permission.\(descriptor.id.rawValue).settings")
            }
            ForEach(usages(descriptor.id), id: \.id) { usage in
                Text(usage.text).font(.caption).foregroundStyle(.secondary)
            }
            if let message = permissions.messages[descriptor.id] {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct Usage: Identifiable {
        let id: String
        let text: String
    }
    private func usages(_ id: HostPermissionID) -> [Usage] {
        store.installed.compactMap { plugin in
            guard let declaration = permissions.declarations(for: plugin.manifest).first(where: { $0.id == id }) else {
                return nil
            }
            let state = plugin.isEnabled ? "" : " · 插件已停用"
            return Usage(
                id: plugin.id,
                text: "\(plugin.manifest.name)：\(declaration.reason)\(declaration.isOptional ? "（可选功能）" : "")\(state)")
        }
    }
}
