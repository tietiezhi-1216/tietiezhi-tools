import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

@MainActor struct CaptureSelection {
    let display: SCDisplay
    let filter: SCContentFilter
    let rect: CGRect
    let scale: CGFloat
    let image: CGImage
    var windowID: CGWindowID?
}

@MainActor final class CaptureService {
    enum Mode { case region, window, screen }
    private var selector: CaptureSelector?
    private var generation = 0

    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }
    static func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func choose(_ mode: Mode) async throws -> CaptureSelection? {
        let currentGeneration = generation
        guard Self.permitted else {
            Self.requestPermission()
            throw PluginError.invalid("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Tietiezhi Tools，再重试。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var screens: [(NSScreen, SCDisplay, SCContentFilter, CGImage)] = []
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            if mode == .screen, !screen.frame.contains(mouse) { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
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
            selector.show(screens, windows: mode == .window ? windows : []) { [weak self] selection in
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
                                    scale: selected.scale, image: image, windowID: id)
        }
        return selected
    }

    func capture(_ selection: CaptureSelection) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.sourceRect = selection.rect
        config.width = max(1, Int(selection.rect.width * selection.scale))
        config.height = max(1, Int(selection.rect.height * selection.scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: selection.filter, configuration: config)
    }

    func cancel() { generation += 1; selector?.finish(nil) }

    func includingOverlays(_ selection: CaptureSelection, windows: [CGWindowID]) async throws -> CaptureSelection {
        guard !windows.isEmpty else { return selection }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let overlays = content.windows.filter { windows.contains($0.windowID) }
        guard overlays.count == windows.count else { throw PluginError.invalid("录屏叠加窗口尚未准备好，请重试。") }
        let apps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: selection.display, excludingApplications: apps, exceptingWindows: overlays)
        return CaptureSelection(display: selection.display, filter: filter, rect: selection.rect, scale: selection.scale, image: selection.image)
    }
}

@MainActor private final class CaptureSelector {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureSelection?) -> Void)?

    func show(_ screens: [(NSScreen, SCDisplay, SCContentFilter, CGImage)], windows: [SCWindow],
              completion: @escaping (CaptureSelection?) -> Void) {
        self.completion = completion
        for (screen, display, filter, image) in screens {
            let panel = CaptureSelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            let view = CaptureSelectionView(image: image)
            view.windows = windows.filter { $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
                .map { $0.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(origin: .zero, size: screen.frame.size)) }
                .filter { !$0.isEmpty }
            view.completed = { [weak self] rect in
                guard let rect else { self?.finish(nil); return }
                let scale = CGFloat(image.width) / screen.frame.width
                let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
                guard let cropped = image.cropping(to: pixels) else { self?.finish(nil); return }
                let window = windows.first {
                    $0.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                        .intersection(CGRect(origin: .zero, size: screen.frame.size)) == rect
                }
                let aligned = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
                self?.finish(CaptureSelection(display: display, filter: filter, rect: aligned, scale: scale, image: cropped, windowID: window?.windowID))
            }
            panel.contentView = view
            panels.append(panel)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish(_ selection: CaptureSelection?) {
        guard let completion else { return }
        self.completion = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        completion(selection)
    }
}

private final class CaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class CaptureSelectionView: NSView {
    let image: CGImage
    var windows: [CGRect] = []
    var completed: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func draw(_ dirtyRect: NSRect) {
        let snapshot = NSImage(cgImage: image, size: bounds.size)
        snapshot.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.42).setFill(); bounds.fill()
        if let selection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            snapshot.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 2; border.stroke()
            let size = "\(Int(selection.width)) × \(Int(selection.height))"
            (size as NSString).draw(at: CGPoint(x: selection.minX + 6, y: max(10, selection.minY - 25)),
                                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        }
        let tips = windows.isEmpty ? "拖动选择截图区域 · Esc 取消" : "点击选择窗口，或拖动框选 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = (tips as NSString).size(withAttributes: attrs)
        let background = CGRect(x: bounds.midX - size.width / 2 - 16, y: 30, width: size.width + 32, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: background, xRadius: 10, yRadius: 10).fill()
        (tips as NSString).draw(at: CGPoint(x: background.minX + 16, y: background.minY + 10), withAttributes: attrs)
    }
    override func mouseMoved(with event: NSEvent) {
        guard anchor == nil, !windows.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = windows.first { $0.contains(point) }; needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { anchor = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let anchor, hypot(point.x - anchor.x, point.y - anchor.y) < 4, !windows.isEmpty {
            selection = windows.first { $0.contains(point) }
        }
        anchor = nil
        if let selection, selection.width >= 8, selection.height >= 8 { completed?(selection) }
    }
    override func rightMouseDown(with event: NSEvent) { completed?(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completed?(nil) }
        else { super.keyDown(with: event) }
    }
}

@MainActor final class ScrollCaptureSession: ObservableObject {
    @Published var axis: StitchAxis = .vertical
    @Published private(set) var count = 1
    @Published private(set) var status = "在选区内缓慢滚动，保留至少三分之一重叠区域。"
    @Published private(set) var size: CGSize
    @Published var automaticScroll = false
    private var stitcher: ImageStitcher
    private let selection: CaptureSelection
    private let service: CaptureService
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    var finished: ((CGImage?) -> Void)?

    init(selection: CaptureSelection, service: CaptureService, axis: StitchAxis) {
        self.selection = selection; self.service = service; self.axis = axis
        stitcher = ImageStitcher(image: selection.image, axis: axis)
        size = CGSize(width: selection.image.width, height: selection.image.height)
    }
    func start() {
        let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 410, height: 140),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "滚动长截图 · \(axis.title)"
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ScrollCaptureControls(session: self))
        panel.center(); panel.orderFrontRegardless()
        self.panel = panel
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(650)) } catch { break }
                guard let self else { break }
                await self.sample()
            }
        }
    }
    func sample() async {
        do {
            if automaticScroll {
                guard AXIsProcessTrusted() else {
                    automaticScroll = false
                    status = "自动滚动需要辅助功能权限；仍可手动滚动。"
                    return
                }
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: axis == .vertical ? -120 : 0, wheel2: axis == .horizontal ? -120 : 0, wheel3: 0) {
                    event.location = CGPoint(x: selection.display.frame.minX + selection.rect.midX, y: selection.display.frame.minY + selection.rect.midY)
                    event.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(220))
                }
            }
            let image = try await service.capture(selection)
            let result = try await Task.detached { [stitcher] in
                var next = stitcher
                let appended = try next.append(image)
                return (next, appended)
            }.value
            guard !Task.isCancelled else { return }
            stitcher = result.0
            if result.1 {
                count += 1; size = CGSize(width: stitcher.image.width, height: stitcher.image.height)
                status = "已拼接 \(count) 帧 · \(Int(size.width)) × \(Int(size.height))"
            } else { status = "等待滚动；无重叠时请回滚一些再继续。" }
        } catch {
            automaticScroll = false
            status = error.localizedDescription
        }
    }
    func finish(cancelled: Bool = false) {
        task?.cancel(); task = nil
        panel?.orderOut(nil); panel?.close(); panel = nil
        let callback = finished; finished = nil
        callback?(cancelled ? nil : stitcher.image)
    }
}

private struct ScrollCaptureControls: View {
    @ObservedObject var session: ScrollCaptureSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.status).font(.callout).lineLimit(2)
            HStack {
                Toggle("自动滚动", isOn: $session.automaticScroll).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("取消") { session.finish(cancelled: true) }
                Button("完成") { session.finish() }.buttonStyle(.borderedProminent)
            }
        }.padding(18).frame(width: 410)
    }
}
