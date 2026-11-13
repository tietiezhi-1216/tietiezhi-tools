import Foundation

enum DoubaoASRLimits {
    static let homepageBytes = 2 * 1024 * 1024
    static let messageBytes = 256 * 1024
    static let textLength = 32_768 // UTF-16 code units
    static let audioBufferBytes = 64_000 // two seconds of PCM16, not a recording archive
    static let preconnectAudioBytes = 320_000 // at most ten seconds while the first connection opens
    static let maximumSeconds = 300
}

/// Observed public VoiceGenie wire format. Implemented natively; no Python bridge or client injection.
enum DoubaoASRProtocol {
    // Public web application identifier, NOT an account credential.
    static let appKey = "GOqQpfo1fO7slHv8"
    static let gateway = "wss://frontier-audio-web-ws.doubao.com/api/v2/sami/voicegenie"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"

    struct Message: Sendable {
        var event = ""
        var taskID = ""
        var messageID = ""
        var statusCode: UInt64?
        var payload = ""
    }

    static func request(_ event: String, taskID: String = "", payload: Data? = nil,
                        audio: Data? = nil, sequence: Int? = nil) -> Data {
        var data = Data()
        func string(_ number: Int, _ value: String) { field(number, Data(value.utf8), into: &data) }
        string(2, appKey); string(3, "VoiceGenie"); string(5, event)
        field(6, payload ?? Data("{}".utf8), into: &data)
        if !taskID.isEmpty { string(8, taskID) }
        if let audio { field(7, audio, into: &data) }
        if let sequence {
            data.append(contentsOf: varint(9 << 3))
            data.append(contentsOf: varint(UInt64(sequence)))
        }
        return data
    }

    /// This source-backed two-pass profile was verified with synthetic audio:
    /// streaming hypotheses during capture, followed by the server's punctuated/ITN final.
    /// No account/chat IDs, browser cookies, adaptation resources or additional LLM requests.
    static func sessionPayload() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "business": 1, "enable_audio_input": true, "query_mode": 2,
            "interrupt_type": 0, "request_type": 3,
            "asr": [
                "model": "bigasr-acllm-release-grpc-main",
                "enable_vad": true, "enable_punctuation": true,
                "enable_disfluency": true, "enable_itn": true,
                "lang": "zh", "hot_word_version": 3, "audio_src": 1,
                "audio_info": ["channel": 1, "format": "pcm", "sample_rate": 16000],
                "extra": [
                    "use_bigasr_audio_emb": true, "enable_shot_audio_without_vad": true,
                    "enable_asr_twopass": true,
                    "minor_model": "bigasr-acllm-release-grpc-mlg-0",
                    "nonstream_model": "bigasr-acllm-release-grpc-main",
                    "nonstream_asr_timeout_ms": 8000,
                    "stream_model": "bigasr-acllm-release-streaming-grpc-4",
                    "enable_trim_punctuation": true, "use_bigasr_itn": true,
                    "use_bigasr_punc": true, "enable_text_post_process": true,
                    "asr_text_post_process_type": "last_post_process"
                ]
            ]
        ])
    }

    static func decode(_ data: Data) throws -> Message {
        guard data.count <= DoubaoASRLimits.messageBytes else { throw invalid() }
        let bytes = [UInt8](data)
        var offset = 0, result = Message()
        func integer() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw invalid() }
                let byte = bytes[offset]; offset += 1
                guard index != 9 || byte <= 1 else { throw invalid() }
                value |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return value }
            }
            throw invalid()
        }
        while offset < bytes.count {
            let tag = try integer(), number = Int(tag >> 3), wire = Int(tag & 7)
            guard number > 0 else { throw invalid() }
            if wire == 0 {
                let value = try integer()
                if number == 5 { result.statusCode = value }
                else if [1, 2, 4, 7].contains(number) { throw invalid() }
                continue
            }
            guard wire == 1 || wire == 2 || wire == 5 else { throw invalid() }
            let length = try wire == 2 ? integer() : UInt64(wire == 1 ? 8 : 4)
            guard length <= UInt64(bytes.count - offset) else { throw invalid() }
            let end = offset + Int(length)
            if [1, 2, 4, 7].contains(number) {
                guard wire == 2, let value = String(bytes: bytes[offset..<end], encoding: .utf8) else { throw invalid() }
                switch number {
                case 1: result.taskID = value
                case 2: result.messageID = value
                case 4: result.event = value
                default: result.payload = value
                }
            } else if number == 5 { throw invalid() }
            offset = end
        }
        guard !result.event.isEmpty else { throw invalid() }
        return result
    }

    static func decode(text: String) throws -> Message {
        struct Envelope: Decodable {
            let event: String
            var task_id: String?
            var message_id: String?
            var status_code: UInt64?
            var payload: String?
        }
        guard text.utf8.count <= DoubaoASRLimits.messageBytes else { throw invalid() }
        let value = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
        return Message(event: value.event, taskID: value.task_id ?? "", messageID: value.message_id ?? "",
                       statusCode: value.status_code, payload: value.payload ?? "")
    }

    private static func field(_ number: Int, _ value: Data, into data: inout Data) {
        data.append(contentsOf: varint(UInt64(number << 3 | 2)))
        data.append(contentsOf: varint(UInt64(value.count))); data.append(value)
    }
    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(value & 127) | (value > 127 ? 128 : 0))
            value >>= 7
        } while value != 0
        return bytes
    }
    private static func invalid() -> PluginError { .invalid("豆包语音协议响应无效，网页接口可能已更新。") }
}

