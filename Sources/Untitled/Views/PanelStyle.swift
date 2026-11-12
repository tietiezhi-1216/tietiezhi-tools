import SwiftUI

enum PanelLayout {
    static let windowControlsHeight: CGFloat = 64
    static let windowControlsLeading: CGFloat = 20
    static let windowControlsTop: CGFloat = 26
    static let coordinateSpace = "panel.content"
    static let sidebarWidth: CGFloat = 224
    static let contentInset: CGFloat = 28
    static let rowInset: CGFloat = 18
    static let itemSpacing: CGFloat = 16
    static let iconSize: CGFloat = 40
    static let actionWidth: CGFloat = 76
}

enum PanelPalette {
    static func window(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.085, green: 0.085, blue: 0.095) : Color(red: 0.965, green: 0.965, blue: 0.975)
    }

    static func content(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.105, green: 0.105, blue: 0.115) : Color(red: 0.985, green: 0.985, blue: 0.99)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.095, green: 0.095, blue: 0.105) : Color(red: 0.95, green: 0.95, blue: 0.96)
    }
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

    @ViewBuilder
    func panelGlassButton(prominent: Bool = false, circular: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .controlSize(.regular)
            } else {
                self.buttonStyle(.glass)
                    .buttonBorderShape(circular ? .circle : .roundedRectangle(radius: 8))
                    .controlSize(.regular)
            }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) }
            else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) }
        else { self.buttonStyle(.bordered) }
        #endif
    }

    @ViewBuilder
    func panelWindowDragArea() -> some View {
        if #available(macOS 15, *) {
            self.gesture(WindowDragGesture())
        } else {
            self
        }
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background(PanelPalette.sidebar(scheme).opacity(reduceTransparency ? 1 : 0.96))
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
        .frame(height: 36)
        .modifier(PanelSearchSurface())
    }
}

private struct PanelSearchSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if !reduceTransparency, #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 10))
        } else {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        #else
        content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        #endif
    }
}
