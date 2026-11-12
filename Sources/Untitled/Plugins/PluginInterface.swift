import Foundation

enum PluginUISlot: String, CaseIterable, Codable, Sendable {
    case headerLeading = "header.leading"
    case headerTrailing = "header.trailing"
    case toolbarLeading = "toolbar.leading"
    case toolbarTrailing = "toolbar.trailing"
    case content
    case footerLeading = "footer.leading"
    case footerTrailing = "footer.trailing"
    case menuBar = "menuBar"
}

struct PluginInterface: Codable, Equatable, Sendable {
    var version: Int
    var icon: String?
    var slots: [String: [PluginUIItem]]
    var panels: [PluginUIPanel]?

    init(version: Int = 1, icon: String? = nil, slots: [String: [PluginUIItem]], panels: [PluginUIPanel] = []) {
        self.version = version
        self.icon = icon
        self.slots = slots
        self.panels = panels
    }

    func items(in slot: PluginUISlot) -> [PluginUIItem] { slots[slot.rawValue] ?? [] }
    func panel(_ id: String) -> PluginUIPanel? { panels?.first { $0.id == id } }
    var allItems: [PluginUIItem] {
        func flatten(_ items: [PluginUIItem]) -> [PluginUIItem] {
            items.flatMap { [$0] + flatten($0.items ?? []) }
        }
        return PluginUISlot.allCases.flatMap { flatten(items(in: $0)) }
            + (panels ?? []).flatMap { panel in (panel.slots ?? [:]).values.flatMap { flatten($0) } }
    }

