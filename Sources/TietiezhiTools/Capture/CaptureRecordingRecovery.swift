import AppKit
@preconcurrency import AVFoundation
import Darwin
import SwiftUI

struct RecordingRecoveryManifest: Codable {
    var version = 1
    var targetFilename: String
    var expectedAudioNames: [String]? = nil
    var created = Date()
    var ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier
    func save(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}
struct RecoverableRecording: Identifiable {
    var id: URL { directory }
    let directory: URL
    let date: Date
    let targetFilename: String
    let segments: [URL]
    let expectedAudioNames: [String]?
}
@MainActor enum CaptureRecordingRecovery {
    static func list(in directory: URL) -> [RecoverableRecording] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [])) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(".recording-") }.compactMap { folder in
            let manifest = (try? Data(contentsOf: folder.appendingPathComponent("session.json"))).flatMap { try? JSONDecoder().decode(RecordingRecoveryManifest.self, from: $0) }
            // Do not offer a live recorder's working files for recovery.
            if let pid = manifest?.ownerPID, pid > 0, Darwin.kill(pid, 0) == 0 { return nil }
            let files = RecordingFinalization.segmentFiles(in: folder)
            guard !files.isEmpty else { return nil }
            let target = manifest?.targetFilename ?? "恢复录屏-\(UUID().uuidString).mp4"
            guard URL(fileURLWithPath: target).lastPathComponent == target, target.hasSuffix(".mp4") else { return nil }
            let date = manifest?.created ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return RecoverableRecording(directory: folder, date: date, targetFilename: target, segments: files, expectedAudioNames: manifest?.expectedAudioNames)
        }.sorted { $0.date > $1.date }
    }
    static func recover(_ item: RecoverableRecording) async throws -> URL {
        try await recoverWithResult(item).url
    }
    static func recoverWithResult(_ item: RecoverableRecording) async throws -> RecordingFinalization.Result {
        var destination = item.directory.deletingLastPathComponent().appendingPathComponent(item.targetFilename)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = item.directory.deletingLastPathComponent().appendingPathComponent("恢复录屏-\(UUID().uuidString).mp4")
        }
        return try await RecordingFinalization.finish(in: item.directory, to: destination, expectedAudioNames: item.expectedAudioNames) {
            let checkpoint = item.directory.appendingPathComponent("events.json")
            if FileManager.default.fileExists(atPath: checkpoint.path) {
                try Data(contentsOf: checkpoint).write(to: RecordingEventArchive.url(for: destination), options: .atomic)
            }
        }
    }
}

/// Both a normal stop and crash recovery share the same durable finalization.
/// The native movie is the primary result; optional sidecars never invalidate it.
@MainActor enum RecordingFinalization {
    struct Result { let url: URL; let warning: String?; let retainedSource: Bool }
    static func segmentFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mp4" && Int($0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { (Int($0.deletingPathExtension().lastPathComponent) ?? 0) < (Int($1.deletingPathExtension().lastPathComponent) ?? 0) }
    }
    static func nextSegmentURL(in directory: URL) -> URL {
        let last = segmentFiles(in: directory).compactMap { Int($0.deletingPathExtension().lastPathComponent) }.max() ?? -1
        return directory.appendingPathComponent("\(last + 1).mp4")
    }
    static func finish(in directory: URL, to destination: URL, expectedAudioNames: [String]?,
                       writeEvents: () throws -> Void) async throws -> Result {
        // Enumerate disk instead of just the recorder's success list. A delegate may
        // report failure after a playable final segment has already reached disk.
        let all = segmentFiles(in: directory)
        var valid: [URL] = []
        for segment in all {
            let asset = AVURLAsset(url: segment)
            if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
               let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty { valid.append(segment) }
        }
        guard !valid.isEmpty else { throw PluginError.invalid("未找到已完成的录屏片段；原始片段已保留供恢复。") }
        try await RecordingExporter.join(valid, to: destination)
        var warnings: [String] = []
        if valid.count != all.count { warnings.append("部分片段尚未写完，已保存可播放部分") }
        do { try await RecordingAudioStems.join(segments: valid, to: destination, expectedNames: expectedAudioNames) }
        catch { RecordingAudioStems.discard(for: destination); warnings.append("独立音轨未能保存，使用原录屏声音") }
        do { try writeEvents() }
        catch { warnings.append("键鼠效果未能保存") }
        // Any missing segment or failed optional write keeps the whole source archive.
        // Cleanup failure must not turn an otherwise successful recording into an error.
        if warnings.isEmpty {
            do { try FileManager.default.removeItem(at: directory) }
            catch { warnings.append("录屏已保存，临时原件未能清理") }
        }
        let retained = FileManager.default.fileExists(atPath: directory.path)
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: "；") + (retained ? "；原始片段已保留。" : "。")
        return Result(url: destination, warning: warning, retainedSource: retained)
    }
}

struct RecordingRecoveryView: View {
    let directory: URL
    let recovered: (URL) -> Void
    @ViewState private var recordings: [RecoverableRecording] = []
    @ViewState private var working: URL?
    @ViewState private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recordings.isEmpty { Text("没有中断的录屏").foregroundStyle(.secondary) }
            else {
                Text("恢复中断前已完成的片段。最后一段尚未写完时可能无法恢复。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(recordings) { recording in
                    HStack {
                        Text(recording.date, style: .date)
                        Text(recording.date, style: .time)
                        Text("\(recording.segments.count) 个片段").foregroundStyle(.secondary)
                        Spacer()
                        if working == recording.id { ProgressView().controlSize(.small) }
                        Button("恢复") {
                            working = recording.id
                            Task { @MainActor in
                                defer { working = nil }
                                do {
                                    let result = try await CaptureRecordingRecovery.recoverWithResult(recording)
                                    recovered(result.url); message = result.warning ?? "已恢复录屏"
                                    recordings = CaptureRecordingRecovery.list(in: directory)
                                } catch { message = error.localizedDescription }
                            }
                        }.disabled(working != nil)
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.task { recordings = CaptureRecordingRecovery.list(in: directory) }
    }
}
