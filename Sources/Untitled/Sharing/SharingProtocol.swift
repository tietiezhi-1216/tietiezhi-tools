import CoreGraphics
import Foundation
import Network
import Security

enum SharingManualEndpoint {
    static func parse(host: String, port: String) throws -> NWEndpoint {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let validName = host.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
            && !host.contains("..")
        guard !host.isEmpty, host.utf8.count <= 253,
              IPv4Address(host) != nil || IPv6Address(host) != nil || validName,
              !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt16(port), number > 0 else {
            throw PluginError.invalid("请输入有效的 IP / DNS 地址与 1–65535 之间的 TCP 端口，不要包含网址协议或路径。")
        }
        return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: number)!)
    }
}

/// A separate protocol: intentionally not wire-compatible with Oink.
enum SharingEdge: String, Codable, CaseIterable, Sendable, Identifiable {
    case left, right, top, bottom
    var id: String { rawValue }
    var title: String {
        switch self { case .left: "左侧"; case .right: "右侧"; case .top: "上方"; case .bottom: "下方" }
    }
    var opposite: Self {
        switch self { case .left: .right; case .right: .left; case .top: .bottom; case .bottom: .top }
    }
    func isCrossing(_ point: CGPoint, delta: CGPoint, bounds: CGRect) -> Bool {
        switch self {
        case .left: point.x <= bounds.minX + 1 && delta.x < 0
        case .right: point.x >= bounds.maxX - 2 && delta.x > 0
        case .top: point.y <= bounds.minY + 1 && delta.y < 0
        case .bottom: point.y >= bounds.maxY - 2 && delta.y > 0
        }
    }
    func fraction(_ point: CGPoint, bounds: CGRect) -> Double {
        let value = self == .left || self == .right
            ? (point.y - bounds.minY) / max(1, bounds.height)
            : (point.x - bounds.minX) / max(1, bounds.width)
        return min(1, max(0, value))
    }
    func entryPoint(fraction: Double, bounds: CGRect) -> CGPoint {
        let f = min(1, max(0, fraction))
        switch self {
        case .left: return .init(x: bounds.minX + 4, y: bounds.minY + f * (bounds.height - 1))
        case .right: return .init(x: bounds.maxX - 5, y: bounds.minY + f * (bounds.height - 1))
        case .top: return .init(x: bounds.minX + f * (bounds.width - 1), y: bounds.minY + 4)
        case .bottom: return .init(x: bounds.minX + f * (bounds.width - 1), y: bounds.maxY - 5)
        }
    }
}

struct SharingLayoutPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    static let zero = Self(x: 0, y: 0)
    var point: CGPoint { CGPoint(x: x, y: y) }
    var mirrored: Self { Self(x: -x, y: -y) }
    func validate() throws {
        guard x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { throw PluginError.invalid("屏幕布局坐标无效。") }
    }
}
struct SharingLayoutStamp: Codable, Equatable, Comparable, Sendable {
    var counter: UInt64
    var author: String
    static func < (a: Self, b: Self) -> Bool { a.counter == b.counter ? a.author < b.author : a.counter < b.counter }
    func validate() throws {
        guard counter <= 1_000_000_000_000, UUID(uuidString: author) != nil else { throw PluginError.invalid("屏幕布局版本无效。") }
    }
}
struct SharingCursorPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { throw PluginError.invalid("无效的光标返回位置。") }
    }
}

/// Tracks queued receiver movement independently of the asynchronously updated OS cursor.
struct SharingPointerAccumulator {
    private(set) var position: CGPoint
    mutating func advance(x: Double, y: Double, constrain: (CGPoint) -> CGPoint) -> CGPoint {
        position = constrain(CGPoint(x: position.x + x, y: position.y + y))
        return position
    }
}

struct SharingInputPacket: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case move, down, up, keyDown, keyUp, flags, scroll }
    var kind: Kind
    var code: Int = 0
    var flags: UInt64 = 0
    var x: Double = 0
    var y: Double = 0
    var clickCount: Int = 1
    var pressed: Bool = false // individual modifier state; combined flags cannot distinguish left/right release
    static let allowedFlags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskNumericPad.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue
    func validate() throws {
        guard x.isFinite, y.isFinite, abs(x) <= 4096, abs(y) <= 4096,
              flags & ~Self.allowedFlags == 0, (0...255).contains(code), (0...3).contains(clickCount),
              ![Kind.down, .up].contains(kind) || code <= 31,
              kind != .flags || [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code) else {
            throw PluginError.invalid("收到无效的外设输入。")
        }
    }
}

/// Event-free bookkeeping shared by physical handoff and remote release handling.
struct SharingHeldInputState: Equatable, Sendable {
    private(set) var keys = Set<Int>()
    private(set) var buttons = Set<Int>()
    var isNeutral: Bool { keys.isEmpty && buttons.isEmpty }
    /// Modifiers must be released as flagsChanged, never as ordinary keyUp events.
    func releasePlan(including other: Self = Self()) -> [SharingInputPacket] {
        let modifiers: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
        return keys.union(other.keys).sorted().map { SharingInputPacket(kind: modifiers.contains($0) ? .flags : .keyUp, code: $0, flags: 0, pressed: false) }
            + buttons.union(other.buttons).sorted().map { SharingInputPacket(kind: .up, code: $0, flags: 0) }
    }
    mutating func observe(_ packet: SharingInputPacket) {
        switch packet.kind {
        case .keyDown: keys.insert(packet.code)
        case .keyUp: keys.remove(packet.code)
        case .down: buttons.insert(packet.code)
        case .up: buttons.remove(packet.code)
        case .flags:
            if packet.pressed && packet.code != 57 { keys.insert(packet.code) }
            else { keys.remove(packet.code) }
        default: break
        }
    }
}