    func validate() throws {
        guard version == 1 else { throw PluginError.invalid("不支持这个插件界面协议版本，请更新主程序。") }
        guard slots.keys.allSatisfy({ PluginUISlot(rawValue: $0) != nil }),
            !items(in: .content).isEmpty, (panels?.count ?? 0) <= 24
        else {
            throw PluginError.invalid("插件界面包含未知槽位、缺少内容或面板过多。")
        }
        if let icon { try Self.validateName(icon) }
        let definitions = panels ?? []
        guard Set(definitions.map(\.id)).count == definitions.count else { throw PluginError.invalid("插件面板标识重复。") }
        for panel in definitions {
            try Self.validateID(panel.id)
            try Self.validateName(panel.title)
            guard (panel.component != nil) != (panel.slots != nil) else {
                throw PluginError.invalid("面板需要指定组件或槽位布局：\(panel.id)")
            }
            if let component = panel.component { try Self.validateReference(component) }
            guard panel.width.map({ (320...1200).contains($0) }) ?? true,
                panel.height.map({ (240...900).contains($0) }) ?? true
            else {
                throw PluginError.invalid("插件面板尺寸超出支持范围。")
            }
        }
        let panelIDs = Set(definitions.map(\.id))
        var identifiers = Set<String>()
        var count = 0
        func validate(_ item: PluginUIItem, slot: PluginUISlot, depth: Int) throws {
            count += 1
            guard count <= 160, depth <= 3 else { throw PluginError.invalid("插件界面过大或菜单嵌套过深。") }
            try Self.validateID(item.id)
            guard identifiers.insert(item.id).inserted else { throw PluginError.invalid("插件界面元素标识重复：\(item.id)") }
            for text in [item.title, item.symbol].compactMap({ $0 }) { try Self.validateName(text) }
            if let component = item.component { try Self.validateReference(component) }
            if let command = item.command { try Self.validateReference(command) }
            switch item.kind {
            case .component:
                guard item.component != nil, item.command == nil, item.panel == nil, item.panels == nil,
                    item.items == nil
                else {
                    throw PluginError.invalid("组件声明无效：\(item.id)")
                }
            case .button:
                guard item.component == nil, item.panels == nil, item.items == nil,
                    (item.command != nil) != (item.panel != nil)
                else {
                    throw PluginError.invalid("按钮必须指定一个命令或面板：\(item.id)")
                }
                if let panel = item.panel {
                    guard panelIDs.contains(panel), item.title != nil || item.symbol != nil else {
                        throw PluginError.invalid("按钮引用了未知面板或缺少标签：\(item.id)")
                    }
                } else if item.presentation != nil {
                    throw PluginError.invalid("仅面板按钮可以指定呈现方式：\(item.id)")
                }
            case .menu:
                guard item.title != nil, let children = item.items, !children.isEmpty,
                    item.component == nil, item.command == nil, item.panel == nil, item.panels == nil
                else {
                    throw PluginError.invalid("菜单声明无效：\(item.id)")
                }
                for child in children {
                    guard child.kind == .button || child.kind == .menu else {
                        throw PluginError.invalid("菜单中仅支持按钮和子菜单。")
                    }
                    try validate(child, slot: slot, depth: depth + 1)
                }
            case .panel:
                guard slot == .content, let panel = item.panel, panelIDs.contains(panel), item.command == nil,
                    item.component == nil, item.panels == nil, item.items == nil
                else {
                    throw PluginError.invalid("内容面板声明无效：\(item.id)")
                }
            case .tabs:
                guard slot == .content, let pages = item.panels, !pages.isEmpty, pages.count <= 12,
                    Set(pages).count == pages.count, pages.allSatisfy(panelIDs.contains),
                    item.component == nil, item.command == nil, item.panel == nil, item.items == nil
                else {
                    throw PluginError.invalid("页面切换器声明无效：\(item.id)")
                }
            }
            if slot == .menuBar {
                guard item.kind == .menu || (item.kind == .button && item.command != nil) else {
                    throw PluginError.invalid("菜单栏槽位仅支持命令按钮和菜单。")
                }
            }
        }
        for slot in PluginUISlot.allCases {
            for item in items(in: slot) { try validate(item, slot: slot, depth: 0) }
        }
        for panel in definitions {
            if let layout = panel.slots {
                guard
                    layout.keys.allSatisfy({ PluginUISlot(rawValue: $0) != nil && $0 != PluginUISlot.menuBar.rawValue }
                    ),
                    !(layout[PluginUISlot.content.rawValue] ?? []).isEmpty
                else {
                    throw PluginError.invalid("面板槽位声明无效：\(panel.id)")
                }
                for slot in PluginUISlot.allCases {
                    for item in layout[slot.rawValue] ?? [] { try validate(item, slot: slot, depth: 0) }
                }
            }
        }
        func embeddedPanels(_ items: [PluginUIItem]) -> [String] {
            items.flatMap { item in item.kind == .panel ? [item.panel!] : item.kind == .tabs ? item.panels! : [] }
        }
        var depths: [String: Int] = [:]
        var costs: [String: Int] = [:]
        func visit(_ id: String, path: Set<String>) throws -> (depth: Int, cost: Int) {
            guard !path.contains(id) else { throw PluginError.invalid("面板嵌套循环：\(id)") }
            if let depth = depths[id], let cost = costs[id] { return (depth, cost) }
            let children = panel(id)?.slots?[PluginUISlot.content.rawValue] ?? []
            var depth = 1, cost = max(1, children.count)
            for child in embeddedPanels(children) {
                let result = try visit(child, path: path.union([id]))
                depth = max(depth, result.depth + 1)
                cost += result.cost
            }
            guard depth <= 8, cost <= 1024 else { throw PluginError.invalid("面板嵌套层级或展开后的界面过大：\(id)") }
            depths[id] = depth; costs[id] = cost
            return (depth, cost)
        }
        for panel in definitions { _ = try visit(panel.id, path: []) }
    }

    private static func validateID(_ value: String) throws {
        guard value.count <= 100, value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        else {
            throw PluginError.invalid("插件界面标识不合法。")
        }
    }
    private static func validateReference(_ value: String) throws {
        try validateID(value)
        guard value.contains(".") else { throw PluginError.invalid("组件和命令需要使用命名空间：\(value)") }
    }
    private static func validateName(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 160 else {
            throw PluginError.invalid("插件界面标签或图标无效。")
        }
    }
}

struct PluginUIItem: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case component, button, menu, panel, tabs }
    enum Style: String, Codable, Sendable { case plain, standard, prominent }
    enum Presentation: String, Codable, Sendable { case sheet, popover, inline }
    var id: String
    var kind: Kind
    var component: String?
    var title: String?
    var symbol: String?
    var command: String?
    var panel: String?
    var panels: [String]?
    var items: [PluginUIItem]?
    var style: Style?
    var presentation: Presentation?

    static func component(_ id: String, _ reference: String) -> Self {
        Self(id: id, kind: .component, component: reference)
    }
    static func command(
        _ id: String, _ reference: String, title: String? = nil, symbol: String? = nil, style: Style = .standard
    ) -> Self {
        Self(id: id, kind: .button, title: title, symbol: symbol, command: reference, style: style)
    }
}

struct PluginUIPanel: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var component: String?
    var slots: [String: [PluginUIItem]]?
    var width: Double?
    var height: Double?
}
