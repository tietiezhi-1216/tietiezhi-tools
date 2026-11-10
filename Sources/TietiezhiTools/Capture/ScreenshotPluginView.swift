import AppKit
import ImageIO
import SwiftUI

struct CaptureHistoryView: View {
    @EnvironmentObject private var store: PluginStore
    let pluginID: String
    @ObservedObject var capture: ScreenshotController
    @ViewState private var permission = CaptureService.permitted
    @Environment(\.scenePhase) private var phase
    private var enabled: Bool { store.installed.first { $0.id == pluginID }?.isEnabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !permission {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "display.trianglebadge.exclamationmark").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("截图和录屏需要屏幕录制权限").font(.callout.weight(.medium))
                        Text("导入图片、标注、OCR 和贴图可直接使用。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("授权…") {
                        CaptureService.requestPermission()
                        permission = CaptureService.permitted
                    }
                    Button("系统设置") { CaptureService.openPermissions() }
                }.padding(.horizontal, PanelLayout.contentInset)
            }
            if let notice = capture.notice {
                HStack {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        capture.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.plain)
                }.padding(.horizontal, PanelLayout.contentInset)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], alignment: .leading, spacing: 18) {
                    ForEach(capture.history) { record in
                        Button {
                            capture.open(record)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                CaptureThumbnail(
                                    url: capture.url(record), video: record.isVideo,
                                    revision: record.revision ?? record.id
                                )
                                .frame(height: 120).frame(maxWidth: .infinity)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                                HStack {
                                    Text(record.isVideo ? "录屏" : "\(record.width) × \(record.height)").font(.caption)
                                    Spacer()
                                    Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(!enabled)
                            .contextMenu {
                                Button("打开") { capture.open(record) }
                                Button("在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([capture.url(record)])
                                }
                                Button("移到废纸篓", role: .destructive) { capture.remove(record) }
                            }
                    }
                }.padding(.horizontal, PanelLayout.contentInset).padding(.vertical, 8)
            }
            .overlay {
                if capture.history.isEmpty {
                    ContentUnavailableView(
                        "开始你的第一张截图", systemImage: "camera.viewfinder",
                        description: Text("截取屏幕或导入图片，继续标注、贴图、识别与翻译。"))
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelRegion("capture.history")
            .onChange(of: phase) { _, _ in permission = CaptureService.permitted }
    }
}

struct CaptureStatusView: View {
    @ObservedObject var capture: ScreenshotController
    var body: some View {
        Text("\(capture.history.count) 项 · 仅保存在本机").font(.caption).foregroundStyle(.secondary)
    }
}

private struct CaptureThumbnail: View {
    let url: URL
    let video: Bool
    let revision: UUID
    @ViewState private var image: CGImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: NSImage(cgImage: image, size: .zero)).resizable().scaledToFit().padding(6)
            } else {
                Image(systemName: video ? "play.rectangle" : "photo").font(.system(size: 28)).foregroundStyle(
                    .secondary)
            }
        }
        .task(id: revision) {
            guard !video else { return }
            image = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
            }.value
        }
    }
}

struct ScreenshotSettingsView: View {
    @AppStorage("capture.systemAudio") private var systemAudio = false
    @AppStorage("capture.microphone") private var microphone = false
    @AppStorage("capture.cursor") private var cursor = true
    @AppStorage("capture.camera") private var camera = false
    @AppStorage("capture.keystrokes") private var keystrokes = false
    @AppStorage("capture.scrollAxis") private var axis = StitchAxis.vertical.rawValue
    @ViewState private var ai = CaptureAISettings.current
    @ViewState private var key = ""
    @ViewState private var message: String?
    var body: some View {
        Form {
            Section("滚动长截图") {
                Picker("快捷键默认方向", selection: $axis) {
                    ForEach(StitchAxis.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("选定区域后缓慢滚动；支持两个方向前进或回滚。自动滚动需在系统设置中开启辅助功能权限。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("自动滚动权限设置") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("录屏") {
                Toggle("录制系统音频", isOn: $systemAudio)
                Toggle("录制麦克风", isOn: $microphone)
                Toggle("显示鼠标和点击效果", isOn: $cursor)
                Toggle("摄像头画中画", isOn: $camera)
                Toggle("显示键盘按键", isOn: $keystrokes)
                Text("画中画需摄像头权限；按键显示需输入监控权限，仅在录屏期间启用，系统安全输入时暂停。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("录屏需要 macOS 15+；停止后可裁剪 MP4 或导出最长 3 分钟、10 帧/秒的 GIF。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("视觉模型（可选）") {
                TextField("HTTPS 接口", text: $ai.endpoint, prompt: Text("https://服务地址/v1/chat/completions"))
                TextField("视觉模型", text: $ai.model)
                SecureField("API 密钥", text: $key)
                Text("支持兼容 Chat Completions 的视觉模型。密钥存储在 macOS 钥匙串。只有你确认发送图片后才请求服务；本地 OCR、二维码和系统翻译不需要此配置。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("保存服务配置") {
                        do {
                            if !ai.endpoint.isEmpty, ai.url == nil {
                                throw PluginError.invalid("请填写有效的 HTTPS 接口和模型名称。")
                            }
                            try CaptureKeychain.save(key)
                            CaptureAISettings.current = ai
                            message = "已保存"
                        } catch { message = error.localizedDescription }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { key = CaptureKeychain.read() }
    }
}
