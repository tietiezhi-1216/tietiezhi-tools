import AppKit
import Combine
import SwiftUI

/// All rectangles here use AppKit's global, bottom-left-origin screen coordinates.
enum CaptureFloatingLayout {
    static let toolbarSize = CGSize(width: 906, height: 52)
    static func screenRect(_ rect: CGRect, on screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + rect.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    static func imageFrame(size: CGSize, preferred: CGRect?, screen: CGRect, pixelsPerPoint: CGFloat) -> CGRect {
        if let preferred, screen.contains(preferred), preferred.width >= 2, preferred.height >= 2 { return preferred }
        let available = screen.insetBy(dx: 16, dy: 16)
        let factor = min(1 / max(1, pixelsPerPoint), min(available.width / size.width, available.height / size.height))
        let fitted = CGSize(width: max(2, size.width * factor), height: max(2, size.height * factor))
        let origin = preferred.map { CGPoint(x: $0.minX, y: $0.maxY - fitted.height) }
            ?? CGPoint(x: screen.midX - fitted.width / 2, y: screen.midY - fitted.height / 2)
        return CGRect(x: min(max(origin.x, available.minX), available.maxX - fitted.width),
                      y: min(max(origin.y, available.minY), available.maxY - fitted.height), width: fitted.width, height: fitted.height)
    }
    static func toolbarFrame(image: CGRect, visible: CGRect, size: CGSize = toolbarSize) -> CGRect {
        let area = visible.insetBy(dx: 8, dy: 8)
        let width = min(size.width, area.width), height = min(size.height, area.height)
        let gap: CGFloat = 10
        let below = image.minY - gap - height
        let above = image.maxY + gap
        let y = below >= area.minY ? below : above + height <= area.maxY ? above : image.minY + gap
        return CGRect(x: min(max(image.maxX - width, area.minX), area.maxX - width),
                      y: min(max(y, area.minY), area.maxY - height), width: width, height: height)
    }
}

@MainActor final class CaptureFloatingEditor: NSObject, ObservableObject, NSWindowDelegate {
    let id = UUID()
    let document: CaptureDocument
    private(set) weak var controller: ScreenshotController?
    let canvasPanel: NSPanel
    let toolsPanel: NSPanel
    @Published var tool: CaptureTool = .move {
        didSet {
            guard tool != oldValue else { return }
            if !synchronizing {
                document.finishMarkEdit()
                if tool != .select { document.selectedMarkID=nil }
                synchronizing=true
                if let saved=toolStyles[tool.rawValue] { style=saved }
                else {
                    var value=CaptureMarkStyle()
                    if tool == .watermark { value.opacity=0.25;value.rotation = -.pi/6 }
                    if tool == .magnify { value.ellipse=true }
                    style=value
                }
                synchronizing=false
            }
        }
    }
    @Published var color = Color.red { didSet { changeSelected { $0.color=NSColor(self.color) } } }
    @Published var width: Double = 3 { didSet { changeSelected { $0.width=self.width } } }
    @Published var text = "" {
        didSet { changeSelected { if $0.tool == .number { $0.caption=self.text } else { $0.text=self.text } } }
    }
    @Published var style = CaptureMarkStyle() {
        didSet {
            guard !synchronizing else { return }
            toolStyles[inspectorTool.rawValue]=style
            annotationDefaults.set(try? JSONEncoder().encode(toolStyles),forKey:"capture.annotation.styles")
            changeSelected { $0.style=self.style }
        }
    }
    @Published var nextNumberOverride: Int?
    @Published var captionFocusRequest=UUID()
    @Published var redactionImage: CGImage?
    @Published var showInpaintingSettings = false
    private var synchronizing=false
    private var toolStyles: [String:CaptureMarkStyle] = [:]
    private let annotationDefaults: UserDefaults
    var inspectorTool: CaptureTool { document.selectedMark?.tool ?? tool }
    var showsInspector: Bool { ![.move,.select,.crop,.deleteMarks,.erase,.inpaint].contains(inspectorTool) }
    var nextNumber: Int {
        if let nextNumberOverride { return nextNumberOverride }
        let local = document.nextNumber(format: style.numberFormat)
        guard annotationDefaults.bool(forKey: "capture.numberGlobal") else { return local }
        return max(local, annotationDefaults.integer(forKey: "capture.numberGlobal.\(style.numberFormat.rawValue)"))
    }
    func setNumber(_ value:Int) {
        if document.selectedMark?.tool == .number { document.updateSelected { $0.numberValue=value } }
        else { nextNumberOverride=value }
    }
    func addMark(_ mark:CaptureMark) {
        if mark.tool == .erase || mark.tool == .inpaint {
            if mark.tool == .inpaint && !CaptureInpaintingModel.installed { showInpaintingSettings = true; return }
            recognitionTask = Task { [document] in await document.repairBackground(in: mark.rect, intelligent: mark.tool == .inpaint) }; return
        }
        document.add(mark)
        if [.text,.watermark].contains(mark.tool), mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { editCaption(mark.id) }
        if mark.tool == .number {
            if annotationDefaults.bool(forKey: "capture.numberGlobal") {
                annotationDefaults.set((mark.numberValue ?? 1) + 1, forKey: "capture.numberGlobal.\(mark.style.numberFormat.rawValue)")
            }
            nextNumberOverride=nil
        }
    }
    private func changeSelected(_ action:(inout CaptureMark)->Void) {
        guard !synchronizing, var mark=document.selectedMark else { return }
        action(&mark)
        if document.isEditingMark { document.previewMark(mark) } else { document.replaceMark(mark) }
    }
    func styleEditing(_ editing:Bool) {
        if editing,let id=document.selectedMarkID { document.beginMarkEdit(id) }
        else if !editing { document.finishMarkEdit() }
    }
    private func synchronizeSelection(_ id:UUID?) {
        if let mark=document.marks.first(where:{ $0.id == id }) {
            synchronizing=true
            color=Color(nsColor:mark.color);width=mark.width;style=mark.style
            text=mark.tool == .number ? mark.caption:mark.text
            synchronizing=false
        }
        positionToolbar()
    }
    func editCaption(_ id:UUID) {
        document.selectedMarkID=id
        toolbarHidden=false;positionToolbar();toolsPanel.makeKeyAndOrderFront(nil);captionFocusRequest=UUID()
    }
    @Published var zoom: Double = 0
    @Published var pixel = ""
    @Published var toolbarHidden = false
    @Published var showRecognition = false
    @Published var recognitionTab = RecognitionTab.text
    @Published private(set) var recognizing = false
    private(set) var isClosed = false
    var onClose: (() -> Void)?
    var pinImage: ((CGImage, CGRect) throws -> Void)?
    private let pixelsPerPoint: CGFloat
    private var imageSize: CGSize
    private var imageOffset = CGPoint.zero
    private var positioning = false
    private var toolbarOrigin = CGPoint.zero
    private var subscriptions = Set<AnyCancellable>()
    private var recognitionTask: Task<Void, Never>?
    var imageFrame: CGRect { canvasPanel.frame }

