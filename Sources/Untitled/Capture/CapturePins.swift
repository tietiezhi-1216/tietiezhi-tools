import AppKit
import Combine
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct CapturePinGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

struct CapturePinRecord: Codable, Identifiable {
    var id = UUID()
    let filename: String
    var groupID: UUID
    var date = Date()
    var isOpen = true
    var closedAt: Date?
    var frame: CGRect?
    var opacity = 1.0
    var locked = false
    var floating = true
    var shadow = true
    var clickThrough = false
    var revision = UUID()
    var text: String?
    var sourceFile: URL?
    var payload: CapturePinPayload?
    var viewport: CGRect?
    var adjustments: CapturePinAdjustments?
}

@MainActor final class CapturePinManager: ObservableObject {
    private struct Archive: Codable {
        let version: Int
        var groups: [CapturePinGroup]
        var records: [CapturePinRecord]
        var activeGroupID: UUID
    }
    @Published private(set) var groups = [CapturePinGroup(id: CapturePinGroup.defaultID, name: "默认分组")]
    @Published private(set) var records: [CapturePinRecord] = []
    @Published private(set) var activeGroupID = CapturePinGroup.defaultID
    @Published private(set) var hidden = false
    var isAllowed: () -> Bool = { true }
    var edit: ((CGImage, UUID, RecognitionTab?) -> Void)?
    var reportError: ((String) -> Void)?
    let directory: URL
    private let displaysWindows: Bool
    private let automaticExports: Bool
    private(set) var loadError: String?
    fileprivate var panels: [UUID: CapturePinWindow] = [:]
    var images: [UUID: CGImage] = [:]
    private var focusedID: UUID?
    @Published var selectedIDs = Set<UUID>()
    var renderedImages: [UUID: CGImage] = [:]
    var recognized: [UUID: CaptureText] = [:]
    var recognitionTasks: [UUID: Task<Void, Never>] = [:]
    var selectedTexts: [UUID: String] = [:]
    var animations: [UUID: CapturePinAnimation] = [:]
    private var keepOnly: UUID?
    private var editingIDs = Set<UUID>()
    private var active = false
    private var closingForLifecycle = false
    private var saveTask: Task<Void, Never>?

