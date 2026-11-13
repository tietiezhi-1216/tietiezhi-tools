import Combine
import SwiftUI

/// The host renders slots. Providers supply components and commands; manifests arrange them.
struct PluginWorkspaceView: View {
    @EnvironmentObject private var store: PluginStore
    @StateObject private var navigation = PluginUINavigation()
    let pluginID: String

    var body: some View {
        let context = PluginUIContext(pluginID: pluginID, store: store, navigation: navigation)
        if let ui = context.interface {
            PluginUILayoutView(slots: ui.slots, context: context, root: true)
                .sheet(item: $navigation.sheet) { sheet in
                    PluginPanelSheet(panelID: sheet.id, context: context)
                }
        }
    }
}

private struct PluginContentHasInsetsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var pluginContentHasInsets: Bool {
        get { self[PluginContentHasInsetsKey.self] }
        set { self[PluginContentHasInsetsKey.self] = newValue }
    }
}

/// The host owns the content rectangle, including clipping. A provider's fixed
/// size, offset or background cannot consume the surrounding workspace gutters.
/// Nested tabs/inline layouts inherit the rectangle instead of adding margins again.
struct PluginContentViewport<Content: View>: View {
    @Environment(\.pluginContentHasInsets) private var hasInsets
    let forceInsets: Bool
    let region: String
    let content: Content

    init(forceInsets: Bool = false, region: String = "plugin.content", @ViewBuilder content: () -> Content) {
        self.forceInsets = forceInsets; self.region = region; self.content = content()
    }

    var body: some View {
        let inset = forceInsets || !hasInsets
        let horizontal: CGFloat = inset ? PanelLayout.contentInset : 0
        let vertical: CGFloat = inset ? PanelLayout.contentVerticalInset : 0
        GeometryReader { geometry in
            content
                .environment(\.pluginContentHasInsets, true)
                .frame(width: max(0, geometry.size.width - 2 * horizontal),
                       height: max(0, geometry.size.height - 2 * vertical), alignment: .topLeading)
                .contentShape(Rectangle())
                .clipped()
                .panelRegion("\(region).bounds")
                .padding(.horizontal, horizontal)
                .padding(.vertical, vertical)
        }
        .panelRegion("\(region).viewport")
    }
}

struct PluginUILayoutView: View {
    let slots: [String: [PluginUIItem]]
    let context: PluginUIContext
    var root = false
    @ObservedObject private var navigation: PluginUINavigation
    @Environment(\.pluginContentHasInsets) private var hasInsets
    private var horizontalInset: CGFloat { hasInsets ? 0 : PanelLayout.contentInset }

    init(slots: [String: [PluginUIItem]], context: PluginUIContext, root: Bool = false) {
        self.slots = slots
        self.context = context
        self.root = root
        navigation = context.navigation
    }
    private func items(_ slot: PluginUISlot) -> [PluginUIItem] { slots[slot.rawValue] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if !items(.headerLeading).isEmpty || !items(.headerTrailing).isEmpty {
                row(.headerLeading, .headerTrailing, spacing: 16)
                    .panelRegion(root ? "panel.heading" : "plugin.panel.heading")
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 24)
                    .frame(minHeight: 96)
                    .panelRegion(root ? "panel.header" : "plugin.panel.header")
            }
            if !items(.toolbarLeading).isEmpty || !items(.toolbarTrailing).isEmpty {
                row(.toolbarLeading, .toolbarTrailing, spacing: 12)
                    .padding(.horizontal, horizontalInset)
                    .frame(minHeight: 52)
                    .padding(.bottom, 8)
                    .panelRegion(root ? "plugin.toolbar" : "plugin.panel.toolbar")
            }
            PluginContentViewport(forceInsets: root, region: root ? "plugin.content" : "plugin.panel.content") {
                VStack(spacing: 0) {
                    if root, let panelID = navigation.inlinePanel {
                        HStack {
                            Button {
                                navigation.inlinePanel = nil
                            } label: {
                                Label("返回", systemImage: "chevron.left")
                            }
                            Spacer()
                        }.padding(.bottom, 12)
                        PluginPanelContent(panelID: panelID, context: context)
                    } else {
                        ForEach(items(.content)) { item in
                            PluginSlotItemView(item: item, context: context)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !items(.footerLeading).isEmpty || !items(.footerTrailing).isEmpty {
                row(.footerLeading, .footerTrailing, spacing: 12)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalInset)
                    .frame(minHeight: 44)
                    .panelRegion(root ? "plugin.footer" : "plugin.panel.footer")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelRegion(root ? "plugin.workspace" : "plugin.panel")
    }

    private func row(_ leading: PluginUISlot, _ trailing: PluginUISlot, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(items(leading)) { PluginSlotItemView(item: $0, context: context) }
            Spacer(minLength: 8)
            ForEach(items(trailing)) { PluginSlotItemView(item: $0, context: context) }
        }
    }
}

struct PluginSlotItemView: View {
    @EnvironmentObject private var store: PluginStore
    let item: PluginUIItem
    let context: PluginUIContext
    var menuItem = false

    var body: some View {
        rendered.panelRegion("plugin.ui.\(item.id)")
    }
    private var rendered: AnyView {
        switch item.kind {
        case .component:
            return store.uiRegistry.components[item.component ?? ""]?.makeView(context) ?? AnyView(EmptyView())
        case .button:
            return AnyView(PluginSlotButton(item: item, context: context, menuItem: menuItem))
        case .menu:
            let menu = Menu {
                ForEach(item.items ?? []) { PluginSlotItemView(item: $0, context: context, menuItem: true) }
            } label: {
                PluginItemLabel(title: item.title ?? "", symbol: item.symbol)
            }
            if menuItem { return AnyView(menu) }
            return AnyView(menu.panelGlassButton(prominent: item.style == .prominent).fixedSize())
        case .panel:
            return AnyView(PluginPanelContent(panelID: item.panel ?? "", context: context))
        case .tabs:
            return AnyView(PluginSlotTabs(item: item, context: context))
        }
    }
}

private struct PluginItemLabel: View {
    let title: String
    let symbol: String?
    var body: some View {
        if let symbol {
            if title.isEmpty {
                Image(systemName: symbol).frame(width: 18, height: 18)
            } else {
                Label(title, systemImage: symbol)
            }
        } else {
            Text(title)
        }
    }
}

/// Observes command state independently of the component currently visible in the content slot.
@MainActor private final class PluginCommandObservation: ObservableObject {
    private var subscription: AnyCancellable?
    init(commandID: String?, context: PluginUIContext) {
        subscription = commandID.flatMap { context.store.uiRegistry.commands[$0]?.updates?(context) }?
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.objectWillChange.send() }
    }
}

private struct PluginSlotButton: View {
    @EnvironmentObject private var store: PluginStore
    let item: PluginUIItem
    let context: PluginUIContext
    let menuItem: Bool
    @StateObject private var observation: PluginCommandObservation
    @ViewState private var showingPopover = false