    init(document: CaptureDocument, controller: ScreenshotController, preferredFrame: CGRect? = nil, annotationDefaults: UserDefaults = .standard) {
        self.document = document; self.controller = controller;self.annotationDefaults=annotationDefaults
        toolStyles=annotationDefaults.data(forKey:"capture.annotation.styles").flatMap { try? JSONDecoder().decode([String:CaptureMarkStyle].self,from:$0) } ?? [:]
        imageSize = CGSize(width: document.image.width, height: document.image.height)
        let screen = Self.screen(for: preferredFrame) ?? NSScreen.main
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        pixelsPerPoint = preferredFrame.map { CGFloat(document.image.width) / max(1, $0.width) } ?? screen?.backingScaleFactor ?? 1
        let frame = CaptureFloatingLayout.imageFrame(size: imageSize, preferred: preferredFrame, screen: screenFrame, pixelsPerPoint: pixelsPerPoint)
        canvasPanel = CaptureEditorPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolsPanel = CaptureEditorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        for panel in [canvasPanel, toolsPanel] {
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = CaptureWindowPolicy.floatingBehavior
            panel.delegate = self
            (panel as? CaptureEditorPanel)?.onDismiss = { [weak self] in self?.close() }
        }
        canvasPanel.title = "截图浮层"; canvasPanel.hasShadow = false; canvasPanel.acceptsMouseMovedEvents = true
        toolsPanel.title = "截图工具条"; toolsPanel.hasShadow = true
        toolsPanel.acceptsMouseMovedEvents = true
        toolsPanel.becomesKeyOnlyIfNeeded = false
        CaptureWindowPolicy.markControl(toolsPanel, name: "editorToolbar")
        canvasPanel.contentView = CaptureFirstMouseHostingView(rootView: CaptureFloatingCanvasView(editor: self, document: document))
        let toolbar = CaptureFirstMouseHostingView(rootView: CaptureFloatingToolbar(editor: self, document: document))
        toolbar.sizingOptions = []
        toolsPanel.contentView = toolbar
        positionToolbar()
        document.$image.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resizeImage(to: CGSize(width: self.document.image.width, height: self.document.image.height), offset: self.document.canvasOffset)
            }
        }.store(in: &subscriptions)
        document.$marks.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return };self.synchronizeSelection(self.document.selectedMarkID)
            }
        }.store(in:&subscriptions)
        document.$selectedMarkID.dropFirst().sink { [weak self] id in
            Task { @MainActor [weak self] in self?.synchronizeSelection(id) }
        }.store(in:&subscriptions)
        Publishers.CombineLatest($tool, $toolbarHidden).dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.positionToolbar() }
        }.store(in: &subscriptions)
    }
    private static func screen(for frame: CGRect?) -> NSScreen? {
        if let frame {
            return NSScreen.screens.max { left, right in
                let a = left.frame.intersection(frame), b = right.frame.intersection(frame)
                return max(0, a.width) * max(0, a.height) < max(0, b.width) * max(0, b.height)
            }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }
    func show(recognition: RecognitionTab? = nil) {
        guard !isClosed else { return }
        canvasPanel.makeKeyAndOrderFront(nil); positionToolbar()
        if let recognition { openRecognition(recognition) }
    }
    func close() {
        guard !isClosed else { return }
        document.finishMarkEdit()
        do { try document.persist() } catch { document.error=error.localizedDescription;return }
        isClosed = true; recognitionTask?.cancel(); subscriptions.removeAll()
        for panel in [toolsPanel, canvasPanel] {
            panel.orderOut(nil); panel.close(); panel.contentView = nil
        }
        let callback = onClose; onClose = nil; callback?()
    }
    func windowWillClose(_ notification: Notification) { close() }
    func windowDidMove(_ notification: Notification) {
        guard !positioning, !isClosed, let window = notification.object as? NSWindow else { return }
        if window === canvasPanel { positionToolbar() }
        else if window === toolsPanel {
            let origin = toolsPanel.frame.origin
            let delta = CGSize(width: origin.x - toolbarOrigin.x, height: origin.y - toolbarOrigin.y)
            positioning = true
            canvasPanel.setFrameOrigin(CGPoint(x: canvasPanel.frame.minX + delta.width, y: canvasPanel.frame.minY + delta.height))
            positioning = false; toolbarOrigin = origin
        }
    }
    private func resizeImage(to size: CGSize, offset: CGPoint) {
        guard !isClosed, size != imageSize || offset != imageOffset else { return }
        let delta = CGPoint(x: (offset.x - imageOffset.x) / pixelsPerPoint, y: (offset.y - imageOffset.y) / pixelsPerPoint)
        imageOffset = offset; imageSize = size; zoom = 0
        let screen = Self.screen(for: imageFrame)?.frame ?? canvasPanel.screen?.frame ?? imageFrame
        let sizeAtScale = CGSize(width: size.width / pixelsPerPoint, height: size.height / pixelsPerPoint)
        let desired = CGRect(x: imageFrame.minX + delta.x, y: imageFrame.maxY - delta.y - sizeAtScale.height, width: sizeAtScale.width, height: sizeAtScale.height)
        positioning = true
        canvasPanel.setFrame(CaptureFloatingLayout.imageFrame(size: size, preferred: desired, screen: screen, pixelsPerPoint: pixelsPerPoint), display: true)
        positioning = false; positionToolbar()
    }
    private func positionToolbar() {
        guard !isClosed else { return }
        let visible = Self.screen(for: imageFrame)?.visibleFrame ?? imageFrame
        let frame = CaptureFloatingLayout.toolbarFrame(image: imageFrame, visible: visible)
        positioning = true
        toolsPanel.setFrame(frame, display: true); toolbarOrigin = frame.origin
        positioning = false
        if toolbarHidden || !canvasPanel.isVisible { toolsPanel.orderOut(nil) }
        else { toolsPanel.orderFrontRegardless() }
    }
    func openRecognition(_ tab: RecognitionTab) {
        guard controller?.canUseFeatures() == true else { return }
        toolbarHidden = false; recognitionTab = tab
        positionToolbar(); toolsPanel.makeKeyAndOrderFront(nil); showRecognition = true
    }
    func perform(_ action: CaptureShortcutAction) {
        guard !isClosed else { return }
        if let next = action.tool { tool = next; toolbarHidden = false; return }
        switch action {
        case .close:
            if let canvas=canvasPanel.firstResponder as? CaptureDrawingView,canvas.cancelActiveInteraction() { return }
            if document.selectedMarkID != nil { document.selectedMarkID=nil } else { close() }
        case .copy, .copyAndClose: if document.copy() { close() }
        case .save: document.save { [weak self] in self?.close() }
        case .quickSave: if document.quickSave() { close() }
        case .printImage: document.printImage()
        case .undo: document.undo()
        case .redo: document.redo()
        case .clearMarks: document.clearMarks()
        case .pin:
            do {
                guard let pinImage else { return }
                try document.persist()
                try pinImage(document.image, imageFrame); close()
            } catch { document.error = error.localizedDescription }
        case .ocr:
            guard !recognizing else { return }; recognizing = true
            recognitionTask = Task { [weak self, document] in
                defer { self?.recognizing = false }
                do {
                    let result = try await CaptureRecognition.recognize(document.image)
                    try Task.checkCancellation()
                    guard !result.text.isEmpty else { throw PluginError.invalid("未识别到文字。") }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string)
                    self?.close()
                } catch is CancellationError {} catch { document.error = error.localizedDescription }
            }
        case .translation: openRecognition(.translation)
        case .document: openRecognition(.document)
        case .table: openRecognition(.table)
        case .formula: openRecognition(.formula)
        case .hideToolbar: toolbarHidden.toggle()
        case .copyColor:
            if !pixel.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pixel, forType: .string) }
        case .autoMosaic:
            redactionImage = document.image
        default: break
        }
    }
}

