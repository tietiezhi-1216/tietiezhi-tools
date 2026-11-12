import AppKit
@preconcurrency import AVFoundation

@MainActor final class CaptureCameraPair {
    private var cameras: [CaptureCameraOverlay] = []
    var windowIDs: [CGWindowID] { cameras.compactMap(\.windowID) }
    func start(in selection: CaptureSelection, permissions: PluginPermissionClient) async throws {
        let defaults = UserDefaults.standard
        let second = defaults.bool(forKey: "capture.secondCamera")
        let secondID = defaults.string(forKey: "capture.secondCameraDevice") ?? ""
        let firstID = defaults.string(forKey: "capture.cameraDevice") ?? ""
        let effectiveFirst = firstID.isEmpty ? AVCaptureDevice.default(for: .video)?.uniqueID : firstID
        if second, secondID.isEmpty || secondID == effectiveFirst { throw PluginError.invalid("请选择另一台摄像头作为第二摄像头。") }
        let first = CaptureCameraOverlay(); cameras = [first]
        do {
            try await first.start(in: selection, permissions: permissions)
            if second {
                let other = CaptureCameraOverlay(); cameras.append(other)
                try await other.start(in: selection, permissions: permissions, deviceID: secondID, secondary: true)
            }
        } catch { stop(); throw error }
    }
    func stop() { cameras.forEach { $0.stop() }; cameras = [] }
}

@MainActor enum CaptureRecordingCountdown {
    private final class Cancellation: NSObject {
        var cancelled = false
        @objc func cancel() { cancelled = true }
    }
    static func wait(seconds: Int) async -> Bool {
        guard seconds > 0 else { return true }
        let state = Cancellation()
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        CaptureWindowPolicy.markControl(panel, name: "recordingCountdown")
        panel.title = "准备录屏"; panel.isReleasedWhenClosed = false; panel.level = .floating
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        label.alignment = .center; label.frame = NSRect(x: 20, y: 62, width: 200, height: 40)
        let button = NSButton(title: "取消", target: state, action: #selector(Cancellation.cancel))
        button.bezelStyle = .rounded; button.keyEquivalent = "\u{1b}"; button.frame = NSRect(x: 80, y: 18, width: 80, height: 30)
        root.addSubview(label); root.addSubview(button); panel.contentView = root
        panel.center(); panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        for value in stride(from: min(60, seconds), through: 1, by: -1) {
            label.stringValue = "\(value)"
            for _ in 0..<10 {
                if state.cancelled || Task.isCancelled { return false }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            }
        }
        return !state.cancelled
    }
}
