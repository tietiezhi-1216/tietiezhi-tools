import AppKit
import Carbon
import Combine
import SwiftUI

enum CaptureShortcutScope { case editor, pin }

enum CaptureShortcutAction: String, CaseIterable, Identifiable {
    case close, copy, copyAndClose, save, quickSave, printImage, undo, redo, clearMarks, pin
    case ocr, translation, document, table, formula, rectangle, line, arrow, number, pen, highlight
    case mosaic, text, erase, spotlight, magnify, watermark, autoMosaic, selectMarks, hideToolbar, copyColor
    case pinLock, pinTop, pinShadow, pinNext, pinOthers, pinGroup, pinAnnotate
    case moveUp, moveDown, moveLeft, moveRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .close: "关闭"
        case .copy: "复制图像"
        case .copyAndClose: "完成并复制"
        case .save: "保存到文件"
        case .quickSave: "快速保存"
        case .printImage: "打印"
        case .undo: "撤销标注"
        case .redo: "重做标注"
        case .clearMarks: "清除所有标注"
        case .pin: "贴图"
        case .ocr: "检测文本并复制"
        case .translation: "翻译"
        case .document: "文档识别"
        case .table: "表格识别"
        case .formula: "公式识别"
        case .rectangle: "几何图形"
        case .line: "直线"
        case .arrow: "箭头"
        case .number: "序号"
        case .pen: "画笔"
        case .highlight: "荧光笔"
        case .mosaic: "马赛克"
        case .text: "文字"
        case .erase: "擦除标注"
        case .spotlight: "聚光灯"
        case .magnify: "放大镜"
        case .watermark: "文字水印"
        case .autoMosaic: "自动马赛克"
        case .selectMarks: "选择 / 移动标注"
        case .hideToolbar: "显示 / 隐藏标注栏"
        case .copyColor: "复制鼠标位置颜色"
        case .pinLock: "锁定贴图"
        case .pinTop: "贴图置顶"
        case .pinShadow: "贴图阴影"
        case .pinNext: "切换到下一张贴图"
        case .pinOthers: "隐藏 / 显示其他贴图"
        case .pinGroup: "移动到新贴图组"
        case .pinAnnotate: "编辑 / 标注贴图"
        case .moveUp: "贴图向上微移"
        case .moveDown: "贴图向下微移"
        case .moveLeft: "贴图向左微移"
        case .moveRight: "贴图向右微移"
        }
    }
    var scopes: [CaptureShortcutScope] {
        switch self {
        case .close, .copy, .save, .quickSave, .printImage, .ocr, .translation, .document, .table, .formula: [.editor, .pin]
        case .pinLock, .pinTop, .pinShadow, .pinNext, .pinOthers, .pinGroup, .pinAnnotate,
             .moveUp, .moveDown, .moveLeft, .moveRight: [.pin]
        default: [.editor]
        }
    }
    var defaultKey: HotKey {
        let command = UInt32(cmdKey), shift = UInt32(shiftKey), option = UInt32(optionKey)
        let values: (UInt32, UInt32, String) = switch self {
        case .close: (53, 0, "Esc")
        case .copy: (8, command, "C")
        case .copyAndClose: (36, 0, "↩")
        case .save: (1, command, "S")
        case .quickSave: (1, command | shift, "S")
        case .printImage: (35, command, "P")
        case .undo: (6, command, "Z")
        case .redo: (16, command, "Y")
        case .clearMarks: (6, command | shift, "Z")
        case .pin: (17, command, "T")
        case .ocr: (8, shift, "C")
        case .translation: (12, option, "Q")
        case .document: (14, shift, "E")
        case .table: (12, shift, "Q")
        case .formula: (3, shift, "F")
        case .rectangle: (18, shift, "1")
        case .line: (19, shift, "2")
        case .arrow: (20, shift, "3")
        case .number: (21, shift, "4")
        case .pen: (23, shift, "5")
        case .highlight: (22, shift, "6")
        case .mosaic: (26, shift, "7")
        case .text: (28, shift, "8")
        case .erase: (25, shift, "9")
        case .spotlight: (29, shift, "0")
        case .watermark: (27, shift, "-")
        case .magnify: (24, shift, "=")
        case .autoMosaic: (33, shift, "[")
        case .selectMarks: (14, command, "E")
        case .hideToolbar, .pinAnnotate: (49, 0, "Space")
        case .copyColor: (8, 0, "C")
        case .pinLock: (37, 0, "L")
        case .pinTop: (17, 0, "T")
        case .pinShadow: (16, 0, "Y")
        case .pinNext: (48, 0, "⇥")
        case .pinOthers: (9, 0, "V")
        case .pinGroup: (5, 0, "G")
        case .moveUp: (126, 0, "↑")
        case .moveDown: (125, 0, "↓")
        case .moveLeft: (123, 0, "←")
        case .moveRight: (124, 0, "→")
        }
        return HotKey(keyCode: values.0, modifiers: values.1, key: values.2)
    }
    var tool: CaptureTool? {
        switch self {
        case .rectangle: .rectangle
        case .line: .line
        case .arrow: .arrow
        case .number: .number
        case .pen: .pen
        case .highlight: .highlight
        case .mosaic: .mosaic
        case .text: .text
        case .watermark: .watermark
        case .erase: .deleteMarks
        case .spotlight: .spotlight
        case .magnify: .magnify
        case .selectMarks: .select
        default: nil
        }
    }
}

