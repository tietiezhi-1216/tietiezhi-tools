import Combine
import SwiftUI

@MainActor protocol PluginUIProvider {
    func register(in registry: PluginUIRegistry)
    func legacyInterface(for manifest: PluginManifest) -> PluginInterface?
}

extension PluginUIProvider {
    func legacyInterface(for manifest: PluginManifest) -> PluginInterface? { nil }
}

@MainActor struct PluginUIContext {
    let pluginID: String
    let store: PluginStore
    let navigation: PluginUINavigation
    var plugin: InstalledPlugin? { store.installed.first { $0.id == pluginID } }
    var interface: PluginInterface? { plugin.map { store.uiRegistry.interface(for: $0.manifest) } }
    var permissions: PluginPermissionClient { store.permissionClient(for: pluginID) }
}

struct PluginCommandPresentation {
    var title: String
    var symbol: String?
    var isEnabled = true
}

@MainActor final class PluginUIRegistry {
    struct Component {
        let requiredActions: Set<ActionKind>
        let makeView: (PluginUIContext) -> AnyView
    }
    struct Command {
        let requiredActions: Set<ActionKind>
        let presentation: (PluginUIContext) -> PluginCommandPresentation
        let updates: ((PluginUIContext) -> AnyPublisher<Void, Never>)?
        let perform: (PluginUIContext) async throws -> Void
    }
    private(set) var components: [String: Component] = [:]
    private(set) var commands: [String: Command] = [:]
    private var providers: [any PluginUIProvider] = []

    func register(_ provider: some PluginUIProvider) {
        providers.append(provider)
        provider.register(in: self)
    }
    func component(
        _ name: String, requiredActions: Set<ActionKind> = [], makeView: @escaping (PluginUIContext) -> AnyView
    ) {
        precondition(components[name] == nil, "Duplicate plugin component: \(name)")
        components[name] = Component(requiredActions: requiredActions, makeView: makeView)
    }
    func command(
        _ name: String, requiredActions: Set<ActionKind> = [],
        presentation: @escaping (PluginUIContext) -> PluginCommandPresentation,
        updates: ((PluginUIContext) -> AnyPublisher<Void, Never>)? = nil,
        perform: @escaping (PluginUIContext) async throws -> Void
    ) {
        precondition(commands[name] == nil, "Duplicate plugin command: \(name)")
        commands[name] = Command(
            requiredActions: requiredActions, presentation: presentation, updates: updates, perform: perform)
    }
    func interface(for manifest: PluginManifest) -> PluginInterface {
        if let ui = manifest.ui { return ui }
        guard manifest.schemaVersion == 1 else { return PluginInterface(slots: [:]) }
        for provider in providers {
            if let ui = provider.legacyInterface(for: manifest) { return ui }
        }
        return Self.legacyCommands
    }
    func validate(_ manifest: PluginManifest) throws {
        let ui = interface(for: manifest)
        try ui.validate()
        let actions = Set(manifest.actions)
        for item in ui.allItems {
            if let reference = item.component { try validateComponent(reference, actions: actions) }
            if let reference = item.command {
                guard let command = commands[reference], command.requiredActions.isSubset(of: actions) else {
                    throw PluginError.invalid("插件引用了未知或未授权的界面命令：\(reference)")
                }
            }
        }
        for panel in ui.panels ?? [] {
            if let component = panel.component { try validateComponent(component, actions: actions) }
        }
    }
    private func validateComponent(_ name: String, actions: Set<ActionKind>) throws {
        guard let component = components[name], component.requiredActions.isSubset(of: actions) else {
            throw PluginError.invalid("插件引用了未知或未授权的界面组件：\(name)")
        }
    }
    func execute(_ commandID: String, context: PluginUIContext) async throws {
        guard let plugin = context.plugin, plugin.isEnabled,
            let command = commands[commandID],
            command.requiredActions.isSubset(of: Set(plugin.manifest.actions)),
            command.presentation(context).isEnabled
        else { throw PluginError.invalid("此插件操作当前不可用。") }
        try await command.perform(context)
    }
    static var legacyCommands: PluginInterface {
        PluginInterface(slots: [
            PluginUISlot.headerLeading.rawValue: [
                .component("icon", "host.icon"), .component("identity", "host.identity"),
            ],
            PluginUISlot.headerTrailing.rawValue: [
                .component("enabled", "host.enabled"), .component("more", "host.more"), .component("info", "host.info"),
            ],
            PluginUISlot.toolbarLeading.rawValue: [.component("commandHeading", "host.commandHeading")],
            PluginUISlot.toolbarTrailing.rawValue: [.component("addCommand", "host.addCommand")],
            PluginUISlot.content.rawValue: [.component("commands", "host.commands")],
            PluginUISlot.footerLeading.rawValue: [.component("commandStatus", "host.commandStatus")],
        ])
    }
}

@MainActor final class PluginUINavigation: ObservableObject {
    struct Sheet: Identifiable { let id: String }
    @Published var sheet: Sheet?
    @Published var inlinePanel: String?
    @Published var selectedTabs: [String: String] = [:]

    func open(_ panel: String, presentation: PluginUIItem.Presentation, interface: PluginInterface) {
        guard interface.panel(panel) != nil else { return }
        if presentation == .sheet {
            sheet = Sheet(id: panel)
        } else {
            if let tabs = interface.allItems.first(where: { $0.kind == .tabs && ($0.panels ?? []).contains(panel) }) {
                selectedTabs[tabs.id] = panel
                inlinePanel = nil
            } else {
                inlinePanel = panel
            }
        }
    }
}
