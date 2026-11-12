import AppKit
@preconcurrency import AVFoundation
import ImageIO
import Testing
@testable import TietiezhiTools

@Suite(.serialized) @MainActor
struct CaptureRecordingTests {
    @Test func recordingExportRejectsInvalidCropAndSpeed() throws {
        var options = RecordingEditOptions()
        options.speed = 0
        #expect(throws: (any Error).self) { try options.validated() }
        options.speed = 1; options.crop = CGRect(x: 0.9, y: 0, width: 0.5, height: 1)
        #expect(throws: (any Error).self) { try options.validated() }
    }

    @Test func realVideoTrimCropSpeedGIFAndSegmentJoin() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await makeVideo(at: source)
        let originalDuration = try await AVURLAsset(url: source).load(.duration).seconds
        #expect(originalDuration > 1.8)
        let joined = folder.appendingPathComponent("joined.mp4")
        try await RecordingExporter.join([source, source], to: joined)
        let joinedDuration = try await AVURLAsset(url: joined).load(.duration).seconds
        #expect(abs(joinedDuration - 2 * originalDuration) < 0.05)
        var options = RecordingEditOptions()
        options.speed = 2; options.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1); options.fps = 5
        let movie = folder.appendingPathComponent("crop.mp4")
        try await RecordingExporter.movie(from: source, to: movie, start: 0, end: originalDuration, options: options)
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(duration - originalDuration / 2) < 0.15)
        #expect(size.width == 64 && size.height == 96)
        let gif = folder.appendingPathComponent("crop.gif")
        try await RecordingExporter.animation(from: source, to: gif, start: 0, end: originalDuration, options: options, webP: false)
        let image = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(image) == Int(ceil(originalDuration / 2 * 5)))
        let frame = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        #expect(frame.width == 64 && frame.height == 96)
        // The selected right half of the source must remain blue after the AV transform.
        let sample = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(sample.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[2] > 200 && bytes[0] < 50)
        if RecordingExporter.webPEncoder != nil {
            let webp = folder.appendingPathComponent("crop.webp")
            try await RecordingExporter.animation(from: source, to: webp, start: 0, end: originalDuration, options: options, webP: true)
            let data = try Data(contentsOf: webp)
            #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
            #expect(String(decoding: data[8..<12], as: UTF8.self) == "WEBP")
        }
    }
    @Test func editableEventEffectsAndCroppedGeometryUseRealVideoFrames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-effects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await makeVideo(at: source, quadrants: true)
        let archive = RecordingEventArchive(events: [
            .init(time: 0.05, kind: .pointer, x: 0.7, y: 0.3, label: ""),
            .init(time: 0.1, kind: .key, x: 0, y: 0, label: "⌘C"),
            .init(time: 0.15, kind: .leftClick, x: 0.7, y: 0.3, label: "")])
        try archive.save(for: source)
        #expect(RecordingEventArchive.read(for: source)?.events == archive.events)
        var options = RecordingEditOptions()
        let enabled = try await frame(source, options: options)
        options.effects.cursor = false; options.effects.clicks = false; options.effects.keys = false
        let disabled = try await frame(source, options: options)
        #expect(try CaptureImage.png(enabled) != CaptureImage.png(disabled))
        options.crop = CGRect(x: 0, y: 0.75, width: 1, height: 0.25)
        let cropped = try await frame(source, options: options)
        #expect(cropped.width == 128 && cropped.height == 24)
        let color = try #require(NSBitmapImageRep(cgImage: cropped).colorAt(x: 20, y: 12)?.usingColorSpace(.deviceRGB))
        let raw = try await AVAssetImageGenerator(asset: AVURLAsset(url: source)).image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let reference = try #require(NSBitmapImageRep(cgImage: raw).colorAt(x: 20, y: 90)?.usingColorSpace(.deviceRGB))
        #expect(abs(color.greenComponent - reference.greenComponent) < 0.03)
        #expect(abs(color.redComponent - reference.redComponent) < 0.03)
        #expect(color.greenComponent > 0.8 && color.blueComponent < 0.2)
        // Exercise the same effects composition through actual MP4 export, not only AVAssetImageGenerator.
        options.crop = CGRect(x: 0, y: 0, width: 1, height: 1); options.effects.keys = true
        let exported = folder.appendingPathComponent("effects.mp4")
        try await RecordingExporter.movie(from: source, to: exported, start: 0, end: 1, options: options)
        #expect(try await AVURLAsset(url: exported).load(.duration).seconds > 0.9)
    }
    @Test func recoveryAndIndependentAudioStems() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = folder.appendingPathComponent(".recording-test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        var manifest = RecordingRecoveryManifest(targetFilename: "recovered.mp4", expectedAudioNames: ["system", "microphone"]); manifest.ownerPID = 0
        try manifest.save(in: session)
        let source = session.appendingPathComponent("0.mp4")
        try await makeVideo(at: source)
        try makeAudio(at: RecordingAudioStems.url(for: source, name: "system"), frequency: 440)
        try makeAudio(at: RecordingAudioStems.url(for: source, name: "microphone"), frequency: 880)
        let candidates = CaptureRecordingRecovery.list(in: folder)
        #expect(candidates.count == 1)
        let recovered = try await CaptureRecordingRecovery.recover(#require(candidates.first))
        #expect(CaptureRecordingRecovery.list(in: folder).isEmpty)
        #expect(Set(RecordingAudioStems.names(for: recovered)) == ["system", "microphone"])
        var options = RecordingEditOptions(); options.systemVolume = 0; options.microphoneVolume = 0.5
        let prepared = try await RecordingExporter.prepare(from: recovered, start: 0, end: 1.9, options: options)
        #expect(prepared.audio.inputParameters.count == 2)
        var volumes: [Float] = []
        for parameters in prepared.audio.inputParameters {
            var start: Float = -1, end: Float = -1, range = CMTimeRange.zero
            #expect(parameters.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
            volumes.append(start)
        }
        #expect(volumes.sorted() == [0, 0.5])
    }
    @Test func incompleteStemsFallBackToMixedAudioForTheWholeRecording() async throws {
        let folder = try temporaryFolder("recording-stem-fallback")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = folder.appendingPathComponent(".recording-session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let first = session.appendingPathComponent("0.mp4"), second = session.appendingPathComponent("1.mp4")
        try await makeMixedVideo(at: first)
        try FileManager.default.copyItem(at: first, to: second)
        // The first segment lost both optional stems, but its MP4 still has sound.
        for name in RecordingAudioStems.supportedNames { try makeAudio(at: RecordingAudioStems.url(for: second, name: name), frequency: 440) }
        let destination = folder.appendingPathComponent("saved.mp4")
        let result = try await RecordingFinalization.finish(in: session, to: destination, expectedAudioNames: ["system", "microphone"]) {}
        #expect(result.retainedSource && result.warning != nil)
        #expect(RecordingAudioStems.names(for: destination).isEmpty)
        let prepared = try await RecordingExporter.prepare(from: destination, start: 0, end: 4, options: .init())
        let tracks = try await prepared.asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let audio = try #require(tracks.first)
        #expect(try await audio.load(.timeRange).duration.seconds > 3.9)
        #expect(prepared.audio.inputParameters.count == 1)
    }
    @Test func deletingOrCorruptingOnePublishedStemRestoresBothMixedSources() async throws {
        let folder = try temporaryFolder("recording-stem-invalidated")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4"), destination = folder.appendingPathComponent("saved.mp4")
        try await makeMixedVideo(at: source)
        try FileManager.default.copyItem(at: source, to: destination)
        for name in RecordingAudioStems.supportedNames { try makeAudio(at: RecordingAudioStems.url(for: source, name: name), frequency: 440) }
        try await RecordingAudioStems.join(segments: [source], to: destination, expectedNames: ["system", "microphone"])
        #expect(await RecordingAudioStems.validatedNames(for: destination).count == 2)
        let mic = RecordingAudioStems.url(for: destination, name: "microphone")
        try FileManager.default.removeItem(at: mic)
        #expect(RecordingAudioStems.names(for: destination).isEmpty)
        var prepared = try await RecordingExporter.prepare(from: destination, start: 0, end: 1.9, options: .init())
        #expect(prepared.audio.inputParameters.count == 1)
        try Data("incomplete AAC file".utf8).write(to: mic)
        #expect(await RecordingAudioStems.validatedNames(for: destination).isEmpty)
        prepared = try await RecordingExporter.prepare(from: destination, start: 0, end: 1.9, options: .init())
        #expect(prepared.audio.inputParameters.count == 1)
    }
    @Test func optionalSidecarWriteFailuresKeepTheMovieAndSourceArchive() async throws {
        let folder = try temporaryFolder("recording-sidecar-failure")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = folder.appendingPathComponent(".recording-session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let source = session.appendingPathComponent("0.mp4"), destination = folder.appendingPathComponent("saved.mp4")
        try await makeMixedVideo(at: source)
        for name in RecordingAudioStems.supportedNames { try makeAudio(at: RecordingAudioStems.url(for: source, name: name), frequency: 440) }
        // Real filesystem failures, not an assertion-only mock: a directory blocks each sidecar destination.
        let blockedStem = RecordingAudioStems.url(for: destination, name: "microphone")
        let blockedEvents = RecordingEventArchive.url(for: destination)
        try FileManager.default.createDirectory(at: blockedStem, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blockedEvents, withIntermediateDirectories: true)
        let result = try await RecordingFinalization.finish(in: session, to: destination, expectedAudioNames: ["system", "microphone"]) {
            try RecordingEventArchive().save(for: destination)
        }
        #expect(result.retainedSource && result.warning != nil)
        #expect(try await AVURLAsset(url: result.url).load(.duration).seconds > 1.9)
        #expect(FileManager.default.fileExists(atPath: source.path))
        // System stem may have published before microphone failed, but rollback must remove it and its marker.
        #expect(!FileManager.default.fileExists(atPath: RecordingAudioStems.url(for: destination, name: "system").path))
        #expect(!FileManager.default.fileExists(atPath: RecordingAudioStems.manifestURL(for: destination).path))
        let prepared = try await RecordingExporter.prepare(from: destination, start: 0, end: 1.9, options: .init())
        #expect(prepared.audio.inputParameters.count == 1)
    }
    @Test func unfinishedPendingSegmentIsPreservedAndReadableUnindexedSegmentIsRecovered() async throws {
        let folder = try temporaryFolder("recording-pending-segment")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = folder.appendingPathComponent(".recording-session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        var manifest = RecordingRecoveryManifest(targetFilename: "recovered.mp4", expectedAudioNames: []); manifest.ownerPID = 0
        try manifest.save(in: session)
        let source = session.appendingPathComponent("0.mp4")
        try await makeVideo(at: source)
        // Segment 1 is playable even though the native completion callback never indexed it.
        try FileManager.default.copyItem(at: source, to: session.appendingPathComponent("1.mp4"))
        let pending = session.appendingPathComponent("2.mp4")
        try Data("unfinished native movie".utf8).write(to: pending)
        #expect(RecordingFinalization.nextSegmentURL(in: session).lastPathComponent == "3.mp4")
        let candidate = try #require(CaptureRecordingRecovery.list(in: folder).first)
        let result = try await CaptureRecordingRecovery.recoverWithResult(candidate)
        #expect(try await AVURLAsset(url: result.url).load(.duration).seconds > 3.9)
        #expect(result.retainedSource && result.warning != nil)
        #expect(try Data(contentsOf: pending) == Data("unfinished native movie".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
    private func temporaryFolder(_ prefix: String) throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func makeMixedVideo(at destination: URL) async throws {
        let video = destination.deletingPathExtension().appendingPathExtension("source.mp4")
        let audio = destination.deletingPathExtension().appendingPathExtension("source.m4a")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: audio) }
        try await makeVideo(at: video); try makeAudio(at: audio, frequency: 660)
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        defer { withExtendedLifetime([videoAsset, audioAsset]) {} }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)).insertTimeRange(range, of: videoTrack, at: .zero)
        try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)).insertTimeRange(range, of: audioTrack, at: .zero)
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        if #available(macOS 15, *) { try await exporter.export(to: destination, as: .mp4) }
        else { exporter.outputURL = destination; exporter.outputFileType = .mp4; await exporter.export(); #expect(exporter.status == .completed) }
    }
    private func frame(_ source: URL, options: RecordingEditOptions) async throws -> CGImage {
        let prepared = try await RecordingExporter.prepare(from: source, start: 0, end: 1, options: options)
        let generator = AVAssetImageGenerator(asset: prepared.asset); generator.videoComposition = prepared.video
        generator.requestedTimeToleranceAfter = .zero; generator.requestedTimeToleranceBefore = .zero
        return try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
    }
    private func makeAudio(at url: URL, frequency: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        let channel = try #require(buffer.floatChannelData)[0]
        for i in 0..<96000 { channel[i] = Float(sin(Double(i) / 48000 * frequency * 2 * .pi) * 0.2) }
        try file.write(from: buffer)
    }
    private func makeVideo(at url: URL, quadrants: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PluginError.invalid("测试视频编码失败。") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 128, 96, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
            context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 64, y: 0, width: 64, height: 96))
            if quadrants { context.setFillColor(NSColor.green.cgColor); context.fill(CGRect(x: 0, y: 0, width: 128, height: 24)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished(); await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
