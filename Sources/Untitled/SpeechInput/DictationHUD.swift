import AppKit
import SwiftUI

@MainActor final class DictationHUD {
    static let size = NSSize(width: 72, height: 30)
    private var panel: DictationPanel?
    isolated deinit { close() }
    func show(controller: DoubaoDictationController) {
        let panel = DictationPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("doubao.dictation.hud")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        // The compact waveform is an indicator, not an input surface. Keep mouse and
        // keyboard focus on the editor; the existing toggle/hold/cancel keys still work.
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: DictationHUDView(controller: controller))
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 36))
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }
    func close() {
        panel?.orderOut(nil); panel?.contentView = nil; panel?.close(); panel = nil
    }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DictationHUDView: View {
    @ObservedObject var controller: DoubaoDictationController
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5) { index in
                Capsule().fill(.white.opacity(index == 2 ? 1 : 0.7))
                    .frame(width: 2, height: CGFloat([3, 6, 9, 6, 3][index])
                           + CGFloat(controller.level) * CGFloat([5, 8, 9, 8, 5][index]))
            }
        }
        .frame(width: DictationHUD.size.width, height: DictationHUD.size.height)
        .background(Color(white: 0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("豆信语音输入，" + controller.phase.title)
        .accessibilityHint("使用听写快捷键结束，或取消快捷键取消")
        .environment(\.colorScheme, .dark)
    }
}
