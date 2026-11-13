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
    @Published private(set) var canvasOffset = CGPoint.zero
    @Published var selectedMarkID: UUID?
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    var reportError: ((String) -> Void)?
    @Published var error: String? { didSet { if let error { reportError?(error) } } }
    @Published private(set) var analyzing = false
    private var base: CGImage
    private struct Snapshot { let base: CGImage; let marks: [CaptureMark]; let offset: CGPoint }
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []
    private var markEdit: Snapshot?
    private var lastCommittedImage: CGImage?
    var commit: ((CGImage) throws -> Void)?

    init(image: CGImage) { self.image = image; base = image }
    func add(_ mark: CaptureMark) {
        guard mark.tool != .move, mark.tool != .select else { return }
        change {
            if mark.tool == .crop {
                let rect = mark.rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect) else { return }
                canvasOffset.x += rect.minX; canvasOffset.y += rect.minY
                base = cropped; marks = []
            } else { marks.append(mark) }
        }
        selectedMarkID = mark.tool == .crop ? nil : mark.id
    }
    func restoreAnnotations(base:CGImage,marks:[CaptureMark]) throws {
        let rendered=try CaptureImage.render(base,marks:marks)
        self.base=base;self.marks=marks;image=rendered;canvasOffset = .zero
        undoStack=[];redoStack=[];selectedMarkID=nil;updateCounts()
    }
    func persist() throws {
        guard lastCommittedImage !== image else { return }
        try commit?(image);lastCommittedImage=image
    }
    var selectedMark: CaptureMark? { marks.first { $0.id == selectedMarkID } }
    var unmarkedImage: CGImage { base }
    var isEditingMark: Bool { markEdit != nil }
    func nextNumber(format: CaptureNumberFormat, start: Int = 1) -> Int {
        max(start,(marks.filter { $0.tool == .number && $0.style.numberFormat == format }.compactMap { $0.numberValue ?? Int($0.text) }.max() ?? (start-1)) + 1)
    }
    func beginMarkEdit(_ id: UUID) {
        guard marks.contains(where: { $0.id == id }) else { return }
        finishMarkEdit(); selectedMarkID = id
        markEdit = Snapshot(base:base,marks:marks,offset:canvasOffset)
    }
    func previewMark(_ value: CaptureMark) {
        guard markEdit != nil, let index=marks.firstIndex(where: { $0.id == value.id }) else { return }
        marks[index] = value
        do { image=try CaptureImage.render(base,marks:marks) } catch { self.error=error.localizedDescription }
    }
    func finishMarkEdit() {
        guard let snapshot=markEdit else { return };markEdit=nil
        if snapshot.marks != marks { undoStack.append(snapshot);redoStack=[];updateCounts() }
    }
    func updateSelected(_ action: (inout CaptureMark) -> Void) {
        guard let index=marks.firstIndex(where: { $0.id == selectedMarkID }) else { return }
        change { action(&marks[index]) }
    }
    func replaceMark(_ value: CaptureMark) {
        guard let index=marks.firstIndex(where: { $0.id == value.id }) else { return }
        change { marks[index]=value }
    }
    func selectionAction(_ action:CaptureSelectionAction) {
        guard let index=marks.firstIndex(where:{ $0.id == selectedMarkID }) else { return }
        switch action {
        case .delete: removeMark(at:index)
        case .duplicate:
            var copy=marks[index].moving(by:CGSize(width:14,height:14));copy.id=UUID()
            if copy.tool == .number { copy.numberValue=nextNumber(format:copy.style.numberFormat) }
            add(copy)
        case .front: change { let value=marks.remove(at:index);marks.append(value) }
        case .back: change { let value=marks.remove(at:index);marks.insert(value,at:0) }
        case .straighten: updateSelected { $0.control=nil }
        }
    }
    func rotate() { change { base = try CaptureImage.rotate(image); marks = [] } }
    func undo() {
        finishMarkEdit()
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: base, marks: marks, offset: canvasOffset)); restore(snapshot)
    }
    func redo() {
        finishMarkEdit()
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: base, marks: marks, offset: canvasOffset)); restore(snapshot)
    }
    @discardableResult func copy() -> Bool {
        do {
            try persist()
            if UserDefaults.standard.bool(forKey: "capture.autoSaveCopy") { _ = try CaptureOutputPreferences.save(image) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(try CaptureImage.png(image), forType: .png)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func clearMarks() { guard !marks.isEmpty else { return }; change { marks = [] } }
    func moveMark(at index: Int, by offset: CGSize) {
        guard marks.indices.contains(index), offset != .zero else { return }
        change { marks[index] = marks[index].moving(by:offset) }
    }
    func removeMark(at index: Int) {
        guard marks.indices.contains(index) else { return }
        change {
            let removed=marks.remove(at:index)
            if removed.tool == .number {
                var next=(removed.numberValue ?? Int(removed.text) ?? 1)+1
                while let i=marks.firstIndex(where:{ $0.tool == .number && $0.style.numberFormat == removed.style.numberFormat && ($0.numberValue ?? Int($0.text)) == next }) {
                    marks[i].numberValue=next-1;next += 1
                }
            }
        }
        selectedMarkID=nil
    }
    @discardableResult func quickSave(directory: URL? = nil) -> Bool {
        do {
            try persist()
            _ = try CaptureOutputPreferences.save(image, folder: directory)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func printImage() {
        let view = NSImageView(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        view.image = NSImage(cgImage: image, size: .zero)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .fit
        NSPrintOperation(view: view, printInfo: info).run()
    }
    func repairBackground(in rect: CGRect, intelligent: Bool = false) async {
        guard !analyzing else { return }; analyzing = true; defer { analyzing = false }
        let original = image
        do {
            let repaired: CGImage
            if intelligent { repaired = try await CaptureInpaintingEngine.shared.repair(original, rect: rect) }
            else { repaired = try await Task.detached { try CaptureTextureRepair.repair(original, rect: rect) }.value }
            guard image === original else { throw PluginError.invalid("图片已修改，请重新选择修补区域。") }
            change { base = repaired; marks = [] }
        } catch { self.error = error.localizedDescription }
    }
    func applyRedactions(_ regions: [CGRect]) {
        change { marks += regions.map { CaptureMark(tool: .mosaic, points: [$0.origin, CGPoint(x: $0.maxX, y: $0.maxY)], color: .black, width: 8) } }
    }
    func automaticallyRedact() async {
        guard !analyzing else { return }
        analyzing = true; defer { analyzing = false }
        let original = image
        do {
            let regions = try await CaptureRecognition.redactionRegions(original)
            guard image === original else { throw PluginError.invalid("图片已修改，请重新执行自动马赛克。") }
            guard !regions.isEmpty else { throw PluginError.invalid("未检测到人脸或常见敏感文本，可使用马赛克手动框选。") }
            change { marks += regions.map { CaptureMark(tool: .mosaic, points: [$0.origin, CGPoint(x: $0.maxX, y: $0.maxY)], color: .black, width: 8) } }
        } catch { self.error = error.localizedDescription }
    }
    func save(completion: (() -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = CaptureOutputPreferences.supportedFormats.compactMap { UTType(filenameExtension: $0) } + [.pdf]
        panel.nameFieldStringValue = CaptureOutputPreferences.filename(width: image.width, height: image.height) + "." + CaptureOutputPreferences.format
        panel.directoryURL = CaptureOutputPreferences.directory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try self.persist(); try CaptureImage.write(self.image, to: url); completion?() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func change(_ action: () throws -> Void) {
        let previous = Snapshot(base: base, marks: marks, offset: canvasOffset)
        do {
            try action()
            let rendered = try CaptureImage.render(base, marks: marks)
            undoStack.append(previous)
            if undoStack.count > 40 { undoStack.removeFirst() }
            redoStack.removeAll()
            image = rendered; updateCounts()
        } catch {
            base = previous.base; marks = previous.marks; canvasOffset = previous.offset
            self.error = error.localizedDescription
        }
    }
    private func restore(_ snapshot: Snapshot) {
        base = snapshot.base; marks = snapshot.marks; canvasOffset = snapshot.offset
        do { image = try CaptureImage.render(base, marks: marks) }
        catch { self.error = error.localizedDescription }
        if !marks.contains(where: { $0.id == selectedMarkID }) { selectedMarkID=nil }
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
    let globalMouse = CaptureGlobalMouse()
    private(set) var editors: [CaptureFloatingEditor] = []
    private var captureGeneration = 0
    private var delayPanel: NSPanel?
    private var delayCancelled = false
    lazy var pinManager: CapturePinManager = {
        let manager = CapturePinManager(directory: directory.appendingPathComponent("Pins", isDirectory: true))
        manager.isAllowed = { [weak self] in self?.canUseFeatures() == true }
        manager.reportError = { [weak self] in self?.errorMessage = $0 }
        manager.edit = { [weak self] image, id, tab in self?.openEditor(image, record: nil, pinID: id, recognition: tab) }
        return manager
    }()
    private var scrollSession: ScrollCaptureSession?
    private var recorder: NSObject?
    private var recordingPanel: NSPanel?
    private var exportWindows: [NSWindow] = []
    private var stoppingRecording = false
    private var camera: CaptureCameraPair?
    private var recordingAnnotations: CaptureRecordingAnnotations?
    var isRecording: Bool { recordingStarted != nil }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.untitled.app/Capture", isDirectory: true)
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

    func configureGlobalMouse(permissions: PluginPermissionClient, allowed: @escaping () -> Bool) {
        globalMouse.start(isAllowed: { [weak self] in
            guard let self else { return false }
            return allowed() && self.canUseFeatures() && !self.busy && !self.isRecording && self.scrollSession == nil
        }, permissions: permissions) { [weak self] selection, action in
            guard let self, self.canUseFeatures() else { return }
            self.busy = true; defer { self.busy = false }
            switch action {
            case .edit: self.accept(selection.image, at: selection.presentationFrame)
            case .copy:
                _ = try self.storeImage(selection.image)
                guard CaptureDocument(image: selection.image).copy() else { throw PluginError.invalid("复制失败。") }
            case .pin: _ = try self.pinManager.create(selection.image, frame: selection.presentationFrame)
            case .text:
                let result = try await CaptureRecognition.recognize(selection.image)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string)
            case .save: _ = try CaptureOutputPreferences.save(selection.image)
            }
        }
    }

    func perform(_ action: ActionKind, permissions: PluginPermissionClient) async throws {
        if action == .captureRecording, isRecording { try await stopRecording(); return }
        switch action {
        case .captureHistory: showHistory(); return
        case .pinClipboard: try pinClipboard(); return
        case .togglePins: togglePins(); return
        case .restorePin: try pinManager.restoreLastClosed(); return
        case .closePins: pinManager.closeAll(); return
        case .hideOtherPins: pinManager.toggleOthers(); return
        case .togglePinClickThrough: pinManager.toggleClickThrough(); return
        case .cyclePinGroup: pinManager.cycleGroup(); return
        case .pinFiles: pinFiles(); return
        default: break
        }
        guard !busy, scrollSession == nil, !isRecording else { throw PluginError.invalid("请先完成当前的截图或录屏。") }
        busy = true
        defer { busy = false }
        let generation = captureGeneration
        if action == .captureDelayed, !(try await waitForDelay()) { return }
        guard generation == captureGeneration, canUseFeatures() else { return }
        let mode: CaptureService.Mode = action == .captureScreen ? .screen : action == .captureWindow ? .window : .region
        let chosen: CaptureSelection?
        if action == .captureLastRegion {
            guard let data = UserDefaults.standard.data(forKey: "capture.lastRegion"),
                  let memory = try? JSONDecoder().decode(CaptureRegionMemory.self, from: data) else {
                throw PluginError.invalid("还没有上次截图区域，请先框选一次。")
            }
            chosen = try await service.repeatRegion(memory, permissions: permissions)
        } else { chosen = try await service.choose(mode, permissions: permissions, allowComplexSelection: action != .captureScrolling && action != .captureRecording) }
        guard let selection = chosen, generation == captureGeneration else { return }
        let memory = CaptureRegionMemory(displayID: selection.display.displayID, rect: selection.rect)
        if !selection.isComposite {
            UserDefaults.standard.set(try JSONEncoder().encode(memory), forKey: "capture.lastRegion")
            var recent = UserDefaults.standard.data(forKey: "capture.regionHistory").flatMap { try? JSONDecoder().decode([CaptureRegionMemory].self, from: $0) } ?? []
            recent.removeAll { $0.displayID == memory.displayID && $0.rect == memory.rect }; recent.insert(memory, at: 0)
            UserDefaults.standard.set(try JSONEncoder().encode(Array(recent.prefix(100))), forKey: "capture.regionHistory")
        }
        guard canUseFeatures() else { throw PluginError.invalid("截图插件已停用。") }
        if action != .captureScrolling && action != .captureRecording, let post = selection.postAction {
            _ = try storeImage(selection.image)
            switch post {
            case .copy: guard CaptureDocument(image: selection.image).copy() else { throw PluginError.invalid("复制失败。") }
            case .pin: _ = try pinManager.create(selection.image, frame: selection.presentationFrame)
            case .save: CaptureDocument(image: selection.image).save()
            }
            return
        }
        switch action {
        case .captureScrolling:
            let axis = StitchAxis(rawValue: UserDefaults.standard.string(forKey: "capture.scrollAxis") ?? "") ?? .vertical
            let session = ScrollCaptureSession(selection: selection, service: service, axis: axis, permissions: permissions)
            session.finished = { [weak self] image in
                self?.scrollSession = nil
                if let image { self?.accept(image, at: selection.presentationFrame) }
            }
            scrollSession = session; session.start()
        case .captureRecording:
            guard #available(macOS 15, *) else { throw PluginError.invalid("录屏需要 macOS 15 或更高版本。") }
            guard await CaptureRecordingCountdown.wait(seconds: UserDefaults.standard.integer(forKey: "capture.recordingDelay")),
                  generation == captureGeneration, canUseFeatures() else { return }
            var started = false
            defer {
                if !started { camera?.stop(); camera = nil; recordingAnnotations?.stop(); recordingAnnotations = nil }
            }
            if UserDefaults.standard.bool(forKey: "capture.camera") {
                let overlay = CaptureCameraPair()
                camera = overlay
                try await overlay.start(in: selection, permissions: permissions)
            }
            let annotations = CaptureRecordingAnnotations()
            annotations.start(in: selection); recordingAnnotations = annotations
            let recordingSelection = try await service.includingOverlays(selection, windows: (camera?.windowIDs ?? []) + [annotations.windowID].compactMap { $0 })
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
            try await recorder.start(selection: recordingSelection, url: url, permissions: permissions,
                                     audio: UserDefaults.standard.bool(forKey: "capture.systemAudio"),
                                     microphone: UserDefaults.standard.bool(forKey: "capture.microphone"),
                                     cursor: UserDefaults.standard.object(forKey: "capture.cursor") as? Bool ?? true)
            guard canUseFeatures() else {
                _ = try? await recorder.stop()
                throw PluginError.invalid("截图插件已停用。")
            }
            self.recorder = recorder; recordingStarted = Date()
            started = true
            let panel = CaptureRecordingPanel(contentRect: CGRect(x: 80, y: 80, width: 460, height: 68),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            CaptureWindowPolicy.markControl(panel, name: "recordingControls")
            panel.title = "正在录屏"; panel.level = .floating; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: RecordingControls(controller: self, recorder: recorder, annotations: annotations))
            panel.collectionBehavior = CaptureWindowPolicy.floatingBehavior
            panel.center(); panel.makeKeyAndOrderFront(nil); recordingPanel = panel
        case .captureAndCopy:
            _ = try storeImage(selection.image)
            guard CaptureDocument(image: selection.image).copy() else { throw PluginError.invalid("无法复制截图。") }
            notice = "截图已复制并保存到历史。"
        default:
            accept(selection.image, at: selection.presentationFrame)
            if let tool = selection.initialTool { editors.last?.tool = tool }
        }
    }

    func stopRecording() async throws {
        guard #available(macOS 15, *), let recorder = recorder as? CaptureRecorder else { return }
        guard !stoppingRecording else { return }
        stoppingRecording = true
        defer {
            self.recorder = nil; recordingStarted = nil; stoppingRecording = false
            recordingPanel?.close(); recordingPanel = nil
            camera?.stop(); camera = nil
            recordingAnnotations?.stop(); recordingAnnotations = nil
        }
        let url = try await recorder.stop()
        let record = CaptureRecord(id: UUID(uuidString: url.deletingPathExtension().lastPathComponent)!, date: Date(),
                                   filename: url.lastPathComponent, width: 0, height: 0)
        history.insert(record, at: 0); try saveIndex()
        notice = recorder.errorMessage ?? "录屏已保存，可在历史中编辑或导出 MP4、GIF、WebP。"
        exportRecording(record)
    }

    func accept(_ image: CGImage, at frame: CGRect? = nil) {
        guard canUseFeatures() else { return }
        do {
            let record = try storeImage(image)
            openEditor(image, record: record, frame: frame)
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
        let files = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { for file in files { try pinFile(file) }; return }
        if let image = NSImage(pasteboard: .general), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            guard cg.width <= CaptureImage.maximumPixels / max(1, cg.height) else { throw PluginError.invalid("剪贴板图片过大。") }
            try pinManager.create(cg)
        } else if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            try pinManager.createText(text, html: NSPasteboard.general.data(forType: .html))
        } else { throw PluginError.invalid("剪贴板里没有图片、文字或文件。") }
    }
    static func textCard(_ text: String, file: URL? = nil) throws -> CGImage {
        let size = CGSize(width: 480, height: file == nil ? 320 : 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.textBackgroundColor.setFill(); CGRect(origin: .zero, size: size).fill()
        if let file { NSWorkspace.shared.icon(forFile: file.path).draw(in: CGRect(x: 20, y: 86, width: 48, height: 48)) }
        (String(text.prefix(10000)) as NSString).draw(in: CGRect(x: 20, y: 20, width: 440, height: file == nil ? 280 : 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PluginError.invalid("无法创建贴图。") }
        return cg
    }
    func pinFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try pinManager.createFile(url)
    }
    func pinFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "选择要贴到桌面的图片或文件"; panel.prompt = "贴图"
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            do { for url in panel.urls { try self.pinFile(url) } }
            catch { self.errorMessage = error.localizedDescription }
        }
    }
    func pin(_ image: CGImage) {
        do { try pinManager.create(image) } catch { errorMessage = error.localizedDescription }
    }
    func togglePins() { pinManager.toggleAll() }
    private func waitForDelay() async throws -> Bool {
        let alert = NSAlert(); alert.messageText = "延时截图"
        let field = NSTextField(string: String(UserDefaults.standard.object(forKey: "capture.delaySeconds") as? Int ?? 5))
        field.frame = CGRect(x: 0, y: 0, width: 160, height: 24)
        alert.informativeText = "输入等待秒数（1–60），倒计时结束后框选截图。"
        alert.accessoryView = field; alert.addButton(withTitle: "开始"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard let seconds = Int(field.stringValue), (1...60).contains(seconds) else { throw PluginError.invalid("请输入 1–60 秒。") }
        UserDefaults.standard.set(seconds, forKey: "capture.delaySeconds")
        delayCancelled = false
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 220, height: 88), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        CaptureWindowPolicy.markControl(panel, name: "delay")
        panel.isReleasedWhenClosed = false; panel.level = .floating
        delayPanel = panel; panel.center()
        defer { panel.close(); delayPanel = nil }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            panel.contentView = NSHostingView(rootView: HStack(spacing: 16) {
                Text("\(remaining) 秒后截图").monospacedDigit()
                Button("取消") { [weak self] in self?.delayCancelled = true }
            }.padding(20))
            panel.orderFrontRegardless()
            try await Task.sleep(for: .seconds(1))
            if delayCancelled || !canUseFeatures() { return false }
        }
        return true
    }
    func remove(_ record: CaptureRecord) {
        do {
            try CaptureEditableArchive.trash(for:url(record))
            try FileManager.default.trashItem(at: url(record), resultingItemURL: nil)
            history.removeAll { $0.id == record.id }
            try saveIndex()
            if record.isVideo {
                for sidecar in recordingSidecars(for: url(record)) where FileManager.default.fileExists(atPath: sidecar.path) {
                    try FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func recordingSidecars(for movie: URL) -> [URL] {
        ["events.json", "system.m4a", "microphone.m4a", "audio.json"].map { movie.deletingPathExtension().appendingPathExtension($0) }
    }

    func importRecoveredRecording(_ recovered: URL) {
        do {
            var movie = recovered
            if !Self.safeFilename(movie.lastPathComponent) {
                movie = directory.appendingPathComponent(UUID().uuidString + ".mp4")
                try FileManager.default.moveItem(at: recovered, to: movie)
                for (source, target) in zip(recordingSidecars(for: recovered), recordingSidecars(for: movie)) where FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: target)
                }
            }
            guard !history.contains(where: { $0.filename == movie.lastPathComponent }),
                  let id = UUID(uuidString: movie.deletingPathExtension().lastPathComponent) else { return }
            history.insert(CaptureRecord(id: id, date: Date(), filename: movie.lastPathComponent, width: 0, height: 0), at: 0)
            try saveIndex()
            notice = "中断的录屏已恢复到历史记录。"
        } catch { errorMessage = error.localizedDescription }
    }
    func deactivate() {
        globalMouse.stop()
        objectWillChange.send()
        service.cancel()
        let scrolling = scrollSession; scrollSession = nil
        Task { await scrolling?.preserveAndClose() }
        captureGeneration += 1; delayCancelled = true; delayPanel?.orderOut(nil)
        Array(editors).forEach { $0.close() }
        pinManager.deactivate()
        if isRecording { Task { try? await stopRecording() } }
    }
    @discardableResult func prepareForQuit() async -> Bool {
        if let scrolling = scrollSession {
            guard await scrolling.preserveAndClose() else {
                errorMessage = "长截图尚未保存，已取消退出。请先导出或检查磁盘空间后重试。"
                return false
            }
            scrollSession = nil
        }
        globalMouse.stop()
        Array(editors).forEach { $0.close() }
        pinManager.saveNow(); captureGeneration += 1; delayCancelled = true
        service.cancel()
        if isRecording {
            do { try await stopRecording() }
            catch { errorMessage = error.localizedDescription; return false }
        }
        while stoppingRecording {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
    private func openEditor(_ image: CGImage, record: CaptureRecord?, pinID: UUID? = nil, recognition: RecognitionTab? = nil, frame: CGRect? = nil) {
        if let pinID, let existing = editors.first(where: { $0.canvasPanel.identifier?.rawValue == pinID.uuidString }) {
            existing.show(recognition: recognition); return
        }
        let preferred = pinID.flatMap { pinManager.beginEditing($0) } ?? frame
        let document = CaptureDocument(image: image)
        let archiveURL=record.map(url) ?? pinID.flatMap { pinManager.record($0).map(pinManager.url) }
        let transformedPin = pinID.flatMap { pinManager.record($0)?.adjustments }.map { $0 != CapturePinAdjustments() } ?? false
        if let archiveURL, !transformedPin {
            do { try CaptureEditableArchive.restore(document,for:archiveURL) }
            catch { document.error="无法恢复可编辑标注，已打开导出的图片："+error.localizedDescription }
        }
        let editor = CaptureFloatingEditor(document: document, controller: self, preferredFrame: preferred)
        if let pinID { editor.canvasPanel.identifier = NSUserInterfaceItemIdentifier(pinID.uuidString) }
        document.commit = { [weak self, weak editor, weak document] image in
            guard let self else { return }
            if let pinID { try self.pinManager.updateImage(image, id: pinID, frame: editor?.imageFrame) }
            if let archiveURL,let document { try CaptureEditableArchive.save(document,for:archiveURL) }
            guard let record else { return }
            try CaptureImage.png(image).write(to: self.url(record), options: .atomic)
            if let index = self.history.firstIndex(where: { $0.id == record.id }) {
                self.history[index].width = image.width; self.history[index].height = image.height
                self.history[index].revision = UUID()
                try self.saveIndex()
            }
        }
        editor.pinImage = { [weak self, weak document] image, frame in
            guard let self, self.canUseFeatures() else { throw PluginError.invalid("截图插件已停用。") }
            if let pinID { try self.pinManager.updateImage(image, id: pinID, frame: frame) }
            else {
                let id=try self.pinManager.create(image,frame:frame)
                if let document,let pin=self.pinManager.record(id) { try CaptureEditableArchive.save(document,for:self.pinManager.url(pin)) }
            }
        }
        editors.append(editor)
        editor.onClose = { [weak self, weak editor] in
            if let pinID { self?.pinManager.endEditing(pinID) }
            self?.editors.removeAll { $0 === editor }
        }
        editor.show(recognition: recognition)
    }
    func exportRecording(_ record: CaptureRecord) {
        let window = OwnedCaptureWindow(contentRect: CGRect(x: 100, y: 100, width: 820, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "录屏编辑"
        window.contentView = NSHostingView(rootView: RecordingReviewView(url: url(record)))
        exportWindows.removeAll { !$0.isVisible }; exportWindows.append(window)
        window.onClose = { [weak self, weak window] in self?.exportWindows.removeAll { $0 === window } }
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    private func saveIndex() throws {
        try JSONEncoder().encode(history).write(to: directory.appendingPathComponent("history.json"), options: .atomic)
    }
}

private final class CaptureRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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

@available(macOS 15, *)
private struct RecordingControls: View {
    @ObservedObject var controller: ScreenshotController
    @ObservedObject var recorder: CaptureRecorder
    @ObservedObject var annotations: CaptureRecordingAnnotations
    @ViewState private var confirmsRestart = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Duration.seconds(recorder.elapsedTime).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
            }
            RecordingAnnotationMenu(annotations: annotations)
            Button(recorder.isPaused ? "继续" : "暂停") {
                Task { do { if recorder.isPaused { try await recorder.resume() } else { try await recorder.pause() } }
                    catch { controller.errorMessage = error.localizedDescription }
                }
            }.disabled(recorder.isTransitioning)
            Button("重新录制") { confirmsRestart = true }
                .disabled(recorder.isTransitioning)
                .confirmationDialog("舍弃本次录制并重新开始？", isPresented: $confirmsRestart) {
                    Button("重新录制", role: .destructive) {
                        Task { annotations.clear(); do { try await recorder.restart() } catch { controller.errorMessage = error.localizedDescription } }
                    }
                }
            Button("停止录制") {
                Task {
                    do { try await controller.stopRecording() }
                    catch { controller.errorMessage = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).disabled(recorder.isTransitioning)
        }.padding(16)
    }
}
