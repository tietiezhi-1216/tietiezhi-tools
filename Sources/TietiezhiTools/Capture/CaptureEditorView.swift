import AppKit
import SwiftUI
import Translation
import NaturalLanguage
import UniformTypeIdentifiers
import AVKit

struct CaptureEditorView: View {
    @ObservedObject var document: CaptureDocument
    @ObservedObject var controller: ScreenshotController
    @ViewState private var tool: CaptureTool = .arrow
    @ViewState private var color = Color.red
    @ViewState private var width: Double = 3
    @ViewState private var text = ""
    @ViewState private var zoom: Double = 0
    @ViewState private var pixel = ""
    @ViewState private var showRecognition = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(document.image.width) × \(document.image.height)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("撤销（⌘Z）").keyboardShortcut("z").disabled(document.undoCount == 0)
                Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("重做（⇧⌘Z）").keyboardShortcut("z", modifiers: [.command, .shift]).disabled(document.redoCount == 0)
                Button { document.rotate() } label: { Image(systemName: "rotate.right") }.help("旋转 90°")
                Button("识别 / 翻译") { showRecognition = true }.disabled(!controller.canUseFeatures())
                Button("贴图") {
                    do { try document.commit?(document.image); controller.pin(document.image) }
                    catch { document.error = error.localizedDescription }
                }.disabled(!controller.canUseFeatures())
                Button("保存…") { document.save() }.keyboardShortcut("s")
                Button("复制") { document.copy() }.buttonStyle(.borderedProminent).keyboardShortcut("c")
            }.padding(14)
            HStack(spacing: 6) {
                ForEach(CaptureTool.allCases) { item in
                    Button { tool = item } label: {
                        Image(systemName: item.symbol).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .background(tool == item ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(tool == item ? Color.accentColor : Color.primary)
                    .help(item.title).accessibilityLabel(item.title)
                }
                Spacer(minLength: 12)
                ColorPicker("颜色", selection: $color).labelsHidden().frame(width: 36)
                Slider(value: $width, in: 1...12).frame(width: 100).help("线宽 / 马赛克强度")
                Text("\(Int(width))").font(.caption.monospacedDigit()).frame(width: 18)
            }.padding(.horizontal, 14).padding(.bottom, 12)
            if tool == .text {
                TextField("输入要标注的文字，也可作为水印", text: $text)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 12)
            }
            CaptureCanvas(image: document.image, tool: tool, color: NSColor(color), width: width, text: text, zoom: zoom,
                          number: document.marks.filter { $0.tool == .number }.count + 1, marked: document.add, pixel: { pixel = $0 })
            HStack(spacing: 12) {
                Text(tool.title).font(.caption)
                Text("拖动标注 · 滚动查看图片").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(pixel.isEmpty ? "屏幕取色" : pixel) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pixel, forType: .string)
                }.buttonStyle(.plain).font(.caption.monospaced()).help("移动到图片上取色，点击复制")
                Picker("缩放", selection: $zoom) {
                    Text("适应窗口").tag(0.0)
                    ForEach([0.25, 0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) { value in
                        Text("\(Int(value * 100))%").tag(value)
                    }
                }.frame(width: 140)
            }.padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showRecognition) { CaptureRecognitionView(document: document, controller: controller) }
        .alert("操作未完成", isPresented: Binding(get: { document.error != nil }, set: { if !$0 { document.error = nil } })) {
            Button("好") { document.error = nil }
        } message: { Text(document.error ?? "") }
    }
}

private struct CaptureCanvas: NSViewRepresentable {
    let image: CGImage
    let tool: CaptureTool
    let color: NSColor
    let width: Double
    let text: String
    let zoom: Double
    let number: Int
    let marked: (CaptureMark) -> Void
    let pixel: (String) -> Void
    func makeNSView(context: Context) -> CaptureScrollView {
        let scroll = CaptureScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = CaptureDrawingView()
        return scroll
    }
    func updateNSView(_ scroll: CaptureScrollView, context: Context) {
        guard let view = scroll.documentView as? CaptureDrawingView else { return }
        if view.image !== image { view.image = image; view.bitmap = NSBitmapImageRep(cgImage: image) }
        view.tool = tool; view.color = color; view.width = width; view.text = text; view.number = number
        view.marked = marked; view.pixel = pixel; view.zoom = zoom
        scroll.needsLayout = true; view.needsDisplay = true
    }
}

private final class CaptureScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? CaptureDrawingView)?.sizeCanvas(contentSize)
    }
}