    init(directory: URL, displaysWindows: Bool = true, automaticExports: Bool? = nil) {
        self.directory = directory; self.displaysWindows = displaysWindows; self.automaticExports = automaticExports ?? displaysWindows
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("pins.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 32 * 1024 * 1024 else { throw PluginError.invalid("贴图索引过大。") }
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 1, !archive.groups.isEmpty,
                      Set(archive.groups.map(\.id)).count == archive.groups.count,
                      archive.groups.contains(where: { $0.id == CapturePinGroup.defaultID }),
                      Set(archive.records.map(\.id)).count == archive.records.count else { throw PluginError.invalid("贴图索引格式无效。") }
                groups = archive.groups
                let ids = Set(groups.map(\.id))
                records = archive.records.filter {
                    ScreenshotController.safeFilename($0.filename) && $0.filename.hasSuffix(".png") && ids.contains($0.groupID)
                    && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
                }
                activeGroupID = ids.contains(archive.activeGroupID) ? archive.activeGroupID : CapturePinGroup.defaultID
            }
        } catch { loadError = "无法读取贴图历史：\(error.localizedDescription)" }
    }
    var currentRecords: [CapturePinRecord] { records.filter { $0.groupID == activeGroupID } }
    var currentGroupName: String { groups.first { $0.id == activeGroupID }?.name ?? "默认分组" }
    func url(_ record: CapturePinRecord) -> URL { directory.appendingPathComponent(record.filename) }
    func record(_ id: UUID) -> CapturePinRecord? { records.first { $0.id == id } }
    func image(_ id: UUID) -> CGImage? { renderedImages[id] ?? images[id] }
    func activate() {
        guard !active, isAllowed() else { return }
        active = true
        if let loadError { reportError?(loadError); self.loadError = nil }
        for item in currentRecords where item.isOpen { show(item) }
        refreshVisibility()
    }
    func deactivate() {
        saveNow(); active = false; closingForLifecycle = true
        Array(panels.values).forEach { $0.close() }
        panels = [:]; images = [:]; renderedImages = [:]; animations.values.forEach { $0.stop() }; animations = [:]; recognitionTasks.values.forEach { $0.cancel() }; recognitionTasks = [:]; closingForLifecycle = false
    }
    @discardableResult func create(_ image: CGImage, text: String? = nil, sourceFile: URL? = nil, frame: CGRect? = nil, payload: CapturePinPayload? = nil) throws -> UUID {
        guard isAllowed() else { throw PluginError.invalid("截图插件已停用。") }
        let id = UUID()
        let record = CapturePinRecord(id: id, filename: id.uuidString + ".png", groupID: activeGroupID, frame: frame, text: text, sourceFile: sourceFile, payload: payload)
        try CaptureImage.png(image).write(to: url(record), options: .atomic)
        records.append(record); images[id] = image
        selectedIDs = [id]
        hidden = false; keepOnly = nil; active = true
        show(record); saveNow()
        if automaticExports,UserDefaults.standard.bool(forKey:"capture.autoSavePin") {
            let imageFile=sourceFile.flatMap { try? $0.resourceValues(forKeys:[.contentTypeKey]).contentType }?.conforms(to:.image) == true
            let isImage=payload?.kind == .image || (payload==nil && text==nil && (sourceFile==nil || imageFile))
            if isImage {
                do { _ = try CaptureOutputPreferences.save(image) }
                catch { reportError?("贴图已创建，自动保存失败："+error.localizedDescription) }
            }
        }
        return id
    }
    func updateImage(_ image: CGImage, id: UUID, frame: CGRect? = nil) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        try CaptureImage.png(image).write(to: url(records[index]), options: .atomic)
        recognitionTasks[id]?.cancel();recognitionTasks[id]=nil;selectedTexts[id]=nil
        images[id] = image; renderedImages[id] = nil; recognized[id] = nil; records[index].revision = UUID()
        records[index].adjustments = nil; records[index].viewport = nil
        if records[index].payload?.kind != .image { records[index].payload = nil; records[index].text = nil; animations[id]?.stop(); animations[id] = nil }
        if let frame { records[index].frame = frame }
        if let panel = panels[id] {
            panel.aspectRatio = CGSize(width: image.width, height: image.height)
            panel.contentView = content(id)
            if let frame { panel.setFrame(frame, display: true) }
        }
        saveNow()
        if displaysWindows { recognizeText(id) }
    }
    func restoreLastClosed() throws {
        guard let item = currentRecords.filter({ !$0.isOpen }).max(by: { ($0.closedAt ?? $0.date) < ($1.closedAt ?? $1.date) }) else {
            throw PluginError.invalid("当前分组没有可恢复的贴图。")
        }
        restore(item.id)
    }
    func restore(_ id: UUID) {
        guard isAllowed(), let index = records.firstIndex(where: { $0.id == id }) else { return }
        if activeGroupID != records[index].groupID { selectGroup(records[index].groupID) }
        records[index].isOpen = true; records[index].closedAt = nil
        hidden = false; keepOnly = nil; show(records[index]); refreshVisibility()
        focusedID=id;selectedIDs=[id];panels[id]?.makeKeyAndOrderFront(nil);saveNow()
    }
    func close(_ id: UUID) {
        if let panel = panels[id] { panel.close() } else { didClose(id) }
    }
    func closeAll() { currentRecords.filter(\.isOpen).forEach { close($0.id) } }
    fileprivate func didClose(_ id: UUID) {
        panels.removeValue(forKey: id); images.removeValue(forKey: id); renderedImages[id] = nil
        animations[id]?.stop(); animations[id] = nil; recognitionTasks[id]?.cancel(); recognitionTasks[id] = nil; selectedIDs.remove(id);selectedTexts[id]=nil
        guard !closingForLifecycle, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isOpen = false; records[index].closedAt = Date()
        if keepOnly == id { keepOnly = nil; refreshVisibility() }
        saveNow()
    }
    func toggleAll() { hidden.toggle(); refreshVisibility() }
    func toggleOthers() {
        guard let id = focusedPin() else { return }
        keepOnly = keepOnly == nil ? id : nil
        hidden = false; refreshVisibility()
    }
    func toggleClickThrough() {
        if let id = pinUnderMouse(), let index = records.firstIndex(where: { $0.id == id }) {
            records[index].clickThrough.toggle(); apply(records[index])
        } else {
            for index in records.indices { records[index].clickThrough = false; apply(records[index]) }
        }
        saveNow()
    }
    func selectGroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        activeGroupID = id; keepOnly = nil; hidden = false; selectedIDs = []
        if isAllowed() { for item in currentRecords where item.isOpen { show(item) } }
        refreshVisibility(); saveNow()
    }
    func cycleGroup() {
        guard let index = groups.firstIndex(where: { $0.id == activeGroupID }), groups.count > 1 else { return }
        selectGroup(groups[(index + 1) % groups.count].id)
    }
    @discardableResult func createGroup(name: String? = nil) -> UUID {
        var title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            var number = 2
            while groups.contains(where: { $0.name == "贴图组\(number)" }) { number += 1 }
            title = "贴图组\(number)"
        }
        let group = CapturePinGroup(name: String(title.prefix(80)))
        groups.append(group); selectGroup(group.id)
        return group.id
    }
    func renameGroup(_ id: UUID, name: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80, !groups.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(value) == .orderedSame }),
              let index = groups.firstIndex(where: { $0.id == id }) else { throw PluginError.invalid("分组名称不能为空或重复，且不超过 80 个字。") }
        groups[index].name = value; saveNow()
    }
    func mergeGroupIntoDefault(_ id: UUID) {
        guard id != CapturePinGroup.defaultID else { return }
        for index in records.indices where records[index].groupID == id { records[index].groupID = CapturePinGroup.defaultID }
        groups.removeAll { $0.id == id }; selectGroup(CapturePinGroup.defaultID)
    }
    func move(_ id: UUID, to groupID: UUID) {
        guard groups.contains(where: { $0.id == groupID }), let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].groupID = groupID; refreshVisibility(); saveNow()
    }
    func remove(_ id: UUID) {
        guard let item = record(id) else { return }
        do {
            if let file = item.payload?.assetFilename, CapturePinMedia.safeAssetFilename(file) {
                let asset = directory.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath:asset.path) { try FileManager.default.trashItem(at:asset,resultingItemURL:nil) }
            }
            try CaptureEditableArchive.trash(for:url(item))
            try FileManager.default.trashItem(at: url(item), resultingItemURL: nil)
            close(id); records.removeAll { $0.id == id }; saveNow()
        } catch { reportError?(error.localizedDescription) }
    }
    func beginEditing(_ id: UUID) -> CGRect? {
        guard let item = record(id) else { return nil }
        editingIDs.insert(id); panels[id]?.orderOut(nil)
        return panels[id]?.frame ?? item.frame
    }
    func endEditing(_ id: UUID) {
        editingIDs.remove(id)
        if isAllowed() { refreshVisibility() }
    }
    func editPin(_ id: UUID, tab: RecognitionTab? = nil) {
        guard isAllowed(), let image = image(id) else { return }
        edit?(image, id, tab)
    }
    func copy(_ id: UUID) {
        if selection(id).count>1 { copySelection(id);return }
        if let text = selectedTexts[id], !text.isEmpty {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); return
        }
        guard let image = visibleImage(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try? CaptureImage.png(image), forType: .png)
        if let text = record(id)?.text { NSPasteboard.general.setString(text, forType: .string) }
        if let file = assetURL(id) { NSPasteboard.general.setString(file.absoluteString,forType:.fileURL) }
    }
    func toggle(_ id: UUID, _ key: WritableKeyPath<CapturePinRecord, Bool>) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index][keyPath: key].toggle(); apply(records[index]); saveNow()
    }
    func resetSize(_ id: UUID) {
        guard let panel = panels[id], let image = images[id] else { return }
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let factor = min(1, min(screen.width / CGFloat(image.width), screen.height / CGFloat(image.height)))
        panel.setContentSize(CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor))
        if let index = records.firstIndex(where: { $0.id == id }) { records[index].opacity = 1; apply(records[index]) }
        saveNow()
    }
    func scroll(_ id: UUID, delta: CGFloat, opacity: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].locked, let panel = panels[id] else { return }
        if opacity {
            records[index].opacity = min(1, max(0.1, records[index].opacity + Double(delta) * 0.015)); apply(records[index])
        } else {
            let width = min(3000, max(60, panel.frame.width * (1 + delta * 0.015)))
            let ratio = panel.aspectRatio.height / max(1, panel.aspectRatio.width)
            panel.setFrame(CGRect(x: panel.frame.midX - width / 2, y: panel.frame.midY - width * ratio / 2,
                                  width: width, height: width * ratio), display: true)
        }
        saveSoon()
    }
    private func document(_ image: CGImage) -> CaptureDocument {
        let document = CaptureDocument(image: image)
        document.reportError = { [weak self] in self?.reportError?($0) }
        return document
    }
    func perform(_ action: CaptureShortcutAction, id: UUID) {
        guard isAllowed(), let image = visibleImage(id) else { return }
        if let animation = animations[id] {
            switch action {
            case .pinAnnotate: animation.toggle(); return
            case .moveLeft: animation.step(-1); return
            case .moveRight: animation.step(1); return
            case .moveUp: animation.changeSpeed(1.5); return
            case .moveDown: animation.changeSpeed(1/1.5); return
            default: break
            }
        }
        switch action {
        case .close: closeSelection(id)
        case .copy: copy(id)
        case .save: document(image).save()
        case .quickSave: document(image).quickSave()
        case .printImage: document(image).printImage()
        case .ocr:
            Task {
                do {
                    let result = try await CaptureRecognition.recognize(image)
                    guard !result.text.isEmpty else { throw PluginError.invalid("未识别到文字。") }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string)
                } catch { reportError?(error.localizedDescription) }
            }
        case .translation: editPin(id, tab: .translation)
        case .document: editPin(id, tab: .document)
        case .table: editPin(id, tab: .table)
        case .formula: editPin(id, tab: .formula)
        case .pinAnnotate: editPin(id)
        case .pinLock: toggle(id, \.locked)
        case .pinTop: toggle(id, \.floating)
        case .pinShadow: toggle(id, \.shadow)
        case .pinOthers: focusedID = id; toggleOthers()
        case .pinGroup: let items = selection(id); let group = createGroup(); items.forEach { move($0,to:group) }
        case .pinNext:
            let items = currentRecords.filter { $0.isOpen && !$0.clickThrough }
            if let index = items.firstIndex(where: { $0.id == id }), !items.isEmpty {
                let next = items[(index + 1) % items.count].id
                focusedID = next; panels[next]?.makeKeyAndOrderFront(nil)
            }
        case .moveUp, .moveDown, .moveLeft, .moveRight:
            guard let panel = panels[id], record(id)?.locked == false else { return }
            let dx: CGFloat = action == .moveLeft ? -1 : action == .moveRight ? 1 : 0
            let dy: CGFloat = action == .moveDown ? -1 : action == .moveUp ? 1 : 0
            panel.setFrameOrigin(CGPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy))
        default: break
        }
    }
    fileprivate func frameChanged(_ id: UUID, frame: CGRect) {
        guard !closingForLifecycle, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].frame = frame; saveSoon()
    }
    fileprivate func focus(_ id: UUID) { focusedID = id }
    func setRecord(_ value: CapturePinRecord) {
        guard let index = records.firstIndex(where: { $0.id == value.id }) else { return }; records[index] = value; saveSoon()
    }
    func select(_ id: UUID, extending: Bool = false) {
        focusedID = id
        if extending { if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) } }
        else if !selectedIDs.contains(id) { selectedIDs = [id] }
    }
    func selection(_ id: UUID) -> Set<UUID> { selectedIDs.contains(id) ? selectedIDs : [id] }
    func closeSelection(_ id: UUID) {
        let prevent=UserDefaults.standard.object(forKey:"capture.pin.lockPreventsClose") as? Bool ?? true
        selection(id).filter { !prevent || record($0)?.locked != true }.forEach { close($0) }
    }
    func moveSelection(_ id: UUID,to group:UUID) { selection(id).forEach { move($0,to:group) } }
    func dragSelection(_ id:UUID,delta:CGSize) {
        for key in selection(id) where record(key)?.locked == false {
            if let panel = panels[key] { panel.setFrameOrigin(CGPoint(x:panel.frame.minX+delta.width,y:panel.frame.minY+delta.height)) }
        }
    }
    func refreshContent(_ id:UUID) { panels[id]?.contentView = content(id) }
    func sizeForViewport(_ id:UUID) {
        guard let panel=panels[id], let image=image(id) else { return }; let rect=record(id)?.viewport ?? CGRect(x:0,y:0,width:1,height:1)
        let ratio=CGFloat(image.height)*rect.height/max(1,CGFloat(image.width)*rect.width)
        panel.aspectRatio=CGSize(width:1,height:ratio)
        panel.setContentSize(CGSize(width:panel.frame.width,height:panel.frame.width*ratio))
    }
    private func pinUnderMouse() -> UUID? {
        NSApp.orderedWindows.compactMap { $0 as? CapturePinWindow }
            .first { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }?.pinID
    }
    private func focusedPin() -> UUID? {
        let id = pinUnderMouse() ?? (NSApp.keyWindow as? CapturePinWindow)?.pinID ?? focusedID
        if let id, let item = record(id), item.isOpen, item.groupID == activeGroupID { return id }
        return currentRecords.first { $0.isOpen }?.id
    }
    private func refreshVisibility() {
        for (id, panel) in panels {
            if let item = record(id), !editingIDs.contains(id), item.isOpen, item.groupID == activeGroupID, !hidden, keepOnly == nil || keepOnly == id {
                panel.orderFrontRegardless()
            } else { panel.orderOut(nil) }
        }
    }
    private func show(_ item: CapturePinRecord) {
        guard displaysWindows, isAllowed() else { return }
        if let existing = panels[item.id] { existing.orderFrontRegardless(); return }
        do {
            let image = try images[item.id] ?? CaptureImage.load(url(item))
            images[item.id] = image
            rebuildImage(item.id)
            let factor = min(1, 640 / CGFloat(max(image.width, image.height)))
            let initial = CGRect(x: 100, y: 100, width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
            let panel = CapturePinWindow(id: item.id, frame: item.frame ?? initial, manager: self)
            panel.aspectRatio = CGSize(width: image.width, height: image.height)
            panel.contentView = content(item.id)
            panels[item.id] = panel
            if item.frame == nil { panel.center() }
            else if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.center() }
            apply(item); panel.orderFrontRegardless(); focusedID = item.id
            sizeForViewport(item.id); startAnimation(item.id); recognizeText(item.id)
        } catch { reportError?(error.localizedDescription) }
    }
    private func content(_ id: UUID) -> NSView { NSHostingView(rootView: CapturePinnedContent(manager: self, id: id)) }
    private func apply(_ item: CapturePinRecord) {
        guard let panel = panels[item.id] else { return }
        panel.alphaValue = min(1, max(0.1, item.opacity)); panel.level = item.floating ? .floating : .normal
        panel.hasShadow = item.shadow; panel.ignoresMouseEvents = item.clickThrough
        if item.locked { panel.styleMask.remove(.resizable) } else { panel.styleMask.insert(.resizable) }
    }
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        do {
            let archive = Archive(version: 1, groups: groups, records: records, activeGroupID: activeGroupID)
            try JSONEncoder().encode(archive).write(to: directory.appendingPathComponent("pins.json"), options: .atomic)
        } catch { reportError?(error.localizedDescription) }
    }
}

