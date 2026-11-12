@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct SharingAudioDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let objectID: AudioDeviceID
}

enum SharingAudioDevices {
    static let inputUID = "app.untitled.microphone.input.v1"
    static let feedUID = "app.untitled.microphone.feed.v1"
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector), value: Unmanaged<CFString>? = nil, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard result == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func all() -> [SharingAudioDevice] {
        var address = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return SharingAudioDevice(id: uid, name: name, objectID: id)
        }
    }
    static func hardwareInputs() -> [SharingAudioDevice] {
        all().filter { device in
            guard number(device.objectID, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeVirtual,
                  number(device.objectID, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeAggregate else { return false }
            var address = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device.objectID, &address, 0, nil, &size) == noErr && size > 0
        }
    }
    static func device(_ uid: String) -> SharingAudioDevice? {
        // A hidden feed is intentionally absent from kAudioHardwarePropertyDevices.
        // Resolve its fixed UID through HAL rather than enumerating visible devices.
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        guard result == noErr, id != kAudioObjectUnknown,
              string(id, kAudioDevicePropertyDeviceUID) == uid,
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        return SharingAudioDevice(id: uid, name: name, objectID: id)
    }
    static var isInUse: Bool {
        guard let input = device(inputUID) else { return false }
        return number(input.objectID, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }
}

/// Small bounded mailbox between the audio callback and the main/network queues.
final class SharingAudioMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    #if DEBUG
    private var inputCallbacks = 0
    private var inputFrames = 0
    private var largestInput = 0
    private var conversionError = ""
    func observeInput(frames: Int) { lock.lock(); inputCallbacks += 1; inputFrames += frames; largestInput = max(largestInput, frames); lock.unlock() }
    func observeConversionError(_ text: String) { lock.lock(); conversionError = text; lock.unlock() }
    func statistics() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["callbacks": inputCallbacks, "inputFrames": inputFrames, "largestInput": largestInput, "conversionError": conversionError]
    }
    #endif
    func push(_ packet: Data) {
        guard !packet.isEmpty, packet.count <= 32768 else { return }
        lock.lock(); defer { lock.unlock() }
        if packets.count >= 6 { packets.removeFirst() }
        packets.append(packet)
    }
    func drain() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let result = packets; packets.removeAll(keepingCapacity: true); return result
    }
}

/// Confined to the single AVAudioEngine tap callback; never escapes to another audio thread.
final class SharingAudioConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let mailbox: SharingAudioMailbox
    init?(source: AVAudioFormat, mailbox: SharingAudioMailbox) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
              let converter = AVAudioConverter(from: source, to: format) else { return nil }
        self.format = format; self.converter = converter; self.mailbox = mailbox
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        #if DEBUG
        mailbox.observeInput(frames: Int(buffer.frameLength))
        #endif
        let count = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 48000 / buffer.format.sampleRate)) + 64
        // Hardware taps may return substantially more than the requested 960 frames.
        // Convert a bounded complete callback, then packetize it; never silently drop
        // every callback merely because a device uses a large native I/O quantum.
        guard count <= 65536, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true; result.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0, let samples = output.floatChannelData?[0] else {
            #if DEBUG
            mailbox.observeConversionError(error.map { "\($0.domain):\($0.code)" } ?? "No output (\(status.rawValue))")
            #endif
            return
        }
        for offset in stride(from: 0, to: Int(output.frameLength), by: 960) {
            let frames = min(960, Int(output.frameLength) - offset)
            mailbox.push(Data(bytes: samples.advanced(by: offset), count: frames * MemoryLayout<Float>.size))
        }
    }
}

