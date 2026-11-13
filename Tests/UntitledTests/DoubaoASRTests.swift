import Foundation
import Testing
@testable import Untitled

struct DoubaoASRTests {
    @Test func observedProtobufAndUnknownFields() throws {
        let packet = Data([0x0a, 4]) + Data("task".utf8) + Data([0x22, 11]) + Data("TaskStarted".utf8)
            + Data([0x28, 0x80, 0xda, 0xc4, 0x09])
        let result = try DoubaoASRProtocol.decode(packet)
        #expect(result.event == "TaskStarted")
        #expect(result.taskID == "task")
        #expect(result.statusCode == 20_000_000)
        let unknown = Data([0x61]) + Data(repeating: 0, count: 8) + Data([0x6d]) + Data(repeating: 0, count: 4)
        #expect(try DoubaoASRProtocol.decode(packet + unknown).event == "TaskStarted")
        let audio = DoubaoASRProtocol.request("TaskRequest", taskID: "task", audio: Data([0x61, 0x62]), sequence: 2)
        #expect(audio.range(of: Data([0x3a, 2, 0x61, 0x62, 0x48, 2])) != nil)
        let start = DoubaoASRProtocol.request("StartTask")
        #expect(start.range(of: Data([0x2a, 9]) + Data("StartTask".utf8)) != nil)
    }

    @Test func malformedProtobufFailsClosed() {
        var packets: [Data] = [[0x22, 8, 0x61], [0x28, 0x80], [0], [0x27],
                               [0x22, 1, 0xff], [0x20, 1], [0x2a, 1, 0]].map { Data($0) }
        packets.append(Data([0x28]) + Data(repeating: 0xff, count: 10))
        packets.append(Data(repeating: 0, count: DoubaoASRLimits.messageBytes + 1))
        for packet in packets {
            #expect(throws: (any Error).self) { try DoubaoASRProtocol.decode(packet) }
        }
    }