private final class CapturePinWindow: NSPanel, NSWindowDelegate {
    let pinID: UUID
    private weak var manager: CapturePinManager?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(id: UUID, frame: CGRect, manager: CapturePinManager) {
        pinID = id; self.manager = manager
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear
        collectionBehavior = CaptureWindowPolicy.floatingBehavior
        delegate = self
    }
    func windowWillClose(_ notification: Notification) { manager?.didClose(pinID) }
    func windowDidMove(_ notification: Notification) { manager?.frameChanged(pinID, frame: frame) }
    func windowDidResize(_ notification: Notification) { manager?.frameChanged(pinID, frame: frame) }
    func windowDidBecomeKey(_ notification: Notification) { manager?.focus(pinID) }
}

private struct CapturePinnedContent: View {
    @ObservedObject var manager: CapturePinManager
    let id: UUID
    var body: some View {
        Group {
            if let image = manager.image(id) {
                CapturePinSurface(image: image, manager: manager, id: id)
                    .contextMenu {
                        Button("复制") { manager.copy(id) }
                        Button("复制原始图像") { manager.copyOriginal(id) }
                        if manager.record(id)?.text != nil { Button("复制全部文本 / 源码") { manager.copyText(id) } }
                        Button("选择全部文字") { manager.selectAllText(id) }
                        Button(manager.record(id)?.viewport == nil ? "缩略图（右键拖动框选范围）" : "退出缩略图") { manager.toggleViewport(id) }
                        if ![CapturePinPayload.Kind.text,.richText,.formula].contains(manager.record(id)?.payload?.kind ?? .image) {
                        Menu("图像调整") {
                            Button("顺时针旋转 90°") { manager.adjust(id) { $0.quarterTurns += 1 } }
                            Button("水平翻转") { manager.adjust(id) { $0.flipX.toggle() } }
                            Button("垂直翻转") { manager.adjust(id) { $0.flipY.toggle() } }
                            Button("灰度") { manager.adjust(id) { $0.grayscale.toggle() } }
                            Button("反色") { manager.adjust(id) { $0.inverted.toggle() } }
                            Button("调亮") { manager.adjust(id) { $0.brightness=min(1,$0.brightness+0.1) } }
                            Button("调暗") { manager.adjust(id) { $0.brightness=max(-1,$0.brightness-0.1) } }
                            Button("恢复原图") { manager.adjust(id) { $0 = CapturePinAdjustments() } }
                        }
                        }
                        if let animation=manager.animations[id] {
                            Menu("动画") {
                                Button(animation.paused ? "播放" : "暂停") { animation.toggle() }
                                Button("上一帧") { animation.step(-1) }
                                Button("下一帧") { animation.step(1) }
                                Button("加快") { animation.changeSpeed(1.5) }
                                Button("减慢") { animation.changeSpeed(1/1.5) }
                                Button("原始速度") { animation.speed=1 }
                                Button("保存原始动图…") { manager.saveAnimation(id) }
                                Text("第 \(animation.index+1) / \(animation.count) 帧")
                            }
                        }
                        if manager.record(id)?.payload?.kind == .richText {
                            Button("忽略 / 恢复格式") { manager.toggleRichText(id) }
                        }
                        Divider()
                        if let file = manager.record(id)?.sourceFile {
                            Button("在访达中显示源文件") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        }
                        Button("编辑 / 标注") { manager.editPin(id) }
                        Button("识别文字") { manager.editPin(id, tab: .text) }
                        Button("翻译") { manager.editPin(id, tab: .translation) }
                        Button("保存…") { manager.perform(.save, id: id) }
                        Button("打印…") { manager.perform(.printImage, id: id) }
                        Divider()
                        Button(manager.record(id)?.locked == true ? "解锁" : "锁定") { manager.toggle(id, \.locked) }
                        Button(manager.record(id)?.floating == true ? "取消置顶" : "置顶") { manager.toggle(id, \.floating) }
                        Button("切换阴影") { manager.toggle(id, \.shadow) }
                        Button("恢复原始大小与透明度") { manager.resetSize(id) }
                        Button("鼠标穿透") { manager.toggle(id, \.clickThrough) }
                        Menu("移动到贴图组") {
                            ForEach(manager.groups) { group in Button(group.name) { manager.moveSelection(id, to: group.id) } }
                            Button("新贴图组") { let items=manager.selection(id);let group = manager.createGroup();items.forEach { manager.move($0,to:group) } }
                        }
                        Button("隐藏其他贴图") { manager.perform(.pinOthers, id: id) }
                        Divider()
                        Button("关闭所选贴图") { manager.closeSelection(id) }
                        Button("移到废纸篓", role: .destructive) { manager.selection(id).forEach { manager.remove($0) } }
                    }
            }
        }
        .overlay { if manager.selectedIDs.count > 1 && manager.selectedIDs.contains(id) { Rectangle().strokeBorder(.blue,lineWidth:3).allowsHitTesting(false) } }
        .background(CaptureShortcutMonitor(scope: .pin) { manager.perform($0, id: id) }.frame(width: 0, height: 0))
    }
}


