import SwiftUI

enum PanelLayout {
    static let coordinateSpace = "panel.content"
    static let sidebarWidth: CGFloat = 224
    static let contentInset: CGFloat = 28
    static let rowInset: CGFloat = 18
    static let itemSpacing: CGFloat = 16
    static let iconSize: CGFloat = 40
    static let actionWidth: CGFloat = 76
}

struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, PanelLayout.contentInset)
    }
}

struct PanelIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: PanelLayout.iconSize, height: PanelLayout.iconSize)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

extension View {
    func panelNavigationSurface() -> some View {
        modifier(PanelNavigationSurface())
    }

    func panelRegion(_ identifier: String) -> some View {
        #if DEBUG
        self.background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PanelLayoutBoundsKey.self,
                    value: [identifier: geometry.frame(in: .named(PanelLayout.coordinateSpace))]
                )
            }
            .allowsHitTesting(false)
        }
        .accessibilityIdentifier(identifier)
        #else
        self.accessibilityIdentifier(identifier)
        #endif
    }
}

#if DEBUG
// 布局回归检查读取实际渲染坐标；Release 不安装这些测量视图。
struct PanelLayoutBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
#endif

private struct PanelNavigationSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            content.background(.bar)
        }
        #else
        content.background(.bar)
        #endif
    }
}

struct PanelSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索插件", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索插件")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
