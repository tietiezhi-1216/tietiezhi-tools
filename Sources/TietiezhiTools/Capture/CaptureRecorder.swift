import AppKit
import AVFoundation
import Combine
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

@available(macOS 15, *)
@MainActor final class CaptureRecorder: NSObject, ObservableObject, SCRecordingOutputDelegate, SCStreamDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var outputURL: URL?
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    var failed: ((String) -> Void)?

    func start(selection: CaptureSelection, url: URL, permissions: PluginPermissionClient, audio: Bool, microphone: Bool, cursor: Bool) async throws {
        guard stream == nil else { throw PluginError.invalid("已有录屏正在进行。") }
        try permissions.require(microphone ? [.screenRecording, .microphone] : [.screenRecording])
        result = nil; errorMessage = nil
        let config = SCStreamConfiguration()
        config.sourceRect = selection.rect
        let width = selection.rect.width * selection.scale, height = selection.rect.height * selection.scale
        let ratio = min(1, 4096 / max(width, height))
        config.width = max(2, Int(width * ratio) / 2 * 2)
        config.height = max(2, Int(height * ratio) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = cursor
        config.showMouseClicks = cursor
        config.capturesAudio = audio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = microphone
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        let stream = SCStream(filter: selection.filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream; self.output = output; outputURL = url
        do {
            try await stream.startCapture()
            if case .failure(let error) = result { throw error }
            isRecording = true
        } catch {
            self.stream = nil; self.output = nil; outputURL = nil
            throw error
        }
    }

    func stop() async throws -> URL {
        guard let stream, let url = outputURL else { throw PluginError.invalid("没有正在进行的录屏。") }
        defer { self.stream = nil; output = nil; outputURL = nil; isRecording = false }
        try await stream.stopCapture()
        if let result { try result.get() }
        else {
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
        return url
    }

    private func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let waiter { self.waiter = nil; waiter.resume(with: result) }
        if case .failure(let error) = result {
            isRecording = false
            errorMessage = error.localizedDescription
            failed?(error.localizedDescription)
        }
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.complete(.success(())) }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.complete(.failure(error)) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.complete(.failure(error)) }
    }
}

enum RecordingExporter {
    static func gif(from url: URL, to destination: URL, start: Double, end: Double, fps: Int = 10) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard start >= 0, end > start, end <= duration + 0.1, end - start <= 180, (1...20).contains(fps) else {
            throw PluginError.invalid("GIF 片段需在录屏范围内，长度不超过 3 分钟。")
        }
        let frames = max(1, Int((end - start) * Double(fps)))
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let target = CGImageDestinationCreateWithURL(staged as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw PluginError.invalid("无法创建 GIF 文件。")
        }
        CGImageDestinationSetProperties(target, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Double(fps)]] as CFDictionary
        for frame in 0..<frames {
            try Task.checkCancellation()
            let time = CMTime(seconds: start + Double(frame) / Double(fps), preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(target, image, properties)
        }
        guard CGImageDestinationFinalize(target) else { throw PluginError.invalid("GIF 编码失败。") }
        try Data(contentsOf: staged, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }

    static func movie(from url: URL, to destination: URL, start: Double, end: Double) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard start >= 0, end > start, end <= duration + 0.1,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw PluginError.invalid("请选择有效的录屏片段。")
        }
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                         end: CMTime(seconds: end, preferredTimescale: 600))
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        if #available(macOS 15, *) { try await exporter.export(to: staged, as: .mp4) }
        else {
            exporter.outputURL = staged; exporter.outputFileType = .mp4
            await exporter.export()
            guard exporter.status == .completed else { throw exporter.error ?? PluginError.invalid("视频导出失败。") }
        }
        try Data(contentsOf: staged, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }
}
