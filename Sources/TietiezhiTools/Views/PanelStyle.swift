import SwiftUI

enum PanelLayout {
    static let sidebarWidth: CGFloat = 224
    static let contentInset: CGFloat = 24
    static let rowInset: CGFloat = 20
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

struct PanelActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .font(.callout)
        .controlSize(.regular)
        .buttonStyle(.borderless)
        .padding(.horizontal, PanelLayout.itemSpacing)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .modifier(PanelGlassSurface())
        .padding(.horizontal, PanelLayout.contentInset)
        .padding(.vertical, 16)
    }
}

private struct PanelGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content.background(.bar, in: RoundedRectangle(cornerRadius: 16))
        }
        #else
        content.background(.bar, in: RoundedRectangle(cornerRadius: 16))
        #endif
    }
}
