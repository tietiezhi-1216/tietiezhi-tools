import AVFoundation
import AppKit
@preconcurrency import ApplicationServices

@MainActor enum SystemPermissionProvider {
    static func drivers() -> [HostPermissionDriver] {
        [
            make(
                .screenRecording, "屏幕与系统音频录制", "用于截图、录屏与录制系统音频。", "display", "ScreenCapture",
                status: { CGPreflightScreenCaptureAccess() ? .authorized : .notGranted },
                request: { _ = CGRequestScreenCaptureAccess() }),
            make(
                .accessibility, "辅助功能", "用于自动滚动及经你允许的跨 Mac 键鼠控制。", "accessibility", "Accessibility",
                status: { AXIsProcessTrusted() ? .authorized : .notGranted },
                request: {
                    _ = AXIsProcessTrustedWithOptions(
                        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }),
            make(
                .inputMonitoring, "输入监控", "用于按键显示，以及开启键鼠共享时的输入监听。", "keyboard", "ListenEvent",
                status: { CGPreflightListenEventAccess() ? .authorized : .notGranted },
                request: { _ = CGRequestListenEventAccess() }),
            make(
                .camera, "摄像头", "用于录屏画中画等摄像头功能。", "camera", "Camera",
                status: { mediaStatus(.video) },
                request: {
                    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                    }
                }),
            make(
                .microphone, "麦克风", "用于录屏旁白，以及经你允许、对端应用使用时的实体麦克风同步。", "mic", "Microphone",
                status: { mediaStatus(.audio) },
                request: {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                    }
                }),
        ]
    }
    private static func make(
        _ id: HostPermissionID, _ title: String, _ summary: String, _ symbol: String, _ pane: String,
        status: @escaping () -> HostPermissionStatus, request: @escaping () async -> Void
    ) -> HostPermissionDriver {
        .init(
            descriptor: .init(id: id, title: title, summary: summary, symbol: symbol),
            status: status, request: request,
            openSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            })
    }
    private static func mediaStatus(_ type: AVMediaType) -> HostPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .notGranted
        }
    }
}
