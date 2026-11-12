import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private let resources = CarbonResources()
    private var callbacks: [UInt32: () -> Void] = [:]
    private var setupStatus: OSStatus = noErr

    init() {
        resources.owner = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        setupStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x54545A48 else { return OSStatus(eventNotHandledErr) }
            let resources = Unmanaged<CarbonResources>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { resources.owner?.callbacks[identifier.id]?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(resources).toOpaque(), &resources.eventHandler)
    }

    func clear() {
        resources.references.forEach { UnregisterEventHotKey($0) }
        resources.references.removeAll()
        callbacks.removeAll()
    }

    func register(_ hotKey: HotKey, action: @escaping () -> Void) throws {
        try hotKey.validate()
        guard setupStatus == noErr else { throw PluginError.invalid("无法监听全局快捷键（\(setupStatus)）。") }
        let identifier = UInt32(callbacks.count + 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers,
                                        EventHotKeyID(signature: 0x54545A48, id: identifier),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            throw PluginError.invalid("\(hotKey.display) 无法注册，可能已被系统或其他应用占用（\(status)）。")
        }
        resources.references.append(reference)
        callbacks[identifier] = action
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
