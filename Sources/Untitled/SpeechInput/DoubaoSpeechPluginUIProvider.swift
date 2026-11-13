import AppKit
import Combine
import SwiftUI

struct DoubaoSpeechPluginUIProvider: PluginUIProvider {
    @MainActor func register(in registry: PluginUIRegistry) {
        registry.component("doubao.dictation", requiredActions: [.toggleDoubaoDictation]) { context in
            AnyView(DoubaoDictationView(controller: context.store.doubaoDictation(for: context.pluginID)))
        }
        registry.component("doubao.preferences", requiredActions: [.toggleDoubaoDictation]) { context in
            AnyView(DoubaoDictationPreferencesView(controller: context.store.doubaoDictation(for: context.pluginID)))
        }
        registry.command("doubao.toggle", requiredActions: [.toggleDoubaoDictation], presentation: { context in
            let controller = context.store.doubaoDictation(for: context.pluginID)
            return .init(title: controller.isBusy ? "结束听写" : "开始听写", symbol: controller.isBusy ? "stop.circle" : "mic",
                         isEnabled: controller.phase != .finishing)
        }, updates: { $0.store.doubaoDictation(for: $0.pluginID).objectWillChange.eraseToAnyPublisher() }) { context in
            try context.store.performDictationAction(.toggleDoubaoDictation, pluginID: context.pluginID)
        }
        registry.command("doubao.cancel", requiredActions: [.cancelDoubaoDictation], presentation: { context in
            .init(title: "取消听写", symbol: "xmark.circle", isEnabled: context.store.doubaoDictation(for: context.pluginID).isBusy)
        }, updates: { $0.store.doubaoDictation(for: $0.pluginID).objectWillChange.eraseToAnyPublisher() }) { context in
            try context.store.performDictationAction(.cancelDoubaoDictation, pluginID: context.pluginID)
        }
    }
}