@MainActor final class CaptureShortcutSettings: ObservableObject {
    static let shared = CaptureShortcutSettings()
    private struct Override: Codable { var key: HotKey? }
    private let defaults: UserDefaults
    @Published private var overrides: [String: Override]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.data(forKey: "capture.localShortcuts").flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
    }
    func binding(_ action: CaptureShortcutAction) -> HotKey? {
        if let override = overrides[action.rawValue] { return override.key }
        return action.defaultKey
    }
    func set(_ key: HotKey?, for action: CaptureShortcutAction) throws {
        if let key {
            try key.validateLocal()
            if let other = CaptureShortcutAction.allCases.first(where: {
                $0 != action && $0.scopes.contains(where: action.scopes.contains) && binding($0)?.identity == key.identity
            }) { throw PluginError.invalid("\(key.display) 已用于「\(other.title)」。") }
        }
        overrides[action.rawValue] = Override(key: key)
        persist()
    }
    func restoreDefaults() { overrides = [:]; persist() }
    private func persist() { defaults.set(try? JSONEncoder().encode(overrides), forKey: "capture.localShortcuts") }
    func action(keyCode: UInt32, modifiers: UInt32, scope: CaptureShortcutScope) -> CaptureShortcutAction? {
        CaptureShortcutAction.allCases.first { $0.scopes.contains(scope) && binding($0).map { $0.keyCode == keyCode && $0.modifiers == modifiers } == true }
    }
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}

struct CaptureShortcutMonitor: NSViewRepresentable {
    let scope: CaptureShortcutScope
    let handle: (CaptureShortcutAction) -> Void
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.scope = scope; view.handle = handle }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }
    final class MonitorView: NSView {
        var scope = CaptureShortcutScope.editor
        var handle: ((CaptureShortcutAction) -> Void)?
        var settings = CaptureShortcutSettings.shared
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.process(event)
            }
        }
        func process(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, !CaptureKeyboardRouting.isEditingText(in: window) else { return event }
            guard let action = settings.action(keyCode: UInt32(event.keyCode),
                modifiers: CaptureShortcutSettings.modifiers(event.modifierFlags), scope: scope) else { return event }
            handle?(action)
            return nil
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}

@MainActor enum CaptureKeyboardRouting {
    static func isEditingText(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable || text.hasMarkedText() }
        if let field = responder as? NSTextField { return field.isEditable || field.currentEditor() != nil }
        if let control = responder as? NSControl, control.currentEditor() != nil { return true }
        // SwiftUI and input-method clients need not be NSTextView subclasses.
        return responder is any NSTextInputClient
    }
}

/// Attach to input-bearing popovers/sheets: their actual window is different
/// from the floating toolbar that presents them.
struct CaptureInputWindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> InputWindowView { InputWindowView() }
    func updateNSView(_ view: InputWindowView, context: Context) {}

    final class InputWindowView: NSView {
        override var needsPanelToBecomeKey: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            (window as? NSPanel)?.becomesKeyOnlyIfNeeded = false
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, window.isVisible else { return }
                window.makeKey()
            }
        }
    }
}

struct CaptureLocalShortcutSettingsView: View {
    @ObservedObject private var settings = CaptureShortcutSettings.shared
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("窗口内快捷键").font(.headline)
                Spacer()
                Button("恢复 PixPin 默认") { settings.restoreDefaults(); error = nil }
            }
            Text("仅在截图编辑或贴图窗口生效；输入文字时保留正常编辑按键。").font(.caption).foregroundStyle(.secondary)
            ForEach(CaptureShortcutAction.allCases) { action in
                LabeledContent(action.title) {
                    ShortcutRecorder(hotKey: Binding(get: { settings.binding(action) }, set: { key in
                        do { try settings.set(key, for: action); error = nil } catch { self.error = error.localizedDescription }
                    }), error: $error, allowsUnmodified: true).frame(width: 165, height: 26)
                    Button("清除") { try? settings.set(nil, for: action) }.disabled(settings.binding(action) == nil)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
