import AVFoundation
import AppKit
@preconcurrency import ApplicationServices

@MainActor enum SystemPermissionProvider {
    static func drivers() -> [HostPermissionDriver] {
        [
            make(
                .screenRecording, "屏幕与系统音频录制", "允许读取屏幕内容、制作截图和录屏，并按功能设置录制系统音频。", "display", "ScreenCapture",
                status: { CGPreflightScreenCaptureAccess() ? .authorized : .notGranted },
                request: { _ = CGRequestScreenCaptureAccess() }),
            make(
                .accessibility, "辅助功能", "允许控制其他应用，例如在长截图时自动滚动。", "accessibility", "Accessibility",
                status: { AXIsProcessTrusted() ? .authorized : .notGranted },
                request: {
                    _ = AXIsProcessTrustedWithOptions(
                        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }),
            make(
                .inputMonitoring, "输入监控", "允许功能监听其他应用中的键盘事件，例如录屏时显示按键。", "keyboard", "ListenEvent",
                status: { CGPreflightListenEventAccess() ? .authorized : .notGranted },
                request: { _ = CGRequestListenEventAccess() }),
            make(
                .camera, "摄像头", "允许使用摄像头，例如录屏中的画中画。", "camera", "Camera",
                status: { mediaStatus(.video) },
                request: {
                    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                    }
                }),
            make(
                .microphone, "麦克风", "允许录制麦克风声音，例如录屏旁白。", "mic", "Microphone",
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
