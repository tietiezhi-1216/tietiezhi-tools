import AppKit
import Combine
@preconcurrency import ApplicationServices

@MainActor final class SharingInput {
    enum Mode { case local, preparingCapture, staged, controlling, receiving, parked }
    static let replayMarker: Int64 = 0x554E544C534852
    private static let receiverReplayPrefix: UInt64 = 0x554E_0000_0000_0000
    private static let releaseReplayPrefix: UInt64 = 0x554C_0000_0000_0000
    private static let localReplayPrefix: UInt64 = 0x554F_0000_0000_0000
    var send: (SharingInputPacket) -> Void = { _ in }
    var requestControl: (SharingEdge, Double) -> Void = { _, _ in }
    var returnLocal: (SharingCursorPosition?) -> Void = { _ in }
    var returnAcrossEdge: (SharingCursorPosition?) -> Void = { _ in }
    var localResumed: () -> Void = {}
    var physicalStateChanged: () -> Void = {}
    var failure: (String) -> Void = { _ in }
    var edge: SharingEdge = .right
    var workspace: SharingDisplayLayout?
    var canSwitch = false
    private(set) var mode: Mode = .local
    private var returnEdge: SharingEdge = .left
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var remoteHeld = SharingHeldInputState()
    private var deliveredRemoteHeld = SharingHeldInputState()
    private var physical = SharingHeldInputState()
    var isNeutral: Bool { physical.isNeutral }
    private var heldKeys: Set<Int> { remoteHeld.keys }
    private var heldButtons: Set<Int> { remoteHeld.buttons }
    private var shortcutKeys = Set<Int>()
    private var switchAllowedAt: TimeInterval = 0
    private var stagedMotion = CGPoint.zero // One bounded move, never keys queued for remote delivery.
    private let handoffClock: () -> TimeInterval
    private let cursor: SharingCursorCapture
    private let tapReadyOverride: (() -> Bool)?
    private let receiverWarp: (CGPoint) -> CGError
    private var resignObserver: AnyCancellable?
    private(set) var physicalMouseMovements = 0
    private(set) var externalInputEvents = 0
    private(set) var lastSafetyFailure: String?
    private var receiverCursor: SharingPointerAccumulator?
    private var receiverEpoch: UInt64 = 0, replaySequence: UInt64 = 0
    private var receiverHasReplay = false
    private var pendingReceiverReplay: [Int64: (epoch: UInt64, held: SharingInputPacket?)] = [:] // At most 512 receiver events.
    private var pendingReleaseReplay: Set<Int64> = [] // At most 288 held key/button releases.
    private var pendingLocalReplay: Set<Int64> = [] // At most 128 genuine local resume events.
    private var droppedReceiverReplay = 0
    private var replayDrainMilliseconds: Double?
    private var localResumeTask: Task<Void, Never>?
    private var localResumeGeneration: UInt64 = 0
    private var localEvents: [CGEvent] = [] // At most 128, transient only; never logged.
    private var localPointer: CGPoint?
    private var physicalEpoch: UInt64 = 0
    private var preparedReceiver: (edge: SharingEdge, fraction: Double, epoch: UInt64)?
    private let eventPoster: (CGEvent) -> Void
    init(cursor: SharingCursorCapture = SharingCursorCapture(), tapReadyOverride: (() -> Bool)? = nil,
         receiverWarp: @escaping (CGPoint) -> CGError = { CGWarpMouseCursorPosition($0) },
         eventPoster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         handoffClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.handoffClock = handoffClock
        self.cursor = cursor; self.tapReadyOverride = tapReadyOverride; self.receiverWarp = receiverWarp; self.eventPoster = eventPoster
        resignObserver = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self, self.mode == .controlling || self.mode == .staged, !self.cursor.isCaptured { self.failCapture("应用失去前台，已停止向远端转发并归还控制。") }
                }
            }
    }
    private var tapReady: Bool {
        if let tapReadyOverride { return tapReadyOverride() }
        return tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }
    var needsRecovery: Bool { cursor.needsRecovery }
    var isCapturing: Bool { mode == .controlling && cursor.isCaptured && tapReady }
    var isStaged: Bool { mode == .staged && cursor.isCaptured && tapReady }
    var isParked: Bool { mode == .parked && cursor.isCaptured && tapReady }
    var safetyDiagnostics: [String: Any] {
        var value = cursor.snapshot
        value["mode"] = String(describing: mode); value["tapReady"] = tapReady
        value["queuedLocalEvents"] = localEvents.count
        value["queuedReceiverEvents"] = pendingReceiverReplay.count
        value["queuedReleaseEvents"] = pendingReleaseReplay.count
        value["queuedLocalReplayEvents"] = pendingLocalReplay.count
        value["droppedStaleReceiverEvents"] = droppedReceiverReplay
        if let replayDrainMilliseconds { value["replayDrainMilliseconds"] = replayDrainMilliseconds }
        value["physicalMouseMovements"] = physicalMouseMovements; value["externalInputEvents"] = externalInputEvents
        if let lastSafetyFailure { value["failure"] = lastSafetyFailure }
        return value
    }
    func captureValidationError() -> String? {
        do { try cursor.validate(tapReady: tapReady); return nil }
        catch { return error.localizedDescription }
    }
    func maintainCapture() {
        guard mode == .controlling || mode == .staged || mode == .parked else { return }
        do { try cursor.validate(tapReady: tapReady); cursor.heartbeat() }
        catch { failCapture(error.localizedDescription) }
    }
    #if DEBUG
    private(set) var appliedPacketCount = 0
    private(set) var replayedEventCount = 0
    #endif

    static var displayRects: [CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displays, &count) == .success else { return [CGDisplayBounds(CGMainDisplayID())] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    static var bounds: CGRect { displayRects.reduce(CGRect.null) { $0.union($1) } }
    static func clamp(_ point: CGPoint) -> CGPoint {
        displayRects.map { rect in
            CGPoint(x: min(rect.maxX - 1, max(rect.minX, point.x)), y: min(rect.maxY - 1, max(rect.minY, point.y)))
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? point
    }
    func start() throws {
        guard !needsRecovery else { throw PluginError.invalid("本机光标尚未恢复，暂不能重新启用共享。") }
        // In-process dependency injection for ordinary tests: never create a real OS tap.
        if tapReadyOverride != nil {
            guard tapReady else { throw PluginError.invalid("测试事件通道未就绪。") }
            return
        }
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let suppress = MainActor.assumeIsolated {
                Unmanaged<SharingInput>.fromOpaque(pointer).takeUnretainedValue().handle(type, event)
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw PluginError.invalid("无法启动键鼠共享，请在应用权限管理中检查辅助功能和输入监控。")
        }
        self.tap = tap; self.source = source
        resamplePhysical()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func stop() {
        reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; canSwitch = false; physical = SharingHeldInputState(); shortcutKeys.removeAll()
        pendingReceiverReplay.removeAll(); pendingReleaseReplay.removeAll(); pendingLocalReplay.removeAll()
    }
    func capture(maximumDuration: TimeInterval? = nil, deferForwarding: Bool = false) async throws {
        guard mode == .local || mode == .parked, isNeutral, localResumeTask == nil else { throw PluginError.invalid("仍有按键或控制会话未释放，已取消接管。") }
        reset(); physicalMouseMovements = 0; externalInputEvents = 0; lastSafetyFailure = nil
        let epoch = receiverEpoch
        try await drainReplay()
        guard await cursor.awaitFocusRestoration() else { throw PluginError.invalid("原应用焦点尚未恢复，请切回原应用后重试。") }
        try Task.checkCancellation()
        guard receiverEpoch == epoch, mode == .local else { throw CancellationError() }
        mode = .preparingCapture
        do {
            try await cursor.acquire(tapReady: { self.tapReady }, neutral: { self.isNeutral }, maximumDuration: maximumDuration)
            try Task.checkCancellation()
            guard receiverEpoch == epoch, mode == .preparingCapture else { throw CancellationError() }
            mode = deferForwarding ? .staged : .controlling
            if !deferForwarding { stagedMotion = .zero }
        } catch {
            if receiverEpoch == epoch { mode = .local; stagedMotion = .zero; _ = cursor.release() }
            throw error
        }
    }
    func beginForwarding() throws {
        guard mode == .staged, isNeutral else { throw PluginError.invalid("交接准备已失效，未向对端发送输入。") }
        try cursor.validate(tapReady: tapReady)
        mode = .controlling
        let motion = stagedMotion; stagedMotion = .zero
        guard motion != .zero else { return }
        guard cursor.withActiveCapture({ send(.init(kind: .move, x: motion.x, y: motion.y)) }) else { throw PluginError.invalid("交接光标租约已失效，未发送等待期间的移动。") }
    }
    func parkAfterReturn() async throws {
        guard mode == .receiving, remoteHeld.isNeutral, isNeutral else { throw PluginError.invalid("按键尚未释放，不能停放光标。") }
        let epoch = physicalEpoch, receiver = receiverEpoch
        // CGEvent.post is asynchronous. Finish already-issued receiver motion
        // before anchoring a capture lease; returning nil at a session tap alone
        // is not proof that WindowServer has not moved its cursor yet.
        try await drainReplay()
        guard mode == .receiving, receiverEpoch == receiver, physicalEpoch == epoch else { throw CancellationError() }
        if receiverHasReplay, let position = receiverCursor?.position {
            guard receiverWarp(position) == .success else { throw PluginError.invalid("接收光标尚未稳定，已取消交接。") }
        }
        reset()
        try await capture()
        guard physicalEpoch == epoch else { reset(); throw PluginError.invalid("本机已有实际输入，已取消光标停放。") }
        mode = .parked; canSwitch = false
    }
    func prepareReceiving(edge: SharingEdge, fraction: Double, deferPointer: Bool = false) async throws {
        let epoch = physicalEpoch
        await localResumeTask?.value
        reset()
        let receiver = receiverEpoch
        try await drainReplay()
        guard await cursor.awaitFocusRestoration() else { throw PluginError.invalid("原应用焦点尚未恢复，未接收对端键盘。") }
        try Task.checkCancellation()
        guard receiverEpoch == receiver, mode == .local else { throw CancellationError() }
        guard physicalEpoch == epoch, isNeutral else { throw PluginError.invalid("本机正在使用键鼠，已拒绝对端接管。") }
        if deferPointer { preparedReceiver = (edge, fraction, epoch) }
        else { try receive(edge: edge, fraction: fraction) }
    }
    func commitReceiving() throws {
        guard let preparedReceiver, preparedReceiver.epoch == physicalEpoch, isNeutral else { throw PluginError.invalid("接收准备已失效，未显示对端光标。") }
        try receive(edge: preparedReceiver.edge, fraction: preparedReceiver.fraction)
    }
    func receive(edge: SharingEdge, fraction: Double) throws {
        let errors = reset()
        guard errors.isEmpty, !needsRecovery, pendingReleaseReplay.isEmpty else { throw PluginError.invalid("本机光标或按键释放尚未完成，已拒绝对端接管。") }
        let entry = edge.opposite
        let position = Self.clamp(entry.entryPoint(fraction: fraction, bounds: Self.bounds))
        let result = receiverWarp(position)
        guard result == .success else { throw PluginError.invalid("无法准备接收端指针（\(result.rawValue)），未确认接管。") }
        receiverCursor = SharingPointerAccumulator(position: position)
        returnEdge = entry; mode = .receiving
    }
    @discardableResult func reset(restoring normalized: SharingCursorPosition? = nil, handoffDelay: TimeInterval = 0) -> [String] {
        localResumeGeneration &+= 1; localResumeTask?.cancel(); localResumeTask = nil
        localEvents.removeAll(); localPointer = nil; preparedReceiver = nil
        receiverEpoch &+= 1; receiverHasReplay = false; stagedMotion = .zero
        mode = .local; switchAllowedAt = handoffClock() + min(0.65, max(0, handoffDelay))
        let restorePoint = normalized.map { Self.clamp(CGPoint(x: Self.bounds.minX + $0.x * (Self.bounds.width - 1), y: Self.bounds.minY + $0.y * (Self.bounds.height - 1))) }
        let recoveryErrors = cursor.release(restoring: restorePoint)
        // Release on the target as well as on disconnect, lock, disable and tap timeout.
        // Include delivered state: a queued key-up can be invalidated even after
        // the desired remote state is neutral. Its matching down still needs up.
        let releases = remoteHeld.releasePlan(including: deliveredRemoteHeld)
        remoteHeld = SharingHeldInputState(); deliveredRemoteHeld = SharingHeldInputState()
        for packet in releases {
            let event: CGEvent?
            if packet.kind == .up {
                let button = packet.code
                event = CGEvent(mouseEventSource: nil, mouseType: button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp,
                    mouseCursorPosition: receiverCursor?.position ?? CGEvent(source: nil)?.location ?? .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!)
            } else {
                event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(packet.code), keyDown: false)
                if packet.kind == .flags { event?.type = .flagsChanged }
            }
            event?.flags = []; postRelease(event)
        }
        receiverCursor = nil
        return recoveryErrors
    }
    private func failCapture(_ message: String) {
        lastSafetyFailure = message
        let errors = reset(); canSwitch = false
        failure(errors.isEmpty ? message : message + "（" + errors.joined(separator: "；") + "）")
    }
    private func resamplePhysical() {
        physical = SharingHeldInputState()
        for code in 0...127 where code != 57 && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) {
            physical.observe(.init(kind: .keyDown, code: code))
        }
        for button in 0...31 where CGEventSource.buttonState(.hidSystemState, button: CGMouseButton(rawValue: UInt32(button))!) {
            physical.observe(.init(kind: .down, code: button))
        }
    }
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            failCapture("键鼠监听已被系统停用，已归还本机控制。")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A release may have been missed while disabled; sample again after posted cleanup.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.tap != nil else { return }
                self.resamplePhysical(); self.physicalStateChanged()
            }
            return false
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let prefix = UInt64(bitPattern: marker) & 0xFFFF_0000_0000_0000
        if prefix == Self.localReplayPrefix {
            pendingLocalReplay.remove(marker)
            return false
        }
        if prefix == Self.releaseReplayPrefix {
            pendingReleaseReplay.remove(marker)
            return false // Never discard a key/button-up needed by a prior receiver.
        }
        if prefix == Self.receiverReplayPrefix {
            let replay = pendingReceiverReplay.removeValue(forKey: marker)
            guard replay?.epoch == receiverEpoch, mode == .receiving else { droppedReceiverReplay += 1; return true }
            if let held = replay?.held { deliveredRemoteHeld.observe(held) }
            #if DEBUG
            replayedEventCount += 1
            #endif
            return false
        }
        if marker == Self.replayMarker {
            #if DEBUG
            replayedEventCount += 1
            #endif
            return false
        }
        // Don't forward or use injected events from other automation as a handoff trigger.
        if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
            if mode == .controlling || mode == .staged || mode == .preparingCapture {
                externalInputEvents += 1
                failCapture("检测到其他输入注入，已暂停共享；请勿同时使用多个键鼠控制工具。")
            }
            return false
        }
        observePhysical(type, event)
        if mode == .preparingCapture || mode == .staged {
            if type != .mouseMoved {
                resumeLocalInput(event) // Cancel and restore verified original focus before local replay.
                return true
            }
            if mode == .staged {
                do { try cursor.validate(tapReady: tapReady) }
                catch { failCapture(error.localizedDescription); return false }
            }
            let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
            stagedMotion.x = min(4096, max(-4096, stagedMotion.x + dx)); stagedMotion.y = min(4096, max(-4096, stagedMotion.y + dy))
            if dx != 0 || dy != 0 { physicalMouseMovements += 1 }
            return true // No network input before accepted handoff + source lease + commit.
        }
        if mode == .parked || localResumeTask != nil {
            resumeLocalInput(event)
            return true
        }
        if mode == .controlling {
            if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type),
               event.getDoubleValueField(.mouseEventDeltaX) != 0 || event.getDoubleValueField(.mouseEventDeltaY) != 0 { physicalMouseMovements += 1 }
            do { try cursor.validate(tapReady: tapReady) }
            catch { failCapture(error.localizedDescription); return false }
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, shortcutKeys.remove(code) != nil { return true }
        let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if type == .keyDown, event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == chord,
           code == 53 || code == 40 {
            shortcutKeys.insert(code)
            if code == 53 || mode != .local { returnLocal(nil) }
            else if canSwitch {
                if let entry = workspace?.defaultEntry { requestControl(entry.wireEdge, entry.fraction) }
                else { requestControl(edge, 0.5) }
            }
            return true
        }
        if mode == .receiving {
            // Local physical activity always takes precedence over remote input.
            if Self.isPhysicalActivity(type) { returnLocal(nil) }
            return false
        }
        let delta = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX), y: event.getDoubleValueField(.mouseEventDeltaY))
        if mode == .local {
            if canSwitch, type == .mouseMoved, physical.isNeutral,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
               handoffClock() >= switchAllowedAt {
                if let workspace {
                    if let entry = workspace.handoff(point: event.location, delta: delta, screen: Self.bounds) {
                        switchAllowedAt = handoffClock() + 0.65; requestControl(entry.wireEdge, entry.fraction)
                    }
                } else if edge.isCrossing(event.location, delta: delta, bounds: Self.bounds) {
                    switchAllowedAt = handoffClock() + 0.65; requestControl(edge, edge.fraction(event.location, bounds: Self.bounds))
                }
            }
            return false
        }
        var packet = SharingInputPacket(kind: .move, flags: event.flags.rawValue & SharingInputPacket.allowedFlags)
        switch type {
        case .keyDown: packet.kind = .keyDown; packet.code = code
        case .keyUp: packet.kind = .keyUp; packet.code = code
        case .flagsChanged:
            packet.kind = .flags; packet.code = code
            packet.pressed = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            packet.x = min(4096, max(-4096, delta.x)); packet.y = min(4096, max(-4096, delta.y))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            packet.kind = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) ? .down : .up
            packet.code = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            packet.clickCount = min(3, max(1, Int(event.getIntegerValueField(.mouseEventClickState))))
        case .scrollWheel:
            packet.kind = .scroll
            packet.x = min(4096, max(-4096, event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)))
            packet.y = min(4096, max(-4096, event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)))
        default: return false
        }
        // The watchdog and the send callback serialize on the same generational lease.
        // A stale .controlling enum can never reopen forwarding after background recovery.
        guard cursor.withActiveCapture({ send(packet) }) else {
            failCapture("光标接管已超时或失效，未继续向远端转发。")
            return false
        }
        return true
    }
    func apply(_ packet: SharingInputPacket) {
        guard mode == .receiving, (try? packet.validate()) != nil else { return }
        guard pendingReceiverReplay.count < 512 else { failCapture("接收输入回放积压，已安全归还控制。"); return }
        #if DEBUG
        appliedPacketCount += 1
        #endif
        remoteHeld.observe(packet)
        var event: CGEvent?
        // CGEvent.post is asynchronous. Later packets in the same network batch
        // must use our logical cursor, not a still-stale system cursor snapshot.
        let current = receiverCursor?.position ?? CGEvent(source: nil)?.location ?? .zero
        switch packet.kind {
        case .move:
            let next = CGPoint(x: current.x + packet.x, y: current.y + packet.y)
            if heldButtons.isEmpty, heldKeys.isEmpty, handoffClock() >= switchAllowedAt {
                if let workspace {
                    if let entry = workspace.handoff(point: next, delta: .init(x: packet.x, y: packet.y), screen: Self.bounds) { returnAcrossEdge(entry.position); return }
                } else if returnEdge.isCrossing(next, delta: .init(x: packet.x, y: packet.y), bounds: Self.bounds) { returnAcrossEdge(nil); return }
            }
            let button = heldButtons.sorted().first
            let type: CGEventType = button == nil ? .mouseMoved : button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
            var pointer = receiverCursor ?? SharingPointerAccumulator(position: current)
            let position = pointer.advance(x: packet.x, y: packet.y) { Self.clamp($0) }
            receiverCursor = pointer
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: CGMouseButton(rawValue: UInt32(button ?? 0))!)
            // This is already an absolute target position. Reapplying deltas at
            // the HID tap can introduce a second round of pointer acceleration.
        case .down, .up:
            let down = packet.kind == .down
            let type: CGEventType = packet.code == 0 ? (down ? .leftMouseDown : .leftMouseUp) : packet.code == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: current, mouseButton: CGMouseButton(rawValue: UInt32(packet.code))!)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(packet.clickCount))
        case .keyDown, .keyUp, .flags:
            let down = packet.kind == .keyDown
            event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(packet.code), keyDown: packet.kind == .flags ? packet.pressed : down)
            if packet.kind == .flags { event?.type = .flagsChanged }
        case .scroll:
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(packet.y), wheel2: Int32(packet.x), wheel3: 0)
        }
        event?.flags = CGEventFlags(rawValue: packet.flags)
        postReceiver(event, packet: packet)
    }
    private func replayToken(prefix: UInt64) -> Int64 {
        replaySequence = (replaySequence &+ 1) & 0x0000_FFFF_FFFF_FFFF
        return Int64(bitPattern: prefix | replaySequence)
    }
    private func postReceiver(_ event: CGEvent?, packet: SharingInputPacket) {
        guard let event else { return }
        let token = replayToken(prefix: Self.receiverReplayPrefix)
        let held: SharingInputPacket? = [.keyDown, .keyUp, .flags, .down, .up].contains(packet.kind) ? packet : nil
        pendingReceiverReplay[token] = (receiverEpoch, held); receiverHasReplay = true
        event.setIntegerValueField(.eventSourceUserData, value: token)
        eventPoster(event)
    }
    private func postRelease(_ event: CGEvent?) {
        guard let event else { return }
        let token = replayToken(prefix: Self.releaseReplayPrefix)
        pendingReleaseReplay.insert(token)
        event.setIntegerValueField(.eventSourceUserData, value: token)
        eventPoster(event)
    }
    private func drainReplay() async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { replayDrainMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 }
        let deadline = started + 250_000_000
        while !pendingReceiverReplay.isEmpty || !pendingReleaseReplay.isEmpty || !pendingLocalReplay.isEmpty {
            try Task.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw PluginError.invalid("本机输入回放尚未完成，已取消交接；请重新开启共享后重试。") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
    }
    private func observePhysical(_ type: CGEventType, _ event: CGEvent) {
        if Self.isPhysicalActivity(type) { physicalEpoch &+= 1 }
        let old = physical, code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown: physical.observe(.init(kind: .keyDown, code: code))
        case .keyUp: physical.observe(.init(kind: .keyUp, code: code))
        case .flagsChanged: physical.observe(.init(kind: .flags, code: code, pressed: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: physical.observe(.init(kind: .down, code: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: physical.observe(.init(kind: .up, code: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        default: break
        }
        if old != physical { physicalStateChanged() }
        if preparedReceiver != nil, Self.isPhysicalActivity(type) { returnLocal(nil) }
    }
    nonisolated static func isPhysicalActivity(_ type: CGEventType) -> Bool {
        [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
         .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel].contains(type)
    }
    private func resumeLocalInput(_ event: CGEvent) {
        if localResumeTask == nil {
            returnLocal(nil) // Also revoke a still-forwarding peer, including during the return task.
            reset(); canSwitch = false
            localPointer = CGEvent(source: nil)?.location
            let generation = localResumeGeneration
            localResumeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let restored = await self.cursor.awaitFocusRestoration()
                guard generation == self.localResumeGeneration, !Task.isCancelled else { return }
                let events = self.localEvents; self.localEvents.removeAll(); self.localPointer = nil
                self.localResumeTask = nil
                // Only restore genuine local input after the real app owns focus.
                // A rejected restoration fails closed instead of typing into Untitled.
                if restored && self.cursor.localReplayAllowed { events.forEach { self.post($0) }; self.localResumed() }
                else { self.failure("原应用焦点未恢复，请切回原应用后继续；共享已暂停。") }
            }
        }
        guard let copy = event.copy() else { return }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(copy.type), let point = localPointer {
            let next = Self.clamp(CGPoint(x: point.x + copy.getDoubleValueField(.mouseEventDeltaX), y: point.y + copy.getDoubleValueField(.mouseEventDeltaY)))
            copy.location = next; localPointer = next
            if localEvents.last?.type == copy.type { localEvents.removeLast() }
        }
        guard localEvents.count < 128 else { reset(); canSwitch = false; failure("本机输入恢复队列已满，共享已暂停。"); return }
        localEvents.append(copy)
    }
    private func post(_ event: CGEvent?) {
        guard let event else { return }
        let token = replayToken(prefix: Self.localReplayPrefix)
        pendingLocalReplay.insert(token)
        event.setIntegerValueField(.eventSourceUserData, value: token)
        eventPoster(event)
    }
}
