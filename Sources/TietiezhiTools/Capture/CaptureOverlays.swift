import AppKit
@preconcurrency import AVFoundation
import Carbon
import SwiftUI

@MainActor final class CaptureCameraOverlay {
    private final class SessionBox: @unchecked Sendable { let session = AVCaptureSession() }
    private let box = SessionBox()
    private var panel: NSPanel?
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func start(in selection: CaptureSelection) async throws {
        guard selection.rect.width >= 240, selection.rect.height >= 180 else {
            throw PluginError.invalid("摄像头画中画需要至少 240 × 180 的录屏选区。")
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw PluginError.invalid("摄像头权限未开启。") }
        guard let device = AVCaptureDevice.default(for: .video) else { throw PluginError.invalid("未检测到摄像头，可关闭画中画后录屏。") }
        let input = try AVCaptureDeviceInput(device: device)
        box.session.beginConfiguration()
        box.session.sessionPreset = .medium
        guard box.session.canAddInput(input) else {
            box.session.commitConfiguration()
            throw PluginError.invalid("无法启动摄像头。")
        }
        box.session.addInput(input); box.session.commitConfiguration()
        let width = min(300, selection.rect.width / 3)
        let height = width * 0.75
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: CGSize(width: width, height: height)),
                            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.aspectRatio = CGSize(width: 4, height: 3)
        let view = CameraPreviewView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: box.session)
        preview.videoGravity = .resizeAspectFill
        view.layer = preview
        panel.contentView = view
        let frame = Self.screenFrame(selection)
        panel.setFrameOrigin(CGPoint(x: frame.minX + selection.rect.maxX - width - 12,
                                     y: frame.maxY - selection.rect.maxY + 12))
        self.panel = panel
        panel.orderFrontRegardless()
        let box = box
        await Task.detached { box.session.startRunning() }.value
    }
    func stop() {
        panel?.close(); panel = nil
        let box = box
        Task.detached { box.session.stopRunning() }
    }
    static func screenFrame(_ selection: CaptureSelection) -> CGRect {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == selection.display.displayID
        }?.frame ?? NSScreen.main?.frame ?? .zero
    }
}

private final class CameraPreviewView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

@MainActor final class CaptureKeystrokeOverlay: ObservableObject {
    @Published private(set) var label = "按键显示"
    private var panel: NSPanel?
    private var monitor: Any?
    private var reset: Task<Void, Never>?
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func start(in selection: CaptureSelection) throws {
        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            throw PluginError.invalid("按键显示需要输入监控权限；可在系统设置中允许，或关闭该选项后录制。")
        }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: min(260, selection.rect.width), height: 54),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: KeystrokeLabel(overlay: self))
        let frame = CaptureCameraOverlay.screenFrame(selection)
        panel.setFrameOrigin(CGPoint(x: frame.minX + selection.rect.minX + 12, y: frame.maxY - selection.rect.maxY + 12))
        self.panel = panel; panel.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !IsSecureEventInputEnabled() else { return }
            let text = Self.keyLabel(event)
            Task { @MainActor [weak self] in self?.show(text) }
        }
        guard monitor != nil else { stop(); throw PluginError.invalid("无法监听按键，请检查输入监控权限。") }
    }
    nonisolated private static func keyLabel(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        var prefix = ""
        if event.modifierFlags.contains(.control) { prefix += "⌃" }
        if event.modifierFlags.contains(.option) { prefix += "⌥" }
        if event.modifierFlags.contains(.shift) { prefix += "⇧" }
        if event.modifierFlags.contains(.command) { prefix += "⌘" }
        return prefix + (special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "")
    }
    private func show(_ value: String) {
        label = value
        reset?.cancel()
        reset = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self?.label = ""
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; reset?.cancel(); reset = nil
        panel?.close(); panel = nil
    }
}

private struct KeystrokeLabel: View {
    @ObservedObject var overlay: CaptureKeystrokeOverlay
    var body: some View {
        Text(overlay.label).font(.system(size: 26, weight: .medium, design: .monospaced))
            .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 8)
            .background(overlay.label.isEmpty ? .clear : Color.black.opacity(0.7), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
