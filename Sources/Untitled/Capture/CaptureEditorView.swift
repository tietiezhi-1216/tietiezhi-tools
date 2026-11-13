import AppKit
import SwiftUI
import Translation
import NaturalLanguage
import UniformTypeIdentifiers
import AVKit

struct CaptureCanvas: NSViewRepresentable {
    let image: CGImage
    let tool: CaptureTool
    let color: NSColor
    let width: Double
    let text: String
    let zoom: Double
    let number: Int
    let marks: [CaptureMark]
    let moved: (Int, CGSize) -> Void
    let removed: (Int) -> Void
    let marked: (CaptureMark) -> Void
    let pixel: (String) -> Void
    var floating = false
    var style = CaptureMarkStyle()
    var selectedID: UUID?
    var selected: (UUID?) -> Void = { _ in }
    var beginEdit: (UUID) -> Void = { _ in }
    var preview: (CaptureMark) -> Void = { _ in }
    var finishEdit: () -> Void = {}
    var editText: (UUID) -> Void = { _ in }
    var selectionAction: (CaptureSelectionAction)->Void = { _ in }
    func makeNSView(context: Context) -> CaptureScrollView {
        let scroll = CaptureScrollView()
        scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = CaptureDrawingView()
        return scroll
    }
    func updateNSView(_ scroll: CaptureScrollView, context: Context) {
        guard let view = scroll.documentView as? CaptureDrawingView else { return }
        if view.image !== image { view.image = image; view.bitmap = NSBitmapImageRep(cgImage: image) }
        view.floating = floating
        view.tool = tool; view.color = color; view.width = width; view.text = text; view.number = number
        view.style=style;view.selectedID=selectedID;view.selected=selected
        view.beginEdit=beginEdit;view.preview=preview;view.finishEdit=finishEdit;view.editText=editText;view.selectionAction=selectionAction
        view.marks = marks; view.moved = moved; view.removed = removed
        view.marked = marked; view.pixel = pixel; view.zoom = zoom
        scroll.needsLayout = true; view.needsDisplay = true
    }
}

final class CaptureScrollView: NSScrollView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        (documentView as? CaptureDrawingView)?.sizeCanvas(contentSize)
    }
}

