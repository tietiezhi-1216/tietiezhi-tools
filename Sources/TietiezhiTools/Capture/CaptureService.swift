import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

enum CaptureSelectionPostAction { case copy, pin, save }

@MainActor struct CaptureSelection {
    let display: SCDisplay
    let filter: SCContentFilter
    let rect: CGRect
    let scale: CGFloat
    let image: CGImage
    var windowID: CGWindowID?
    var presentationFrameOverride: CGRect? = nil
    var isComposite = false
    var initialTool: CaptureTool? = nil
    var postAction: CaptureSelectionPostAction? = nil
    var presentationFrame: CGRect? {
        if let presentationFrameOverride { return presentationFrameOverride }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }) else { return nil }
        return CaptureFloatingLayout.screenRect(rect, on: screen.frame)
    }
}

struct CaptureRegionMemory: Codable, Equatable {
    let displayID: UInt32
    let rect: CGRect
    func clamped(to size: CGSize) throws -> CGRect {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else {
            throw PluginError.invalid("上次截图区域无效，请重新框选。")
        }
        let value = rect.intersection(CGRect(origin: .zero, size: size))
        guard value.width >= 8, value.height >= 8 else { throw PluginError.invalid("显示器布局已变化，请重新框选截图区域。") }
        return value
    }
}

/// Keep visible app content in the snapshot while omitting capture controls.
/// New controls created after a stream starts remain excluded by the app filter.
@MainActor enum CaptureWindowPolicy {
    static let controlPrefix = "capture.control."
    // An overlay joins the current stage instead of causing Stage Manager to shelve
    // the source app's windows. These flags also allow overlays above full-screen apps.
    static let floatingBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient, .ignoresCycle,
    ]
    static func contentWindowIDs(in windows: [NSWindow]) -> Set<CGWindowID> {
        Set(windows.compactMap { window in
            guard window.isVisible, !(window.identifier?.rawValue.hasPrefix(controlPrefix) ?? false) else { return nil }
            return captureID(window.windowNumber)
        })
    }
    static func captureID(_ number: Int) -> CGWindowID? {
        guard number > 0, let id = CGWindowID(exactly: number) else { return nil }
        return id
    }
    static func markControl(_ window: NSWindow, name: String) {
        window.identifier = NSUserInterfaceItemIdentifier(controlPrefix + name)
        window.hidesOnDeactivate = false
    }
}

@MainActor final class CaptureService {
    enum Mode { case region, window, screen }
    private var selector: CaptureSelector?
    private var generation = 0

