import Combine
import Foundation

struct HostPermissionID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    static let screenRecording = Self(rawValue: "system.screenRecording")
    static let accessibility = Self(rawValue: "system.accessibility")
    static let inputMonitoring = Self(rawValue: "system.inputMonitoring")
    static let camera = Self(rawValue: "system.camera")
    static let microphone = Self(rawValue: "system.microphone")
}

struct PluginPermissionDeclaration: Codable, Equatable, Sendable {
    let id: HostPermissionID
    let reason: String
    var optional: Bool?
    var isOptional: Bool { optional == true }
}

enum HostPermissionStatus: Equatable {
    case authorized, notDetermined, notGranted, denied, restricted
    var title: String {
        switch self {
        case .authorized: "已授权"
        case .notDetermined: "尚未请求"
        case .notGranted: "未授权"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        }
    }
}

struct HostPermissionDescriptor: Identifiable {
    let id: HostPermissionID
    let title: String
    let summary: String
    let symbol: String
}

@MainActor struct HostPermissionDriver {
    let descriptor: HostPermissionDescriptor
    let status: () -> HostPermissionStatus
    let request: () async -> Void
    let openSettings: () -> Void
}

enum HostSettingsPage: String, CaseIterable { case general, permissions }

struct HostPermissionRequest: Identifiable, Equatable {
    let pluginID: String
    let pluginName: String
    let permissions: Set<HostPermissionID>
    var id: String { pluginID }
}

enum HostPermissionError: LocalizedError {
    case missing
    var errorDescription: String? { "所需权限尚未开启，请在应用设置的“权限管理”中授权后重新执行。" }
}

/// No native module owns OS authorization. All status, prompting and settings links pass through this broker.
@MainActor final class HostPermissionCenter: ObservableObject {
    let drivers: [HostPermissionDriver]
    private let byID: [HostPermissionID: HostPermissionDriver]
    private let legacyDeclarations: (PluginManifest) -> [PluginPermissionDeclaration]
    @Published private(set) var statuses: [HostPermissionID: HostPermissionStatus] = [:]
    @Published private(set) var requesting: HostPermissionID?
    @Published private(set) var messages: [HostPermissionID: String] = [:]
    @Published var pendingRequest: HostPermissionRequest?
    @Published var settingsPage: HostSettingsPage = .general
    var presentManagement: () -> Void = {}

    init(
        drivers: [HostPermissionDriver],
        legacyDeclarations: @escaping (PluginManifest) -> [PluginPermissionDeclaration] = { _ in [] }
    ) {
        precondition(Set(drivers.map { $0.descriptor.id }).count == drivers.count)
        self.drivers = drivers
        self.byID = Dictionary(uniqueKeysWithValues: drivers.map { ($0.descriptor.id, $0) })
        self.legacyDeclarations = legacyDeclarations
        refresh()
    }

    func declarations(for manifest: PluginManifest) -> [PluginPermissionDeclaration] {
        manifest.permissions ?? legacyDeclarations(manifest)
    }
    func validate(_ manifest: PluginManifest) throws {
        let declarations = declarations(for: manifest)
        guard Set(declarations.map(\.id)).count == declarations.count,
            declarations.allSatisfy({ byID[$0.id] != nil })
        else {
            throw PluginError.invalid("插件声明了重复或宿主尚未支持的权限，请更新主应用。")
        }
    }
    func status(_ id: HostPermissionID) -> HostPermissionStatus { statuses[id] ?? .notGranted }
    func refresh(_ ids: Set<HostPermissionID>? = nil) {
        var next = statuses
        for driver in drivers where ids?.contains(driver.descriptor.id) ?? true {
            next[driver.descriptor.id] = driver.status()
        }
        if next != statuses { statuses = next }
    }
    func reveal() {
        settingsPage = .permissions
        refresh()
        presentManagement()
    }
    func require(_ ids: Set<HostPermissionID>, for plugin: InstalledPlugin) throws {
        guard plugin.isEnabled else { throw PluginError.invalid("插件已停用。") }
        let declared = Set(declarations(for: plugin.manifest).map(\.id))
        guard ids.isSubset(of: declared), ids.allSatisfy({ byID[$0] != nil }) else {
            throw PluginError.invalid("插件请求了未声明或不支持的权限。")
        }
        guard !ids.isEmpty else { return }
        // Always query the OS again: permissions can be revoked while the app is running.
        refresh(ids)
        let missing = ids.filter { status($0) != .authorized }
        guard !missing.isEmpty else { return }
        pendingRequest = .init(pluginID: plugin.id, pluginName: plugin.manifest.name, permissions: Set(missing))
        reveal()
        throw HostPermissionError.missing
    }
    func request(_ id: HostPermissionID) async {
        guard requesting == nil, let driver = byID[id] else { return }
        refresh()
        guard status(id) != .authorized else { return }
        guard status(id) != .restricted, status(id) != .denied else { return }
        requesting = id
        defer { requesting = nil }
        await driver.request()
        refresh()
        messages[id] = status(id) == .authorized ? nil : "请在系统隐私设置中允许 Tietiezhi Tools；部分权限更改后需要重新启动应用。"
    }
    func openSettings(_ id: HostPermissionID) { byID[id]?.openSettings() }
}

/// A plugin receives this client from the host; it cannot manufacture an OS grant.
@MainActor struct PluginPermissionClient {
    let require: (Set<HostPermissionID>) throws -> Void
}