private final class SharingMicrophoneQueueContext: @unchecked Sendable {
    let mailbox: SharingAudioMailbox
    init(mailbox: SharingAudioMailbox) { self.mailbox = mailbox }
    func consume(_ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef) {
        let size = Int(buffer.pointee.mAudioDataByteSize)
        #if DEBUG
        mailbox.observeInput(frames: size / 4)
        #endif
        if size > 0 && size <= 32768 { mailbox.push(Data(bytes: buffer.pointee.mAudioData, count: size)) }
        _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}

@MainActor final class SharingMicrophoneCapture {
    private var queue: AudioQueueRef?
    private var context: SharingMicrophoneQueueContext?
    private(set) var deviceUID: String?
    private(set) var mailbox = SharingAudioMailbox()
    var isRunning: Bool {
        guard let queue else { return false }
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &value, &size) == noErr && value != 0
    }
    func start(uid: String) throws {
        stop()
        let devices = SharingAudioDevices.hardwareInputs()
        let defaultID = SharingAudioDevices.number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        guard let device = uid.isEmpty ? (devices.first { $0.objectID == defaultID } ?? devices.first) : devices.first(where: { $0.id == uid }) else {
            throw PluginError.invalid("找不到选定的实体麦克风。请刷新设备列表；不会采集虚拟麦克风以免形成回路。")
        }
        // A dedicated input queue has no dependency on the system output device.
        // This matters when the default I/O is a virtual loopback and the selected
        // physical USB microphone is an input-only device.
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        mailbox = SharingAudioMailbox()
        let context = SharingMicrophoneQueueContext(mailbox: mailbox)
        var created: AudioQueueRef?
        let status = AudioQueueNewInput(&format, { info, queue, buffer, _, _, _ in
            guard let info else { return }
            Unmanaged<SharingMicrophoneQueueContext>.fromOpaque(info).takeUnretainedValue().consume(queue, buffer)
        }, Unmanaged.passUnretained(context).toOpaque(), nil, nil, 0, &created)
        guard status == noErr, let created else { throw PluginError.invalid("无法创建麦克风输入队列（\(status)）。") }
        do {
            var selected = device.id as CFString
            let selectedStatus = withUnsafePointer(to: &selected) {
                AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size))
            }
            guard selectedStatus == noErr else { throw PluginError.invalid("无法选择实体麦克风（\(selectedStatus)）。") }
            var negotiated = AudioStreamBasicDescription(), formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioQueueGetProperty(created, kAudioQueueProperty_StreamDescription, &negotiated, &formatSize) == noErr,
                  negotiated.mSampleRate == 48000, negotiated.mChannelsPerFrame == 1,
                  negotiated.mBytesPerFrame == 4, negotiated.mBitsPerChannel == 32,
                  negotiated.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw PluginError.invalid("麦克风未协商到共享所需的单声道 48 kHz Float32 格式。")
            }
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                let allocated = AudioQueueAllocateBuffer(created, 960 * 4, &buffer)
                guard allocated == noErr, let buffer, AudioQueueEnqueueBuffer(created, buffer, 0, nil) == noErr else {
                    throw PluginError.invalid("无法准备麦克风音频缓冲。")
                }
            }
            let started = AudioQueueStart(created, nil)
            guard started == noErr else { throw PluginError.invalid("实体麦克风启动失败（\(started)）。") }
            self.context = context; queue = created; deviceUID = device.id
        } catch {
            _ = AudioQueueStop(created, true); _ = AudioQueueDispose(created, true)
            throw error
        }
    }
    func stop() {
        // Dispose synchronously before releasing the callback context or its mailbox.
        if let queue { _ = AudioQueueStop(queue, true); _ = AudioQueueDispose(queue, true) }
        queue = nil; context = nil; deviceUID = nil; mailbox = SharingAudioMailbox()
    }
}

@MainActor final class SharingMicrophoneSink {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var queuedFrames = 0
    private var generation = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    var isRunning: Bool { engine?.isRunning == true }
    var isRoutingToFeed: Bool {
        guard let engine, let unit = engine.outputNode.audioUnit, let feed = SharingAudioDevices.device(SharingAudioDevices.feedUID) else { return false }
        var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr && id == feed.objectID
    }
    func start() throws {
        stop()
        guard let feed = SharingAudioDevices.device(SharingAudioDevices.feedUID) else {
            throw PluginError.invalid("请先显式安装 Untitled Microphone 虚拟驱动，再在目标应用中选择该输入。")
        }
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { throw PluginError.invalid("无法访问虚拟麦克风馈送端。") }
        var id = feed.objectID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw PluginError.invalid("无法连接虚拟麦克风，已取消接收；不会回退到扬声器。")
        }
        let player = AVAudioPlayerNode()
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { engine.stop(); throw error }
        self.engine = engine; self.player = player
        guard isRoutingToFeed else { stop(); throw PluginError.invalid("虚拟麦克风路由校验失败。") }
        player.play()
    }
    func append(_ data: Data) {
        guard let player, isRunning, isRoutingToFeed, !data.isEmpty, data.count.isMultiple(of: 4), data.count <= 32768 else { return }
        let count = data.count / 4
        guard queuedFrames + count <= 9600, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { bytes in
            for index in 0..<count {
                let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                samples[index] = value.isFinite ? min(1, max(-1, value)) : 0
            }
        }
        queuedFrames += count
        let generation = self.generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - count)
            }
        }
    }
    func stop() {
        generation += 1; player?.stop(); engine?.stop(); player = nil; engine = nil; queuedFrames = 0
    }
}
