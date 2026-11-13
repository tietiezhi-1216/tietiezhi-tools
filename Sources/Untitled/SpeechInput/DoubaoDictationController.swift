import Combine
import Foundation

struct DictationPreferences: Codable, Equatable, Sendable {
    var liveInput: Bool
    var maximumSeconds: Int
    var experimentalRealtimeInput: Bool
    var inputDeviceUID: String?
    init(liveInput: Bool = true, maximumSeconds: Int = 180, experimentalRealtimeInput: Bool = false, inputDeviceUID: String? = nil) {
        self.liveInput = liveInput; self.maximumSeconds = maximumSeconds
        self.experimentalRealtimeInput = experimentalRealtimeInput; self.inputDeviceUID = inputDeviceUID
    }
    private enum CodingKeys: String, CodingKey { case liveInput, maximumSeconds, experimentalRealtimeInput, inputDeviceUID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        liveInput = try values.decodeIfPresent(Bool.self, forKey: .liveInput) ?? true
        maximumSeconds = try values.decodeIfPresent(Int.self, forKey: .maximumSeconds) ?? 180
        experimentalRealtimeInput = try values.decodeIfPresent(Bool.self, forKey: .experimentalRealtimeInput) ?? false
        inputDeviceUID = try values.decodeIfPresent(String.self, forKey: .inputDeviceUID)
    }
    func validate() throws {
        guard (30...DoubaoASRLimits.maximumSeconds).contains(maximumSeconds) else {
            throw PluginError.invalid("单次听写上限须为 30–300 秒。")
        }
        if let inputDeviceUID {
            guard !inputDeviceUID.isEmpty, inputDeviceUID.utf8.count <= 1024,
                  !inputDeviceUID.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw PluginError.invalid("麦克风选择无效，请重新选择输入设备。")
            }
        }
    }
}

enum DictationGesture: Equatable { case toggle, hold(UUID) }
enum DictationPhase: String { case idle, connecting, listening, finishing
    var title: String {
        switch self {
        case .idle: "准备就绪"
        case .connecting: "正在连接"
        case .listening: "正在聆听"
        case .finishing: "正在定稿"
        }
    }
}

@MainActor final class DoubaoDictationController: ObservableObject {
    static let pluginID = "com.untitled.doubao-speech-input"
    private static let previewNotice = "仅预览，不向当前应用写入文字。"
    static let realtimeInputUnavailable = "实时上屏尚未完成验收；如需自行测试，请在插件面板开启“实验性实时输入”，否则使用试音（仅预览）。"
    let realtimeInputVerified: Bool
    var realtimeInputAvailable: Bool { realtimeInputVerified || preferences.experimentalRealtimeInput }
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var lastResult = ""
    @Published private(set) var notice = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var seconds = 0
    @Published private(set) var acknowledgedTextLength = 0
    @Published private(set) var isPreviewing = false
    @Published private(set) var audioDiagnostics: DictationAudioDiagnostics?
    @Published private(set) var recognitionUpdates = 0
    @Published private(set) var preferences = DictationPreferences()
    var isBusy: Bool { phase != .idle }
    var resultText: String { transcript.isEmpty ? lastResult : transcript }
    var isAllowed: () -> Bool = { false }
    var requirePermissions: (Set<HostPermissionID>) throws -> Void = { _ in throw PluginError.invalid("听写权限客户端尚未绑定。") }
    private let preferencesURL: URL?
    private let makeSession: () -> any DoubaoSpeechSession
    private let makeMicrophone: () -> any DictationAudioSource
    private let makeTarget: () throws -> any DictationTextInserting
    private let showsHUD: Bool
    private var session: (any DoubaoSpeechSession)?
    private var microphone: (any DictationAudioSource)?
    private var target: (any DictationTextInserting)?
    private var hud: DictationHUD?
    private var task: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var textWriter: Task<Void, Never>?
    private var generation: UUID?
    private var gesture: DictationGesture?
    private var pendingWrite = false
    private var finalTextToWrite: String?
    private var lastWrite: TimeInterval = 0
    isolated deinit { releaseResources() }

    init(preferencesURL: URL? = nil, showsHUD: Bool = true, realtimeInputVerified: Bool = false,
         makeSession: @escaping () -> any DoubaoSpeechSession = { DoubaoASRClient() },
         makeMicrophone: @escaping () -> any DictationAudioSource = { DictationMicrophone() },
         makeTarget: @escaping () throws -> any DictationTextInserting = { try DictationTextTarget.capture() }) {
        self.preferencesURL = preferencesURL; self.showsHUD = showsHUD
        self.realtimeInputVerified = realtimeInputVerified
        self.makeSession = makeSession; self.makeMicrophone = makeMicrophone; self.makeTarget = makeTarget
        if let preferencesURL, FileManager.default.fileExists(atPath: preferencesURL.path) {
            do {
                let data = try Data(contentsOf: preferencesURL)
                guard data.count <= 4096 else { throw PluginError.invalid("听写设置文件过大。") }
                let value = try JSONDecoder().decode(DictationPreferences.self, from: data)
                try value.validate(); preferences = value
            } catch { notice = "听写设置无法读取，原文件已保留；可重新保存设置。" }
        }
    }