    func repeatRegion(_ memory: CaptureRegionMemory, permissions: PluginPermissionClient) async throws -> CaptureSelection? {
        let current = generation
        try permissions.require([.screenRecording])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == memory.displayID }) else {
            throw PluginError.invalid("上次截图所在的显示器已断开，请重新框选。")
        }
        let rect = try memory.clamped(to: display.frame.size)
        let filter = contentFilter(display: display, content: content)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let config = SCStreamConfiguration()
        config.sourceRect = rect; config.width = Int(rect.width * scale); config.height = Int(rect.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard generation == current else { return nil }
        return CaptureSelection(display: display, filter: filter, rect: rect, scale: scale, image: image)
    }

    func choose(_ mode: Mode, permissions: PluginPermissionClient, allowComplexSelection: Bool = true) async throws -> CaptureSelection? {
        let currentGeneration = generation
        try permissions.require([.screenRecording])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var screens: [(NSScreen, SCDisplay, SCContentFilter, CGImage)] = []
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            if mode == .screen, !screen.frame.contains(mouse) { continue }
            let filter = contentFilter(display: display, content: content)
            let config = SCStreamConfiguration()
            let scale = max(1, CGFloat(filter.pointPixelScale))
            config.width = max(1, Int(filter.contentRect.width * scale))
            config.height = max(1, Int(filter.contentRect.height * scale))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            screens.append((screen, display, filter, image))
        }
        guard !screens.isEmpty else { throw PluginError.invalid("没有可用的显示器。") }
        guard generation == currentGeneration else { return nil }
        if mode == .screen {
            let (screen, display, filter, image) = screens[0]
            return CaptureSelection(display: display, filter: filter,
                                    rect: CGRect(origin: .zero, size: screen.frame.size),
                                    scale: CGFloat(image.width) / screen.frame.width, image: image)
        }
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let windows = content.windows.sorted { (ranks[$0.windowID] ?? .max) < (ranks[$1.windowID] ?? .max) }
        let selected: CaptureSelection? = await withCheckedContinuation { continuation in
            let selector = CaptureSelector()
            self.selector = selector
            selector.show(screens, windows: windows, allowsShapes: allowComplexSelection) { [weak self] selection in
                self?.selector = nil
                continuation.resume(returning: selection)
            }
        }
        guard let selected else { return nil }
        if mode == .window, let id = selected.windowID, let window = content.windows.first(where: { $0.windowID == id }) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(window.frame.width * selected.scale))
            configuration.height = max(1, Int(window.frame.height * selected.scale))
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CaptureSelection(display: selected.display, filter: selected.filter, rect: selected.rect,
                                    scale: selected.scale, image: image, windowID: id, initialTool:selected.initialTool,postAction:selected.postAction)
        }
        return selected
    }

    func capture(_ selection: CaptureSelection, permissions: PluginPermissionClient) async throws -> CGImage {
        try permissions.require([.screenRecording])
        let config = SCStreamConfiguration()
        config.sourceRect = selection.rect
        config.width = max(1, Int(selection.rect.width * selection.scale))
        config.height = max(1, Int(selection.rect.height * selection.scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: selection.filter, configuration: config)
    }

    private func contentFilter(display: SCDisplay, content: SCShareableContent, including additional: Set<CGWindowID> = []) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter { $0.processID == pid }
        let contentIDs = CaptureWindowPolicy.contentWindowIDs(in: NSApp.windows).union(additional)
        let visibleContent = content.windows.filter { $0.owningApplication?.processID == pid && contentIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: visibleContent)
    }

    func cancel() { generation += 1; selector?.finish(nil) }

    /// Global mouse gestures use Quartz desktop coordinates, including negative origins.
    func captureGlobalRegion(_ globalRect: CGRect, permissions: PluginPermissionClient) async throws -> CaptureSelection {
        try permissions.require([.screenRecording])
        let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        let displays=content.displays.filter { $0.frame.intersects(globalRect) }
        guard let first=displays.first,globalRect.width>=8,globalRect.height>=8 else { throw PluginError.invalid("截图范围不在可用显示器内。") }
        let filters=displays.map { contentFilter(display:$0,content:content) }
        let scale=filters.map { max(1,CGFloat($0.pointPixelScale)) }.max() ?? 1
        let context=try CaptureImage.context(width:Int((globalRect.width*scale).rounded()),height:Int((globalRect.height*scale).rounded()))
        for (display,filter) in zip(displays,filters) {
            let visible=globalRect.intersection(display.frame)
            let config=SCStreamConfiguration();config.sourceRect=visible.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY)
            config.width=max(1,Int((visible.width*scale).rounded()));config.height=max(1,Int((visible.height*scale).rounded()));config.showsCursor=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            context.draw(image,in:CGRect(x:(visible.minX-globalRect.minX)*scale,y:(globalRect.maxY-visible.maxY)*scale,width:visible.width*scale,height:visible.height*scale))
        }
        guard let image=context.makeImage() else { throw PluginError.invalid("无法生成截图。") }
        let cocoaTop=NSScreen.screens.first?.frame.maxY ?? 0
        let presentation=CGRect(x:globalRect.minX,y:cocoaTop-globalRect.maxY,width:globalRect.width,height:globalRect.height)
        return CaptureSelection(display:first,filter:filters[0],rect:globalRect.offsetBy(dx:-first.frame.minX,dy:-first.frame.minY),scale:scale,image:image,presentationFrameOverride:presentation,isComposite:displays.count>1)
    }

    func includingOverlays(_ selection: CaptureSelection, windows: [CGWindowID]) async throws -> CaptureSelection {
        guard !windows.isEmpty else { return selection }
        // An empty transparent annotation panel is not considered on-screen by
        // WindowServer yet. Register its ID before the user draws the first mark.
        for attempt in 0..<8 {
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let overlays = content.windows.filter { windows.contains($0.windowID) }
            if overlays.count == windows.count {
                let filter = contentFilter(display: selection.display, content: content, including: Set(overlays.map(\.windowID)))
                return CaptureSelection(display: selection.display, filter: filter, rect: selection.rect, scale: selection.scale, image: selection.image)
            }
            if attempt < 7 { try await Task.sleep(for: .milliseconds(50)) }
        }
        throw PluginError.invalid("录屏叠加窗口尚未准备好，请重试。")
    }
}