final class CaptureFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

private final class CaptureEditorPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { onDismiss?() }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

struct CaptureFloatingCanvasView: View {
    @ObservedObject var editor: CaptureFloatingEditor
    @ObservedObject var document: CaptureDocument
    var body: some View {
        CaptureCanvas(image: document.image, tool: editor.tool, color: NSColor(editor.color), width: editor.width,
                      text: editor.text, zoom: editor.zoom, number: editor.nextNumber,
                      marks: document.marks, moved: document.moveMark, removed: document.removeMark,
                      marked: editor.addMark, pixel: { editor.pixel = $0 }, floating: true, style:editor.style,
                      selectedID:document.selectedMarkID,selected:{ document.selectedMarkID=$0 },
                      beginEdit:document.beginMarkEdit,preview:document.previewMark,finishEdit:document.finishMarkEdit,editText:editor.editCaption,selectionAction:document.selectionAction)
            .overlay { Rectangle().strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1).allowsHitTesting(false) }
            .background(CaptureShortcutMonitor(scope: .editor, handle: editor.perform).frame(width: 0, height: 0))
            .accessibilityIdentifier("capture.floating.canvas")
    }
}

struct CaptureFloatingToolbar: View {
    @ObservedObject var editor: CaptureFloatingEditor
    @ObservedObject var document: CaptureDocument
    @ObservedObject private var shortcuts = CaptureShortcutSettings.shared
    @AppStorage("capture.toolbarOrder") private var toolbarOrder = ""
    @ViewState private var toolbarSettings = false
    @ViewState private var stylesPresented = false
    @ViewState private var focusCaption = false
    private var tools: [CaptureTool] { CaptureToolbarPreferences.ordered(toolbarOrder) }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 16, height: 28).contentShape(Rectangle()).panelWindowDragArea()
                .background(CaptureToolbarHelp("拖动工具条；按住 ⌥ 可临时拖动图片"))
            ForEach(tools) { tool in
                Button { select(tool) } label: { Image(systemName: tool.symbol).frame(width: 28, height: 28) }
                    .foregroundStyle(editor.tool == tool ? Color.accentColor : Color.primary)
                    .background(editor.tool == tool ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .background(CaptureToolbarHelp(hint(tool))).accessibilityLabel(tool.title)
                    .accessibilityIdentifier("capture.tool.\(tool.rawValue)")
            }
            action(.autoMosaic, symbol: "checkmark.shield").disabled(document.analyzing)
            stylesButton
            action(.undo, symbol: "arrow.uturn.backward").disabled(document.undoCount == 0)
            action(.redo, symbol: "arrow.uturn.forward").disabled(document.redoCount == 0)
            recognitionMenu
            action(.pin, symbol: "pin")
            action(.save, symbol: "square.and.arrow.down")
            moreActions
            action(.copyAndClose, symbol: "doc.on.doc").accessibilityIdentifier("capture.floating.copy")
            action(.close, symbol: "xmark")
        }
        .font(.system(size: 13)).buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 12).modifier(CaptureToolbarSurface())
        .background(CaptureShortcutMonitor(scope: .editor, handle: editor.perform).frame(width: 0, height: 0))
        .popover(isPresented: $editor.showRecognition) {
            if let controller = editor.controller {
                CaptureRecognitionView(document: document, controller: controller, initialTab: editor.recognitionTab)
            }
        }
        .sheet(isPresented: $editor.showInpaintingSettings) {
            VStack { Form { CaptureInpaintingSettingsView() }.formStyle(.grouped); Button("完成") { editor.showInpaintingSettings = false; if CaptureInpaintingModel.installed { editor.tool = .inpaint } } }.padding(16).frame(width: 500, height: 260)
                .background(CaptureInputWindowFocus().frame(width: 0, height: 0))
        }
        .sheet(isPresented: $toolbarSettings) { CaptureToolbarSettingsView() }
        .sheet(isPresented: Binding(get: { editor.redactionImage != nil }, set: { if !$0 { editor.redactionImage = nil } })) {
            if let source = editor.redactionImage {
                CaptureRedactionReview(image: source) { regions in
                    if document.image === source { document.applyRedactions(regions) }
                    else { document.error = "图片已修改，请重新检测。" }
                    editor.redactionImage = nil
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { document.error != nil }, set: { if !$0 { document.error = nil } })) {
            Button("好") { document.error = nil }
        } message: { Text(document.error ?? "") }
        .onChange(of: editor.inspectorTool) { _, _ in stylesPresented = false }
        .onChange(of: editor.tool) { _, tool in
            if [.text, .watermark].contains(tool) { presentStyles(focus: true) }
        }
        .onChange(of: editor.captionFocusRequest) { _, _ in presentStyles(focus: true) }
        .accessibilityIdentifier("capture.floating.toolbar")
    }
    private var stylesButton: some View {
        Button {
            if stylesPresented { stylesPresented = false }
            else { presentStyles() }
        } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
        .disabled(!editor.showsInspector)
        .background(CaptureToolbarHelp("颜色与样式；再次点击当前工具也可打开"))
        .accessibilityLabel("颜色与样式").accessibilityIdentifier("capture.floating.styles")
        .popover(isPresented: $stylesPresented) {
            CaptureAnnotationInspector(editor: editor, document: document, focusCaptionOnAppear: focusCaption)
                .buttonStyle(.bordered)
                .onExitCommand { stylesPresented = false; editor.canvasPanel.makeKeyAndOrderFront(nil) }
        }
    }
    private func presentStyles(focus: Bool = false) {
        guard editor.showsInspector else { return }
        editor.toolsPanel.makeKeyAndOrderFront(nil)
        focusCaption = focus; stylesPresented = true
    }
    private func select(_ tool: CaptureTool) {
        if tool == .inpaint && !CaptureInpaintingModel.installed { editor.showInpaintingSettings = true }
        else if tool == editor.tool && editor.showsInspector { presentStyles(focus: [.text, .watermark].contains(tool)) }
        else { editor.tool = tool }
    }
    private var recognitionMenu: some View {
        Menu {
            Button("文字 / 二维码") { editor.openRecognition(.text) }
            Button("OCR 并复制") { editor.perform(.ocr) }.disabled(editor.recognizing)
            Button("翻译") { editor.openRecognition(.translation) }
            Divider()
            Button("表格") { editor.openRecognition(.table) }
            Button("公式") { editor.openRecognition(.formula) }
            Button("文档") { editor.openRecognition(.document) }
        } label: { Image(systemName: "text.viewfinder").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
        .background(CaptureToolbarHelp("识别与翻译")).accessibilityLabel("识别与翻译")
    }
    private var moreActions: some View {
        Menu {
            Button("快速保存") { editor.perform(.quickSave) }
            Button("打印…") { editor.perform(.printImage) }
            Divider()
            Button("旋转 90°") { document.rotate() }
            Menu("缩放") {
                Button("适应贴图") { editor.zoom = 0 }
                ForEach([0.5, 1.0, 2.0, 3.0], id: \.self) { value in Button("\(Int(value * 100))%") { editor.zoom = value } }
            }
            Button(editor.pixel.isEmpty ? "复制颜色" : "复制颜色 \(editor.pixel)") { editor.perform(.copyColor) }.disabled(editor.pixel.isEmpty)
            Button("清除标注") { editor.perform(.clearMarks) }.disabled(document.marks.isEmpty)
            Divider()
            Button("工具顺序") { toolbarSettings = true }
            Button("隐藏工具条") { editor.toolbarHidden = true }
            Text("\(document.image.width) × \(document.image.height) 像素")
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
        .background(CaptureToolbarHelp("更多操作")).accessibilityLabel("更多操作").accessibilityIdentifier("capture.floating.more")
    }
    private func action(_ action: CaptureShortcutAction, symbol: String) -> some View {
        Button { if action == .close { editor.close() } else { editor.perform(action) } } label: { Image(systemName: symbol).frame(width: 28, height: 28) }
            .background(CaptureToolbarHelp(action.title + (shortcuts.binding(action).map { "（\($0.display)）" } ?? "")))
            .accessibilityLabel(action.title).accessibilityIdentifier("capture.floating.\(action.rawValue)")
    }
    private func hint(_ tool: CaptureTool) -> String {
        let binding = CaptureShortcutAction.allCases.first { $0.tool == tool }.flatMap { shortcuts.binding($0) }
        return tool.title + (binding.map { "（\($0.display)）" } ?? "")
    }
}

/// SwiftUI's help tracking is limited to active windows. Screenshot controls must
/// also explain themselves while another app remains active.
struct CaptureToolbarHelp: NSViewRepresentable {
    let text: String
    init(_ text: String) { self.text = text }
    func makeNSView(context: Context) -> CaptureToolbarHelpView { CaptureToolbarHelpView() }
    func updateNSView(_ view: CaptureToolbarHelpView, context: Context) { view.hint = text }
    static func dismantleNSView(_ view: CaptureToolbarHelpView, coordinator: ()) { view.dismissHint() }
}

final class CaptureToolbarHelpView: NSView {
    var hint = ""
    private var hoverArea: NSTrackingArea?
    private var pending: Task<Void, Never>?
    private var interactionMonitor: Any?
    private(set) var hintPanel: NSPanel?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissHint() }
    }
    override func mouseEntered(with event: NSEvent) {
        dismissHint()
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.dismissHint()
            return event
        }
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.showHint()
        }
    }
    override func mouseExited(with event: NSEvent) { dismissHint() }
    func dismissHint() {
        pending?.cancel(); pending = nil
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor); self.interactionMonitor = nil }
        hintPanel?.orderOut(nil); hintPanel?.close(); hintPanel = nil
    }
    func showHint() {
        guard let window, window.isVisible, !hint.isEmpty, hintPanel == nil else { return }
        let font = NSFont.systemFont(ofSize: 12)
        let textBounds = (hint as NSString).boundingRect(with: NSSize(width: 320, height: 1000), options: .usesLineFragmentOrigin, attributes: [.font: font])
        let size = NSSize(width: ceil(textBounds.width) + 20, height: max(16, ceil(textBounds.height)) + 14)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let below = anchor.minY - size.height - 6
        let y = below >= visible.minY + 8 ? below : min(anchor.maxY + 6, visible.maxY - size.height - 8)
        let panel = CaptureHintPanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        panel.collectionBehavior = CaptureWindowPolicy.floatingBehavior
        panel.appearance = window.effectiveAppearance
        CaptureWindowPolicy.markControl(panel, name: "editorTooltip")
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .popover; material.state = .active; material.blendingMode = .behindWindow
        material.wantsLayer = true; material.layer?.cornerRadius = 7; material.layer?.masksToBounds = true
        let label = NSTextField(wrappingLabelWithString: hint)
        label.font = font; label.textColor = .labelColor
        label.frame = NSRect(x: 10, y: 7, width: size.width - 20, height: size.height - 14)
        material.addSubview(label); panel.contentView = material
        hintPanel = panel; panel.orderFrontRegardless()
    }
}

private final class CaptureHintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CaptureToolbarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: 12))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            #else
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            #endif
        }
    }
}
