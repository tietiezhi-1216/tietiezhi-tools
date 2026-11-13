import SwiftUI
import AppKit

struct CaptureAnnotationInspector: View {
    @ObservedObject var editor: CaptureFloatingEditor
    @ObservedObject var document: CaptureDocument
    var focusCaptionOnAppear = false
    @Environment(\.dismiss) private var dismiss
    @ViewState private var captionFocus: UUID?
    @ViewState private var contentHeight: CGFloat = 280
    private var tool: CaptureTool { editor.inspectorTool }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(tool.title)设置").font(.headline).padding(.bottom, 2)
                if [.text, .watermark].contains(tool) { caption }
                if showsColor { colorSettings }
                primaryParameter
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: CaptureInspectorHeightKey.self, value: geometry.size.height)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 340, height: min(contentHeight, 440))
        .background(CaptureInputWindowFocus().frame(width: 0, height: 0))
        .controlSize(.small)
        .buttonStyle(.bordered)
        .onPreferenceChange(CaptureInspectorHeightKey.self) { contentHeight = $0 }
        .onAppear { if focusCaptionOnAppear { captionFocus = UUID() } }
        .onChange(of: editor.captionFocusRequest) { _, _ in
            if [.arrow, .number, .text, .watermark].contains(tool) { captionFocus = UUID() }
        }
        .accessibilityIdentifier("capture.annotation.styles")
    }

    private var showsColor: Bool {
        if tool == .mosaic { return editor.style.mosaic == .solid }
        return [.arrow, .rectangle, .ellipse, .line, .pen, .highlight, .text, .number, .cover, .watermark].contains(tool)
    }

    private var colorSettings: some View {
        row("颜色") {
            HStack(spacing: 5) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, item in
                    Button { editor.color = item.color } label: {
                        Circle().fill(item.color).frame(width: 18, height: 18)
                            .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1) }
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                    .accessibilityLabel(item.name)
                }
                Spacer(minLength: 0)
                ColorPicker("自定颜色", selection: $editor.color).labelsHidden().fixedSize()
            }
        }
    }

    private var palette: [(name: String, color: Color)] {
        [("红色", .red), ("黄色", .yellow), ("绿色", .green), ("蓝色", .blue), ("白色", .white), ("黑色", .black)]
    }

    @ViewBuilder private var primaryParameter: some View {
        switch tool {
        case .arrow, .rectangle, .ellipse, .line, .pen, .highlight:
            slider("粗细", value: $editor.width, range: 1...30, display: "\(Int(editor.width))")
        case .text, .watermark, .number:
            slider("字号", value: binding(\.fontSize), range: 12...80, display: "\(Int(editor.style.fontSize))")
        case .mosaic:
            if editor.style.mosaic != .solid {
                slider("强度", value: binding(\.strength), range: 4...64, display: "\(Int(editor.style.strength))")
            }
        case .spotlight:
            slider("暗度", value: binding(\.dimming), range: 0.15...0.85, display: "\(Int(editor.style.dimming * 100))%")
        case .magnify:
            slider("放大", value: binding(\.magnification), range: 1.25...5, display: String(format: "%.1f×", editor.style.magnification))
        default: EmptyView()
        }
    }

    @ViewBuilder private var controls: some View {
        switch tool {
        case .ellipse: ellipseSettings
        case .rectangle:
            option("填充", \.fill)
            option("线型", \.line)
            slider("圆角", value: binding(\.cornerRadius), range: 0...120, display: "\(Int(editor.style.cornerRadius))")
            opacity
        case .arrow:
            option("箭头", \.arrow)
            option("线型", \.line)
            caption
            if document.selectedMark?.control != nil {
                Button("恢复直线") { document.updateSelected { $0.control = nil } }
            } else {
                hint("拖动箭头中间的圆点可调整弧度。")
            }
        case .number: numberSettings
        case .mosaic:
            option("效果", \.mosaic)
            option("范围", \.coverage)
            if editor.style.coverage == .brush {
                slider("画笔", value: binding(\.brushSize), range: 8...120, display: "\(Int(editor.style.brushSize))")
            }
        case .text: textSettings
        case .line:
            Toggle("连续绘制折线", isOn: binding(\.polyline))
            option("线型", \.line)
            hint(editor.style.polyline ? "连续点击添加节点，双击或右键完成。" : "按住 ⇧ 可对齐 45°。")
        case .pen, .highlight:
            Toggle("平滑笔迹", isOn: binding(\.smooth))
            opacity
        case .spotlight:
            Toggle("椭圆聚光区域", isOn: binding(\.ellipse))
        case .watermark: watermarkSettings
        case .magnify:
            Toggle("旁置放大", isOn: binding(\.detachedMagnifier))
            Toggle("圆形放大区域", isOn: binding(\.ellipse))
        default: EmptyView()
        }
    }

    private var ellipseSettings: some View {
        Group {
            row("形状") {
                Picker("形状", selection: Binding(get: { editor.style.ellipseKind }, set: {
                    var value = editor.style
                    value.ellipseKind = $0
                    if [.sector, .ringSector].contains($0), value.arcSpan >= 360 { value.arcSpan = 270 }
                    editor.style = value
                })) {
                    ForEach(CaptureEllipseKind.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            option("填充", \.fill)
            option("线型", \.line)
            if [.sector, .ringSector].contains(editor.style.ellipseKind) {
                slider("角度", value: binding(\.arcSpan), range: 5...360, display: "\(Int(editor.style.arcSpan))°")
            }
            if [.ring, .ringSector].contains(editor.style.ellipseKind) {
                slider("内径", value: binding(\.innerRatio), range: 0.05...0.95, display: "\(Int(editor.style.innerRatio * 100))%")
            }
        }
    }

    private var numberSettings: some View {
        Group {
            option("样式", \.number)
            option("编号", \.numberFormat)
            row("数值") {
                HStack {
                    Stepper(value: Binding(get: { document.selectedMark?.numberValue ?? editor.nextNumber }, set: { editor.setNumber($0) }), in: 0...9999) {
                        Text("\(document.selectedMark?.numberValue ?? editor.nextNumber)").monospacedDigit()
                    }
                    Button("从 1 开始") { document.selectedMarkID = nil; editor.nextNumberOverride = 1 }
                }
            }
            caption
        }
    }

    private var textSettings: some View {
        Group {
            row("字体") {
                Picker("字体", selection: Binding(get: { editor.style.fontName ?? "" }, set: {
                    var value = editor.style; value.fontName = $0.isEmpty ? nil : $0; editor.style = value
                })) {
                    Text("系统字体").tag("")
                    ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            row("字形") {
                HStack {
                    Toggle("粗体", isOn: binding(\.bold)).toggleStyle(.button)
                    Toggle("斜体", isOn: binding(\.italic)).toggleStyle(.button)
                    Spacer(minLength: 0)
                }
            }
            Toggle("文字背景", isOn: binding(\.textBackground))
            Toggle("文字描边", isOn: Binding(get: { editor.style.textOutline ?? false }, set: {
                var value = editor.style; value.textOutline = $0; editor.style = value
            }))
            Toggle("自动换行", isOn: Binding(get: { editor.style.textWrapWidth != nil }, set: {
                var value = editor.style; value.textWrapWidth = $0 ? 240 : nil; editor.style = value
            }))
            if let width = editor.style.textWrapWidth {
                slider("文本宽度", value: Binding(get: { editor.style.textWrapWidth ?? 240 }, set: {
                    var value = editor.style; value.textWrapWidth = $0; editor.style = value
                }), range: 40...1000, display: "\(Int(width))")
            }
            opacity
        }
    }

    private var watermarkSettings: some View {
        Group {
            Toggle("平铺水印", isOn: binding(\.watermarkTiled))
            slider("角度", value: Binding(get: { editor.style.rotation * 180 / .pi }, set: {
                var value = editor.style; value.rotation = $0 * .pi / 180; editor.style = value
            }), range: -90...90, display: "\(Int(editor.style.rotation * 180 / .pi))°")
            opacity
            hint("文字中可使用 {date} 和 {time} 插入日期与时间。")
        }
    }

    private var opacity: some View {
        slider("透明度", value: binding(\.opacity), range: 0.1...1, display: "\(Int(editor.style.opacity * 100))%")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([.text, .watermark].contains(tool) ? "文字内容" : "说明文字").foregroundStyle(.secondary)
            CaptureCaptionField(text: $editor.text,
                                placeholder: [.text, .watermark].contains(tool) ? "输入文字，回车后点击图片放置" : "可选",
                                focusRequest: captionFocus,
                                onSubmit: finishCaption, onCancel: finishCaption)
                .frame(height: 26)
        }
    }

    private func finishCaption() {
        captionFocus = nil
        dismiss()
        editor.canvasPanel.makeKeyAndOrderFront(nil)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 24)
    }

    private func slider<Value: BinaryFloatingPoint>(_ label: String, value: Binding<Value>, range: ClosedRange<Value>, display: String) -> some View where Value.Stride: BinaryFloatingPoint {
        row(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, onEditingChanged: editor.styleEditing).accessibilityLabel(label)
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<CaptureMarkStyle, Value>) -> Binding<Value> {
        Binding(get: { editor.style[keyPath: key] }, set: {
            var value = editor.style; value[keyPath: key] = $0; editor.style = value
        })
    }

    private func option<Value: CaptureStyleOption & Hashable>(_ label: String, _ key: WritableKeyPath<CaptureMarkStyle, Value>) -> some View {
        row(label) {
            Picker(label, selection: binding(key)) {
                ForEach(Array(Value.allCases), id: \.self) { value in Text(value.title).tag(value) }
            }.labelsHidden()
        }
    }
}

private struct CaptureInspectorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 280
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A native field explicitly opts into keyboard focus in a nonactivating panel.
/// SwiftUI's hosting view does not opt in, and its initial FocusState update can
/// occur before a popover has an NSWindow to receive the field editor.
struct CaptureCaptionField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusRequest: UUID?
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CaptureCaptionTextField {
        let field = CaptureCaptionTextField(string: text)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.controlSize = .small
        field.usesSingleLineMode = true
        field.setAccessibilityIdentifier("capture.annotation.text")
        return field
    }
    func updateNSView(_ field: CaptureCaptionTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        // Never replace an input method's marked text during a SwiftUI refresh.
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        field.requestFocus(focusRequest)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptureCaptionField
        init(_ parent: CaptureCaptionField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Return/Escape belong to the input method while composing Chinese.
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit(); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel(); return true
            }
            return false
        }
    }
}

final class CaptureCaptionTextField: NSTextField {
    private var pendingFocus: UUID?
    private var appliedFocus: UUID?
    private var focusScheduled = false
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFocus()
    }
    func requestFocus(_ request: UUID?) {
        pendingFocus = request
        scheduleFocus()
    }
    private func scheduleFocus() {
        guard let pendingFocus, pendingFocus != appliedFocus, window != nil, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            guard let request = self.pendingFocus, request != self.appliedFocus, let window = self.window else { return }
            window.makeKey()
            if window.makeFirstResponder(self) {
                self.appliedFocus = request
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}
