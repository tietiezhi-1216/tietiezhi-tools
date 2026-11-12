import AppKit
@preconcurrency import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordingPreferencesView: View {
    @AppStorage("capture.recordingFPS") private var fps = 30
    @AppStorage("capture.recordingMaximumEdge") private var edge = 4096
    @AppStorage("capture.cameraDevice") private var device = ""
    @AppStorage("capture.cameraCircle") private var circle = false
    @AppStorage("capture.cameraMirror") private var mirror = true
    @AppStorage("capture.recordingDelay") private var delay = 0
    @AppStorage("capture.secondCamera") private var secondCamera = false
    @AppStorage("capture.secondCameraDevice") private var secondDevice = ""
    @ViewState private var devices: [AVCaptureDevice] = []
    var body: some View {
        Picker("录制帧率", selection: $fps) { ForEach([5, 16, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) } }
        Picker("录制倒计时", selection: $delay) {
            Text("无延时").tag(0)
            ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) 秒").tag($0) }
        }
        Picker("最长边", selection: $edge) { ForEach([1280, 1920, 2560, 4096], id: \.self) { Text("\($0) px").tag($0) } }
        Picker("摄像头设备", selection: $device) {
            Text("系统默认").tag("")
            ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
        }.task { devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices }
        Toggle("圆形画中画", isOn: $circle)
        Toggle("镜像摄像头画面", isOn: $mirror)
        Toggle("第二个摄像头", isOn: $secondCamera)
        if secondCamera {
            Picker("第二摄像头设备", selection: $secondDevice) {
                Text("请选择").tag("")
                ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
        }
    }
}