    func savePreferences(_ value: DictationPreferences) throws {
        guard !isBusy else { throw PluginError.invalid("请先结束听写，再修改设置。") }
        try value.validate()
        if let preferencesURL {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: preferencesURL, options: .atomic)
        }
        preferences = value
    }

    func setExperimentalRealtimeInput(_ enabled: Bool) throws {
        var value = preferences
        value.experimentalRealtimeInput = enabled
        if enabled { value.liveInput = true }
        try savePreferences(value)
    }

    func toggle(previewOnly: Bool = false) throws {
        if isBusy { stopRecording() }
        else { try start(.toggle, previewOnly: previewOnly) }
    }
    func holdPressed(_ commandID: UUID) throws {
        guard !isBusy else { return }
        try start(.hold(commandID))
    }
    func holdReleased(_ commandID: UUID) {
        guard gesture == .hold(commandID) else { return }
        stopRecording()
    }

    private func start(_ gesture: DictationGesture, previewOnly: Bool = false) throws {
        guard isAllowed() else { throw PluginError.invalid("请先启用豆信语音输入插件。") }
        let liveInput = preferences.liveInput && !previewOnly
        guard !liveInput || realtimeInputAvailable else {
            notice = Self.realtimeInputUnavailable
            throw PluginError.invalid(Self.realtimeInputUnavailable)
        }
        var needed: Set<HostPermissionID> = [.microphone]
        if liveInput { needed.insert(.accessibility) }
        target = nil
        notice = ""
        do {
            try requirePermissions(needed)
            if liveInput {
                // Realtime means realtime: never silently run a preview when capture failed.
                target = try makeTarget()
            } else { notice = Self.previewNotice }
        } catch { notice = error.localizedDescription; throw error }
        isPreviewing = !liveInput
        let id = UUID(), session = makeSession(), microphone = makeMicrophone()
        // Capture immediately on the user's gesture, including a short utterance released
        // before networking is ready. Startup has its own strictly bounded PCM allowance.
        do {
            try microphone.configureInputDevice(preferences.inputDeviceUID)
            try microphone.start()
        } catch {
            audioDiagnostics = microphone.diagnostics
            microphone.stop(); session.cancel(); target?.cancel(); target = nil
            notice = error.localizedDescription
            throw error
        }
        self.session = session; self.microphone = microphone
        audioDiagnostics = microphone.diagnostics; recognitionUpdates = 0
        generation = id; self.gesture = gesture
        transcript = ""; seconds = 0; level = 0; acknowledgedTextLength = 0; pendingWrite = false; finalTextToWrite = nil; lastWrite = 0
        phase = .connecting
        if showsHUD {
            let hud = DictationHUD()
            self.hud = hud; hud.show(controller: self)
        }
        session.onTranscript = { [weak self] text in
            guard let self, self.generation == id, self.finalTextToWrite == nil else { return }
            self.transcript = text; self.recognitionUpdates += 1
            if !text.isEmpty {
                self.lastResult = text
                // EndASR may emit several revisions. Observe them in the panel, but do
                // not apply any while finishing: finish() supplies one authoritative final.
                if self.phase == .connecting || self.phase == .listening {
                    self.pendingWrite = true
                    self.scheduleTextWrite()
                }
            }
        }
        session.onFailure = { [weak self] error in
            guard let self, self.generation == id else { return }
            self.cancel(message: error.localizedDescription)
        }
        let started = ProcessInfo.processInfo.systemUptime
        monitor = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, self.generation == id else { return }
                    guard self.phase == .connecting || self.phase == .listening else { continue }
                    self.seconds = Int(ProcessInfo.processInfo.systemUptime - started)
                    try self.microphone?.validateBuffer()
                    if let microphone = self.microphone { self.refreshAudioDiagnostics(microphone) }
                    if self.seconds >= 5, let audio = self.audioDiagnostics, audio.capturedBytes == 0 {
                        throw PluginError.invalid(audio.emptyResultReason)
                    }
                    try self.requirePermissions(liveInput ? [.microphone, .accessibility] : [.microphone])
                    if let target = self.target {
                        do { try await target.validate() }
                        catch {
                            guard self.generation == id, !Task.isCancelled else { return }
                            self.detachTarget(error); self.stopRecording()
                        }
                        guard self.generation == id, !Task.isCancelled else { return }
                    }
                    if self.seconds >= self.preferences.maximumSeconds { self.stopRecording() }
                }
            } catch {
                guard let self, self.generation == id else { return }
                self.cancel(message: error is HostPermissionError ? "权限已失效，听写已停止。" : error.localizedDescription)
            }
        }
        task = Task { [weak self] in await self?.run(id: id, session: session, microphone: microphone) }
    }

    private func run(id: UUID, session: any DoubaoSpeechSession, microphone: any DictationAudioSource) async {
        do {
            try await session.start()
            try Task.checkCancellation()
            guard generation == id, phase == .connecting || phase == .finishing, isAllowed() else { throw CancellationError() }
            let startup = try microphone.read()
            refreshAudioDiagnostics(microphone)
            microphone.setStreaming()
            try await transmit(startup.pcm, session: session)
            if phase == .connecting { phase = .listening }
            while phase == .listening {
                try Task.checkCancellation()
                guard generation == id, isAllowed() else { throw CancellationError() }
                let packet = try microphone.read()
                refreshAudioDiagnostics(microphone)
                level = packet.level
                try await transmit(packet.pcm, session: session)
                scheduleTextWrite()
                if phase == .listening { try await Task.sleep(for: .milliseconds(50)) }
            }
            try Task.checkCancellation()
            guard generation == id, phase == .finishing else { throw CancellationError() }
            // stopRecording() synchronously joined the input callback; flush bounded tail once.
            let tail = try microphone.read()
            refreshAudioDiagnostics(microphone)
            try await transmit(tail.pcm, session: session)
            let final = try await session.finish()
            try Task.checkCancellation()
            guard generation == id, isAllowed() else { throw CancellationError() }
            if final.isEmpty {
                if notice.isEmpty || notice == Self.previewNotice {
                    notice = transcript.isEmpty ? (audioDiagnostics?.emptyResultReason ?? "本次没有识别到语音。") : "最终结果为空，已保留中间草稿；请核对后使用。"
                }
            } else {
                transcript = final; lastResult = final; finalTextToWrite = final; pendingWrite = true
                scheduleTextWrite()
                await flushTextWrites(id: id)
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
                if notice.isEmpty { notice = target == nil ? "已定稿，可复制识别文字。" : "已确认输入最终识别结果。" }
            }
            releaseResources()
        } catch {
            guard generation == id else { return }
            let message = error is CancellationError ? "已取消，已输入的文字保留。" :
                (error is HostPermissionError ? "权限已失效，听写已停止；请到宿主权限管理中处理。" : error.localizedDescription)
            cancel(message: message)
        }
    }

    private func refreshAudioDiagnostics(_ microphone: any DictationAudioSource) {
        if let value = microphone.diagnostics {
            audioDiagnostics = value
            if phase == .connecting { level = value.currentLevel }
        }
    }

    private func transmit(_ pcm: Data, session: any DoubaoSpeechSession) async throws {
        for offset in stride(from: 0, to: pcm.count, by: 3200) {
            try Task.checkCancellation()
            try await session.send(pcm.subdata(in: offset..<min(offset + 3200, pcm.count)))
        }
    }
    func stopRecording() {
        guard phase == .connecting || phase == .listening else { return }
        pendingWrite = false
        level = 0; phase = .finishing
        microphone?.stop()
    }
    func cancel(message: String = "已取消，已输入的文字保留。") {
        notice = message
        releaseResources()
    }
    func clearResult() {
        guard !isBusy else { return }
        transcript = ""; lastResult = ""; notice = ""
    }

    private func scheduleTextWrite() {
        guard pendingWrite, let target, let id = generation, textWriter == nil else { return }
        textWriter = Task { [weak self, target] in
            guard let self else { return }
            defer {
                if self.generation == id {
                    self.textWriter = nil
                    if self.pendingWrite { self.scheduleTextWrite() }
                }
            }
            do {
                while self.generation == id, self.pendingWrite, self.target != nil {
                    let delay = self.finalTextToWrite == nil ? 0.15 - (ProcessInfo.processInfo.systemUptime - self.lastWrite) : 0
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    guard self.generation == id, self.isAllowed() else { throw CancellationError() }
                    guard self.pendingWrite else { return }
                    if self.phase == .finishing, self.finalTextToWrite == nil {
                        self.pendingWrite = false
                        return
                    }
                    try self.requirePermissions([.accessibility])
                    // Coalesce partials, but freeze finishing output until the final is ready.
                    let final = self.finalTextToWrite
                    let text = final ?? self.transcript
                    self.pendingWrite = false
                    if final != nil { try await target.commitFinal(text) }
                    else { try await target.update(text) }
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    self.acknowledgedTextLength = text.utf16.count
                    self.lastWrite = ProcessInfo.processInfo.systemUptime
                }
            } catch {
                guard self.generation == id else { return }
                self.detachTarget(error)
                self.stopRecording()
            }
        }
    }
    private func flushTextWrites(id: UUID) async {
        while generation == id, target != nil {
            if pendingWrite { scheduleTextWrite() }
            guard let writer = textWriter else { return }
            await writer.value
        }
    }
    private func detachTarget(_ error: Error) {
        target?.cancel(); target = nil; pendingWrite = false
        notice = error.localizedDescription
    }
    private func releaseResources() {
        generation = nil; gesture = nil
        if let microphone { microphone.stop(); refreshAudioDiagnostics(microphone) }
        microphone = nil
        session?.cancel(); session = nil
        task?.cancel(); task = nil; monitor?.cancel(); monitor = nil
        target?.cancel(); target = nil; pendingWrite = false; finalTextToWrite = nil; level = 0
        textWriter?.cancel(); textWriter = nil
        hud?.close(); hud = nil
        phase = .idle
    }
}
