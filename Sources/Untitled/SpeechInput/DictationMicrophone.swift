import AudioToolbox
import CoreAudio
import Foundation
import os

struct DictationAudioDiagnostics: Equatable, Sendable {
    var inputName = ""
    var callbacks = 0
    var capturedBytes = 0
    var peakRMS: Float = 0
    var currentLevel: Float = 0
    var sampleRate: Double = 16000
    var peakDBFS: Double? { peakRMS > 0 ? 20 * log10(Double(peakRMS)) : nil }
    var emptyResultReason: String {
        if capturedBytes == 0 { return "没有收到麦克风音频帧。请重新选择已连接的输入设备，并检查麦克风权限。" }
        if peakRMS == 0 { return "麦克风返回了静音音频。请检查所选设备、输入音量或硬件静音；采集来自运行 Untitled 的这台 Mac，不会自动使用手机或另一台 Mac 的麦克风。" }
        return "本次没有识别到语音。麦克风已有信号，请靠近所选设备并说完整一句；也可先仅试音排除输入框问题。"
    }
}

struct DictationInputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let objectID: AudioDeviceID
    let isVirtual: Bool
}

/// Read-only HAL discovery. No device changes, I/O, listener, or permission request.
enum DictationInputDevices {
    static func resolve(preferredUID: String?, defaultUID: String?, devices: [DictationInputDevice]) throws -> DictationInputDevice {
        let uid = preferredUID ?? defaultUID
        guard let uid, let device = devices.first(where: { $0.id == uid }) else {
            throw PluginError.invalid(preferredUID == nil ? "找不到系统默认输入设备，请在豆信面板选择麦克风。" : "所选麦克风已断开，请刷新设备并重新选择；不会悄悄切换到其他设备。")
        }
        return device
    }
    static func snapshot() -> (devices: [DictationInputDevice], defaultUID: String?) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let defaultID = number(system, kAudioHardwarePropertyDefaultInputDevice)
        var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
              size > 0, size <= 128 * MemoryLayout<AudioDeviceID>.size,
              size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else { return ([], nil) }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return ([], nil) }
        let devices = ids.compactMap { id -> DictationInputDevice? in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), streamBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamBytes) == noErr, streamBytes > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty, uid.utf8.count <= 1024,
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = number(id, kAudioDevicePropertyTransportType)
            return .init(id: uid, name: String(name.prefix(256)), objectID: id,
                         isVirtual: transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (devices, devices.first(where: { $0.objectID == defaultID })?.id)
    }
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

@MainActor protocol DictationAudioSource: AnyObject {
    var diagnostics: DictationAudioDiagnostics? { get }
    func configureInputDevice(_ uid: String?) throws
    func start() throws
    func read() throws -> (pcm: Data, level: Float)
    func setStreaming()
    func validateBuffer() throws
    func stop()
}
extension DictationAudioSource {
    var diagnostics: DictationAudioDiagnostics? { nil }
    func configureInputDevice(_ uid: String?) throws {}
}

/// Only this lock-protected, Sendable mailbox crosses the AudioQueue callback boundary.
/// AudioQueueDispose(..., true) joins callbacks before its owner releases the mailbox.
final class DictationAudioMailbox: Sendable {
    private struct State: Sendable {
        var pcm = Data()
        var level: Float = 0
        var peakRMS: Float = 0
        var callbacks = 0
        var capturedBytes = 0
        var queueError: OSStatus?
        var stopping = false
        var overflow = false
        var limit = DoubaoASRLimits.preconnectAudioBytes
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ data: Data) {
        var sum: Float = 0
        data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: max(0, bytes.count - 1), by: 2) {
                let sample = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let value = Float(sample) / 32768
                sum += value * value
            }
        }
        let rms = sqrt(sum / Float(max(1, data.count / 2)))
        state.withLock {
            $0.callbacks += 1; $0.capturedBytes += data.count
            $0.peakRMS = max($0.peakRMS, rms)
            // Preserve the peak between 50 ms drains instead of only the last 20 ms frame.
            $0.level = max($0.level, min(1, rms * 8))
            guard !$0.overflow, !data.isEmpty else { return }
            guard data.count <= $0.limit - $0.pcm.count else {
                $0.overflow = true; $0.pcm.removeAll(); return
            }
            $0.pcm.append(data)
        }
    }
    func recordQueueError(_ status: OSStatus) {
        guard status != noErr else { return }
        state.withLock { if !$0.stopping { $0.queueError = status } }
    }
    func beginStopping() { state.withLock { $0.stopping = true } }
    func diagnostics(inputName: String = "", sampleRate: Double = 16000) -> DictationAudioDiagnostics {
        state.withLock { .init(inputName: inputName, callbacks: $0.callbacks, capturedBytes: $0.capturedBytes, peakRMS: $0.peakRMS, currentLevel: $0.level, sampleRate: sampleRate) }
    }
    func validate() throws {
        try state.withLock {
            if let error = $0.queueError { throw PluginError.invalid("麦克风音频队列中断（\(error)），请重新选择输入设备后再试。") }
            guard !$0.overflow else { throw PluginError.invalid("豆包连接或发送跟不上录音，已停止以避免丢字；请检查网络后重新开始。") }
        }
    }
    func drain() throws -> (pcm: Data, level: Float) {
        try state.withLock {
            if let error = $0.queueError { throw PluginError.invalid("麦克风音频队列中断（\(error)），请重新选择输入设备后再试。") }
            guard !$0.overflow else { throw PluginError.invalid("豆包连接或发送跟不上录音，已停止以避免丢字；请检查网络后重新开始。") }
            let result = ($0.pcm, $0.level)
            $0.pcm = Data(); $0.level = 0
            return result
        }
    }
    func setStreaming() {
        state.withLock {
            $0.limit = DoubaoASRLimits.audioBufferBytes
            if $0.pcm.count > $0.limit { $0.overflow = true; $0.pcm.removeAll() }
        }
    }
    var bufferedBytes: Int { state.withLock { $0.pcm.count } }
}