    @Test func textEnvelopeAndExplicitFinals() throws {
        let message = try DoubaoASRProtocol.decode(text: #"{"event":"ASRResponse","status_code":20000000,"payload":"{}"}"#)
        #expect(message.event == "ASRResponse")
        var transcript = DoubaoTranscript()
        try transcript.consume(#"{"results":[{"text":"明天下午三点","is_interim":true}]}"#)
        #expect(transcript.text == "明天下午三点")
        #expect(transcript.finalCount == 0)
        try transcript.consume(#"{"results":[{"text":"明天下午 3 点。","is_interim":false}]}"#)
        try transcript.consume(#"{"results":[{"text":"再开会","is_interim":true}]}"#)
        #expect(transcript.text == "明天下午 3 点。再开会")
        try transcript.consume(#"{"results":[{"text":"再开会。","is_interim":false}]}"#)
        #expect(transcript.confirmed == "明天下午 3 点。再开会。")
        #expect(transcript.pending.isEmpty)
        #expect(transcript.finalCount == 2)
        #expect(throws: (any Error).self) { try transcript.consume(#"{"results":[{"text":"不能猜测完成"}]}"#) }
        #expect(throws: (any Error).self) { try DoubaoASRProtocol.decode(text: "[]") }
    }

    @Test func audioDiagnosticsDistinguishNoCallbacksSilenceAndSignal() throws {
        let mailbox = DictationAudioMailbox()
        #expect(mailbox.diagnostics().emptyResultReason.contains("没有收到"))
        mailbox.append(Data(repeating: 0, count: 640))
        #expect(mailbox.diagnostics().callbacks == 1 && mailbox.diagnostics().capturedBytes == 640)
        #expect(mailbox.diagnostics().emptyResultReason.contains("静音音频"))
        let signal = Data((0..<320).flatMap { _ in [UInt8(0), UInt8(0x40)] })
        mailbox.append(signal)
        mailbox.append(Data(repeating: 0, count: 640))
        #expect(try mailbox.drain().level > 0) // Last callback silence must not hide a preceding voice frame.
        #expect(mailbox.diagnostics().capturedBytes == 1920 && mailbox.diagnostics().callbacks == 3)
        #expect(abs((mailbox.diagnostics().peakDBFS ?? 0) + 6.02) < 0.05)
        #expect(try mailbox.drain().level == 0)
    }

    @Test func selectedInputNeverSilentlyFallsBackToAnotherMicrophone() throws {
        let a = DictationInputDevice(id: "test.a", name: "Test A", objectID: 10, isVirtual: false)
        let b = DictationInputDevice(id: "test.b", name: "Test B", objectID: 11, isVirtual: true)
        #expect(try DictationInputDevices.resolve(preferredUID: nil, defaultUID: a.id, devices: [a, b]) == a)
        #expect(try DictationInputDevices.resolve(preferredUID: b.id, defaultUID: a.id, devices: [a, b]) == b)
        #expect(throws: PluginError.self) { try DictationInputDevices.resolve(preferredUID: "disconnected", defaultUID: a.id, devices: [a, b]) }
        #expect(throws: PluginError.self) { try DictationInputDevices.resolve(preferredUID: nil, defaultUID: nil, devices: [a, b]) }
    }

    @Test func microphoneQueueErrorsAreNotSilentlyIgnored() throws {
        let failed = DictationAudioMailbox()
        failed.recordQueueError(-123)
        #expect(throws: PluginError.self) { try failed.drain() }
        let stopped = DictationAudioMailbox()
        stopped.beginStopping()
        stopped.recordQueueError(-123)
        try stopped.validate()
    }

    @Test func textAndAudioBudgetsAreBounded() throws {
        var transcript = DoubaoTranscript()
        let payload = try JSONSerialization.data(withJSONObject: ["results": [
            ["text": String(repeating: "字", count: DoubaoASRLimits.textLength + 1), "is_interim": true]
        ]])
        #expect(throws: (any Error).self) { try transcript.consume(String(decoding: payload, as: UTF8.self)) }
        let mailbox = DictationAudioMailbox()
        mailbox.setStreaming()
        mailbox.append(Data(repeating: 0, count: 3200))
        #expect(mailbox.bufferedBytes == 3200)
        #expect(try mailbox.drain().pcm.count == 3200)
        #expect(mailbox.bufferedBytes == 0)
        mailbox.append(Data(repeating: 0, count: DoubaoASRLimits.audioBufferBytes))
        mailbox.append(Data([0, 0]))
        #expect(mailbox.bufferedBytes == 0)
        #expect(throws: PluginError.self) { try mailbox.drain() }
        let startup = DictationAudioMailbox()
        startup.append(Data(repeating: 0, count: DoubaoASRLimits.preconnectAudioBytes))
        try startup.validate()
        #expect(startup.bufferedBytes == DoubaoASRLimits.preconnectAudioBytes)
        startup.setStreaming()
        #expect(throws: PluginError.self) { try startup.validate() }
        #expect(startup.bufferedBytes == 0)
    }

    @Test func sourceBackedTwoPassProfileHasNoAccountContext() throws {
        let value = try #require(JSONSerialization.jsonObject(with: DoubaoASRProtocol.sessionPayload()) as? [String: Any])
        let asr = try #require(value["asr"] as? [String: Any])
        let extra = try #require(asr["extra"] as? [String: Any])
        #expect(value["request_type"] as? Int == 3)
        #expect(extra["enable_asr_twopass"] as? Bool == true)
        #expect(extra["stream_model"] as? String == "bigasr-acllm-release-streaming-grpc-4")
        #expect(extra["use_bigasr_punc"] as? Bool == true)
        #expect(value["chat"] == nil)
        #expect(asr["adaptation_phrase_set_id"] == nil)
    }

    @Test func visitorBootstrapParsesNestedJSONWithoutForwardingCookies() throws {
        let guest = try DoubaoGuestContext.parse(homepage(device: "123456789"))
        #expect(guest.deviceID == "123456789")
        #expect(guest.aid == "497858")
        let request = guest.request
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.doubao.com")
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "device_id" && $0.value == "123456789" })
        #expect(!query.contains { $0.name.lowercased().contains("cookie") || $0.name == "ttwid" })
        #expect(throws: (any Error).self) { try DoubaoGuestContext.parse(Data("changed".utf8)) }
        #expect(throws: (any Error).self) { try DoubaoGuestContext.parse(homepage(device: "0")) }
        #expect(throws: (any Error).self) { try DoubaoGuestContext.parse(homepage(device: "123abc")) }
    }

    private func homepage(device: String) throws -> Data {
        let value: [String: Any] = ["loaderData": ["chat_layout": ["chat_layout": [
            "launchCore": ["web_id": device, "ttwid": "test-only-do-not-forward"],
            "aid": 497858, "pc_version": "test", "ignored": #"nested } [ \" string"#
        ]]]]
        return Data("<script>window._ROUTER_DATA = ".utf8)
            + (try JSONSerialization.data(withJSONObject: value))
            + Data(";</script><script>unrelated()</script>".utf8)
    }

    /// Opt-in native Swift end-to-end probe. Sends ONLY the explicit synthetic WAV path.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNTITLED_DOUBAO_LIVE_TEST"] == "1"))
    @MainActor func nativeTwoPassLiveWithExplicitSyntheticAudio() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["UNTITLED_DOUBAO_SYNTHETIC_WAV"])
        let url = URL(fileURLWithPath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try #require(size > 44 && size < 1_100_000, "Only short, explicit synthetic WAV fixtures may be submitted.")
        let wav = try Data(contentsOf: url)
        try #require(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        try #require(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        // The verification input is a canonical 16 kHz mono PCM16 WAV generated by afconvert.
        var position = 12, pcm: Data?
        while position + 8 <= wav.count {
            let size = (0..<4).reduce(0) { $0 | Int(wav[position + 4 + $1]) << (8 * $1) }
            guard size >= 0, size <= wav.count - position - 8 else { break }
            if String(decoding: wav[position..<position + 4], as: UTF8.self) == "data" {
                pcm = wav.subdata(in: position + 8..<position + 8 + size); break
            }
            position += 8 + size + size % 2
        }
        let audio = try #require(pcm)
        #expect(audio.count > 32000 && audio.count < 1_000_000)
        let client = DoubaoASRClient()
        defer { client.cancel() }
        var duringStream = 0, finalText = "", failure: Error?
        var streaming = true
        client.onTranscript = { text in
            if streaming && !text.isEmpty { duringStream += 1 }
            finalText = text
        }
        client.onFailure = { failure = $0 }
        try await client.start()
        let started = ContinuousClock.now
        for offset in stride(from: 0, to: audio.count, by: 3200) {
            try await client.send(audio.subdata(in: offset..<min(offset + 3200, audio.count)))
            let deadline = started.advanced(by: .milliseconds((min(offset + 3200, audio.count) * 1000) / 32000))
            try await ContinuousClock().sleep(until: deadline)
        }
        streaming = false
        let final = try await client.finish()
        #expect(failure == nil)
        #expect(duringStream > 1)
        #expect(!final.isEmpty)
        #expect(final == finalText)
        #expect(final.contains("3") || final.contains("测试"))
        print("Native Doubao verification: \(duringStream) nonempty streaming updates, \(final.utf16.count) final UTF-16 units; no microphone/AX used.")
    }
}
