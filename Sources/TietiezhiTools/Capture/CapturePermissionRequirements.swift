import Foundation

enum CapturePermissionRequirements {
    static func legacyDeclarations(for manifest: PluginManifest) -> [PluginPermissionDeclaration] {
        guard manifest.hasCaptureCapability else { return [] }
        var declarations: [PluginPermissionDeclaration] = []
        if manifest.actions.contains(where: {
            [.captureRegion, .captureWindow, .captureScreen, .captureScrolling, .captureRecording].contains($0)
        }) {
            declarations.append(.init(id: .screenRecording, reason: "截图、滚动长截图和录屏"))
        }
        if manifest.actions.contains(.captureScrolling) {
            declarations.append(.init(id: .accessibility, reason: "长截图的自动滚动", optional: true))
        }
        if manifest.actions.contains(.captureRecording) {
            declarations += [
                .init(id: .camera, reason: "录屏摄像头画中画", optional: true),
                .init(id: .microphone, reason: "录屏麦克风旁白", optional: true),
                .init(id: .inputMonitoring, reason: "录屏按键显示", optional: true),
            ]
        }
        return declarations
    }
    static func permissions(for action: ActionKind, recordingOptions: UserDefaults = .standard) -> Set<HostPermissionID>
    {
        switch action {
        case .captureRegion, .captureWindow, .captureScreen, .captureScrolling: return [.screenRecording]
        case .captureRecording:
            var result: Set<HostPermissionID> = [.screenRecording]
            if recordingOptions.bool(forKey: "capture.camera") { result.insert(.camera) }
            if recordingOptions.bool(forKey: "capture.microphone") { result.insert(.microphone) }
            if recordingOptions.bool(forKey: "capture.keystrokes") { result.insert(.inputMonitoring) }
            return result
        default: return []
        }
    }
}
