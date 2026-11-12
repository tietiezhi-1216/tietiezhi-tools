// Standalone acceptance fixture. Uses the product protocol and TLS transport.
// Does not observe/inject local input, capture a microphone, grant permissions, or save audio.
import Foundation
import Network

// The standalone build excludes the app's manifest module; preserve its error contract.
enum PluginError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { text } else { nil } }
}

private struct FixtureRequest: Decodable {
    let id: UUID
    let action: String
    var packets: [SharingInputPacket]?
}

@MainActor private final class Fixture {
    let transport = SharingTransport()
    let directory: URL
    let microphone: Bool
    var phase = "starting"
    var failure = ""
    var hello = false
    var accepted = false
    var lastCommand = ""
    var packetCount = 0
    var frames = 0
    var sumSquares = 0.0
    var peak = 0.0
    var microphoneBegan: Date?
    var demandStopped: Date?
    var stoppedByPeer = false
    var controlDeadline: Date?

    init(directory: URL, microphone: Bool) {
        self.directory = directory; self.microphone = microphone
        transport.connected = { [weak self] in
            guard let self else { return }
            self.phase = "connected"
            self.transport.send(.init(kind: .hello, version: 1, deviceID: UUID().uuidString,
                                      name: microphone ? "验收音量接收端" : "验收模拟输入源"))
        }
        transport.received = { [weak self] message in self?.receive(message) }
        transport.disconnected = { [weak self] error in
            self?.accepted = false
            if let error { self?.failure = error }
        }
    }
    private func receive(_ message: SharingMessage) {
        switch message.kind {
        case .hello:
            hello = true; phase = "hello"
            if microphone { transport.send(.init(kind: .micDemand, enabled: true)) }
        case .accepted:
            accepted = true; phase = "accepted"; controlDeadline = Date().addingTimeInterval(4)
        case .end: accepted = false; phase = "returned"
        case .micState:
            if message.enabled == true { phase = "microphone-active" }
            else if demandStopped != nil { stoppedByPeer = true; phase = "microphone-stopped" }
        case .audio:
            guard microphone, let data = message.audio else { return }
            if microphoneBegan == nil { microphoneBegan = Date() }
            data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    let value = Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
                    if value.isFinite { frames += 1; sumSquares += value * value; peak = max(peak, abs(value)) }
                }
            }
        default: break
        }
    }
    func tick() throws {
        let url = directory.appendingPathComponent("producer-command.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
                  ((attrs[.size] as? NSNumber)?.intValue ?? 65537) <= 65536 else { throw PluginError.invalid("Invalid private fixture request") }
            let request = try JSONDecoder().decode(FixtureRequest.self, from: Data(contentsOf: url))
            if request.id.uuidString != lastCommand {
                lastCommand = request.id.uuidString
                switch request.action {
                case "begin":
                    guard hello else { throw PluginError.invalid("Peer not authenticated") }
                    transport.send(.init(kind: .begin, edge: .right, position: 0.5))
                case "input":
                    guard accepted, let packets = request.packets, packets.count <= 40 else { throw PluginError.invalid("No permitted control session") }
                    for packet in packets { try packet.validate() }
                    for packet in packets { transport.send(.init(kind: .input, input: packet)); packetCount += 1 }
                case "end":
                    transport.send(.init(kind: .end)); accepted = false; phase = "returned"
                default: throw PluginError.invalid("Unknown fixture action")
                }
            }
        }
        if let controlDeadline, Date() >= controlDeadline {
            transport.send(.init(kind: .end)); accepted = false; self.controlDeadline = nil; phase = "returned"
        }
        if let microphoneBegan, demandStopped == nil, Date().timeIntervalSince(microphoneBegan) >= 3 {
            transport.send(.init(kind: .micDemand, enabled: false)); demandStopped = Date()
        }
        try report()
    }
    func report() throws {
        let value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "phase": phase, "error": failure, "hello": hello, "accepted": accepted,
            "lastCommand": lastCommand, "packetsSent": packetCount, "frames": frames,
            "rms": frames == 0 ? 0 : sqrt(sumSquares / Double(frames)), "peak": peak,
            "stoppedByPeer": stoppedByPeer, "capturesLocalInput": false, "audioSaved": false,
            "updatedAt": Date().timeIntervalSince1970]
        let url = directory.appendingPathComponent("producer-status.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@main struct SharingSyntheticPeer {
    @MainActor static func main() async {
        var fixture: Fixture?
        do {
            let args = CommandLine.arguments
            guard args.count == 5, let port = UInt16(args[3]), port > 0 else {
                throw PluginError.invalid("Usage: SyntheticPeer <private-directory> <peer-host> <peer-port> <input|microphone>")
            }
            let directory = URL(fileURLWithPath: args[1], isDirectory: true)
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw PluginError.invalid("Fixture directory must be private") }
            let key = try SharingPairingKey.decode(String(contentsOf: directory.appendingPathComponent("pairing-key"), encoding: .utf8))
            let peer = Fixture(directory: directory, microphone: args[4] == "microphone"); fixture = peer
            try peer.transport.start(key: key, name: "private-fixture", localOnly: true)
            let readyDeadline = Date().addingTimeInterval(5)
            while peer.transport.port == nil && Date() < readyDeadline { try await Task.sleep(for: .milliseconds(20)) }
            try peer.transport.connect(.hostPort(host: NWEndpoint.Host(args[2]), port: NWEndpoint.Port(rawValue: port)!))
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, peer.failure.isEmpty {
                try peer.tick()
                if let stopped = peer.demandStopped, peer.stoppedByPeer, Date().timeIntervalSince(stopped) > 1 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            peer.transport.send(.init(kind: .end)); peer.transport.send(.init(kind: .micDemand, enabled: false))
            try? await Task.sleep(for: .milliseconds(100))
            peer.transport.stop(); try peer.report()
        } catch {
            fixture?.transport.stop(); fixture?.failure = error.localizedDescription; try? fixture?.report()
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
