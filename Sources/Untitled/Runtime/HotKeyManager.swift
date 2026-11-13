import Carbon
import Foundation

/// Suppress repeat-downs; clearing bindings releases only keys that actually started a gesture.
struct HotKeyPressState {
    private var down: Set<UInt32> = []
    mutating func transition(_ id: UInt32, pressed: Bool) -> Bool {
        if pressed { return down.insert(id).inserted }
        return down.remove(id) != nil
    }
    mutating func clear() -> Set<UInt32> { let previous = down; down.removeAll(); return previous }
}

@MainActor
final class HotKeyManager {
    private let resources = CarbonResources()
    private struct Callbacks { let press: () -> Void; let release: (() -> Void)? }
    private var callbacks: [UInt32: Callbacks] = [:]
    private var presses = HotKeyPressState()
    private var nextIdentifier: UInt32 = 0
    private var setupStatus: OSStatus = noErr

    init() {
        resources.owner = self
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        setupStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x554E544C else { return OSStatus(eventNotHandledErr) }
            let resources = Unmanaged<CarbonResources>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { resources.owner?.dispatch(identifier.id, pressed: pressed) }
            return noErr
        }, 2, &eventTypes, Unmanaged.passUnretained(resources).toOpaque(), &resources.eventHandler)
    }

    private func dispatch(_ identifier: UInt32, pressed: Bool) {
        guard let callback = callbacks[identifier], presses.transition(identifier, pressed: pressed) else { return }
        if pressed { callback.press() } else { callback.release?() }
    }

    func clear() {
        let releases = presses.clear().compactMap { callbacks[$0]?.release }
        resources.references.forEach { UnregisterEventHotKey($0) }
        resources.references.removeAll()
        callbacks.removeAll()
        releases.forEach { $0() }
    }

    func register(_ hotKey: HotKey, onRelease: (() -> Void)? = nil, action: @escaping () -> Void) throws {
        try hotKey.validate()
        guard setupStatus == noErr else { throw PluginError.invalid("无法监听全局快捷键（\(setupStatus)）。") }
        nextIdentifier &+= 1
        if nextIdentifier == 0 { nextIdentifier = 1 }
        let identifier = nextIdentifier
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers,
                                        EventHotKeyID(signature: 0x554E544C, id: identifier),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            throw PluginError.invalid("\(hotKey.display) 无法注册，可能已被系统或其他应用占用（\(status)）。")
        }
        resources.references.append(reference)
        callbacks[identifier] = Callbacks(press: action, release: onRelease)
    }

    deinit {
        let resources = resources
        if Thread.isMainThread {
            MainActor.assumeIsolated { resources.invalidate() }
        } else {
            Task { @MainActor in resources.invalidate() }
        }
    }

    // Carbon 句柄仅在主线程使用；Sendable 包装用于将析构清理移交回主线程。
    private final class CarbonResources: @unchecked Sendable {
        var eventHandler: EventHandlerRef?
        var references: [EventHotKeyRef] = []
        @MainActor weak var owner: HotKeyManager?

        @MainActor func invalidate() {
            owner = nil
            references.forEach { UnregisterEventHotKey($0) }
            references.removeAll()
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
        }
    }
}