private final class CaptureScrollControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class ScrollCaptureSession: ObservableObject {
    @Published var axis: StitchAxis = .vertical
    @Published private(set) var count = 1
    @Published private(set) var status = "在选区内缓慢滚动，保留至少三分之一重叠区域。"
    @Published private(set) var size: CGSize
    @Published var automaticScroll = false
    @Published var isPaused = false
    @Published private(set) var isSaving = false
    @Published private(set) var completedSegments = 0
    @Published var trimOnReverse = UserDefaults.standard.bool(forKey: "capture.scrollTrimOnReverse")
    @Published private(set) var preview: NSImage
    @Published private(set) var viewport = CGRect.zero
    @Published var cropStart = 0.0
    @Published var cropEnd = 1.0
    private var revision = 0
    private var collector: SegmentedScrollCapture
    private let selection: CaptureSelection
    private let service: CaptureService
    private let permissions: PluginPermissionClient
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    private var sampling = false
    private var closed = false
    private var closing = false
    private var directoryPanel: NSOpenPanel?
    private var exportTask: Task<Void,Never>?
    private var restarting = false
    var finished: ((CGImage?) -> Void)?

    init(selection: CaptureSelection, service: CaptureService, axis: StitchAxis, permissions: PluginPermissionClient) {
        self.selection = selection; self.service = service; self.axis = axis
        self.permissions = permissions
        collector = SegmentedScrollCapture(image: selection.image, axis: axis)
        size = CGSize(width: selection.image.width, height: selection.image.height)
        preview = NSImage(cgImage: CaptureImage.thumbnail(selection.image, maximum: 640), size: .zero)
        viewport = collector.viewport
    }
    func start() {
        let panel = CaptureScrollControlPanel(contentRect: CGRect(x: 100, y: 100, width: 310, height: 610),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        CaptureWindowPolicy.markControl(panel, name: "scrollControls")
        panel.title = "滚动长截图 · \(axis.title)"
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ScrollCaptureControls(session: self))
        if let selected = selection.presentationFrame, let screen = NSScreen.screens.first(where: { $0.frame.intersects(selected) }) {
            let area = screen.visibleFrame
            let x = selected.maxX + 12 + 310 <= area.maxX ? selected.maxX + 12 : max(area.minX, selected.minX - 322)
            panel.setFrameOrigin(CGPoint(x: x, y: max(area.minY, min(selected.maxY - 610, area.maxY - 610))))
        } else { panel.center() }
        panel.makeKeyAndOrderFront(nil); self.panel = panel
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(650)) } catch { break }
                guard let self else { break }
                await self.sample()
            }
        }
    }
    func sample() async {
        guard !isPaused,!sampling,!closed else { return }
        sampling=true;defer { sampling=false }
        let currentRevision = revision
        do {
            if automaticScroll {
                do { try permissions.require([.accessibility]) }
                catch { automaticScroll=false;status="请在主应用权限管理中开启辅助功能；仍可手动滚动。";return }
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: axis == .vertical ? -120 : 0, wheel2: axis == .horizontal ? -120 : 0, wheel3: 0) {
                    event.location = CGPoint(x: selection.display.frame.minX + selection.rect.midX, y: selection.display.frame.minY + selection.rect.midY)
                    event.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(220))
                }
            }
            let image = try await service.capture(selection, permissions: permissions)
            let shouldTrim = trimOnReverse
            let result = try await Task.detached { [collector] in
                var next=collector;let appended=try next.append(image,trimOnReverse:shouldTrim);return (next,appended)
            }.value
            guard !Task.isCancelled,currentRevision==revision,!closed else { return }
            let rolled=result.0.segments.count>collector.segments.count
            collector=result.0
            if result.1 {
                count += 1;completedSegments=collector.segments.count
                if rolled { cropStart=0;cropEnd=1 }
                updatePreview()
                status=rolled ? "第 \(completedSegments) 段已暂存；继续捕获第 \(completedSegments+1) 段，相邻段保留重叠。" : "第 \(completedSegments+1) 段 · 已拼接 \(count) 帧 · \(Int(size.width)) × \(Int(size.height))"
            } else { status="等待滚动；无重叠时请回滚一些再继续。" }
        } catch {
            automaticScroll=false;status=error.localizedDescription
            isPaused=true
        }
    }
    private func updatePreview() {
        size=CGSize(width:collector.image.width,height:collector.image.height);viewport=collector.viewport
        preview=NSImage(cgImage:CaptureImage.thumbnail(collector.image,maximum:640),size:.zero)
    }
    func togglePause() { guard !isSaving else { return };isPaused.toggle();if isPaused { automaticScroll=false } }
    private func settle() async {
        isPaused=true;automaticScroll=false
        // Let the one already-captured frame commit before exporting or restarting.
        while sampling { try? await Task.sleep(for:.milliseconds(20)) }
    }
    func restart() async {
        guard !isSaving,!closed,!closing else { return };isSaving=true;restarting=true
        defer { restarting=false;if !closing { isSaving=false } }
        await settle();revision += 1
        do {
            if collector.isSegmented { _ = try await Task.detached { [collector] in try collector.checkpoint() }.value }
            guard !closing else { return }
            let image=try await service.capture(selection,permissions:permissions)
            guard !closing else { return }
            collector=SegmentedScrollCapture(image:image,axis:axis);completedSegments=0;count=1
            updatePreview();cropStart=0;cropEnd=1;status="已从当前位置重新开始；此前封存分段仍在暂存目录。";isPaused=false
        } catch { status=error.localizedDescription }
    }
    func revealRecovery() {
        let directory=SegmentedScrollCapture.recoveryDirectory
        do { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);NSWorkspace.shared.open(directory) }
        catch { status=error.localizedDescription }
    }
    func finish(cancelled: Bool = false,asSegments:Bool=false) {
        guard !isSaving,!closed else { return }
        if cancelled { Task { await preserveAndClose(reveal:true) };return }
        isSaving=true
        Task {
            await settle()
            guard !closed,!closing else { return }
            if collector.isSegmented || asSegments { chooseExportDirectory() }
            else { complete(collector.croppedImage(start:cropStart,end:cropEnd).0) }
        }
    }
    private func chooseExportDirectory() {
        let picker=NSOpenPanel();picker.canChooseFiles=false;picker.canChooseDirectories=true;picker.canCreateDirectories=true
        picker.prompt="导出全部分段";picker.message="选择保存位置，将创建按顺序编号的 PNG 文件夹并附带重叠信息。"
        directoryPanel=picker
        picker.begin { [weak self] response in
            guard let self,!self.closed,!self.closing else { return };self.directoryPanel=nil
            guard response == .OK,let folder=picker.url else { self.isSaving=false;self.status="已暂停，全部内容保留；可继续或重新选择导出位置。";return }
            let start=self.cropStart,end=self.cropEnd
            self.exportTask=Task {
                defer { self.exportTask=nil }
                do {
                    let exported=try await Task.detached { [collector=self.collector] in try collector.export(to:folder,start:start,end:end) }.value
                    self.complete(nil);NSWorkspace.shared.activateFileViewerSelecting([exported])
                } catch { self.isSaving=false;self.status="导出失败，已保留全部分段："+error.localizedDescription }
            }
        }
    }
    /// Await this before terminating the app, so the active part is checkpointed too.
    @discardableResult func preserveAndClose(reveal:Bool=false) async -> Bool {
        guard !closed else { return true }
        if closing {
            while closing && !closed { try? await Task.sleep(for:.milliseconds(20)) }
            return closed
        }
        closing=true;defer { closing=false }
        directoryPanel?.cancel(nil);directoryPanel=nil;isSaving=true
        if let exportTask { await exportTask.value;guard !closed else { return true } }
        while restarting { try? await Task.sleep(for:.milliseconds(20)) }
        await settle()
        do {
            _ = try await Task.detached { [collector] in try collector.checkpoint() }.value
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([collector.directory]) }
            complete(nil)
            return true
        } catch { isSaving=false;status="当前段暂存失败，请重试导出："+error.localizedDescription;return false }
    }
    private func complete(_ image:CGImage?) {
        guard !closed else { return };closed=true;revision += 1;task?.cancel();task=nil
        panel?.orderOut(nil);panel?.close();panel=nil
        let callback=finished;finished=nil;callback?(image)
    }
}