struct RecordingReviewView: View {
    let url: URL
    @ViewState private var player: AVPlayer?
    @ViewState private var duration = 1.0
    @ViewState private var start = 0.0
    @ViewState private var end = 1.0
    @ViewState private var options = RecordingEditOptions()
    @ViewState private var sourceAspect = 16.0 / 9
    @ViewState private var displayAspect = 16.0 / 9
    @ViewState private var busy = false
    @ViewState private var status = ""
    @ViewState private var cropMode = false
    @ViewState private var dragStart: CGPoint?
    @ViewState private var work: Task<Void, Never>?
    @ViewState private var format = "mp4"
    @ViewState private var audioStems: [String] = []
    @ViewState private var hasEvents = false
    var body: some View {
        VStack(spacing: 12) {
            NativeCaptureVideoPlayer(player: player)
                .aspectRatio(displayAspect, contentMode: .fit)
                .overlay {
                    if cropMode { GeometryReader { geometry in cropOverlay(size: geometry.size) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("起点").frame(width: 30)
                Slider(value: $start, in: 0...max(0.01, duration - 0.01))
                    .onChange(of: start) { _, value in if end <= value { end = min(duration, value + 0.01) } }
                Text("\(start, specifier: "%.2f") s").monospacedDigit().frame(width: 70)
                Text("终点").frame(width: 30)
                Slider(value: $end, in: 0.01...max(0.01, duration))
                    .onChange(of: end) { _, value in if start >= value { start = max(0, value - 0.01) } }
                Text("\(end, specifier: "%.2f") s").monospacedDigit().frame(width: 70)
            }
            HStack(spacing: 16) {
                Picker("倍速", selection: $options.speed) {
                    ForEach([0.2, 0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                }.frame(width: 150)
                if audioStems.isEmpty {
                    Text("音量")
                    Slider(value: $options.volume, in: 0...2).frame(width: 100)
                    Text("\(Int(options.volume * 100))%").monospacedDigit().frame(width: 42)
                }
                Spacer()
                Toggle("裁剪画面", isOn: $cropMode).toggleStyle(.button)
                    .onChange(of: cropMode) { _, value in if value { showOriginal() } }
                Button("恢复完整画面") { options.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Button("预览选段") { preview() }
            }.controlSize(.small)
            if !audioStems.isEmpty {
                HStack {
                    if audioStems.contains("system") {
                        Text("系统音频"); Slider(value: $options.systemVolume, in: 0...2).frame(width: 140)
                        Text("\(Int(options.systemVolume * 100))%").monospacedDigit().frame(width: 45)
                    }
                    if audioStems.contains("microphone") {
                        Text("麦克风"); Slider(value: $options.microphoneVolume, in: 0...2).frame(width: 140)
                        Text("\(Int(options.microphoneVolume * 100))%").monospacedDigit().frame(width: 45)
                    }
                    Spacer()
                }.font(.caption)
            }
            if hasEvents { RecordingEffectsControls(options: $options.effects) }
            if cropMode {
                Text("在画面上拖出要保留的区域；预览与导出使用同一裁剪范围。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("格式", selection: $format) {
                    Text("MP4").tag("mp4"); Text("GIF").tag("gif")
                    if RecordingExporter.webPEncoder != nil { Text("WebP").tag("webp") }
                }.frame(width: 130)
                if format != "mp4" {
                    Picker("帧率", selection: $options.fps) {
                        ForEach([5, 10, 15, 20, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }.frame(width: 130)
                    Picker("尺寸", selection: $options.maximumEdge) {
                        ForEach([640, 960, 1280, 1920, 2560], id: \.self) { Text("\($0) px").tag($0) }
                    }.frame(width: 150)
                }
                if format != "gif" {
                    Picker("画质", selection: $options.quality) {
                        Text("轻量").tag(30.0); Text("标准").tag(60.0); Text("高").tag(90.0)
                    }.frame(width: 130)
                }
                Spacer()
                Text("导出 \((end - start) / options.speed, specifier: "%.1f") s").monospacedDigit().foregroundStyle(.secondary)
            }.controlSize(.small)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("导出…") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(minWidth: 760, minHeight: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(busy)
        .task {
            do {
                let asset = AVURLAsset(url: url)
                duration = max(0.01, try await asset.load(.duration).seconds); end = duration
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                    let oriented = CGRect(origin: .zero, size: size).applying(transform)
                    sourceAspect = oriented.width / max(1, oriented.height)
                }
                audioStems = await RecordingAudioStems.validatedNames(for: url)
                hasEvents = RecordingEventArchive.read(for: url)?.events.isEmpty == false
                options.quality = 90; showOriginal()
                if hasEvents { preview() }
            } catch { status = error.localizedDescription }
        }
        .onDisappear { player?.pause(); work?.cancel() }
    }
    private func cropOverlay(size: CGSize) -> some View {
        let crop = options.crop
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.2)
            Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .frame(width: crop.width * size.width, height: crop.height * size.height)
                .offset(x: crop.minX * size.width, y: crop.minY * size.height)
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let a = value.startLocation, b = value.location
                let x = max(0, min(1, min(a.x, b.x) / size.width)), y = max(0, min(1, min(a.y, b.y) / size.height))
                let maxX = max(0, min(1, max(a.x, b.x) / size.width)), maxY = max(0, min(1, max(a.y, b.y) / size.height))
                if maxX - x >= 0.02, maxY - y >= 0.02 { options.crop = CGRect(x: x, y: y, width: maxX - x, height: maxY - y) }
            })
    }
    private func showOriginal() {
        player?.pause(); player = AVPlayer(url: url); displayAspect = sourceAspect
        player?.seek(to: CMTime(seconds: start, preferredTimescale: 600))
    }
    private func preview() {
        work?.cancel(); busy = true; status = "正在准备预览…"
        work = Task { @MainActor in
            defer { busy = false }
            do {
                let prepared = try await RecordingExporter.prepare(from: url, start: start, end: end, options: options)
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: prepared.asset); item.videoComposition = prepared.video; item.audioMix = prepared.audio
                item.audioTimePitchAlgorithm = .timeDomain
                player?.pause(); player = AVPlayer(playerItem: item)
                displayAspect = prepared.video.renderSize.width / prepared.video.renderSize.height
                cropMode = false; player?.play(); status = "正在预览所选片段"
            } catch { status = error.localizedDescription }
        }
    }
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == "mp4" ? .mpeg4Movie : format == "gif" ? .gif : UTType(filenameExtension: "webp") ?? .image]
        panel.nameFieldStringValue = "录屏.\(format)"
        panel.begin { result in
            guard result == .OK, let target = panel.url else { return }
            player?.pause(); busy = true; status = "正在导出…"
            work = Task { @MainActor in
                defer { busy = false }
                do {
                    if format == "mp4" { try await RecordingExporter.movie(from: url, to: target, start: start, end: end, options: options) }
                    else { try await RecordingExporter.animation(from: url, to: target, start: start, end: end, options: options, webP: format == "webp") }
                    status = "已导出 \(target.lastPathComponent)"
                } catch { status = error.localizedDescription }
            }
        }
    }
}