private final class CaptureDrawingView: NSView {
    var image: CGImage?
    var bitmap: NSBitmapImageRep?
    var tool = CaptureTool.arrow
    var color = NSColor.red
    var width: Double = 3
    var text = ""
    var zoom: Double = 0
    var number = 1
    var marked: ((CaptureMark) -> Void)?
    var pixel: ((String) -> Void)?
    private var points: [CGPoint] = []
    private var imageRect = CGRect.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func sizeCanvas(_ available: CGSize) {
        guard let image else { return }
        let scale = zoom == 0 ? min((available.width - 48) / CGFloat(image.width), (available.height - 48) / CGFloat(image.height), 1) : zoom
        let size = CGSize(width: CGFloat(image.width) * max(0.005, scale), height: CGFloat(image.height) * max(0.005, scale))
        setFrameSize(CGSize(width: max(available.width, size.width + 48), height: max(available.height, size.height + 48)))
        imageRect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(imageRect, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
        guard let image else { return }
        NSImage(cgImage: image, size: .zero).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard points.count >= 2 else { return }
        let scale = imageRect.width / CGFloat(image.width)
        func display(_ point: CGPoint) -> CGPoint { CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale) }
        let path = NSBezierPath()
        color.setStroke(); path.lineWidth = max(1, width * scale)
        if [.rectangle, .ellipse, .mosaic, .cover, .erase, .crop, .magnify].contains(tool) {
            let start = display(points[0]), end = display(points.last!)
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
            let shape = tool == .ellipse ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            shape.lineWidth = path.lineWidth; shape.stroke()
        } else {
            path.move(to: display(points[0]))
            for point in points.dropFirst() { path.line(to: display(point)) }
            path.stroke()
        }
    }
    private func point(_ event: NSEvent) -> CGPoint? {
        guard let image else { return nil }
        let value = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(value) else { return nil }
        return CGPoint(x: (value.x - imageRect.minX) * CGFloat(image.width) / imageRect.width,
                       y: (value.y - imageRect.minY) * CGFloat(image.height) / imageRect.height)
    }
    override func mouseMoved(with event: NSEvent) {
        guard let point = point(event), let bitmap, let color = bitmap.colorAt(x: min(bitmap.pixelsWide - 1, Int(point.x)), y: min(bitmap.pixelsHigh - 1, Int(point.y)))?.usingColorSpace(.deviceRGB) else { return }
        func channel(_ value: CGFloat) -> Int { min(255, max(0, Int((value * 255).rounded()))) }
        pixel?(String(format: "#%02X%02X%02X", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent)))
    }
    override func mouseDown(with event: NSEvent) { if let point = point(event) { points = [point] } }
    override func mouseDragged(with event: NSEvent) {
        guard let point = point(event), !points.isEmpty else { return }
        if [.pen, .highlight].contains(tool) { points.append(point) }
        else { points = [points[0], point] }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !points.isEmpty else { return }
        if points.count == 1 { points.append(points[0]) }
        if tool != .text || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            marked?(CaptureMark(tool: tool, points: points, color: color, width: width, text: tool == .number ? String(number) : text))
        }
        points = []; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { points = []; needsDisplay = true }
        else { super.keyDown(with: event) }
    }
}

private enum RecognitionTab: String, CaseIterable { case text = "文字 / 二维码", table = "表格", formula = "公式", document = "文档", translation = "翻译" }

private struct CaptureRecognitionView: View {
    @ObservedObject var document: CaptureDocument
    @ObservedObject var controller: ScreenshotController
    @Environment(\.dismiss) private var dismiss
    @ViewState private var tab = RecognitionTab.text
    @ViewState private var source = ""
    @ViewState private var result = ""
    @ViewState private var localTable: [[String]] = []
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
                    NativeCaptureTranslation(source: source, result: $result)
                } else { Text("系统翻译需要 macOS 15+，也可以使用已配置的视觉模型。").font(.caption) }
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
                    Button("可搜索 PDF (.pdf)") { export("pdf") }
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
        .task {
            busy = true
            defer { busy = false }
            do {
                let text = try await CaptureRecognition.recognize(document.image)
                source = text.text; codes = text.codes; localTable = text.table
                if text.text.isEmpty { error = "未识别到文字，可以调整截图区域或使用视觉模型。" }
                busy = false
                codes = (try? await CaptureRecognition.barcodes(document.image)) ?? []
                if !codes.isEmpty, source.isEmpty { error = nil }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: tab) { _, value in
            error = nil
            result = value == .table ? CaptureDocumentExport.csv(localTable) : value == .document ? source : ""
        }
        .confirmationDialog("将当前截图发送到 \(CaptureAISettings.current.url?.host ?? "视觉模型服务")？", isPresented: $confirmUpload) {
            Button("发送并识别") { recognizeAI() }
        } message: { Text("该服务会收到当前编辑后的图片，可能按你的账户计费。本地 OCR 和系统翻译不需要发送图片。") }
    }
    private func recognizeAI() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { result = try await CaptureAI.recognize(document.image, mode: aiMode, settings: .current, key: CaptureKeychain.read()) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func export(_ suffix: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "识别结果." + suffix
        panel.allowedContentTypes = [UTType(filenameExtension: suffix) ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = tab == .text ? source : result
            do {
                if suffix == "xlsx" { try CaptureDocumentExport.spreadsheet(CaptureDocumentExport.parseCSV(text), to: url) }
                else if suffix == "docx" { try CaptureDocumentExport.document(text, to: url) }
                else if suffix == "pdf" { try CaptureDocumentExport.textPDF(text, to: url) }
                else { try Data(text.utf8).write(to: url, options: .atomic) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

@available(macOS 15, *)
private struct NativeCaptureTranslation: View {
    let source: String
    @Binding var result: String
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
                let response = try await session.translate(text)
                await MainActor.run { result = response.targetText; busy = false }
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
            VideoPlayer(player: player).frame(minHeight: 300)
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