@MainActor final class DictationMicrophone: DictationAudioSource {
    private var mailbox = DictationAudioMailbox()
    private var queue: AudioQueueRef?
    private var preferredUID: String?
    private var inputName = ""
    private var sampleRate: Double = 16000
    var diagnostics: DictationAudioDiagnostics? { mailbox.diagnostics(inputName: inputName, sampleRate: sampleRate) }
    isolated deinit { stop() }

    func configureInputDevice(_ uid: String?) throws {
        guard queue == nil else { throw PluginError.invalid("请先停止录音，再选择麦克风。") }
        preferredUID = uid
    }
    func start() throws {
        guard queue == nil else { return }
        mailbox = DictationAudioMailbox()
        let available = DictationInputDevices.snapshot()
        let device = try DictationInputDevices.resolve(preferredUID: preferredUID, defaultUID: available.defaultUID, devices: available.devices)
        inputName = device.name
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var created: AudioQueueRef?
        let status = AudioQueueNewInput(&format, { context, queue, buffer, _, _, _ in
            guard let context else { return }
            let mailbox = Unmanaged<DictationAudioMailbox>.fromOpaque(context).takeUnretainedValue()
            let size = Int(buffer.pointee.mAudioDataByteSize)
            guard size <= Int(buffer.pointee.mAudioDataBytesCapacity), size % 2 == 0 else { mailbox.recordQueueError(-1); return }
            mailbox.append(Data(bytes: buffer.pointee.mAudioData, count: size))
            mailbox.recordQueueError(AudioQueueEnqueueBuffer(queue, buffer, 0, nil))
        }, Unmanaged.passUnretained(mailbox).toOpaque(), nil, nil, 0, &created)
        guard status == noErr, let created else { throw PluginError.invalid("无法打开麦克风（\(status)），请检查设备与权限。") }
        queue = created
        do {
            // Bind the resolved input explicitly; never inherit an unrelated loopback route.
            var selected = device.id as CFString
            let selectedStatus = withUnsafePointer(to: &selected) {
                AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size))
            }
            guard selectedStatus == noErr else { throw PluginError.invalid("无法选择麦克风（\(selectedStatus)），请重新选择已连接的输入设备。") }
            var negotiated = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioQueueGetProperty(created, kAudioQueueProperty_StreamDescription, &negotiated, &size) == noErr,
                  negotiated.mFormatID == kAudioFormatLinearPCM, negotiated.mSampleRate == 16000,
                  negotiated.mChannelsPerFrame == 1, negotiated.mBytesPerFrame == 2, negotiated.mBitsPerChannel == 16,
                  negotiated.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                  negotiated.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
                throw PluginError.invalid("麦克风没有提供 16 kHz 单声道 PCM16 音频，请换一个输入设备后再试。")
            }
            sampleRate = negotiated.mSampleRate
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                let allocated = AudioQueueAllocateBuffer(created, 640, &buffer)
                guard allocated == noErr, let buffer, AudioQueueEnqueueBuffer(created, buffer, 0, nil) == noErr else {
                    throw PluginError.invalid("无法分配麦克风音频缓冲区。")
                }
            }
            let started = AudioQueueStart(created, nil)
            guard started == noErr else { throw PluginError.invalid("麦克风启动失败（\(started)），请检查系统输入设备。") }
        } catch { stop(); throw error }
    }
    func read() throws -> (pcm: Data, level: Float) { try mailbox.drain() }
    func setStreaming() { mailbox.setStreaming() }
    func validateBuffer() throws { try mailbox.validate() }
    func stop() {
        guard let queue else { return }
        self.queue = nil; mailbox.beginStopping()
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
    }
}
