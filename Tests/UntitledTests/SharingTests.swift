import AppKit
@preconcurrency import AVFoundation
import Foundation
import Network
import Testing
@testable import Untitled

@Suite(.serialized) struct SharingTests {
    @Test func manualConnectionAcceptsLANVPNDNSAndIPv6ButNotURLsOrInvalidPorts() throws {
        for host in ["192.168.1.10", "100.64.0.10", "peer.tailnet.example", "::1", "[fd7a:115c:a1e0::1234]"] {
            guard case .hostPort(_, let port) = try SharingManualEndpoint.parse(host: host, port: "48479") else { Issue.record("Not a host endpoint"); continue }
            #expect(port.rawValue == 48479)
        }
        for host in ["", "https://100.64.0.10", "user@server", "server/path", "bad name", "a..b"] {
            #expect(throws: PluginError.self) { try SharingManualEndpoint.parse(host: host, port: "48479") }
        }
        for port in ["", "0", "65536", "-1", "22/ssh", "１２"] {
            #expect(throws: PluginError.self) { try SharingManualEndpoint.parse(host: "localhost", port: port) }
        }
    }
    @Test @MainActor func dailySetupOnlyReadsBoundedPrivateOwnedProfiles() throws {
        let caches = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let directory = caches.appendingPathComponent("com.untitled.app/SharingSetup/session", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: caches) }
        let key = try SharingPairingKey.generate()
        let url = directory.appendingPathComponent("profile.json")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "pairingKey": key, "peerName": "Test Mac", "peerHost": "192.0.2.81", "edge": "right"])
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let profile = try SharingSetupSession.readProfile(url, caches: caches)
        #expect(profile.peerHost == "192.0.2.81" && profile.fingerprint.count == 17)
        #expect(try SharingPairingKey.decode(profile.pairingKey) == SharingPairingKey.decode(key))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: PluginError.self) { try SharingSetupSession.readProfile(url, caches: caches) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(throws: PluginError.self) { try SharingSetupSession.readProfile(url, caches: caches) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: PluginError.self) { try SharingSetupSession.readProfile(link, caches: caches) }
        try Data(repeating: 0x20, count: 8193).write(to: url)
        #expect(throws: PluginError.self) { try SharingSetupSession.readProfile(url, caches: caches) }
    }
    @Test func dailySetupRejectsInvalidVersionsKeysAndEndpoints() throws {
        let key = try SharingPairingKey.generate()
        for fields: [String: Any] in [
            ["version": 2, "pairingKey": key, "peerName": "Mac", "edge": "right"],
            ["version": 1, "pairingKey": "bad", "peerName": "Mac", "edge": "left"],
            ["version": 1, "pairingKey": key, "peerName": "Mac", "peerHost": "https://bad", "edge": "left"],
        ] {
            let profile = try JSONDecoder().decode(SharingSetupProfile.self, from: JSONSerialization.data(withJSONObject: fields))
            #expect(throws: PluginError.self) { try profile.validate() }
        }
    }
    #if DEBUG
    @Test @MainActor func acceptanceInboxRequiresPrivateOwnedCacheDirectory() throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("com.untitled.app/SharingAcceptance/test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try SharingAcceptance.validateDirectory(directory, caches: caches)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(throws: PluginError.self) { try SharingAcceptance.validateDirectory(directory, caches: caches) }
        #expect(throws: PluginError.self) { try SharingAcceptance.validateDirectory(FileManager.default.temporaryDirectory, caches: caches) }
    }
    @Test func acceptanceProtocolHasNoShellOrPrivilegeActions() throws {
        let request = Data("{\"id\":\"\(UUID().uuidString)\",\"action\":\"runShell\",\"command\":\"true\"}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SharingAcceptanceRequest.self, from: request) }
    }
    #endif
    @Test func pairingKeysHaveFullEntropyAndStrictSyntax() throws {
        let a = try SharingPairingKey.generate(), b = try SharingPairingKey.generate()
        #expect(a.count == 64 && a != b)
        #expect(try SharingPairingKey.decode(a).count == 32)
        #expect(try SharingPairingKey.decode("  \(a.uppercased())\n") == SharingPairingKey.decode(a))
        for invalid in ["123456", String(repeating: "g", count: 64), String(repeating: "a", count: 63), a + "00"] {
            #expect(throws: PluginError.self) { try SharingPairingKey.decode(invalid) }
        }
    }
    @Test func streamFramingHandlesFragmentationAndCoalescing() throws {
        let hello = SharingMessage(kind: .hello, version: 1, deviceID: UUID().uuidString, name: "测试 Mac")
        let input = SharingInputPacket(kind: .keyDown, code: 40, flags: 0)
        let messages = [hello, .init(kind: .input, input: input), .init(kind: .ping)]
        let bytes = try messages.reduce(into: Data()) { $0.append(try SharingFramer.encode($1)) }
        for chunkSize in [1, 3, 4, 7, 16, bytes.count] {
            var decoder = SharingFramer(), decoded: [SharingMessage] = []
            for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
                decoded += try decoder.append(Data(bytes.dropFirst(offset).prefix(chunkSize)))
            }
            #expect(decoded.map(\.kind) == messages.map(\.kind))
            #expect(decoded[1].input == input)
        }
    }
    @Test func framingRejectsOversizedAndMalformedData() throws {
        for bytes in [Data([0, 0, 0, 0]), Data([0, 4, 0, 1]), Data([0, 0, 0, 1, 123])] {
            var decoder = SharingFramer()
            #expect(throws: (any Error).self) { try decoder.append(bytes) }
        }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .hello, version: 999, deviceID: UUID().uuidString, name: "Mac").validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .begin, edge: .right, position: .infinity).validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .micDemand).validate() }
    }
    @Test func validatesUntrustedInputAndAudioBeforeInjection() throws {
        var packet = SharingInputPacket(kind: .move, x: 10, y: -10)
        try packet.validate()
        packet.x = .nan
        #expect(throws: PluginError.self) { try packet.validate() }
        packet.x = 5000
        #expect(throws: PluginError.self) { try packet.validate() }
        packet.x = 0; packet.code = 256
        #expect(throws: PluginError.self) { try packet.validate() }
        packet.code = 0; packet.flags = 1 << 63
        #expect(throws: PluginError.self) { try packet.validate() }
        packet.flags = 0; packet.kind = .down; packet.code = 32
        #expect(throws: PluginError.self) { try packet.validate() }
        var sample = Float(0.5)
        let data = withUnsafeBytes(of: &sample) { Data($0) }
        try SharingMessage(kind: .audio, audio: data).validate()
        sample = .nan
        let bad = withUnsafeBytes(of: &sample) { Data($0) }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .audio, audio: bad).validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .audio, audio: Data([1, 2, 3])).validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .audio, audio: Data(count: 32772)).validate() }
    }
    @Test func queuedPointerMovesNeverReuseTheStaleSystemCursor() {
        var pointer = SharingPointerAccumulator(position: CGPoint(x: 4, y: 100))
        let constrain: (CGPoint) -> CGPoint = { CGPoint(x: min(1919, max(0, $0.x)), y: min(1079, max(0, $0.y))) }
        #expect(pointer.advance(x: 100, y: 20, constrain: constrain) == CGPoint(x: 104, y: 120))
        #expect(pointer.advance(x: 200, y: -10, constrain: constrain) == CGPoint(x: 304, y: 110))
        // A click queued before the OS processes those moves uses this logical position.
        #expect(pointer.position == CGPoint(x: 304, y: 110))
        #expect(pointer.advance(x: 4096, y: 4096, constrain: constrain) == CGPoint(x: 1919, y: 1079))
    }
    @Test func screenEdgesUseGlobalCoordinatesAndOppositeEntry() {
        let bounds = CGRect(x: -1920, y: -100, width: 3840, height: 1200)
        #expect(SharingEdge.left.isCrossing(.init(x: -1920, y: 400), delta: .init(x: -1, y: 0), bounds: bounds))
        #expect(!SharingEdge.left.isCrossing(.init(x: -1920, y: 400), delta: .init(x: 1, y: 0), bounds: bounds))
        #expect(SharingEdge.top.isCrossing(.init(x: 200, y: -100), delta: .init(x: 0, y: -1), bounds: bounds))
        for edge in SharingEdge.allCases {
            #expect(edge.opposite.opposite == edge)
            let point = edge.entryPoint(fraction: 0.5, bounds: bounds)
            #expect(bounds.contains(point))
            #expect(abs(edge.fraction(point, bounds: bounds) - 0.5) < 0.01)
        }
    }
    @Test func handoffWaitsForCompletePhysicalDownUpPairsAndModifierRelease() {
        var state = SharingHeldInputState()
        // A shortcut begins with its modifiers held. Don't activate on acknowledgement yet.
        state.observe(.init(kind: .flags, code: 59, pressed: true))
        state.observe(.init(kind: .flags, code: 55, pressed: true))
        state.observe(.init(kind: .keyDown, code: 40))
        #expect(!state.isNeutral)
        state.observe(.init(kind: .keyUp, code: 40))
        state.observe(.init(kind: .flags, code: 59, pressed: false))
        #expect(!state.isNeutral)
        state.observe(.init(kind: .flags, code: 55, pressed: false))
        #expect(state.isNeutral)
        // A mouse-down during negotiation must receive its matching local mouse-up first.
        state.observe(.init(kind: .down, code: 0))
        #expect(!state.isNeutral)
        state.observe(.init(kind: .up, code: 0))
        #expect(state.isNeutral)
        // Releasing left Command while right Command stays down must remove only the left key.
        state.observe(.init(kind: .flags, code: 54, pressed: true))
        state.observe(.init(kind: .flags, code: 55, pressed: true))
        state.observe(.init(kind: .flags, code: 55, flags: CGEventFlags.maskCommand.rawValue, pressed: false))
        #expect(state.keys == [54])
        state.observe(.init(kind: .flags, code: 54, pressed: false))
        #expect(state.isNeutral) // edge-return is possible again
    }
    @Test func cleanupUsesModifierReleaseEventsAndClearsEveryHeldButton() throws {
        var state = SharingHeldInputState()
        state.observe(.init(kind: .keyDown, code: 0))
        state.observe(.init(kind: .flags, code: 55, pressed: true))
        state.observe(.init(kind: .flags, code: 58, pressed: true))
        state.observe(.init(kind: .down, code: 0))
        state.observe(.init(kind: .down, code: 3))
        let plan = state.releasePlan()
        #expect(plan.map(\.kind) == [.keyUp, .flags, .flags, .up, .up])
        #expect(plan.map(\.code) == [0, 55, 58, 0, 3])
        #expect(plan.allSatisfy { $0.flags == 0 && !$0.pressed })
        for packet in plan { try packet.validate(); state.observe(packet) }
        #expect(state.isNeutral && state.releasePlan().isEmpty)
    }
    @Test func microphoneConversionHandlesStereoAndLargeHardwareCallbacks() throws {
        for rate in [48000.0, 44100.0] {
            for frames in [960, 16384] {
                let source = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = AVAudioFrameCount(frames)
                for channel in 0..<2 { for index in 0..<frames { buffer.floatChannelData![channel][index] = 0.25 } }
                let mailbox = SharingAudioMailbox()
                let converter = try #require(SharingAudioConverter(source: source, mailbox: mailbox))
                converter.consume(buffer)
                let packets = mailbox.drain()
                #expect(!packets.isEmpty, "Missing mono output at \(rate) Hz, \(frames) input frames")
                #expect(packets.allSatisfy { !$0.isEmpty && $0.count <= 32768 && $0.count.isMultiple(of: 4) })
            }
        }
    }
    @Test func audioMailboxHasBoundedBacklog() {
        let mailbox = SharingAudioMailbox()
        for value in 0..<20 { mailbox.push(Data([UInt8(value)])) }
        let packets = mailbox.drain()
        #expect(packets.count == 6)
        #expect(packets.first == Data([14]))
        #expect(mailbox.drain().isEmpty)
        mailbox.push(Data(count: 32769))
        #expect(mailbox.drain().isEmpty)
    }
    @Test @MainActor func pluginIsDeclarativeAndInstallationDoesNotStartSharing() throws {
        let manifest = try manifest()
        try manifest.validate()
        let registry = PluginComposition.makeUIRegistry()
        try registry.validate(manifest)
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory)
        try store.installManifest(manifest)
        let controller = store.peripheralSharing(for: manifest.id)
        #expect(!controller.isRunning && !controller.keyboardMouseEnabled)
        #expect(!controller.microphoneOffered && !controller.wantsRemoteMicrophone)
        #expect(controller.transport.port == nil)
        #expect(!ActionKind.sharePeripherals.isScreenshotAction)
        #expect(!ActionKind.switchPeripheralControl.isScreenshotAction)
        #expect(!ActionKind.stopPeripheralSharing.isScreenshotAction)
        #expect(manifest.permissions?.map(\.id) == [.accessibility, .inputMonitoring, .microphone])
    }
    @Test @MainActor func disablingAndUninstallingReleaseServices() throws {
        let manifest = try manifest(), directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory)
        try store.installManifest(manifest)
        let controller = store.peripheralSharing(for: manifest.id)
        try controller.start(key: SharingPairingKey.generate(), localOnly: true)
        controller.setMicrophoneOffered(true)
        #expect(controller.isRunning)
        store.setEnabled(false, pluginID: manifest.id)
        #expect(!controller.isRunning && !controller.microphoneOffered)
        #expect(controller.transport.port == nil && controller.control == .local)
        #expect(throws: PluginError.self) { try controller.start(key: SharingPairingKey.generate(), localOnly: true) }
        store.setEnabled(true, pluginID: manifest.id)
        #expect(!controller.isRunning) // re-enabling never resumes a privileged session
        try controller.start(key: SharingPairingKey.generate(), localOnly: true)
        store.uninstall(manifest.id)
        #expect(!controller.isRunning && controller.transport.port == nil)
    }
    @Test @MainActor func missingPermissionCannotStartInputCapture() throws {
        let suite = "sharing-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Explicit closures fail before CGEventTap creation or any OS authorization request.
        let controller = PeripheralSharingController(defaults: defaults)
        defer { controller.stop(); defaults.removePersistentDomain(forName: suite) }
        controller.isAllowed = { true }
        var requests = 0
        controller.requirePermissions = { _ in requests += 1; throw HostPermissionError.missing }
        try controller.start(key: SharingPairingKey.generate(), localOnly: true)
        #expect(throws: HostPermissionError.self) { try controller.setKeyboardMouse(true) }
        #expect(!controller.keyboardMouseEnabled && requests == 1)
        controller.setMicrophoneOffered(true)
        #expect(requests == 1 && !controller.isSendingMicrophone) // no demand => no microphone request
    }
    @Test @MainActor func explicitLayoutChangesMirrorOverTLSWithoutEnablingInput() async throws {
        let one = "layout-a-\(UUID().uuidString)", two = "layout-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let a = PeripheralSharingController(defaults: da), b = PeripheralSharingController(defaults: db)
        a.isAllowed = { true }; b.isAllowed = { true }; b.edge = .bottom
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.peerSupportsLayoutSync && b.peerSupportsLayoutSync })
        a.setLayoutEdge(.left)
        #expect(await wait { b.edge == .right })
        b.setLayoutEdge(.top)
        #expect(await wait { a.edge == .bottom })
        #expect(da.string(forKey: "sharing.edge") == "bottom" && db.string(forKey: "sharing.edge") == "top")
        #expect(!a.keyboardMouseEnabled && !b.keyboardMouseEnabled && !a.microphoneOffered && !b.microphoneOffered)
        #expect(a.sentInputPackets == 0 && b.receivedInputPackets == 0)
    }
    @Test @MainActor func sharingResumesOnlyAnExplicitPriorStartAndNeverAfterUserStop() async throws {
        let domain = "sharing-intent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!, key = try SharingPairingKey.generate()
        let controller = PeripheralSharingController(defaults: defaults, input: SharingInput(tapReadyOverride: { true }, receiverWarp: { _ in .success }), loadPairingKey: { key }, inputAccessAvailable: { true })
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defaults.set(false, forKey: "sharing.inputDesired")
        defer { controller.stop(); defaults.removePersistentDomain(forName: domain) }
        try controller.restoreUserSessionIfRequested(localOnly: true)
        #expect(!controller.isRunning)
        try controller.startUserSession(localOnly: true)
        #expect(controller.isRunning && defaults.bool(forKey: "sharing.sessionEnabled"))
        controller.stop() // Normal process shutdown/upgrade does not erase the user's on switch.
        try controller.restoreUserSessionIfRequested(localOnly: true)
        #expect(controller.isRunning && controller.keyboardMouseEnabled && !controller.microphoneOffered)
        controller.stopUserSession()
        try controller.restoreUserSessionIfRequested(localOnly: true)
        #expect(!controller.isRunning && !defaults.bool(forKey: "sharing.sessionEnabled"))
    }
    @Test @MainActor func deniedKeyboardPermissionCannotLeaveAnApparentlyOnShareSwitch() throws {
        let domain = "sharing-denied-\(UUID().uuidString)", defaults = UserDefaults(suiteName: domain)!
        let key = try SharingPairingKey.generate()
        let controller = PeripheralSharingController(defaults: defaults, input: SharingInput(tapReadyOverride: { true }), loadPairingKey: { key })
        controller.isAllowed = { true }; controller.requirePermissions = { _ in throw PluginError.invalid("permission denied") }
        defer { controller.stop(); defaults.removePersistentDomain(forName: domain) }
        #expect(throws: PluginError.self) { try controller.startUserSession(localOnly: true) }
        #expect(!controller.isRunning && !controller.keyboardMouseEnabled && controller.transport.port == nil)
        #expect(!controller.microphoneOffered && !controller.isSendingMicrophone)
    }
    @Test @MainActor func startupWaitsAndRetriesWhenTheOtherMacStartsLater() async throws {
        let domain = "sharing-retry-\(UUID().uuidString)", defaults = UserDefaults(suiteName: domain)!
        let key = try SharingPairingKey.generate(), peer = SharingTransport()
        let controller = PeripheralSharingController(defaults: defaults, input: SharingInput(tapReadyOverride: { true }, receiverWarp: { _ in .success }), loadPairingKey: { key }, inputAccessAvailable: { true })
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defer { controller.stop(); peer.stop(); defaults.removePersistentDomain(forName: domain) }
        try peer.start(key: SharingPairingKey.decode(key), name: "port-reservation", localOnly: true)
        #expect(await wait { peer.port != nil })
        let port = try #require(peer.port).rawValue; peer.stop()
        try? await Task.sleep(for: .milliseconds(100))
        defaults.set("127.0.0.1", forKey: "sharing.lastPeerHost"); defaults.set(String(port), forKey: "sharing.lastPeerPort")
        var failedOnce = false
        controller.transport.diagnostics = { if $0.contains("failed") || $0.contains("waiting") { failedOnce = true } }
        try controller.startUserSession(localOnly: true)
        #expect(await wait { failedOnce })
        peer.connected = { peer.send(.init(kind: .hello, version: 1, deviceID: UUID().uuidString, name: "Late Mac")) }
        try peer.start(key: SharingPairingKey.decode(key), name: "late", localOnly: true, listenPort: port)
        #expect(await wait { controller.peerName == "Late Mac" })
        #expect(controller.isRunning && controller.keyboardMouseEnabled && controller.sentInputPackets == 0)
    }
    @Test @MainActor func freeOffsetIsMirroredAndAcknowledgedBeforeEdgeSwitching() async throws {
        let one = "free-a-\(UUID().uuidString)", two = "free-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let stamp = SharingLayoutStamp(counter: 4, author: UUID().uuidString)
        for settings in [da, db] { settings.set(try JSONEncoder().encode(stamp), forKey: "sharing.layoutStamp") }
        da.set(try JSONEncoder().encode(SharingLayoutPoint(x: -200, y: 20)), forKey: "sharing.layoutOffset")
        db.set(try JSONEncoder().encode(SharingLayoutPoint(x: 200, y: -20)), forKey: "sharing.layoutOffset")
        da.set(1920.0 / 1080, forKey: "sharing.peerAspect"); db.set(2560.0 / 1080, forKey: "sharing.peerAspect")
        let a = PeripheralSharingController(defaults: da, screenPixels: .init(width: 2560, height: 1080))
        let b = PeripheralSharingController(defaults: db, screenPixels: .init(width: 1920, height: 1080))
        a.isAllowed = { true }; b.isAllowed = { true }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady })
        #expect(a.peerSupportsFreeLayout && b.peerSupportsFreeLayout)
        #expect(a.peerPixels == b.localPixels && b.peerPixels == a.localPixels)
        #expect(a.layoutOffset.x == -2240 && b.layoutOffset == a.layoutOffset.mirrored)
        #expect(abs(a.workspace.localRect.height - a.workspace.peerRect.height) < 0.001)
        a.setLayoutOffset(.init(x: -3320, y: 47))
        #expect(!a.layoutReady)
        #expect(await wait { a.layoutReady && b.layoutOffset == .init(x: 3320, y: -47) })
        #expect(a.layoutStamp == b.layoutStamp)
        b.setLayoutOffset(.init(x: 3285, y: 80))
        #expect(await wait { b.layoutReady && a.layoutOffset == .init(x: -3285, y: -80) })
        #expect(a.sentInputPackets == 0 && b.receivedInputPackets == 0)
    }
    @Test @MainActor func equalWidthFreeLayoutPeerFallsBackWithoutReceivingPixelCoordinates() async throws {
        let domain = "layout-v2-\(UUID().uuidString)", defaults = UserDefaults(suiteName: domain)!
        let a = PeripheralSharingController(defaults: defaults), old = SharingTransport(), identity = UUID().uuidString
        let key = try SharingPairingKey.generate(); var layouts: [SharingMessage] = []
        a.isAllowed = { true }
        old.connected = { old.send(.init(kind: .hello, version: 1, deviceID: identity, name: "v2 Mac", layoutSync: true,
            layoutVersion: 2, screenAspect: 1.6, layoutOffset: .init(x: 200, y: 0), layoutStamp: .init(counter: 0, author: identity))) }
        old.received = { if $0.kind == .layout { layouts.append($0) } }
        defer { a.stop(); old.stop(); defaults.removePersistentDomain(forName: domain) }
        try a.start(key: key, localOnly: true); try old.start(key: SharingPairingKey.decode(key), name: "v2", localOnly: true)
        #expect(await wait { a.transport.port != nil && old.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(old.port).rawValue))
        #expect(await wait { a.peerName != nil })
        #expect(a.layoutReady && !a.peerSupportsFreeLayout)
        a.setLayoutEdge(.top)
        #expect(await wait { !layouts.isEmpty })
        #expect(layouts.allSatisfy { $0.layoutVersion == nil && $0.layoutOffset == nil && $0.edge == .top })
    }
    @Test @MainActor func olderPeersNeverReceiveUnsupportedLayoutMessages() async throws {
        let domain = "layout-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let a = PeripheralSharingController(defaults: defaults), legacy = SharingTransport()
        a.isAllowed = { true }
        let key = try SharingPairingKey.generate()
        var layoutMessages = 0
        legacy.connected = { legacy.send(.init(kind: .hello, version: 1, deviceID: UUID().uuidString, name: "Legacy Mac")) }
        legacy.received = { if $0.kind == .layout { layoutMessages += 1 } }
        defer { a.stop(); legacy.stop(); defaults.removePersistentDomain(forName: domain) }
        try a.start(key: key, localOnly: true)
        try legacy.start(key: SharingPairingKey.decode(key), name: "legacy", localOnly: true)
        #expect(await wait { legacy.port != nil && a.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(legacy.port).rawValue))
        #expect(await wait { a.peerName != nil })
        #expect(!a.peerSupportsLayoutSync)
        a.setLayoutEdge(.top)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(layoutMessages == 0 && a.transport.isConnected && a.edge == .top)
    }
    @Test @MainActor func tlsPairExchangesFramedMessagesOnlyWithMatchingKey() async throws {
        let server = SharingTransport(), client = SharingTransport()
        let key = try SharingPairingKey.decode(SharingPairingKey.generate())
        var serverReady = false, clientReady = false, received = 0, failure: String?
        server.diagnostics = { print("server: \($0)") }; client.diagnostics = { print("client: \($0)") }
        server.connected = { serverReady = true }
        client.connected = { clientReady = true; client.send(.init(kind: .ping)) }
        server.received = { if $0.kind == .ping { received += 1 } }
        server.disconnected = { failure = $0 }
        client.disconnected = { failure = $0 }
        defer { client.stop(); server.stop() }
        try server.start(key: key, name: "loopback-server", localOnly: true)
        try client.start(key: key, name: "loopback-client", localOnly: true)
        #expect(await wait { server.port != nil && client.port != nil })
        #expect(server.port?.rawValue != 0 && client.port?.rawValue != 0)
        let port = try #require(server.port)
        try client.connect(.hostPort(host: "127.0.0.1", port: port))
        #expect(await wait { received == 1 || failure != nil })
        #expect(serverReady && clientReady && received == 1, "TLS failure: \(failure ?? "none")")
        #expect(!client.send(.init(kind: .ping), ifAllowed: { false }))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received == 1) // A revoked source lease cannot enqueue another frame.
        client.disconnect()
        #expect(await wait { !server.isConnected })
        // Reconnect on the same listeners after cleanup; no cached authenticated session.
        try client.connect(.hostPort(host: "127.0.0.1", port: port))
        #expect(await wait { received == 2 })
        #expect(server.isConnected && client.isConnected)
    }
    @Test @MainActor func tlsRejectsWrongPairingKey() async throws {
        let server = SharingTransport(), client = SharingTransport()
        var authenticated = false, failed = false
        var clientTLS: OSStatus?, serverTLS: OSStatus?
        server.diagnostics = { print("reject-server: \($0)") }; client.diagnostics = { print("reject-client: \($0)") }
        server.connected = { authenticated = true }
        client.connected = { authenticated = true }
        client.disconnected = { _ in failed = true }
        client.tlsHandshakeFailed = { clientTLS = $0 }
        server.tlsHandshakeFailed = { serverTLS = $0 }
        defer { client.stop(); server.stop() }
        try server.start(key: SharingPairingKey.decode(SharingPairingKey.generate()), name: "reject-server", localOnly: true)
        try client.start(key: SharingPairingKey.decode(SharingPairingKey.generate()), name: "reject-client", localOnly: true)
        #expect(await wait { server.port != nil && client.port != nil })
        let began = Date()
        try client.connect(.hostPort(host: "127.0.0.1", port: #require(server.port)))
        #expect(await wait { failed && clientTLS != nil && serverTLS != nil })
        #expect(clientTLS != nil && serverTLS != nil) // TCP/path failure or timeout is NOT proof of PSK authentication.
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(!authenticated && !server.isConnected && !client.isConnected)
    }
    @Test @MainActor func simultaneousDialHasOneSessionOrExplicitRetryableCollision() async throws {
        let a = SharingTransport(), b = SharingTransport()
        let key = try SharingPairingKey.decode(SharingPairingKey.generate())
        var reasonA: String?, reasonB: String?
        a.disconnected = { reasonA = $0 }; b.disconnected = { reasonB = $0 }
        defer { a.stop(); b.stop() }
        try a.start(key: key, name: "collision-a", localOnly: true)
        try b.start(key: key, name: "collision-b", localOnly: true)
        #expect(await wait { a.port != nil && b.port != nil })
        try a.connect(.hostPort(host: "127.0.0.1", port: #require(b.port)))
        try b.connect(.hostPort(host: "127.0.0.1", port: #require(a.port)))
        #expect(await wait { (a.isConnected && b.isConnected) || (reasonA?.contains("同时") == true && reasonB?.contains("同时") == true) })
        if !a.isConnected || !b.isConnected {
            #expect(!a.isConnected && !b.isConnected)
            #expect(reasonA?.contains("同时") == true && reasonB?.contains("同时") == true)
            // Either device can subsequently retry alone; a collision leaves no stuck candidate.
            try a.connect(.hostPort(host: "127.0.0.1", port: #require(b.port)))
            #expect(await wait { a.isConnected && b.isConnected })
        }
    }
    @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<650 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
    private func manifest() throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/peripheral-sharing/manifest.json")))
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sharing-tests-\(UUID().uuidString)", isDirectory: true) }
}