private struct ScrollCaptureControls: View {
    @ObservedObject var session: ScrollCaptureSession
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            ScrollCapturePreview(session:session).frame(height:220)
            Text(session.status).font(.callout).lineLimit(3)
            HStack {
                Text("当前第 \(session.completedSegments+1) 段 · 已封存 \(session.completedSegments) 段").font(.caption)
                Spacer();Button("暂存目录") { session.revealRecovery() }.controlSize(.small)
            }
            Text(session.completedSegments>0 ? "裁剪只影响当前段；回滚可在当前段内进行，不能修改已封存段。" : "单段达到 8000 万像素后自动分段，之前内容会写入磁盘。").font(.caption).foregroundStyle(.secondary)
            Toggle("回滚时裁掉多余部分",isOn:$session.trimOnReverse).font(.caption)
                .onChange(of:session.trimOnReverse) { _,value in UserDefaults.standard.set(value,forKey:"capture.scrollTrimOnReverse") }
            HStack { Text("起点");Slider(value:$session.cropStart,in:0...max(0.01,session.cropEnd-0.01));Text("\(Int(session.cropStart*100))%").monospacedDigit().frame(width:38) }.font(.caption)
            HStack { Text("终点");Slider(value:$session.cropEnd,in:min(0.99,session.cropStart+0.01)...1);Text("\(Int(session.cropEnd*100))%").monospacedDigit().frame(width:38) }.font(.caption)
            HStack {
                Button(session.isPaused ? "继续":"暂停") { session.togglePause() }
                Button("重新开始") { Task { await session.restart() } }
                Spacer();Button("分段导出…") { session.finish(asSegments:true) }
            }.controlSize(.small)
            HStack {
                Toggle("自动滚动",isOn:$session.automaticScroll).toggleStyle(.switch).controlSize(.small).disabled(session.isPaused)
                Spacer()
                Button("保留并关闭") { session.finish(cancelled:true) }
                Button(session.completedSegments>0 ? "导出全部":"完成") { session.finish() }.buttonStyle(.borderedProminent)
            }
        }.disabled(session.isSaving).padding(16).frame(width:310)
            .overlay { if session.isSaving { ProgressView("正在准备…").padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) } }
    }
}

private struct ScrollCapturePreview: View {
    @ObservedObject var session: ScrollCaptureSession
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / max(1, session.size.width), geometry.size.height / max(1, session.size.height))
            let size = CGSize(width: session.size.width * scale, height: session.size.height * scale)
            let vertical = session.axis == .vertical
            Image(nsImage: session.preview).resizable().frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.black.opacity(0.55)).frame(width: vertical ? size.width : size.width * session.cropStart, height: vertical ? size.height * session.cropStart : size.height)
                        Rectangle().fill(.black.opacity(0.55)).frame(width: vertical ? size.width : size.width * (1-session.cropEnd), height: vertical ? size.height * (1-session.cropEnd) : size.height)
                            .offset(x: vertical ? 0 : size.width * session.cropEnd, y: vertical ? size.height * session.cropEnd : 0)
                        Rectangle().strokeBorder(.green, lineWidth: 2).frame(width: session.viewport.width * scale, height: session.viewport.height * scale)
                            .offset(x: session.viewport.minX * scale, y: session.viewport.minY * scale)
                    }.allowsHitTesting(false)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
