@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import Foundation

/// Writes optional audio stems alongside each native recording segment.
/// All mutable writer state is confined to the stream's serial sample queue.
@available(macOS 15, *)
final class CaptureRecordingAudio: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TietiezhiTools.recording.audio")
    private let directory: URL
    private let stem: String
    private let clockOrigin = CMClockGetTime(CMClockGetHostTimeClock())
    private struct Track { let writer: AVAssetWriter; let input: AVAssetWriterInput }
    private var tracks: [String: Track] = [:]
    private var failed: Error?
    private var finishing = false
    init(directory: URL, stem: String) { self.directory = directory; self.stem = stem }
    func attach(to stream: SCStream, system: Bool, microphone: Bool) throws {
        if system { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finishing, failed == nil, CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer),
              type == .audio || type == .microphone,
              let description = CMSampleBufferGetFormatDescription(buffer), let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let name = type == .audio ? "system" : "microphone"
        do {
            var track = tracks[name]
            if track == nil {
                let url = directory.appendingPathComponent("\(stem).\(name).m4a")
                let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.pointee.mSampleRate,
                    AVNumberOfChannelsKey: Int(format.pointee.mChannelsPerFrame), AVEncoderBitRateKey: 128000])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw PluginError.invalid("无法创建录屏音轨。") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? PluginError.invalid("无法开始录屏音轨。") }
                writer.startSession(atSourceTime: min(clockOrigin, CMSampleBufferGetPresentationTimeStamp(buffer)))
                track = Track(writer: writer, input: input); tracks[name] = track
            }
            if let track {
                // A dropped sample makes the stem incomplete. Fail it so export falls back
                // to the native recording's complete mixed audio instead of silently muting.
                guard track.input.isReadyForMoreMediaData else { throw PluginError.invalid("录屏独立音轨写入繁忙。") }
                guard track.input.append(buffer) else { throw track.writer.error ?? PluginError.invalid("录屏音轨写入失败。") }
            }
        } catch { failed = error }
    }
    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.finishing = true
                let group = DispatchGroup()
                for track in self.tracks.values {
                    track.input.markAsFinished(); group.enter()
                    track.writer.finishWriting { group.leave() }
                }
                group.notify(queue: self.queue) {
                    if let error = self.failed ?? self.tracks.values.first(where: { $0.writer.status != .completed })?.writer.error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }
}

@MainActor enum RecordingAudioStems {
    private struct Manifest: Codable { var version = 1; var names: [String] }
    static let supportedNames = ["system", "microphone"]
    static func url(for movie: URL, name: String) -> URL { movie.deletingPathExtension().appendingPathExtension("\(name).m4a") }
    static func manifestURL(for movie: URL) -> URL { movie.deletingPathExtension().appendingPathExtension("audio.json") }
    /// The marker is committed last. An incomplete publish, deleted stem or legacy
    /// partial recording must use the MP4's mixed audio, never the surviving stem alone.
    static func names(for movie: URL) -> [String] {
        guard let data = try? Data(contentsOf: manifestURL(for: movie)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1,
              !manifest.names.isEmpty, Set(manifest.names).count == manifest.names.count,
              manifest.names.allSatisfy({ supportedNames.contains($0) && isFile(url(for: movie, name: $0)) }) else { return [] }
        return manifest.names
    }
    static func validatedNames(for movie: URL) async -> [String] {
        let names = names(for: movie)
        for name in names {
            guard await isReadable(url(for: movie, name: name)) else { return [] }
        }
        return names
    }
    private static func isFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
    private static func isReadable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first,
              let range = try? await track.load(.timeRange), range.duration.seconds.isFinite, range.duration.seconds > 0 else { return false }
        return true
    }
    static func discard(for movie: URL) {
        // Invalidate the marker first; stale orphan stems can never replace mixed audio.
        for file in [manifestURL(for: movie)] + supportedNames.map({ url(for: movie, name: $0) }) where isFile(file) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    static func join(segments: [URL], to movie: URL, expectedNames: [String]? = nil) async throws {
        discard(for: movie)
        let requested = expectedNames ?? supportedNames.filter { name in segments.contains { isFile(url(for: $0, name: name)) } }
        guard !requested.isEmpty else { return }
        guard requested.allSatisfy(supportedNames.contains), Set(requested).count == requested.count else {
            throw PluginError.invalid("独立音轨配置无效，使用原录屏声音。")
        }
        // Validate the full source set before writing any final stem. Missing silence-only
        // stems also choose mixed audio conservatively; they are not assumed to be silence.
        for segment in segments {
            for name in requested where !(await isReadable(url(for: segment, name: name))) {
                throw PluginError.invalid("独立音轨不完整，使用原录屏声音。")
            }
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            for name in requested {
                let composition = AVMutableComposition()
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw PluginError.invalid("无法创建独立音轨。")
                }
                var cursor = CMTime.zero
                var sources: [AVAsset] = []
                defer { withExtendedLifetime(sources) {} }
                for segment in segments {
                    let duration = try await AVURLAsset(url: segment).load(.duration)
                    let asset = AVURLAsset(url: url(for: segment, name: name)); sources.append(asset)
                    guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw PluginError.invalid("录屏独立音轨不可读。") }
                    let available = try await source.load(.timeRange)
                    let range = CMTimeRangeGetIntersection(available, otherRange: CMTimeRange(start: .zero, duration: duration))
                    guard range.duration.seconds > 0 else { throw PluginError.invalid("录屏独立音轨没有有效声音。") }
                    try track.insertTimeRange(range, of: source, at: CMTimeAdd(cursor, range.start))
                    cursor = CMTimeAdd(cursor, duration)
                }
                guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw PluginError.invalid("无法导出独立音轨。") }
                if composition.duration < cursor { composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: CMTimeSubtract(cursor, composition.duration))) }
                let staged = staging.appendingPathComponent("\(name).m4a")
                if #available(macOS 15, *) { try await exporter.export(to: staged, as: .m4a) }
                else {
                    exporter.outputURL = staged; exporter.outputFileType = .m4a; await exporter.export()
                    guard exporter.status == .completed else { throw exporter.error ?? PluginError.invalid("音轨导出失败。") }
                }
            }
            for name in requested {
                try Data(contentsOf: staging.appendingPathComponent("\(name).m4a"), options: .mappedIfSafe).write(to: url(for: movie, name: name), options: .atomic)
            }
            try JSONEncoder().encode(Manifest(names: requested)).write(to: manifestURL(for: movie), options: .atomic)
        } catch {
            discard(for: movie)
            throw error
        }
    }
}