struct CapturePinsView: View {
    @Environment(\.pluginContentHasInsets) private var hasInsets
    @ObservedObject var manager: CapturePinManager
    @ViewState private var name = ""
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("贴图组", selection: Binding(get: { manager.activeGroupID }, set: { manager.selectGroup($0) })) {
                    ForEach(manager.groups) { group in Text(group.name).tag(group.id) }
                }.frame(maxWidth: 260)
                Button("新建分组") { manager.createGroup() }
                Spacer()
                Button("显示 / 隐藏") { manager.toggleAll() }
                Button("关闭本组贴图") { manager.closeAll() }
            }
            HStack {
                TextField("分组名称", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("重命名") {
                    do { try manager.renameGroup(manager.activeGroupID, name: name); error = nil } catch { self.error = error.localizedDescription }
                }.disabled(name == manager.currentGroupName)
                if manager.activeGroupID != CapturePinGroup.defaultID {
                    Button("合并到默认分组") { manager.mergeGroupIntoDefault(manager.activeGroupID) }
                }
            }
            if !manager.selectedIDs.isEmpty {
                HStack {
                    Text("已选 \(manager.selectedIDs.count) 项").font(.caption)
                    Button("恢复所选") { manager.selectedIDs.forEach { manager.restore($0) } }
                    Button("关闭所选") { Array(manager.selectedIDs).forEach { manager.close($0) } }
                    Menu("移动到") { ForEach(manager.groups) { group in Button(group.name) { Array(manager.selectedIDs).forEach { manager.move($0,to:group.id) } } } }
                    Button("取消选择") { manager.selectedIDs=[] }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(manager.currentRecords.reversed()) { record in
                        HStack(spacing: 12) {
                            Toggle("选择",isOn:Binding(get:{manager.selectedIDs.contains(record.id)},set:{ _ in manager.select(record.id,extending:true) })).labelsHidden()
                            CaptureThumbnail(url: manager.url(record), video: false, revision: record.revision)
                                .frame(width: 90, height: 60).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.sourceFile?.lastPathComponent ?? record.text.map { String($0.prefix(30)) } ?? "图像贴图").lineLimit(1)
                                Text(record.isOpen ? "未关闭" : "已关闭 · 可恢复").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(record.isOpen ? "定位" : "恢复") { manager.restore(record.id) }
                            if record.isOpen { Button("关闭") { manager.close(record.id) } }
                            Menu {
                                ForEach(manager.groups) { group in Button("移至 \(group.name)") { manager.move(record.id, to: group.id) } }
                                Button("移到废纸篓", role: .destructive) { manager.remove(record.id) }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
            }.overlay { if manager.currentRecords.isEmpty { ContentUnavailableView("还没有贴图", systemImage: "pin", description: Text("使用 ⌃2 贴出剪贴板内容，关闭后可按 ⌃3 恢复。")) } }
        }.padding(.horizontal, hasInsets ? 0 : PanelLayout.contentInset)
            .onChange(of: manager.activeGroupID, initial: true) { _, _ in name = manager.currentGroupName }
    }
}