struct SharingMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case hello, begin, accepted, commit, end, input, micDemand, micState, audio, ping, layout, layoutAck }
    var kind: Kind
    var version: Int? = nil
    var deviceID: String? = nil
    var name: String? = nil
    var edge: SharingEdge? = nil
    var position: Double? = nil
    var input: SharingInputPacket? = nil
    var enabled: Bool? = nil
    var audio: Data? = nil // 48 kHz, mono, Float32 little endian; never played on speakers.
    var layoutSync: Bool? = nil // Hello capability: old v1 peers ignore these optional fields.
    var layoutVersion: Int? = nil
    var screenAspect: Double? = nil
    var layoutOffset: SharingLayoutPoint? = nil
    var layoutStamp: SharingLayoutStamp? = nil
    var returnPosition: SharingCursorPosition? = nil
    var screenPixels: SharingScreenPixels? = nil
    var cursorParking: Bool? = nil // Opt-in lifecycle capability; old peers ignore it.
    var handoffID: String? = nil
    var returned: Bool? = nil // Normal edge return, not emergency/cancel/disconnect.
    var keyboardEnabled: Bool? = nil // Hello/ping state only; never authorizes remote enablement.

    func validate() throws {
        if let screenAspect { guard screenAspect.isFinite, (0.1...10).contains(screenAspect) else { throw PluginError.invalid("屏幕比例无效。") } }
        try layoutOffset?.validate(); try layoutStamp?.validate(); try returnPosition?.validate(); try screenPixels?.validate()
        if let handoffID, UUID(uuidString: handoffID) == nil { throw PluginError.invalid("无效的接力标识。") }
        if returned == true, kind != .end || handoffID == nil { throw PluginError.invalid("正常归还缺少接力标识。") }
        if layoutVersion == 2 { guard layoutOffset != nil, layoutStamp != nil, screenAspect != nil else { throw PluginError.invalid("自由布局信息不完整。") } }
        if layoutVersion == 3 {
            guard let screenPixels, let screenAspect, abs(screenPixels.aspect - screenAspect) < 0.0001,
                  layoutStamp != nil, kind != .layout || layoutOffset != nil else { throw PluginError.invalid("像素布局信息不完整。") }
        }
        switch kind {
        case .hello:
            guard version == 1, let deviceID, UUID(uuidString: deviceID) != nil,
                  let name, !name.isEmpty, name.count <= 80 else { throw PluginError.invalid("对端协议版本或设备信息不兼容。") }
        case .layout:
            guard edge != nil else { throw PluginError.invalid("布局消息缺少屏幕方向。") }
        case .layoutAck:
            guard layoutStamp != nil else { throw PluginError.invalid("缺少布局确认版本。") }
        case .begin:
            guard edge != nil, let position, position.isFinite, (0...1).contains(position) else { throw PluginError.invalid("无效的屏幕切换请求。") }
        case .commit:
            guard handoffID != nil else { throw PluginError.invalid("接管提交缺少接力标识。") }
        case .input:
            guard let input else { throw PluginError.invalid("缺少输入数据。") }
            try input.validate()
        case .micDemand, .micState:
            guard enabled != nil else { throw PluginError.invalid("无效的麦克风状态。") }
        case .audio:
            guard let audio, !audio.isEmpty, audio.count <= 32768, audio.count.isMultiple(of: 4) else { throw PluginError.invalid("无效的麦克风音频包。") }
            let valid = audio.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 4).allSatisfy { offset in
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))).isFinite
                }
            }
            guard valid else { throw PluginError.invalid("无效的音频采样。") }
        default: break
        }
    }
}

struct SharingFramer {
    static let maximumBytes = 256 * 1024
    private var buffer = Data()
    static func encode(_ message: SharingMessage) throws -> Data {
        try message.validate()
        let body = try JSONEncoder().encode(message)
        guard body.count <= maximumBytes else { throw PluginError.invalid("共享数据过大。") }
        var length = UInt32(body.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(body)
        return framed
    }
    mutating func append(_ data: Data) throws -> [SharingMessage] {
        guard buffer.count + data.count <= Self.maximumBytes + 65540 else { throw PluginError.invalid("共享缓冲超出限制。") }
        buffer.append(data)
        var messages: [SharingMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumBytes else { throw PluginError.invalid("共享数据长度无效。") }
            guard buffer.count >= length + 4 else { break }
            let message = try JSONDecoder().decode(SharingMessage.self, from: Data(buffer.dropFirst(4).prefix(length)))
            try message.validate()
            messages.append(message)
            buffer = Data(buffer.dropFirst(length + 4))
        }
        return messages
    }
}

enum SharingPairingKey {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PluginError.invalid("无法生成安全配对密钥。") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func decode(_ text: String) throws -> Data {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PluginError.invalid("请粘贴另一台 Mac 生成的完整 64 位配对密钥。")
        }
        return Data(stride(from: 0, to: 64, by: 2).map { i in
            UInt8(value[value.index(value.startIndex, offsetBy: i)..<value.index(value.startIndex, offsetBy: i + 2)], radix: 16)!
        })
    }
    private static let service = HostInfo.bundleIdentifier + ".peripheral-sharing"
    private static let account = "pairing-v1"
    static func load() -> String? {
        guard let data = try? AppCredentials.read(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        _ = try decode(value)
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
        try AppCredentials.save(data, service: service, account: account)
    }
    static func delete() throws {
        try AppCredentials.delete(service: service, account: account)
    }
}
