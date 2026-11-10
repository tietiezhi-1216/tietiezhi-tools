import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct CaptureRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let filename: String
    var width: Int
    var height: Int
    var revision: UUID?
    var isVideo: Bool { filename.hasSuffix(".mp4") }
}

@MainActor final class CaptureDocument: ObservableObject {
    @Published private(set) var image: CGImage
    @Published private(set) var marks: [CaptureMark] = []
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    @Published var error: String?
    private var base: CGImage
    private struct Snapshot { let base: CGImage; let marks: [CaptureMark] }
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []
    var commit: ((CGImage) throws -> Void)?

    init(image: CGImage) { self.image = image; base = image }
    func add(_ mark: CaptureMark) {
        change {
            if mark.tool == .crop {
                let rect = mark.rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect) else { return }
                base = cropped; marks = []
            } else { marks.append(mark) }
        }
    }
    func rotate() { change { base = try CaptureImage.rotate(image); marks = [] } }
    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: base, marks: marks)); restore(snapshot)
    }
    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: base, marks: marks)); restore(snapshot)
    }
    func copy() {
        do {
            try commit?(image)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(try CaptureImage.png(image), forType: .png)
        } catch { self.error = error.localizedDescription }
    }
    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .pdf]
        panel.nameFieldStringValue = "截图.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try self.commit?(self.image); try CaptureImage.write(self.image, to: url) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func change(_ action: () throws -> Void) {
        let previous = Snapshot(base: base, marks: marks)
        do {
            try action()
            let rendered = try CaptureImage.render(base, marks: marks)
            undoStack.append(previous)
            if undoStack.count > 40 { undoStack.removeFirst() }
            redoStack.removeAll()
            image = rendered; updateCounts()
        } catch {
            base = previous.base; marks = previous.marks
            self.error = error.localizedDescription
        }
    }
    private func restore(_ snapshot: Snapshot) {
        base = snapshot.base; marks = snapshot.marks
        do { image = try CaptureImage.render(base, marks: marks) }
        catch { self.error = error.localizedDescription }
        updateCounts()
    }
    private func updateCounts() { undoCount = undoStack.count; redoCount = redoStack.count }
}

