import AppKit
import SwiftUI

/// A transparent drawing surface inside the capture filter. Ordinary pointer
/// input passes through until the user chooses an annotation tool.
@MainActor final class CaptureRecordingAnnotations: ObservableObject {
    @Published var tool: CaptureTool? {
        didSet {
            panel?.ignoresMouseEvents = tool == nil
            if tool != nil {
                if NSApp?.keyWindow !== panel { previousKeyWindow = NSApp?.keyWindow }
                panel?.makeKeyAndOrderFront(nil); panel?.makeFirstResponder(surface)
            } else if panel?.isKeyWindow == true { previousKeyWindow?.makeKeyAndOrderFront(nil) }
            surface?.needsDisplay = true
        }
    }
    @Published var color = Color.red
    @Published var width = 3.0
    @Published private(set) var marks: [CaptureMark] = []
    private var panel: NSPanel?
    private var surface: RecordingAnnotationSurface?
    private weak var previousKeyWindow: NSWindow?
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }
    private(set) var draft: CaptureMark?
    private var nextNumber = 1

    func start(in selection: CaptureSelection) {
        guard let frame = selection.presentationFrame else { return }
        let panel = RecordingAnnotationPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        CaptureWindowPolicy.markControl(panel, name: "recordingAnnotations")
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.level = .floating; panel.ignoresMouseEvents = true
        panel.collectionBehavior = CaptureWindowPolicy.floatingBehavior
        let surface = RecordingAnnotationSurface(owner: self)
        panel.contentView = surface; self.panel = panel; self.surface = surface
        panel.orderFrontRegardless()
    }
    func stop() { panel?.close(); panel = nil; surface = nil; draft = nil }
    func undo() {
        if let last = marks.popLast(), last.tool == .number { nextNumber = max(1, (last.numberValue ?? 1)) }
        surface?.needsDisplay = true
    }
    func clear() { marks = []; draft = nil; nextNumber = 1; surface?.needsDisplay = true; surface?.displayIfNeeded() }
    func begin(_ point: CGPoint) {
        guard let tool, marks.count < 1000 else { return }
        var mark = CaptureMark(tool: tool, points: [point, point], color: NSColor(color), width: CGFloat(width))
        if tool == .number { mark.numberValue = nextNumber; mark.text = String(nextNumber) }
        if tool == .rectangle { mark.style.cornerRadius = 6 }
        if tool == .highlight { mark.style.opacity = 0.35; mark.width = max(12, mark.width * 4) }
        draft = mark; surface?.needsDisplay = true
    }
    func drag(_ point: CGPoint) {
        guard var mark = draft else { return }
        if mark.tool == .pen || mark.tool == .highlight { mark.points.append(point) }
        else { mark.points[mark.points.count - 1] = point }
        draft = mark; surface?.needsDisplay = true
    }
    func end(_ point: CGPoint) {
        drag(point)
        if let draft { marks.append(draft); if draft.tool == .number { nextNumber += 1 } }
        draft = nil; surface?.needsDisplay = true
    }
}

private final class RecordingAnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class RecordingAnnotationSurface: NSView {
    private weak var owner: CaptureRecordingAnnotations?
    init(owner: CaptureRecordingAnnotations) { self.owner = owner; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.begin(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { owner?.drag(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { owner?.end(convert(event.locationInWindow, from: nil)) }
    override func rightMouseDown(with event: NSEvent) { owner?.tool = nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.tool = nil }
        else if event.modifierFlags.contains(.command), event.keyCode == 6 { owner?.undo() }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let owner, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        for mark in owner.marks + [owner.draft].compactMap({ $0 }) {
            context.saveGState()
            context.setStrokeColor(mark.color.cgColor); context.setFillColor(mark.color.cgColor)
            context.setLineWidth(mark.width); context.setLineCap(.round); context.setLineJoin(.round)
            context.setAlpha(mark.style.opacity)
            switch mark.tool {
            case .arrow: CaptureAnnotationRenderer.drawArrow(mark, in: context)
            case .number: CaptureAnnotationRenderer.drawNumber(mark, in: context)
            case .rectangle, .ellipse: context.addPath(CaptureAnnotationRenderer.shape(mark)); context.strokePath()
            default: context.addPath(CaptureAnnotationRenderer.path(mark)); context.strokePath()
            }
            context.restoreGState()
        }
    }
}

struct RecordingAnnotationMenu: View {
    @ObservedObject var annotations: CaptureRecordingAnnotations
    var body: some View {
        Menu {
            Button("操作屏幕") { annotations.tool = nil }
            ForEach([CaptureTool.arrow, .rectangle, .ellipse, .number, .pen, .highlight], id: \.self) { tool in
                Button(tool.title) { annotations.tool = tool }
            }
            Divider()
            Menu("颜色") {
                Button("红色") { annotations.color = .red }; Button("蓝色") { annotations.color = .blue }
                Button("黄色") { annotations.color = .yellow }; Button("白色") { annotations.color = .white }
            }
            Menu("线宽") { ForEach([2.0, 3.0, 5.0, 8.0], id: \.self) { value in Button("\(Int(value))") { annotations.width = value } } }
            Button("撤销标注") { annotations.undo() }.disabled(annotations.marks.isEmpty)
            Button("清除标注") { annotations.clear() }.disabled(annotations.marks.isEmpty)
        } label: { Label(annotations.tool?.title ?? "标注", systemImage: "pencil.tip") }
            .fixedSize()
            .help("录屏中绘制标注；Esc、右键或选择「操作屏幕」恢复操作其他应用")
    }
}