final class CaptureDrawingView: NSView {
    var image: CGImage?
    var floating = false
    var bitmap: NSBitmapImageRep?
    var tool = CaptureTool.move {
        didSet { if tool != oldValue { points=[];hover=nil;editing=nil;windowDrag=nil;window?.invalidateCursorRects(for:self) } }
    }
    var color = NSColor.red
    var width: Double = 3
    var text = ""
    var style = CaptureMarkStyle()
    var zoom: Double = 0
    var number = 1
    var marks: [CaptureMark] = []
    var selectedID: UUID?
    var moved: ((Int, CGSize) -> Void)?
    var removed: ((Int) -> Void)?
    var marked: ((CaptureMark) -> Void)?
    var selected: ((UUID?) -> Void)?
    var beginEdit: ((UUID) -> Void)?
    var preview: ((CaptureMark) -> Void)?
    var finishEdit: (() -> Void)?
    var editText: ((UUID) -> Void)?
    var selectionAction: ((CaptureSelectionAction)->Void)?
    private var wheelEditing=false
    var pixel: ((String) -> Void)?
    private var points: [CGPoint] = []
    private var hover: CGPoint?
    private var imageRect = CGRect.zero
    private var windowDrag: (start:CGPoint,origin:CGPoint)?
    private var editing: (mark:CaptureMark,handle:CaptureMarkHandle?,start:CGPoint)?
    private var scale: CGFloat { guard let image else { return 1 };return max(0.0001,imageRect.width/CGFloat(image.width)) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    func sizeCanvas(_ available:CGSize) {
        guard let image else { return }
        let inset:CGFloat = floating ? 0:48
        let fit=min((available.width-inset)/CGFloat(image.width),(available.height-inset)/CGFloat(image.height))
        let factor=zoom == 0 ? (floating ? fit:min(fit,1)):zoom
        let size=CGSize(width:CGFloat(image.width)*max(0.0001,factor),height:CGFloat(image.height)*max(0.0001,factor))
        setFrameSize(CGSize(width:max(available.width,size.width+inset),height:max(available.height,size.height+inset)))
        imageRect=CGRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
        needsDisplay=true
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseMoved,.activeAlways,.inVisibleRect],owner:self))
        super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(imageRect,cursor:tool == .move ? .openHand:tool == .select ? .arrow:.crosshair) }
    private func display(_ p:CGPoint) -> CGPoint { CGPoint(x:imageRect.minX+p.x*scale,y:imageRect.minY+p.y*scale) }
    override func draw(_ dirtyRect:NSRect) {
        if !floating { NSColor(calibratedWhite:0.12,alpha:1).setFill();bounds.fill() }
        guard let image else { return }
        var output=image
        if let draft=draft() { output=(try? CaptureImage.render(image,marks:[draft])) ?? image }
        NSImage(cgImage:output,size:.zero).draw(in:imageRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        if let mark=marks.first(where: { $0.id == selectedID }) {
            let handles=mark.handles(scale:scale)
            if ![.arrow,.line].contains(mark.tool) {
                let r=mark.selectionBounds
                let corners=[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]
                let path=NSBezierPath();path.move(to:display(mark.rotated(corners[0])))
                for p in corners.dropFirst() { path.line(to:display(mark.rotated(p))) };path.close()
                NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke();path.lineWidth=1;path.setLineDash([3,3],count:2,phase:0);path.stroke()
            }
            for handle in handles {
                let p=display(handle.point),r=CGRect(x:p.x-4,y:p.y-4,width:8,height:8)
                let path=handle.round ? NSBezierPath(ovalIn:r):NSBezierPath(rect:r)
                (handle.kind == .bend || handle.kind == .radius ? NSColor.systemOrange:NSColor.white).setFill();path.fill()
                NSColor.controlAccentColor.setStroke();path.lineWidth=1;path.stroke()
            }
        }
    }
    private func point(_ event:NSEvent,clamped:Bool=false) -> CGPoint? {
        guard image != nil else { return nil }
        var p=convert(event.locationInWindow,from:nil)
        if clamped { p.x=min(imageRect.maxX,max(imageRect.minX,p.x));p.y=min(imageRect.maxY,max(imageRect.minY,p.y)) }
        guard imageRect.contains(p) || clamped else { return nil }
        return CGPoint(x:(p.x-imageRect.minX)/scale,y:(p.y-imageRect.minY)/scale)
    }
    override func mouseMoved(with event:NSEvent) {
        guard let p=point(event) else { return }
        if tool == .line,style.polyline,!points.isEmpty { hover=p;needsDisplay=true }
        if let mark=marks.first(where: { $0.id == selectedID }),mark.handles(scale:scale).contains(where: { hypot($0.point.x-p.x,$0.point.y-p.y)<8/scale }) { NSCursor.crosshair.set() }
        if let bitmap,let c=bitmap.colorAt(x:min(bitmap.pixelsWide-1,max(0,Int(p.x))),y:min(bitmap.pixelsHigh-1,max(0,Int(p.y))))?.usingColorSpace(.deviceRGB) {
            func byte(_ v:CGFloat)->Int { min(255,max(0,Int((v*255).rounded()))) }
            pixel?(String(format:"#%02X%02X%02X",byte(c.redComponent),byte(c.greenComponent),byte(c.blueComponent)))
        }
    }
    private func select(_ id:UUID?) { selectedID=id;selected?(id);needsDisplay=true }
    override func mouseDown(with event:NSEvent) {
        window?.makeKey();window?.makeFirstResponder(self)
        guard let p=point(event) else { return }
        if floating,(tool == .move || event.modifierFlags.contains(.option)) { beginWindowDrag(event);return }
        if tool == .deleteMarks { erase(at:p);return }
        if let mark=marks.first(where: { $0.id == selectedID }),let handle=mark.handles(scale:scale).reversed().first(where: { hypot($0.point.x-p.x,$0.point.y-p.y)<=9/scale }) {
            beginEdit?(mark.id);editing=(mark,handle.kind,p);return
        }
        if let mark=marks.reversed().first(where: {
            guard tool == .select || $0.tool == tool else { return false }
            return $0.hit(p,tolerance:6/scale) || ($0.id == selectedID && $0.selectionBounds.contains($0.rotated(p,inverse:true)) && ![.arrow,.line,.pen,.highlight].contains($0.tool))
        }) {
            select(mark.id)
            if event.clickCount==2,[.text,.watermark,.arrow,.number].contains(mark.tool) { editText?(mark.id);return }
            beginEdit?(mark.id);editing=(mark,nil,p);return
        }
        select(nil)
        if tool == .select { if floating { beginWindowDrag(event) };return }
        if tool == .line,style.polyline {
            if points.last.map({ hypot($0.x-p.x,$0.y-p.y)>1/scale }) ?? true { points.append(p) }
            if event.clickCount>=2 { completeDraft() };return
        }
        points=[p];hover=nil;needsDisplay=true
    }
    private func beginWindowDrag(_ event:NSEvent) {
        guard let window else { return };points=[];hover=nil;editing=nil;select(nil)
        windowDrag=(window.convertPoint(toScreen:event.locationInWindow),window.frame.origin);NSCursor.closedHand.set()
    }
    override func mouseDragged(with event:NSEvent) {
        if let drag=windowDrag,let window {
            let p=window.convertPoint(toScreen:event.locationInWindow)
            window.setFrameOrigin(CGPoint(x:drag.origin.x+p.x-drag.start.x,y:drag.origin.y+p.y-drag.start.y));return
        }
        guard let p=point(event,clamped:true) else { return }
        if tool == .deleteMarks { erase(at:p);return }
        if let edit=editing {
            let mark=edit.handle.map { edit.mark.adjusting($0,to:p,constrained:event.modifierFlags.contains(.shift)) }
                ?? edit.mark.moving(by:CGSize(width:p.x-edit.start.x,height:p.y-edit.start.y))
            preview?(mark);return
        }
        guard !points.isEmpty else { return }
        if [.pen,.highlight].contains(tool) || (tool == .mosaic && style.coverage == .brush) { points.append(p) }
        else if !(tool == .line && style.polyline) {
            var end=p
            if event.modifierFlags.contains(.shift),let a=points.first {
                if [.rectangle,.ellipse,.crop,.mosaic].contains(tool) { let d=max(abs(p.x-a.x),abs(p.y-a.y));end=CGPoint(x:a.x+(p.x<a.x ? -d:d),y:a.y+(p.y<a.y ? -d:d)) }
                else if [.arrow,.line].contains(tool) { let angle=(atan2(p.y-a.y,p.x-a.x)/(.pi/4)).rounded()*(.pi/4),length=hypot(p.x-a.x,p.y-a.y);end=CGPoint(x:a.x+cos(angle)*length,y:a.y+sin(angle)*length) }
            }
            points=[points[0],end]
        }
        needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        if windowDrag != nil { windowDrag=nil;window?.invalidateCursorRects(for:self);if tool == .move { NSCursor.openHand.set() };return }
        if editing != nil { editing=nil;finishEdit?();needsDisplay=true;return }
        if tool == .line,style.polyline { return }
        completeDraft()
    }
    private func draft() -> CaptureMark? {
        guard !points.isEmpty,![.move,.select,.deleteMarks].contains(tool) else { return nil }
        var values=points
        if values.count==1 { values.append(values[0]) }
        if tool == .line,style.polyline,let hover { values.append(hover) }
        var mark=CaptureMark(tool:tool,points:values,color:color,width:width,text:tool == .text ? (text.isEmpty ? "文字":text):"")
        mark.style=style
        if tool == .watermark {
            mark.text=text.isEmpty ? "水印":text
            if style.watermarkTiled,let image { mark.points=[.zero,CGPoint(x:image.width,y:image.height)] }
        }
        if tool == .magnify,style.detachedMagnifier,let image {
            let area=mark.calloutRect(in:CGRect(x:0,y:0,width:image.width,height:image.height));mark.control=CGPoint(x:area.midX,y:area.midY)
        }
        if tool == .number { mark.numberValue=number }
        return mark
    }
    private func completeDraft() {
        defer { points=[];hover=nil;needsDisplay=true }
        hover=nil
        guard let mark=draft() else { return }
        if ![.text,.number,.watermark].contains(tool),let a=mark.points.first,let b=mark.points.last,hypot(a.x-b.x,a.y-b.y)<2,mark.points.count<3 { return }
        marked?(mark)
    }
    private func erase(at point:CGPoint) {
        if let index=marks.indices.reversed().first(where: { marks[$0].hit(point,tolerance:8/scale) }) { removed?(index) }
    }
    override func rightMouseDown(with event:NSEvent) {
        if tool == .line,style.polyline,!points.isEmpty { hover=nil;completeDraft();return }
        if let mark=marks.first(where: { $0.id == selectedID }),mark.tool == .arrow,let p=point(event),hypot(p.x-mark.curveMidpoint.x,p.y-mark.curveMidpoint.y)<12/scale {
            var straight=mark;straight.control=nil;beginEdit?(mark.id);preview?(straight);finishEdit?();return
        }
        guard let p=point(event),let mark=marks.reversed().first(where:{ $0.hit(p,tolerance:8/scale) }) else { select(nil);return }
        select(mark.id)
        let menu=NSMenu()
        for (title,selector) in [("复制标注",#selector(duplicateSelected)),("置于顶层",#selector(frontSelected)),("置于底层",#selector(backSelected)),("删除标注",#selector(deleteSelected))] {
            let item=menu.addItem(withTitle:title,action:selector,keyEquivalent:"");item.target=self
        }
        if mark.tool == .arrow,mark.control != nil { let item=menu.addItem(withTitle:"恢复直线",action:#selector(straightenSelected),keyEquivalent:"");item.target=self }
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc private func duplicateSelected() { selectionAction?(.duplicate) }
    @objc private func frontSelected() { selectionAction?(.front) }
    @objc private func backSelected() { selectionAction?(.back) }
    @objc private func deleteSelected() { selectionAction?(.delete) }
    @objc private func straightenSelected() { selectionAction?(.straighten) }
    override func scrollWheel(with event:NSEvent) {
        if event.modifierFlags.contains(.command),let mark=marks.first(where:{ $0.id == selectedID }) {
            if !wheelEditing { beginEdit?(mark.id);wheelEditing=true }
            var value=mark;value.style.opacity=min(1,max(0.1,mark.style.opacity+event.scrollingDeltaY*0.02));preview?(value)
            if event.phase.isEmpty || event.phase.contains(.ended) || event.phase.contains(.cancelled) { finishEdit?();wheelEditing=false }
        } else { super.scrollWheel(with:event) }
    }
    func cancelActiveInteraction()->Bool {
        if !points.isEmpty { points=[];hover=nil;needsDisplay=true;return true };return false
    }
    override func keyDown(with event:NSEvent) {
        if [51,117].contains(event.keyCode),let index=marks.firstIndex(where: { $0.id == selectedID }) { removed?(index);select(nil) }
        else if [123,124,125,126].contains(event.keyCode),let mark=marks.first(where: { $0.id == selectedID }) {
            let step:CGFloat=event.modifierFlags.contains(.shift) ? 10:1
            let delta=CGSize(width:event.keyCode==123 ? -step:event.keyCode==124 ? step:0,height:event.keyCode==126 ? -step:event.keyCode==125 ? step:0)
            beginEdit?(mark.id);preview?(mark.moving(by:delta));finishEdit?()
        } else { super.keyDown(with:event) }
    }
}

enum RecognitionTab: String, CaseIterable { case text = "文字 / 二维码", table = "表格", formula = "公式", document = "文档", translation = "翻译" }

struct CaptureRecognitionView: View {
    @ObservedObject var document: CaptureDocument
    @ObservedObject var controller: ScreenshotController
    @Environment(\.dismiss) private var dismiss
    let initialTab: RecognitionTab
    @ViewState private var tab = RecognitionTab.text
    @ViewState private var source = ""
    @ViewState private var result = ""
    @ViewState private var localTable: [[String]] = []
    @ViewState private var recognizedLines: [RecognizedLine] = []
    @ViewState private var translatedLines: [String] = []
    @ViewState private var translatedImage: CGImage?
    @ViewState private var showOriginal = false
    @ViewState private var showDocument = false
    @ViewState private var codes: [String] = []
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var confirmUpload = false
    private var aiMode: CaptureAIMode {
        switch tab { case .table: .table; case .formula: .formula; case .document: .document; default: .translation }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("识别与翻译").font(.title3.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("识别方式", selection: $tab) {
                ForEach(RecognitionTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(busy)
            if tab == .translation {
                if #available(macOS 15, *) {
                    NativeCaptureTranslation(source: $source, result: $result, lines: recognizedLines, translatedLines: $translatedLines)
                } else { Text("系统翻译需要 macOS 15+，也可以使用已配置的视觉模型。").font(.caption) }
            }
            if tab == .translation, let translatedImage {
                HStack {
                    Toggle("对照原图", isOn: $showOriginal)
                    Spacer()
                    Button("编辑译图") { controller.accept(translatedImage); dismiss() }
                    Button("贴出译图") { controller.pin(translatedImage) }
                    Button("保存译图") { CaptureDocument(image: translatedImage).save() }
                }
                Image(nsImage: NSImage(cgImage: showOriginal ? document.image : translatedImage, size: .zero)).resizable().scaledToFit().frame(height: 180)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("本地识别原文").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $source).font(.system(size: 13))
                    if !codes.isEmpty { Text("条码 / 二维码：\n" + codes.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                }
                if tab != .text {
                    VStack(alignment: .leading) {
                        Text(tab == .table ? "CSV 表格（可编辑）" : tab == .formula ? "LaTeX 公式（可编辑）" : "结果（可编辑）")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $result).font(.system(size: 13, design: .monospaced))
                    }
                }
            }
            if tab == .table || tab == .document {
                Button("文档与多表格编辑") { showDocument = true }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("正在处理…").font(.caption) }
                else if tab != .text {
                    if tab == .table || tab == .document {
                        if #available(macOS 26, *) {
                            Button("本地结构识别") {
                                busy = true; error = nil
                                Task {
                                    defer { busy = false }
                                    do {
                                        let output = try await CaptureRecognition.structure(document.image)
                                        if tab == .table, output.table.isEmpty {
                                            error = "没有检测到完整表格结构，已保留基础表格；可裁剪表格区域后重试或使用视觉模型。"
                                        } else {
                                            let value = tab == .table ? CaptureDocumentExport.csv(output.table) : output.document
                                            if value.isEmpty { error = "没有检测到文档结构，请尝试本地 OCR 或视觉模型。" }
                                            else { result = value }
                                        }
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                    Button("使用视觉模型\(aiMode.title)…") { confirmUpload = true }
                        .disabled(CaptureAISettings.current.url == nil)
                    Text(CaptureAISettings.current.url == nil ? "先在插件设置中配置视觉模型。" : "发送前需要确认。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("OCR 在本机完成，图片不会上传。").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Menu("导出") {
                    Button("纯文本 (.txt)") { export("txt") }
                    Button("Markdown (.md)") { export("md") }
                    Button("Word 文档 (.docx)") { export("docx") }
                    Button("文本 PDF (.pdf)") { export("pdf") }
                    Button("原图与可搜索文字 (.pdf)") { export("image-pdf") }
                    if tab == .table {
                        Button("Excel 表格 (.xlsx)") { export("xlsx") }
                        Button("CSV 表格 (.csv)") { export("csv") }
                    }
                    if tab == .formula { Button("LaTeX (.tex)") { export("tex") } }
                }.disabled(busy)
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab == .text ? source : result, forType: .string)
                }.disabled(busy)
            }
        }
        .padding(22).frame(width: 800, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(CaptureInputWindowFocus().frame(width: 0, height: 0))
        .task {
            tab = initialTab
            busy = true
            defer { busy = false }
            do {
                let text = try await CaptureRecognition.recognize(document.image)
                source = text.text; codes = text.codes; localTable = text.table; recognizedLines = text.lines
                result = tab == .table ? CaptureDocumentExport.csv(localTable) : tab == .document ? source : ""
                if text.text.isEmpty { error = "未识别到文字，可以调整截图区域或使用视觉模型。" }
                busy = false
                codes = (try? await CaptureRecognition.barcodes(document.image)) ?? []
                if !codes.isEmpty, source.isEmpty { error = nil }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: translatedLines) { _, values in
            do { translatedImage = values.isEmpty ? nil : try CaptureImageTranslation.render(document.image, lines: recognizedLines, translations: values) }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: source) { _, _ in translatedImage = nil; translatedLines = [] }
        .onChange(of: tab) { _, value in
            translatedLines = []; translatedImage = nil
            error = nil
            result = value == .table ? CaptureDocumentExport.csv(localTable) : value == .document ? source : ""
        }
        .sheet(isPresented: $showDocument) {
            CaptureDocumentPreview(image: document.image, initialLines: recognizedLines)
                .background(CaptureInputWindowFocus().frame(width: 0, height: 0))
        }
        .confirmationDialog("将当前截图发送到 \(CaptureAISettings.current.url?.host ?? "视觉模型服务")？", isPresented: $confirmUpload) {
            Button("发送并识别") { recognizeAI() }
        } message: { Text("该服务会收到当前编辑后的图片，可能按你的账户计费。本地 OCR 和系统翻译不需要发送图片。") }
    }
    private func recognizeAI() {
        translatedLines = []; translatedImage = nil
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { result = try await CaptureAI.recognize(document.image, mode: aiMode, settings: .current, key: CaptureKeychain.read()) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func export(_ suffix: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "识别结果." + (suffix == "image-pdf" ? "pdf" : suffix)
        panel.allowedContentTypes = [UTType(filenameExtension: suffix == "image-pdf" ? "pdf" : suffix) ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = tab == .text ? source : result
            do {
                if suffix == "image-pdf" { try CaptureStructuredExport.searchablePDF(document.image, lines: recognizedLines, to: url) }
                else if suffix == "xlsx" { try CaptureDocumentExport.spreadsheet(CaptureDocumentExport.parseCSV(text), to: url) }
                else if suffix == "docx" { try CaptureDocumentExport.document(text, to: url) }
                else if suffix == "pdf" { try CaptureDocumentExport.textPDF(text, to: url) }
                else { try Data(text.utf8).write(to: url, options: .atomic) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

@available(macOS 15, *)
private struct NativeCaptureTranslation: View {
    @Binding var source: String
    @Binding var result: String
    let lines: [RecognizedLine]
    @Binding var translatedLines: [String]
    @ViewState private var target = "zh-Hans"
    @ViewState private var sourceLanguage = ""
    @ViewState private var configuration: TranslationSession.Configuration?
    @ViewState private var busy = false
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("原文", selection: $sourceLanguage) {
                    Text("自动检测").tag("")
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }.frame(width: 210).disabled(busy)
                Picker("译为", selection: $target) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }.frame(width: 200).disabled(busy)
                Button(busy ? "翻译中…" : "系统翻译") {
                    busy = true; error = nil
                    let detected = NLLanguageRecognizer.dominantLanguage(for: source)?.rawValue
                    let identifier = sourceLanguage.isEmpty ? detected : sourceLanguage
                    let language = identifier.map { Locale.Language(identifier: $0) }
                    let next = TranslationSession.Configuration(source: language, target: Locale.Language(identifier: target))
                    if configuration == next { configuration?.invalidate() } else { configuration = next }
                }.disabled(source.isEmpty || busy)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .translationTask(configuration) { @Sendable session in
            let text = await MainActor.run { source }
            do {
                try await session.prepareTranslation()
                let regions = await MainActor.run { lines }
                if !regions.isEmpty, regions.map(\.text).joined(separator: "\n") == text {
                    let requests = regions.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset)) }
                    let responses = try await session.translations(from: requests)
                    let mapped = Dictionary(responses.compactMap { response -> (Int, String)? in
                        guard let id = response.clientIdentifier.flatMap(Int.init) else { return nil }; return (id, response.targetText)
                    }, uniquingKeysWith: { _, new in new })
                    guard mapped.count == regions.count else { throw PluginError.invalid("部分译文缺失，请重试。") }
                    let values = regions.indices.map { mapped[$0] ?? "" }
                    await MainActor.run {
                        busy = false
                        guard source == text else { error = "原文已变化，请重新翻译。"; return }
                        result = values.joined(separator: "\n"); translatedLines = values
                    }
                } else {
                    let response = try await session.translate(text)
                    await MainActor.run {
                        busy = false
                        guard source == text else { error = "原文已变化，请重新翻译。"; return }
                        result = response.targetText; translatedLines = []
                    }
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; busy = false }
            }
        }
    }
    private var languages: [(String, String)] {
        [("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
         ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"),
         ("ru", "Русский"), ("ar", "العربية"), ("th", "ไทย"), ("vi", "Tiếng Việt")]
    }
}

struct RecordingExportView: View {
    let url: URL
    @ViewState private var player: AVPlayer?
    @ViewState private var duration: Double = 1
    @ViewState private var start: Double = 0
    @ViewState private var end: Double = 1
    @ViewState private var busy = false
    @ViewState private var status = ""
    var body: some View {
        VStack(spacing: 16) {
            NativeCaptureVideoPlayer(player: player).frame(minHeight: 300)
            HStack {
                Text("起点 \(start, specifier: "%.1f") s").monospacedDigit().frame(width: 110)
                Slider(value: $start, in: 0...max(0.1, duration - 0.1)).disabled(busy)
            }
            HStack {
                Text("终点 \(end, specifier: "%.1f") s").monospacedDigit().frame(width: 110)
                Slider(value: $end, in: 0.1...max(0.1, duration)).disabled(busy)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("导出 GIF…") { export(gif: true) }.disabled(busy || end <= start)
                Button("导出 MP4…") { export(gif: false) }.disabled(busy || end <= start)
            }
        }.padding(20).frame(minWidth: 680, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            do {
                duration = max(0.1, try await AVURLAsset(url: url).load(.duration).seconds)
                end = duration
                player = AVPlayer(url: url)
            } catch { status = error.localizedDescription }
        }
        .onDisappear { player?.pause() }
    }
    private func export(gif: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = gif ? "录屏.gif" : "录屏.mp4"
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            busy = true; status = "正在导出…"
            Task {
                defer { busy = false }
                do {
                    if gif { try await RecordingExporter.gif(from: url, to: target, start: start, end: end) }
                    else { try await RecordingExporter.movie(from: url, to: target, start: start, end: end) }
                    status = "已导出 \(target.lastPathComponent)"
                } catch { status = error.localizedDescription }
            }
        }
    }
}