private struct DoubaoDictationView: View {
    @ObservedObject var controller: DoubaoDictationController
    @EnvironmentObject private var store: PluginStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: "waveform.and.mic").font(.system(size: 28, weight: .light))
                        .frame(width: 60, height: 60).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(controller.phase.title).font(.title3.weight(.semibold))
                        Text(controller.realtimeInputAvailable && controller.preferences.liveInput ? "豆包实时输入，结束后用最终结果修正本次听写。" : "当前为预览；开启实验性实时输入后可自行测试上屏。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(controller.isBusy ? "结束听写" : "试音（仅预览）") {
                        do { try controller.toggle(previewOnly: true) } catch { store.handleExecutionError(error) }
                    }.disabled(controller.phase == .finishing).buttonStyle(.borderedProminent)
                    if controller.isBusy { Button("取消") { controller.cancel() } }
                }
                if !controller.realtimeInputVerified {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("实验性实时输入（自行测试）", isOn: Binding(get: { controller.preferences.experimentalRealtimeInput }, set: { enabled in
                            do { try controller.setExperimentalRealtimeInput(enabled) } catch { store.handleExecutionError(error) }
                        })).disabled(controller.isBusy)
                        Label("尚未完成端到端验收。开启后先点回目标输入框，再按听写快捷键；遇到回读或焦点异常会停止写入。", systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(controller.realtimeInputAvailable ? "在目标应用的输入框中使用快捷键" : "开启实验性实时输入后使用快捷键", systemImage: "keyboard")
                        .font(.callout.weight(.medium))
                    Text(controller.realtimeInputAvailable ? "支持按一下开始 / 再按一下结束，以及按住说话 / 松开结束。快捷键可在右上角修改；黑白浮条不会抢走输入焦点。" : "原有快捷键与设置已保留。未开启自测开关时实时模式会在录音前明确拒绝；上方试音按钮始终仅预览。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(controller.realtimeInputAvailable ? "切换窗口、移动光标或手动编辑会停止自动写入。失败后可在这里复制识别文字；不会反复重发、盲目退格或整框重写。微信独立接口尚未接通。" : "仅预览模式的识别结果可手动复制。实验开关只允许自行测试，不代表兼容性已验收；微信独立接口尚未接通。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                DictationMicrophoneSettings(controller: controller)
                    .padding(18).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                if let audio = controller.audioDiagnostics {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本次采集诊断").font(.callout.weight(.medium))
                        Text("实际输入：\(audio.inputName)").font(.caption)
                        Text("采集 \(audio.capturedBytes) 字节 · 回调 \(audio.callbacks) 次 · ASR 更新 \(controller.recognitionUpdates) 次")
                            .font(.caption.monospacedDigit())
                        Text(audio.peakDBFS.map { String(format: "音量峰值 %.1f dBFS · 发送格式 %.0f Hz 单声道 PCM16", $0, audio.sampleRate) } ?? "尚无非零音量信号")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(controller.isBusy ? "本次识别" : "最近一次").font(.headline)
                        Spacer()
                        Button("复制文字") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(controller.resultText, forType: .string)
                        }.disabled(controller.resultText.isEmpty)
                        Button("清除") { controller.clearResult() }.disabled(controller.isBusy || controller.resultText.isEmpty)
                    }
                    if controller.resultText.isEmpty {
                        Text("识别文字会显示在这里，仅保留在本次应用内存中。")
                            .foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    } else {
                        Text(controller.resultText).textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    }
                    if controller.isBusy {
                        Text(controller.isPreviewing ? "仅预览，不写入其他应用" : "已确认上屏 \(controller.acknowledgedTextLength) 个 UTF-16 字符")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !controller.notice.isEmpty {
                        Text(controller.notice).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(18).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                Label("仅在主动听写时将音频发送给豆包；无需账号或密钥。非官方网页接口可能变更。", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 12)
        }
    }
}

private struct DoubaoDictationPreferencesView: View {
    @ObservedObject var controller: DoubaoDictationController
    @EnvironmentObject private var store: PluginStore
    var body: some View {
        Form {
            Section("输入") {
                if !controller.realtimeInputVerified {
                    Toggle("实验性实时输入（自行测试）", isOn: Binding(get: { controller.preferences.experimentalRealtimeInput }, set: { enabled in
                        do { try controller.setExperimentalRealtimeInput(enabled) } catch { store.handleExecutionError(error) }
                    }))
                    Text("自测开关默认关闭，升级不自动开启。开启后仍需正常权限；遇到焦点或回读异常停止，不代表所有编辑器已兼容。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("实时输入当前应用", isOn: Binding(get: { controller.preferences.liveInput }, set: { value in
                    var settings = controller.preferences; settings.liveInput = value; save(settings)
                })).disabled(!controller.realtimeInputAvailable)
                Text(controller.realtimeInputAvailable ? "关闭后只在插件面板预览，不需要辅助功能权限。开启选项不申请权限，实际听写时由宿主检查。" : "先开启上方自测开关才能尝试实时上屏；原偏好保留。试音仅预览，无需辅助功能权限，普通实时热键不会开始录音。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("麦克风") { DictationMicrophoneSettings(controller: controller) }
            Section("录音预算") {
                Picker("单次最长", selection: Binding(get: { controller.preferences.maximumSeconds }, set: { value in
                    var settings = controller.preferences; settings.maximumSeconds = value; save(settings)
                })) {
                    Text("30 秒").tag(30); Text("1 分钟").tag(60)
                    Text("3 分钟").tag(180); Text("5 分钟").tag(300)
                }
                Text("到达上限自动停止录音并等待最终结果；连接中暂存最多 10 秒开头语音；就绪后网络积压超过 2 秒时停止，不静默丢弃音频。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("最终整理") {
                Label("豆包双通道 ASR", systemImage: "text.badge.checkmark")
                Text("当前实时通道返回的草稿通常不带标点；按结束键并等待定稿后，才用最终文字校正标点和数字。不要在定稿前直接发送；插件不会改写已发送的内容。不保证去口头语或改写，不调用额外大模型。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("隐私与停止") {
                Text("不保存录音、游客标识或转写历史，不读取浏览器资料。取消、停用、卸载或退出会停止麦克风并关闭连接。已写入的文字不会被撤回，最近文字可手动清除。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(controller.isBusy)
    }
    private func save(_ settings: DictationPreferences) {
        do { try controller.savePreferences(settings) } catch { store.handleExecutionError(error) }
    }
}

private struct DictationMicrophoneSettings: View {
    @ObservedObject var controller: DoubaoDictationController
    @EnvironmentObject private var store: PluginStore
    @ViewState private var devices: [DictationInputDevice] = []
    @ViewState private var defaultName = "未发现输入设备"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("麦克风", selection: Binding(get: { controller.preferences.inputDeviceUID ?? "" }, set: { value in
                    var settings = controller.preferences
                    settings.inputDeviceUID = value.isEmpty ? nil : value
                    do { try controller.savePreferences(settings) } catch { store.handleExecutionError(error) }
                })) {
                    Text("系统默认 · " + defaultName).tag("")
                    ForEach(devices) { device in
                        Text(device.name + (device.isVirtual ? "（虚拟/聚合）" : "")).tag(device.id)
                    }
                    if let selected = controller.preferences.inputDeviceUID, !devices.contains(where: { $0.id == selected }) {
                        Text("已断开的设备（请重新选择）").tag(selected)
                    }
                }
                Button("刷新设备") { refresh() }
            }.disabled(controller.isBusy)
            Text("仅选择本插件使用的输入，不更改系统默认设备。声音来自运行 Untitled 的这台 Mac，不会自动使用手机或另一台 Mac 的麦克风。")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { refresh() }
    }
    private func refresh() {
        let value = DictationInputDevices.snapshot()
        devices = value.devices
        defaultName = value.devices.first(where: { $0.id == value.defaultUID })?.name ?? "不可用，请选择其他设备"
    }
}
