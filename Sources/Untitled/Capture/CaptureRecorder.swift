import AppKit
@preconcurrency import AVFoundation
import Combine
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

struct RecordingOptions: Equatable {
    var fps = 30
    var maximumEdge = 4096
    static var current: Self {
        let defaults = UserDefaults.standard
        let fps = defaults.integer(forKey: "capture.recordingFPS")
        let edge = defaults.integer(forKey: "capture.recordingMaximumEdge")
        return Self(fps: [5, 16, 24, 30, 60].contains(fps) ? fps : 30,
                    maximumEdge: [1280, 1920, 2560, 4096].contains(edge) ? edge : 4096)
    }
}

@available(macOS 15, *)
@MainActor final class CaptureRecorder: NSObject, ObservableObject, SCRecordingOutputDelegate, SCStreamDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var errorMessage: String?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var outputURL: URL?
    private var directory: URL?
    private var segments: [URL] = []
    private var segmentURL: URL?
    private var config: SCStreamConfiguration?
    private var filter: SCContentFilter?
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    private var segmentStarted: Date?
    private var audioWriter: CaptureRecordingAudio?
    private let eventMonitor = CaptureRecordingEventMonitor()
    private var manifest: RecordingRecoveryManifest?
    private var recordedTime: TimeInterval = 0
    var failed: ((String) -> Void)?
    var elapsedTime: TimeInterval { recordedTime + (segmentStarted.map { Date().timeIntervalSince($0) } ?? 0) }

    func start(selection: CaptureSelection, url: URL, permissions: PluginPermissionClient, audio: Bool, microphone: Bool, cursor: Bool, options: RecordingOptions = .current) async throws {
        guard !isRecording, !isTransitioning else { throw PluginError.invalid("已有录屏正在进行。") }
        guard [5, 16, 24, 30, 60].contains(options.fps), [1280, 1920, 2560, 4096].contains(options.maximumEdge) else { throw PluginError.invalid("无效的录屏帧率或尺寸。") }
        try permissions.require(microphone ? [.screenRecording, .microphone] : [.screenRecording])
        errorMessage = nil; recordedTime = 0; segments = []
        let config = SCStreamConfiguration()
        config.sourceRect = selection.rect
        let width = selection.rect.width * selection.scale, height = selection.rect.height * selection.scale
        let ratio = min(1, CGFloat(options.maximumEdge) / max(width, height))
        config.width = max(2, Int(width * ratio) / 2 * 2)
        config.height = max(2, Int(height * ratio) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(options.fps))
        config.showsCursor = false; config.showMouseClicks = false // Cursor and clicks are editable metadata.
        config.capturesAudio = audio; config.excludesCurrentProcessAudio = true
        config.captureMicrophone = microphone
        self.config = config; filter = selection.filter; outputURL = url
        let directory = url.deletingLastPathComponent().appendingPathComponent(".recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        manifest = RecordingRecoveryManifest(targetFilename: url.lastPathComponent, expectedAudioNames: [audio ? "system" : nil, microphone ? "microphone" : nil].compactMap { $0 })
        try manifest?.save(in: directory)
        if let frame = selection.presentationFrame {
            try eventMonitor.start(frame: frame, mouse: cursor, keyboard: UserDefaults.standard.bool(forKey: "capture.keystrokes"),
                permissions: permissions, checkpoint: directory.appendingPathComponent("events.json")) { [weak self] in
                guard let self, self.isRecording, !self.isPaused, !self.isTransitioning else { return nil }
                return self.elapsedTime
            }
        }
        isTransitioning = true
        defer { isTransitioning = false }
        do { try await startSegment(); isRecording = true }
        catch {
            eventMonitor.stop(); manifest?.ownerPID = 0; try? manifest?.save(in: directory)
            if RecordingFinalization.segmentFiles(in: directory).isEmpty { try? FileManager.default.removeItem(at: directory) }
            self.directory = nil; throw error
        }
    }

    func pause() async throws {
        guard isRecording, !isPaused, !isTransitioning else { return }
        isTransitioning = true; defer { isTransitioning = false }
        try await finishSegment(); isPaused = true
    }
    func resume() async throws {
        guard isRecording, isPaused, !isTransitioning else { return }
        isTransitioning = true; defer { isTransitioning = false }
        try await startSegment(); isPaused = false
    }
    func stop() async throws -> URL {
        while isTransitioning { try await Task.sleep(for: .milliseconds(20)) }
        guard isRecording, let url = outputURL else { throw PluginError.invalid("没有正在进行的录屏。") }
        isTransitioning = true
        defer {
            eventMonitor.stop()
            if let directory { manifest?.ownerPID = 0; try? manifest?.save(in: directory) }
            stream = nil; output = nil; outputURL = nil; config = nil; filter = nil
            isRecording = false; isPaused = false; isTransitioning = false; segmentStarted = nil
        }
        if stream != nil {
            do { try await finishSegment() }
            catch { errorMessage = error.localizedDescription }
        }
        eventMonitor.stop()
        guard let directory else { throw PluginError.invalid("录屏原始片段不存在。") }
        let completed = try await RecordingFinalization.finish(in: directory, to: url, expectedAudioNames: manifest?.expectedAudioNames) {
            try eventMonitor.save(for: url)
        }
        if let warning = completed.warning { errorMessage = warning }
        if !completed.retainedSource { self.directory = nil }
        segments = []
        return completed.url
    }

    func restart() async throws {
        guard isRecording, !isTransitioning, let oldDirectory = directory, let outputURL else { return }
        isTransitioning = true; defer { isTransitioning = false }
        if stream != nil { try await finishSegment() }
        let previous = segments, elapsed = recordedTime
        let fresh = oldDirectory.deletingLastPathComponent().appendingPathComponent(".recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let newManifest = RecordingRecoveryManifest(targetFilename: outputURL.lastPathComponent, expectedAudioNames: manifest?.expectedAudioNames)
        try newManifest.save(in: fresh)
        directory = fresh; segments = []; recordedTime = 0
        do {
            try await startSegment(); isPaused = false; manifest = newManifest
            eventMonitor.reset(checkpoint: fresh.appendingPathComponent("events.json"))
            try? FileManager.default.removeItem(at: oldDirectory)
        } catch {
            directory = oldDirectory; segments = previous; recordedTime = elapsed; isPaused = true
            try? FileManager.default.removeItem(at: fresh); throw error
        }
    }

    private func startSegment() async throws {
        guard let config, let filter, let directory else { throw PluginError.invalid("录屏配置已失效。") }
        result = nil; waiter = nil
        let url = RecordingFinalization.nextSegmentURL(in: directory)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url; recording.outputFileType = .mp4; recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let audio = CaptureRecordingAudio(directory: directory, stem: url.deletingPathExtension().lastPathComponent)
        try audio.attach(to: stream, system: config.capturesAudio, microphone: config.captureMicrophone)
        audioWriter = audio
        try stream.addRecordingOutput(output)
        self.stream = stream; self.output = output; segmentURL = url
        do {
            try await stream.startCapture()
            if case .failure(let error) = result { throw error }
            segmentStarted = Date()
        } catch {
            try? await stream.stopCapture(); try? await audioWriter?.finish()
            self.stream = nil; self.output = nil; segmentURL = nil; audioWriter = nil; throw error
        }
    }
    private func finishSegment() async throws {
        guard let stream, let url = segmentURL else { return }
        segmentStarted = nil
        defer { self.stream = nil; output = nil; segmentURL = nil; audioWriter = nil }
        do {
            try await stream.stopCapture()
            if let result { try result.get() }
            else { try await withCheckedThrowingContinuation { waiter = $0 } }
        } catch {
            // Preserve the on-disk pending file. Finalization scans it even though the
            // native completion callback failed; a resume uses a fresh numeric name.
            try? await audioWriter?.finish()
            isPaused = true
            throw error
        }
        do { try await audioWriter?.finish() }
        catch {
            errorMessage = "独立音轨未能保存，已保留原录屏中的声音。"
            for name in ["system", "microphone"] { try? FileManager.default.removeItem(at: RecordingAudioStems.url(for: url, name: name)) }
        }
        if let duration = try? await AVURLAsset(url: url).load(.duration).seconds { recordedTime += duration }
        segments.append(url)
    }
    private func complete(_ result: Result<Void, Error>, outputID: ObjectIdentifier?) {
        if let outputID, output.map(ObjectIdentifier.init) != outputID { return }
        guard self.result == nil else { return }
        self.result = result
        if let waiter { self.waiter = nil; waiter.resume(with: result) }
        if case .failure(let error) = result { errorMessage = error.localizedDescription; failed?(error.localizedDescription) }
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let id = ObjectIdentifier(recordingOutput)
        Task { @MainActor [weak self] in self?.complete(.success(()), outputID: id) }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let id = ObjectIdentifier(recordingOutput)
        Task { @MainActor [weak self] in self?.complete(.failure(error), outputID: id) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let id = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == id else { return }
            self.complete(.failure(error), outputID: nil)
        }
    }
}

struct RecordingEditOptions: Equatable, Sendable {
    var speed = 1.0
    /// Coordinates in the oriented video image, normalized from its top left.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var volume: Float = 1
    var systemVolume: Float = 1
    var microphoneVolume: Float = 1
    var effects = RecordingEffectOptions()
    var fps = 10
    var maximumEdge = 1280
    var quality = 80.0
    func validated() throws -> Self {
        guard speed.isFinite, (0.2...2).contains(speed), volume.isFinite, (0...2).contains(volume), systemVolume.isFinite, microphoneVolume.isFinite,
              (0...2).contains(systemVolume), (0...2).contains(microphoneVolume),
              (1...30).contains(fps), (320...2560).contains(maximumEdge), quality.isFinite, (1...100).contains(quality),
              [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
              crop.minX >= 0, crop.minY >= 0, crop.width >= 0.02, crop.height >= 0.02,
              crop.maxX <= 1.00001, crop.maxY <= 1.00001 else { throw PluginError.invalid("请检查录屏裁剪、倍速和导出参数。") }
        return self
    }
}

/// All export paths share the same trim, speed and crop composition.
@MainActor enum RecordingExporter {
    struct Prepared {
        let asset: AVMutableComposition
        let video: AVMutableVideoComposition
        let audio: AVMutableAudioMix
        let duration: Double
    }
    static func prepare(from url: URL, start: Double, end: Double, options: RecordingEditOptions) async throws -> Prepared {
        let options = try options.validated(), source = AVURLAsset(url: url)
        let duration = try await source.load(.duration).seconds
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.05,
              let video = try await source.loadTracks(withMediaType: .video).first else { throw PluginError.invalid("请选择有效的录屏片段。") }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: min(end, duration) - start, preferredTimescale: 600))
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw PluginError.invalid("无法创建视频轨道。") }
        try track.insertTimeRange(range, of: video, at: .zero)
        let audio = AVMutableAudioMix()
        let stems = await RecordingAudioStems.validatedNames(for: url)
        var audioSources: [(AVAssetTrack, Float)] = []
        var sourceAssets: [AVAsset] = [source]
        defer { withExtendedLifetime(sourceAssets) {} }
        if stems.isEmpty {
            audioSources = try await source.loadTracks(withMediaType: .audio).map { ($0, options.volume) }
        } else {
            for name in stems {
                let stem = AVURLAsset(url: RecordingAudioStems.url(for: url, name: name))
                sourceAssets.append(stem)
                audioSources += try await stem.loadTracks(withMediaType: .audio).map { ($0, name == "system" ? options.systemVolume : options.microphoneVolume) }
            }
        }
        for (original, volume) in audioSources {
            guard let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let available = try await original.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
            if intersection.duration.seconds > 0 {
                try added.insertTimeRange(intersection, of: original, at: CMTimeSubtract(intersection.start, range.start))
                let parameters = AVMutableAudioMixInputParameters(track: added)
                parameters.setVolume(volume, at: .zero)
                audio.inputParameters.append(parameters)
            }
        }
        let resultDuration = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / options.speed)
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: resultDuration)
        let size = try await video.load(.naturalSize), transform = try await video.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        let crop = CGRect(x: options.crop.minX * oriented.width, y: options.crop.minY * oriented.height,
                          width: options.crop.width * oriented.width, height: options.crop.height * oriented.height)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -oriented.minX - crop.minX, y: -oriented.minY - crop.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: resultDuration); instruction.layerInstructions = [layer]
        let output = AVMutableVideoComposition()
        output.instructions = [instruction]
        output.renderSize = CGSize(width: max(2, Int(crop.width) / 2 * 2), height: max(2, Int(crop.height) / 2 * 2))
        let sourceFPS = try await video.load(.nominalFrameRate)
        output.frameDuration = CMTime(value: 1, timescale: Int32(min(60, max(5, sourceFPS.rounded()))))
        if let events = RecordingEventArchive.read(for: url), !events.events.isEmpty {
            let transform = transform.concatenating(CGAffineTransform(translationX: -oriented.minX - crop.minX, y: -oriented.minY - crop.minY))
            let effects = RecordingEffects.composition(asset: composition, cgTransform: transform, sourceSize: size, outputSize: output.renderSize,
                orientedSize: oriented.size, crop: crop, frameDuration: output.frameDuration,
                events: events.events, options: options.effects, start: start, speed: options.speed)
            return Prepared(asset: composition, video: effects, audio: audio, duration: resultDuration.seconds)
        }
        return Prepared(asset: composition, video: output, audio: audio, duration: resultDuration.seconds)
    }
    static func movie(from url: URL, to destination: URL, start: Double, end: Double, options: RecordingEditOptions = .init()) async throws {
        let prepared = try await prepare(from: url, start: start, end: end, options: options)
        let preset = options.quality >= 80 ? AVAssetExportPresetHighestQuality : options.quality >= 40 ? AVAssetExportPresetMediumQuality : AVAssetExportPresetLowQuality
        guard let exporter = AVAssetExportSession(asset: prepared.asset, presetName: preset) else { throw PluginError.invalid("无法创建视频编码器。") }
        exporter.videoComposition = prepared.video; exporter.audioMix = prepared.audio
        exporter.audioTimePitchAlgorithm = .timeDomain
        try await export(exporter, to: destination)
    }
    static func gif(from url: URL, to destination: URL, start: Double, end: Double, fps: Int = 10) async throws {
        var options = RecordingEditOptions(); options.fps = fps
        try await animation(from: url, to: destination, start: start, end: end, options: options, webP: false)
    }
    static var webPEncoder: URL? { CaptureWebP.encoder }
    static func animation(from url: URL, to destination: URL, start: Double, end: Double, options: RecordingEditOptions, webP: Bool) async throws {
        let prepared = try await prepare(from: url, start: start, end: end, options: options)
        guard prepared.duration <= 180 else { throw PluginError.invalid("动图片段按所选倍速导出后不能超过 3 分钟。") }
        let frames = max(1, Int(ceil(prepared.duration * Double(options.fps))))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let staged = temp.appendingPathComponent(webP ? "output.webp" : "output.gif")
        let generator = AVAssetImageGenerator(asset: prepared.asset)
        generator.videoComposition = prepared.video
        generator.maximumSize = CGSize(width: options.maximumEdge, height: options.maximumEdge)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var gifTarget: CGImageDestination?
        if !webP {
            gifTarget = CGImageDestinationCreateWithURL(staged as CFURL, UTType.gif.identifier as CFString, frames, nil)
            guard let gifTarget else { throw PluginError.invalid("无法创建 GIF 文件。") }
            CGImageDestinationSetProperties(gifTarget, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        if webP, webPEncoder == nil { throw PluginError.invalid("当前构建缺少 WebP 编码组件，请重新安装完整应用。") }
        var paths: [String] = []
        for frame in 0..<frames {
            try Task.checkCancellation()
            let time = CMTime(seconds: min(prepared.duration - 0.001, Double(frame) / Double(options.fps)), preferredTimescale: 60000)
            let image = try await generator.image(at: time).image
            if let gifTarget {
                let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Double(options.fps)]] as CFDictionary
                CGImageDestinationAddImage(gifTarget, image, properties)
            } else {
                let path = temp.appendingPathComponent("\(frame).png")
                try CaptureImage.png(image).write(to: path); paths.append(path.path)
            }
        }
        if let gifTarget, !CGImageDestinationFinalize(gifTarget) { throw PluginError.invalid("GIF 编码失败。") }
        if webP, let encoder = webPEncoder {
            let arguments = ["-loop", "0", "-lossy", "-q", String(Int(options.quality)), "-d", String(max(1, Int((1000 / Double(options.fps)).rounded())))] + paths + ["-o", staged.path]
            try await Task.detached {
                let process = Process(); process.executableURL = encoder; process.arguments = arguments
                // The encoder may emit one line per frame: a file avoids a full pipe blocking termination.
                let log = temp.appendingPathComponent("encoder.log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
                process.standardError = handle; process.standardOutput = handle
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw PluginError.invalid("WebP 编码失败，请尝试缩短片段或降低尺寸。") }
            }.value
        }
        try Task.checkCancellation()
        try Data(contentsOf: staged, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }
    static func join(_ urls: [URL], to destination: URL) async throws {
        guard !urls.isEmpty else { throw PluginError.invalid("录屏没有有效片段。") }
        if urls.count == 1 {
            let asset = AVURLAsset(url: urls[0])
            guard try await asset.load(.duration).seconds > 0 else { throw PluginError.invalid("录屏片段过短。") }
            try Data(contentsOf: urls[0], options: .mappedIfSafe).write(to: destination, options: .atomic); return
        }
        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:], cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url), duration = try await asset.load(.duration)
            guard duration.seconds > 0 else { continue }
            for kind in [AVMediaType.video, .audio] {
                for (index, source) in try await asset.loadTracks(withMediaType: kind).enumerated() {
                    let key = "\(kind.rawValue)-\(index)"
                    let target: AVMutableCompositionTrack
                    if let existing = tracks[key] { target = existing }
                    else {
                        guard let added = composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                        added.preferredTransform = try await source.load(.preferredTransform); tracks[key] = added; target = added
                    }
                    let available = try await source.load(.timeRange)
                    let range = CMTimeRangeGetIntersection(CMTimeRange(start: .zero, duration: duration), otherRange: available)
                    if range.duration.seconds > 0 { try target.insertTimeRange(range, of: source, at: CMTimeAdd(cursor, range.start)) }
                }
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard cursor.seconds > 0, let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw PluginError.invalid("无法合并录屏片段。") }
        try await export(exporter, to: destination)
    }
    private static func export(_ exporter: AVAssetExportSession, to destination: URL) async throws {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        if #available(macOS 15, *) { try await exporter.export(to: staged, as: .mp4) }
        else {
            exporter.outputURL = staged; exporter.outputFileType = .mp4; await exporter.export()
            guard exporter.status == .completed else { throw exporter.error ?? PluginError.invalid("视频导出失败。") }
        }
        try Data(contentsOf: staged, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }
}
