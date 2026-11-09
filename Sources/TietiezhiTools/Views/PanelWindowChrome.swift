import AppKit
import SwiftUI

@MainActor
enum PanelWindowChrome {
    static func configure(_ window: NSWindow) {
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        layoutWindowButtons(window)
    }

    static func layoutWindowButtons(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview,
              let frame = container.superview else { return }

        // 仅保留左侧按钮宿主，避免透明标题区挡住右侧设置、搜索等控件。
        let height = PanelLayout.windowControlsHeight
        let y = frame.isFlipped ? frame.bounds.minY : frame.bounds.maxY - height
        let containerFrame = NSRect(x: 0, y: y, width: PanelLayout.sidebarWidth, height: height)
        if container.frame != containerFrame { container.frame = containerFrame }
        container.autoresizingMask = [.minYMargin]
        let titlebarFrame = NSRect(origin: .zero, size: containerFrame.size)
        if titlebar.frame != titlebarFrame { titlebar.frame = titlebarFrame }

        var x = PanelLayout.windowControlsLeading
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), button.superview === titlebar else { continue }
            let y = titlebar.isFlipped ? PanelLayout.windowControlsTop : height - PanelLayout.windowControlsTop - button.frame.height
            let origin = NSPoint(x: x, y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            x += button.frame.width + 8
        }
    }
}

struct PanelWindowChromeAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        if let window = view.window { PanelWindowChrome.configure(window) }
    }

    final class ChromeView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            if let window { PanelWindowChrome.layoutWindowButtons(window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { PanelWindowChrome.configure(window) }
        }
    }
}

struct PanelWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