@MainActor final class ScreenshotController: ObservableObject {
    @Published private(set) var history: [CaptureRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var recordingStarted: Date?
    @Published var errorMessage: String? {
        didSet { if let errorMessage { reportError?(errorMessage) } }
    }
    var reportError: ((String) -> Void)?
    @Published var notice: String?
    var showHistory: () -> Void = {}
    var canUseFeatures: () -> Bool = { true }
    let directory: URL
    private let service = CaptureService()
    private var editors: [NSWindow] = []
    private var pins: [NSPanel] = []
    private var pinsHidden = false
    private var scrollSession: ScrollCaptureSession?
    private var recorder: NSObject?
    private var recordingPanel: NSPanel?
    private var exportWindows: [NSWindow] = []
    private var stoppingRecording = false
    private var camera: CaptureCameraOverlay?
    private var keystrokes: CaptureKeystrokeOverlay?
    var isRecording: Bool { recordingStarted != nil }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tietiezhi.tools/Capture", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let index = self.directory.appendingPathComponent("history.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let records = try JSONDecoder().decode([CaptureRecord].self, from: Data(contentsOf: index))
                history = records.filter { Self.safeFilename($0.filename) && FileManager.default.fileExists(atPath: self.directory.appendingPathComponent($0.filename).path) }
            }
        } catch { errorMessage = "无法读取截图历史：\(error.localizedDescription)" }
    }

    static func safeFilename(_ filename: String) -> Bool {
        guard let id = UUID(uuidString: String(filename.split(separator: ".").first ?? "")) else { return false }
        return [id.uuidString + ".png", id.uuidString + ".mp4"].contains(filename)
    }

    func perform(_ action: ActionKind) async throws {
        if action == .captureRecording, isRecording { try await stopRecording(); return }
        switch action {
        case .captureHistory: showHistory(); return
        case .pinClipboard: try pinClipboard(); return
        case .togglePins: togglePins(); return
        default: break
        }
        guard !busy, scrollSession == nil, !isRecording else { throw PluginError.invalid("请先完成当前的截图或录屏。") }
        busy = true
        defer { busy = false }
        let mode: CaptureService.Mode = action == .captureScreen ? .screen : action == .captureWindow ? .window : .region
        guard let selection = try await service.choose(mode) else { return }
        guard canUseFeatures() else { throw PluginError.invalid("截图插件已停用。") }
        switch action {
        case .captureScrolling:
            let axis = StitchAxis(rawValue: UserDefaults.standard.string(forKey: "capture.scrollAxis") ?? "") ?? .vertical
            let session = ScrollCaptureSession(selection: selection, service: service, axis: axis)
            session.finished = { [weak self] image in
                self?.scrollSession = nil
                if let image { self?.accept(image) }
            }
            scrollSession = session; session.start()
        case .captureRecording:
            guard #available(macOS 15, *) else { throw PluginError.invalid("录屏需要 macOS 15 或更高版本。") }
            var started = false
            defer {
                if !started { camera?.stop(); camera = nil; keystrokes?.stop(); keystrokes = nil }
            }
            if UserDefaults.standard.bool(forKey: "capture.camera") {
                let overlay = CaptureCameraOverlay()
                camera = overlay
                try await overlay.start(in: selection)
            }
            if UserDefaults.standard.bool(forKey: "capture.keystrokes") {
                let overlay = CaptureKeystrokeOverlay()
                keystrokes = overlay
                try overlay.start(in: selection)
            }
            let recordingSelection = try await service.includingOverlays(selection, windows: [camera?.windowID, keystrokes?.windowID].compactMap { $0 })
            guard canUseFeatures() else { throw PluginError.invalid("截图插件已停用。") }
            let recorder = CaptureRecorder()
            recorder.failed = { [weak self] message in
                guard let self else { return }
                self.errorMessage = message
                Task {
                    try? await self.stopRecording()
                }
            }
            let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
            try await recorder.start(selection: recordingSelection, url: url,
                                     audio: UserDefaults.standard.bool(forKey: "capture.systemAudio"),
                                     microphone: UserDefaults.standard.bool(forKey: "capture.microphone"),
                                     cursor: UserDefaults.standard.object(forKey: "capture.cursor") as? Bool ?? true)
            guard canUseFeatures() else {
                _ = try? await recorder.stop()
                throw PluginError.invalid("截图插件已停用。")
            }
            self.recorder = recorder; recordingStarted = Date()
            started = true
            let panel = NSPanel(contentRect: CGRect(x: 80, y: 80, width: 280, height: 68),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "正在录屏"; panel.level = .floating; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: RecordingControls(controller: self))
            panel.center(); panel.orderFrontRegardless(); recordingPanel = panel
        default: accept(selection.image)
        }
    }

    func stopRecording() async throws {
        guard #available(macOS 15, *), let recorder = recorder as? CaptureRecorder else { return }
        guard !stoppingRecording else { return }
        stoppingRecording = true
        defer {
            self.recorder = nil; recordingStarted = nil; stoppingRecording = false
            recordingPanel?.close(); recordingPanel = nil
            camera?.stop(); camera = nil; keystrokes?.stop(); keystrokes = nil
        }
        let url = try await recorder.stop()
        let record = CaptureRecord(id: UUID(uuidString: url.deletingPathExtension().lastPathComponent)!, date: Date(),
                                   filename: url.lastPathComponent, width: 0, height: 0)
        history.insert(record, at: 0); try saveIndex()
        notice = "录屏已保存，可在历史中裁剪或导出 GIF。"
        exportRecording(record)
    }

    func accept(_ image: CGImage) {
        guard canUseFeatures() else { return }
        do {
            let record = try storeImage(image)
            openEditor(image, record: record)
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult func storeImage(_ image: CGImage) throws -> CaptureRecord {
        let id = UUID()
        let record = CaptureRecord(id: id, date: Date(), filename: id.uuidString + ".png", width: image.width, height: image.height)
        try CaptureImage.png(image).write(to: directory.appendingPathComponent(record.filename), options: .atomic)
        history.insert(record, at: 0)
        try saveIndex()
        return record
    }
    func open(_ record: CaptureRecord) {
        guard canUseFeatures() else { return }
        if record.isVideo { exportRecording(record); return }
        do { openEditor(try CaptureImage.load(url(record)), record: record) }
        catch { errorMessage = error.localizedDescription }
    }
    func url(_ record: CaptureRecord) -> URL { directory.appendingPathComponent(record.filename) }
    func importImage() {
        guard canUseFeatures() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { self?.accept(try CaptureImage.load(url)) }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }
    func pinClipboard() throws {
        if let image = NSImage(pasteboard: .general), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            guard cg.width <= CaptureImage.maximumPixels / max(1, cg.height) else { throw PluginError.invalid("剪贴板图片过大。") }
            pin(cg)
        } else if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            let size = CGSize(width: 480, height: 320)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.textBackgroundColor.setFill(); CGRect(origin: .zero, size: size).fill()
            (String(text.prefix(5000)) as NSString).draw(in: CGRect(x: 20, y: 20, width: 440, height: 280),
                                                       withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor])
            image.unlockFocus()
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            pin(cg)
        } else { throw PluginError.invalid("剪贴板里没有图片或文字。") }
    }
    func pin(_ image: CGImage) {
        guard canUseFeatures() else { return }
        let scale = min(1, 640 / CGFloat(max(image.width, image.height)))
        let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale),
                            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.aspectRatio = CGSize(width: image.width, height: image.height)
        let view = PinnedImageView(image: image)
        view.edit = { [weak self] in self?.openEditor(image, record: nil) }
        view.closed = { [weak self, weak panel] in
            panel?.close(); self?.pins.removeAll { $0 === panel }
        }
        panel.contentView = view; panel.center()
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + CGFloat(pins.count % 8) * 24, y: panel.frame.minY - CGFloat(pins.count % 8) * 24))
        pins.append(panel); pinsHidden = false; panel.orderFrontRegardless()
    }
    func togglePins() {
        pinsHidden.toggle()
        for panel in pins { if pinsHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    }
    func remove(_ record: CaptureRecord) {
        do {
            try FileManager.default.trashItem(at: url(record), resultingItemURL: nil)
            history.removeAll { $0.id == record.id }
            try saveIndex()
        } catch { errorMessage = error.localizedDescription }
    }
    func deactivate() {
        objectWillChange.send()
        service.cancel(); scrollSession?.finish(cancelled: true); scrollSession = nil
        pins.forEach { $0.close() }; pins.removeAll()
        if isRecording { Task { try? await stopRecording() } }
    }
    func prepareForQuit() async {
        service.cancel(); scrollSession?.finish(cancelled: true); scrollSession = nil
        if isRecording {
            do { try await stopRecording() }
            catch { errorMessage = error.localizedDescription }
        }
        while stoppingRecording {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    private func openEditor(_ image: CGImage, record: CaptureRecord?) {
        let document = CaptureDocument(image: image)
        document.commit = { [weak self] image in
            guard let self, let record else { return }
            try CaptureImage.png(image).write(to: self.url(record), options: .atomic)
            if let index = self.history.firstIndex(where: { $0.id == record.id }) {
                self.history[index].width = image.width; self.history[index].height = image.height
                self.history[index].revision = UUID()
                try self.saveIndex()
            }
        }
        let window = OwnedCaptureWindow(contentRect: CGRect(x: 100, y: 100, width: 1080, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "截图编辑"
        window.contentMinSize = CGSize(width: 820, height: 560)
        window.contentView = NSHostingView(rootView: CaptureEditorView(document: document, controller: self))
        editors.removeAll { !$0.isVisible }
        editors.append(window)
        window.onClose = { [weak self, weak window] in self?.editors.removeAll { $0 === window } }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func exportRecording(_ record: CaptureRecord) {
        let window = OwnedCaptureWindow(contentRect: CGRect(x: 100, y: 100, width: 720, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "录屏与 GIF"
        window.contentView = NSHostingView(rootView: RecordingExportView(url: url(record)))
        exportWindows.removeAll { !$0.isVisible }; exportWindows.append(window)
        window.onClose = { [weak self, weak window] in self?.exportWindows.removeAll { $0 === window } }
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    private func saveIndex() throws {
        try JSONEncoder().encode(history).write(to: directory.appendingPathComponent("history.json"), options: .atomic)
    }
}

private final class OwnedCaptureWindow: NSWindow {
    var onClose: (() -> Void)?
    override func close() {
        super.close()
        let callback = onClose
        onClose = nil
        callback?()
    }
}

private final class PinnedImageView: NSImageView {
    let cgImage: CGImage
    var edit: (() -> Void)?
    var closed: (() -> Void)?
    init(image: CGImage) {
        cgImage = image
        super.init(frame: .zero)
        self.image = NSImage(cgImage: image, size: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel("贴图；右键打开操作，滚轮缩放，双击关闭")
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { closed?() }
        else { window?.performDrag(with: event) }
    }
    override func scrollWheel(with event: NSEvent) { zoom(1 + event.scrollingDeltaY * 0.015) }
    override func magnify(with event: NSEvent) { zoom(1 + event.magnification) }
    private func zoom(_ factor: CGFloat) {
        guard let window else { return }
        let width = min(2000, max(80, window.frame.width * factor))
        let height = width * CGFloat(cgImage.height) / CGFloat(cgImage.width)
        window.setFrame(CGRect(x: window.frame.midX - width / 2, y: window.frame.midY - height / 2, width: width, height: height), display: true)
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (title, action) in [("复制图片", #selector(copyImage)), ("编辑 / 标注", #selector(editImage)),
                                ("保存图片…", #selector(saveImage)), ("半透明 / 不透明", #selector(toggleOpacity)),
                                ("关闭贴图", #selector(closeImage))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try? CaptureImage.png(cgImage), forType: .png)
    }
    @objc private func editImage() { edit?() }
    @objc private func saveImage() { CaptureDocument(image: cgImage).save() }
    @objc private func toggleOpacity() { window?.alphaValue = window?.alphaValue == 1 ? 0.55 : 1 }
    @objc private func closeImage() { closed?() }
}

private struct RecordingControls: View {
    @ObservedObject var controller: ScreenshotController
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
            if let date = controller.recordingStarted { Text(date, style: .timer).monospacedDigit() }
            Button("停止录制") {
                Task {
                    do { try await controller.stopRecording() }
                    catch { controller.errorMessage = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent)
        }.padding(16)
    }
}
