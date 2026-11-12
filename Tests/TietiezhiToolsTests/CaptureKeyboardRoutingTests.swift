import AppKit
import SwiftUI
import Testing
@testable import TietiezhiTools

@Suite(.serialized)
struct CaptureKeyboardRoutingTests {
    @Test @MainActor func hostingAndCaptionFieldsRequestPanelKeyboardFocus() {
        let host = CaptureFirstMouseHostingView(rootView: TextField("Test", text: .constant("")))
        #expect(host.needsPanelToBecomeKey)
        let field = CaptureCaptionTextField(string: "")
        #expect(field.needsPanelToBecomeKey)
        #expect(field.acceptsFirstMouse(for: nil))
    }

    @Test @MainActor func captionFocusWaitsForItsActualPopoverWindow() async throws {
        let panel = fixturePanel()
        defer { panel.close() }
        let anchor = NSButton(title: "Styles", target: nil, action: nil)
        anchor.frame = CGRect(x: 20, y: 20, width: 80, height: 28)
        panel.contentView?.addSubview(anchor)
        panel.makeKeyAndOrderFront(nil)

        let field = CaptureCaptionTextField(string: "")
        field.frame = CGRect(x: 12, y: 12, width: 240, height: 26)
        field.requestFocus(UUID()) // The popover has not created its window yet.
        #expect(field.window == nil)
        let controller = NSViewController()
        controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 264, height: 50))
        controller.view.addSubview(field)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close() }
        for _ in 0..<8 { await Task.yield() }
        #expect(field.window !== panel)
        let window = try #require(field.window)
        #expect(window.isKeyWindow)
        #expect(field.currentEditor() != nil)
        #expect(CaptureKeyboardRouting.isEditingText(in: window))
    }

    @Test @MainActor func englishAndChineseCompositionKeepTheirKeysAndEscapeOnlyClosesInput() throws {
        let panel = fixturePanel()
        defer { panel.close() }
        var value = "", submitted = 0, cancelled = 0
        let bridge = CaptureCaptionField(text: Binding(get: { value }, set: { value = $0 }),
                                         placeholder: "", focusRequest: nil,
                                         onSubmit: { submitted += 1 }, onCancel: { cancelled += 1 })
        let coordinator = bridge.makeCoordinator()
        let field = CaptureCaptionTextField(string: "")
        field.frame = CGRect(x: 12, y: 12, width: 260, height: 26)
        field.delegate = coordinator
        let monitor = CaptureShortcutMonitor.MonitorView()
        panel.contentView?.addSubview(monitor)
        panel.contentView?.addSubview(field)
        var actions: [CaptureShortcutAction] = []
        monitor.handle = { actions.append($0) }
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.makeFirstResponder(field))
        let input = try #require(field.currentEditor() as? NSTextView)
        input.insertText("Hello c ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(value == "Hello c ")

        input.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        for (code, characters, flags) in [(UInt16(8), "c", NSEvent.ModifierFlags()), (49, " ", []),
                                          (36, "\r", []), (53, "\u{1B}", []), (8, "c", .command)] {
            let key = try event(code, characters, flags, in: panel)
            #expect(monitor.process(key) === key)
        }
        #expect(!coordinator.control(field, textView: input, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!coordinator.control(field, textView: input, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(submitted == 0 && cancelled == 0 && actions.isEmpty)

        input.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!input.hasMarkedText())
        #expect(value == "Hello c 你好")
        let escape = try event(53, "\u{1B}", [], in: panel)
        #expect(monitor.process(escape) === escape)
        #expect(coordinator.control(field, textView: input, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(cancelled == 1 && actions.isEmpty)
    }

    @Test @MainActor func screenshotShortcutsStillRunWhenCanvasOwnsFocus() throws {
        let suite = "CaptureKeyboardRouting-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = fixturePanel()
        defer { panel.close() }
        let target = KeyboardCanvas()
        let monitor = CaptureShortcutMonitor.MonitorView()
        monitor.settings = CaptureShortcutSettings(defaults: defaults)
        panel.contentView?.addSubview(target)
        panel.contentView?.addSubview(monitor)
        var actions: [CaptureShortcutAction] = []
        monitor.handle = { actions.append($0) }
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.makeFirstResponder(target))
        #expect(!CaptureKeyboardRouting.isEditingText(in: panel))
        #expect(monitor.process(try event(8, "c", [], in: panel)) == nil)
        #expect(monitor.process(try event(53, "\u{1B}", [], in: panel)) == nil)
        #expect(actions == [.copyColor, .close])
    }

    @Test @MainActor func sharedPopoverFocusSupportsTextEditorAndServiceFields() async throws {
        let panel = fixturePanel()
        defer { panel.close() }
        let anchor = NSButton(title: "Input", target: nil, action: nil)
        anchor.frame = CGRect(x: 12, y: 12, width: 80, height: 28)
        panel.contentView?.addSubview(anchor)
        panel.makeKeyAndOrderFront(nil)
        var recognized = "", endpoint = "", secret = ""
        let root = VStack {
            TextEditor(text: Binding(get: { recognized }, set: { recognized = $0 })).frame(height: 60)
            TextField("Endpoint", text: Binding(get: { endpoint }, set: { endpoint = $0 }))
            SecureField("Key", text: Binding(get: { secret }, set: { secret = $0 }))
        }
        .padding(12).frame(width: 280, height: 150)
        .background(CaptureInputWindowFocus().frame(width: 0, height: 0))
        let popover = NSPopover()
        let controller = NSHostingController(rootView: root)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close() }
        for _ in 0..<8 { await Task.yield() }
        controller.view.layoutSubtreeIfNeeded()
        let window = try #require(controller.view.window)
        #expect(window.isKeyWindow)
        let descendants = allViews(controller.view)
        let text = try #require(descendants.compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isFieldEditor })
        #expect(window.makeFirstResponder(text))
        text.insertText("OCR 中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(CaptureKeyboardRouting.isEditingText(in: window))
        for _ in 0..<4 { await Task.yield() }
        #expect(recognized == "OCR 中文")

        let field = try #require(descendants.compactMap { $0 as? NSTextField }.first { $0.isEditable && !($0 is NSSecureTextField) })
        #expect(window.makeFirstResponder(field))
        let fieldEditor = try #require(field.currentEditor() as? NSTextView)
        fieldEditor.insertText("https://example.test", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<4 { await Task.yield() }
        #expect(endpoint == "https://example.test")

        let secureField = try #require(descendants.compactMap { $0 as? NSSecureTextField }.first)
        #expect(window.makeFirstResponder(secureField))
        let secureEditor = try #require(secureField.currentEditor() as? NSTextView)
        secureEditor.insertText("fixture-only", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(CaptureKeyboardRouting.isEditingText(in: window))
        for _ in 0..<4 { await Task.yield() }
        #expect(secret == "fixture-only")
    }

    @MainActor private func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews)
    }

    @MainActor private func fixturePanel() -> NSPanel {
        _ = NSApplication.shared
        let panel = KeyboardPanel(contentRect: CGRect(x: 100, y: 100, width: 320, height: 120),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        return panel
    }
    @MainActor private func event(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: text, charactersIgnoringModifiers: text,
                                     isARepeat: false, keyCode: code))
    }
}

private final class KeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
private final class KeyboardCanvas: NSView {
    override var acceptsFirstResponder: Bool { true }
}