    init(item: PluginUIItem, context: PluginUIContext, menuItem: Bool) {
        self.item = item
        self.context = context
        self.menuItem = menuItem
        _observation = StateObject(wrappedValue: PluginCommandObservation(commandID: item.command, context: context))
    }
    private var state: PluginCommandPresentation? {
        item.command.flatMap { store.uiRegistry.commands[$0]?.presentation(context) }
    }
    private var title: String { item.title ?? state?.title ?? "" }
    private var accessibleTitle: String {
        if !title.isEmpty { return title }
        return item.panel.flatMap { context.interface?.panel($0)?.title } ?? state?.title ?? "插件操作"
    }
    var body: some View {
        styledButton
            .disabled(item.command != nil && (store.installed.first { $0.id == context.pluginID }?.isEnabled != true || state?.isEnabled == false))
            .help(accessibleTitle)
            .accessibilityLabel(accessibleTitle)
            .popover(isPresented: $showingPopover) {
                if let panelID = item.panel {
                    PluginPanelSheet(panelID: panelID, context: context)
                }
            }
    }
    private var button: some View {
        Button {
            if let command = item.command {
                Task {
                    do { try await context.store.uiRegistry.execute(command, context: context) } catch {
                        context.store.handleExecutionError(error)
                    }
                }
            } else if let panel = item.panel, let ui = context.interface {
                if item.presentation == .popover {
                    showingPopover = true
                } else {
                    context.navigation.open(panel, presentation: item.presentation ?? .sheet, interface: ui)
                }
            }
        } label: {
            PluginItemLabel(title: title, symbol: item.symbol ?? state?.symbol)
        }
    }
    @ViewBuilder private var styledButton: some View {
        if menuItem {
            button
        } else if item.style == .plain {
            button.buttonStyle(.plain).fixedSize()
        } else {
            button.panelGlassButton(prominent: item.style == .prominent, circular: title.isEmpty).fixedSize()
        }
    }
}

private struct PluginSlotTabs: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.pluginContentHasInsets) private var hasInsets
    let item: PluginUIItem
    let context: PluginUIContext
    @ObservedObject private var navigation: PluginUINavigation
    init(item: PluginUIItem, context: PluginUIContext) {
        self.item = item
        self.context = context
        navigation = context.navigation
    }
    private var selected: Binding<String> {
        Binding(
            get: { navigation.selectedTabs[item.id] ?? item.panels?.first ?? "" },
            set: { navigation.selectedTabs[item.id] = $0 })
    }
    var body: some View {
        let ui = store.installed.first { $0.id == context.pluginID }.map { store.uiRegistry.interface(for: $0.manifest) }
        VStack(spacing: 16) {
            Picker(item.title ?? "插件页面", selection: selected) {
                ForEach(item.panels ?? [], id: \.self) { id in
                    Text(ui?.panel(id)?.title ?? id).tag(id)
                }
            }.pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, hasInsets ? 0 : PanelLayout.contentInset)
                .panelRegion("plugin.ui.\(item.id).tabs")
            PluginPanelContent(panelID: selected.wrappedValue, context: context)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PluginPanelContent: View {
    @EnvironmentObject private var store: PluginStore
    let panelID: String
    let context: PluginUIContext
    var body: some View {
        if let manifest = store.installed.first(where: { $0.id == context.pluginID })?.manifest,
           let panel = store.uiRegistry.interface(for: manifest).panel(panelID) {
            if let component = panel.component {
                context.store.uiRegistry.components[component]?.makeView(context)
            } else if let slots = panel.slots {
                // Type erasure also allows providers to compose nested layouts.
                AnyView(PluginUILayoutView(slots: slots, context: context))
            }
        }
    }
}

struct PluginPanelSheet: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.dismiss) private var dismiss
    let panelID: String
    let context: PluginUIContext
    var body: some View {
        let panel = store.installed.first { $0.id == context.pluginID }
            .flatMap { store.uiRegistry.interface(for: $0.manifest).panel(panelID) }
        VStack(spacing: 0) {
            HStack {
                Text(panel?.title ?? "插件面板").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.panelRegion("plugin.sheet.heading")
                .padding(.horizontal, PanelLayout.contentInset).padding(.vertical, 20)
            PluginContentViewport(forceInsets: true, region: "plugin.sheet.content") {
                PluginPanelContent(panelID: panelID, context: context)
            }
        }
        .frame(width: panel?.width ?? 660, height: panel?.height ?? 560)
    }
}
