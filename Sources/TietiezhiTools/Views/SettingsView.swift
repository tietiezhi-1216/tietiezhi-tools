import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var permissions: HostPermissionCenter
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    init(store: PluginStore) {
        permissions = store.permissions
    }

    var body: some View {
        TabView(selection: $permissions.settingsPage) {
            generalSettings.tabItem { Label("通用", systemImage: "gearshape") }.tag(HostSettingsPage.general)
            PermissionManagementView(permissions: permissions)
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
                        PermissionRow(permissions: permissions, descriptor: driver.descriptor)
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
    @ObservedObject var permissions: HostPermissionCenter
    let descriptor: HostPermissionDescriptor
    @ViewState private var showingInfo = false

    var body: some View {
        let status = permissions.status(descriptor.id)
        let needed = status != .authorized && permissions.pendingRequest?.permissions.contains(descriptor.id) == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: descriptor.symbol)
                    .font(.system(size: 16)).foregroundStyle(needed ? Color.accentColor : Color.secondary).frame(
                        width: 22
                    )
                    .accessibilityHidden(true)
                Text(descriptor.title).font(.callout.weight(needed ? .medium : .regular))
                    .foregroundStyle(needed ? Color.accentColor : Color.primary)
                    .accessibilityLabel(needed ? "\(descriptor.title)，当前需要" : descriptor.title)
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("查看用途").accessibilityLabel("\(descriptor.title)用途")
                .popover(isPresented: $showingInfo) {
                    Text(descriptor.summary)
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(width: 220, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                }
                Spacer(minLength: 8)
                PermissionStatusBadge(status: status)
                    .frame(width: 82, alignment: .trailing)
                if status == .notDetermined || status == .notGranted, permissions.messages[descriptor.id] == nil {
                    Button {
                        Task { await permissions.request(descriptor.id) }
                    } label: {
                        Text(permissions.requesting == descriptor.id ? "请求中" : "授权").frame(minWidth: 56)
                    }
                    .disabled(permissions.requesting != nil)
                    .accessibilityIdentifier("host.permission.\(descriptor.id.rawValue).request")
                    .frame(width: 88, alignment: .trailing)
                } else {
                    Button {
                        permissions.openSettings(descriptor.id)
                    } label: {
                        Text("系统设置").frame(minWidth: 56)
                    }
                    .accessibilityIdentifier("host.permission.\(descriptor.id.rawValue).settings")
                    .frame(width: 88, alignment: .trailing)
                }
            }
            .frame(minHeight: 38)
            if status != .authorized, let message = permissions.messages[descriptor.id] {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
        }
    }

}

private struct PermissionStatusBadge: View {
    @Environment(\.colorScheme) private var scheme
    let status: HostPermissionStatus

    private var title: String {
        switch status {
        case .authorized: "已授权"
        case .notDetermined, .notGranted: "未授权"
        case .denied: "已拒绝"
        case .restricted: "受限制"
        }
    }
    private var symbol: String {
        switch status {
        case .authorized: "checkmark"
        case .notDetermined, .notGranted: "minus"
        case .denied: "xmark"
        case .restricted: "lock.fill"
        }
    }
    private var color: Color {
        switch status {
        case .authorized:
            scheme == .dark ? Color(red: 0.40, green: 0.85, blue: 0.56) : Color(red: 0.12, green: 0.43, blue: 0.25)
        case .notDetermined, .notGranted:
            scheme == .dark ? Color(red: 1, green: 0.73, blue: 0.30) : Color(red: 0.55, green: 0.35, blue: 0.04)
        case .denied:
            scheme == .dark ? Color(red: 1, green: 0.51, blue: 0.48) : Color(red: 0.72, green: 0.20, blue: 0.17)
        case .restricted:
            scheme == .dark ? Color(red: 0.76, green: 0.64, blue: 0.96) : Color(red: 0.43, green: 0.31, blue: 0.65)
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .frame(minWidth: 50)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(scheme == .dark ? 0.13 : 0.08), in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("权限状态：\(title)")
    }
}
