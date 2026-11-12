import AppKit
@preconcurrency import ApplicationServices

@MainActor final class SharingInput {
    enum Mode { case local, controlling, receiving }
    static let replayMarker: Int64 = 0x54545348415245
    var send: (SharingInputPacket) -> Void = { _ in }
    var requestControl: (Double) -> Void = { _ in }
    var returnLocal: () -> Void = {}
    var physicalStateChanged: () -> Void = {}
    var failure: (String) -> Void = { _ in }
    var edge: SharingEdge = .right
    var edgeSwitching = true
    var canSwitch = false
    private(set) var mode: Mode = .local
    private var returnEdge: SharingEdge = .left
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var remoteHeld = SharingHeldInputState()
    private var physical = SharingHeldInputState()
    var isNeutral: Bool { physical.isNeutral }
    private var heldKeys: Set<Int> { remoteHeld.keys }
    private var heldButtons: Set<Int> { remoteHeld.buttons }
    private var shortcutKeys = Set<Int>()
    private var lastSwitch = Date.distantPast
    private var origin = CGPoint.zero
    private var receiverCursor: CGPoint?
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
    }
    func capture() {
        guard isNeutral else { return }
        reset()
        origin = CGEvent(source: nil)?.location ?? .zero
        mode = .controlling
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
    }
    func receive(edge: SharingEdge, fraction: Double) {
        reset(); returnEdge = edge.opposite; mode = .receiving
        receiverCursor = Self.clamp(returnEdge.entryPoint(fraction: fraction, bounds: Self.bounds))
        CGWarpMouseCursorPosition(receiverCursor!)
    }
    func reset() {
        let oldMode = mode; mode = .local; lastSwitch = Date()
        if oldMode == .controlling {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(Self.clamp(origin))
            CGDisplayShowCursor(CGMainDisplayID())
        }
        // Release on the target as well as on disconnect, lock, disable and tap timeout.
        let releases = remoteHeld.releasePlan()
        remoteHeld = SharingHeldInputState()
        for packet in releases {
            let event: CGEvent?
            if packet.kind == .up {
                let button = packet.code
                event = CGEvent(mouseEventSource: nil, mouseType: button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp,
                    mouseCursorPosition: receiverCursor ?? CGEvent(source: nil)?.location ?? .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!)
            } else {
                event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(packet.code), keyDown: false)
                if packet.kind == .flags { event?.type = .flagsChanged }
            }
            event?.flags = []; post(event)
        }
        receiverCursor = nil
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
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            returnLocal()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A release may have been missed while disabled; sample again after posted cleanup.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.tap != nil else { return }
                self.resamplePhysical(); self.physicalStateChanged()
            }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            #if DEBUG
            replayedEventCount += 1
            #endif
            return false
        }
        // Don't forward or use injected events from other automation as a handoff trigger.
        if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 { return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let oldPhysical = physical
        switch type {
        case .keyDown: physical.observe(.init(kind: .keyDown, code: code))
        case .keyUp: physical.observe(.init(kind: .keyUp, code: code))
        case .flagsChanged: physical.observe(.init(kind: .flags, code: code, pressed: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: physical.observe(.init(kind: .down, code: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: physical.observe(.init(kind: .up, code: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        default: break
        }
        if physical != oldPhysical { physicalStateChanged() }
        if type == .keyUp, shortcutKeys.remove(code) != nil { return true }
        let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if type == .keyDown, event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == chord,
           code == 53 || code == 40 {
            shortcutKeys.insert(code)
            if code == 53 || mode != .local { returnLocal() }
            else if canSwitch { requestControl(0.5) }
            return true
        }
        if mode == .receiving {
            // Local physical activity always takes precedence over remote input.
            if [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved].contains(type) { returnLocal() }
            return false
        }
        let delta = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX), y: event.getDoubleValueField(.mouseEventDeltaY))
        if mode == .local {
            if canSwitch, edgeSwitching, type == .mouseMoved, physical.isNeutral,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
               Date().timeIntervalSince(lastSwitch) > 0.65, edge.isCrossing(event.location, delta: delta, bounds: Self.bounds) {
                lastSwitch = Date(); requestControl(edge.fraction(event.location, bounds: Self.bounds))
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
        send(packet)
        return true
    }
    func apply(_ packet: SharingInputPacket) {
        guard mode == .receiving, (try? packet.validate()) != nil else { return }
        #if DEBUG
        appliedPacketCount += 1
        #endif
        remoteHeld.observe(packet)
        var event: CGEvent?
        // CGEvent.post is asynchronous. Later packets in the same network batch
        // must use our logical cursor, not a still-stale system cursor snapshot.
        let current = receiverCursor ?? CGEvent(source: nil)?.location ?? .zero
        switch packet.kind {
        case .move:
            let next = CGPoint(x: current.x + packet.x, y: current.y + packet.y)
            if heldButtons.isEmpty, heldKeys.isEmpty, Date().timeIntervalSince(lastSwitch) > 0.65,
               returnEdge.isCrossing(next, delta: .init(x: packet.x, y: packet.y), bounds: Self.bounds) { returnLocal(); return }
            let button = heldButtons.sorted().first
            let type: CGEventType = button == nil ? .mouseMoved : button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
            receiverCursor = Self.clamp(next)
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: receiverCursor!, mouseButton: CGMouseButton(rawValue: UInt32(button ?? 0))!)
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
        post(event)
    }
    private func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event?.post(tap: .cghidEventTap)
    }
}