struct DoubaoTranscript: Sendable {
    private(set) var confirmed = ""
    private(set) var pending = ""
    private(set) var finalCount = 0
    var text: String { confirmed + pending }

    mutating func consume(_ payload: String) throws {
        struct Result: Decodable { let text: String; let is_interim: Bool }
        struct Payload: Decodable { let results: [Result] }
        let value = try JSONDecoder().decode(Payload.self, from: Data(payload.utf8))
        guard value.results.count <= 128 else { throw PluginError.invalid("豆包返回了过多语音分段。") }
        for result in value.results {
            guard result.text.utf16.count <= DoubaoASRLimits.textLength else { throw PluginError.invalid("听写文字超过长度预算，请分段输入。") }
            if result.is_interim { pending = result.text }
            else { confirmed += result.text; pending = ""; finalCount += 1 }
            guard text.utf16.count <= DoubaoASRLimits.textLength else { throw PluginError.invalid("听写文字超过长度预算，请分段输入。") }
        }
    }
}

struct DoubaoGuestContext: Sendable {
    let deviceID: String
    let version: String
    let aid: String

    static func load(using session: URLSession) async throws -> Self {
        var request = URLRequest(url: URL(string: "https://www.doubao.com/chat/")!, timeoutInterval: 15)
        request.setValue(DoubaoASRProtocol.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= DoubaoASRLimits.homepageBytes else {
            throw PluginError.invalid("豆包首页暂时不可用，请检查网络后重试。")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < DoubaoASRLimits.homepageBytes else { throw PluginError.invalid("豆包首页超过大小预算。") }
            data.append(byte)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Self {
        func changed() -> PluginError { .invalid("无法取得豆包游客会话，网页结构可能已更新。") }
        guard data.count <= DoubaoASRLimits.homepageBytes, let html = String(data: data, encoding: .utf8),
              let marker = html.range(of: #"window\._ROUTER_DATA\s*=\s*"#, options: .regularExpression) else { throw changed() }
        let bytes = Array(html[marker.upperBound...].utf8)
        guard bytes.first == 123 else { throw changed() }
        var depth = 0, quoted = false, escaped = false, end: Int?
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 {
                depth -= 1
                if depth == 0 { end = index + 1; break }
            }
        }
        guard let end,
              let router = try JSONSerialization.jsonObject(with: Data(bytes[..<end])) as? [String: Any],
              let loader = router["loaderData"] as? [String: Any],
              let parent = loader["chat_layout"] as? [String: Any],
              let layout = parent["chat_layout"] as? [String: Any],
              let launch = layout["launchCore"] as? [String: Any] else { throw changed() }
        func identifier(_ value: Any?) -> String? {
            let text: String
            if let value = value as? String { text = value }
            else if let value = value as? NSNumber {
                guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
                text = value.stringValue
            }
            else { return nil }
            guard !text.isEmpty, text.utf8.count <= 100, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  text.contains(where: { $0 != "0" }) else { return nil }
            return text
        }
        guard let device = identifier(launch["web_id"]), let aid = identifier(layout["aid"]),
              let version = layout["pc_version"] as? String, !version.isEmpty, version.utf8.count <= 100 else { throw changed() }
        return Self(deviceID: device, version: version, aid: aid)
    }

    var request: URLRequest {
        var url = URLComponents(string: DoubaoASRProtocol.gateway)!
        let fields = [
            "api_app_key": DoubaoASRProtocol.appKey, "namespace": "VoiceGenie", "version_code": "20800",
            "language": "zh", "device_platform": "web", "pkg_type": "release_version",
            "pc_version": version, "doubao_pc_version": version, "region": "CN", "sys_region": "CN",
            "samantha_web": "1", "use-olympus-account": "1", "doubao_device_platform": "web",
            "aid": aid, "real_aid": aid, "device_id": deviceID, "web_platform": "browser"
        ]
        url.queryItems = fields.sorted(by: { $0.key < $1.key }).map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!, timeoutInterval: 15)
        request.setValue("https://www.doubao.com", forHTTPHeaderField: "Origin")
        request.setValue(DoubaoASRProtocol.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
