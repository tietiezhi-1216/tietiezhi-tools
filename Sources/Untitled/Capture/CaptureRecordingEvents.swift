import AppKit
import Carbon
import Foundation

struct RecordingEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case pointer, leftClick, rightClick, middleClick, scroll, key }
    var time: Double
    var kind: Kind
    var x: Double
    var y: Double
    var label: String
}
struct RecordingEventArchive: Codable, Sendable {
    var version = 1
    var events: [RecordingEvent] = []
    static func url(for movie: URL) -> URL { movie.deletingPathExtension().appendingPathExtension("events.json") }
    static func read(for movie: URL) -> Self? {
        guard let size = try? url(for: movie).resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 100_000_000,
              let data = try? Data(contentsOf: url(for: movie)), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.events.count <= 1_000_000,
              value.events.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.x.isFinite && $0.y.isFinite && $0.label.count <= 200 }) else { return nil }
        return Self(events: value.events.sorted { $0.time < $1.time })
    }
    func save(for movie: URL) throws { try JSONEncoder().encode(self).write(to: Self.url(for: movie), options: .atomic) }
}

/// Captures only while the recorder supplies an active media clock; paused time is excluded.
@MainActor final class CaptureRecordingEventMonitor {
    private var global: Any?
    private var local: Any?
    private var checkpoint: Task<Void, Never>?
    private var archive = RecordingEventArchive()
    private var frame = CGRect.zero
    private var mouseEnabled = false
    private var keyboardEnabled = false
    private var clock: (() -> Double?)?
    private var checkpointURL: URL?
    private var lastPointerTime = -Double.infinity

    func start(frame: CGRect, mouse: Bool, keyboard: Bool, permissions: PluginPermissionClient,
               checkpoint: URL, clock: @escaping () -> Double?) throws {
        if keyboard { try permissions.require([.inputMonitoring]) }
        self.frame = frame; mouseEnabled = mouse; keyboardEnabled = keyboard; self.clock = clock
        checkpointURL = checkpoint; archive = .init(); lastPointerTime = -.infinity
        var mask: NSEvent.EventTypeMask = []
        if mouse { mask.formUnion([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) }
        if keyboard { mask.insert(.keyDown) }
        guard !mask.isEmpty else { return }
        seedPointer()
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return event
        }
        guard global != nil else { stop(); throw PluginError.invalid("无法记录键鼠操作，请检查权限后重新录屏。") }
        self.checkpoint = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.saveCheckpoint()
            }
        }
    }
    private func seedPointer() {
        guard mouseEnabled else { return }
        let point = NSEvent.mouseLocation
        archive.events.append(.init(time: 0, kind: .pointer, x: (point.x - frame.minX) / max(1, frame.width),
            y: (frame.maxY - point.y) / max(1, frame.height), label: ""))
    }
    private func record(_ event: NSEvent) {
        guard let time = clock?(), time.isFinite, archive.events.count < 1_000_000 else { return }
        let point = NSEvent.mouseLocation
        let x = Double((point.x - frame.minX) / max(1, frame.width))
        let y = Double((frame.maxY - point.y) / max(1, frame.height))
        let kind: RecordingEvent.Kind
        var label = ""
        switch event.type {
        case .keyDown:
            guard keyboardEnabled, !IsSecureEventInputEnabled(), !event.isARepeat else { return }
            kind = .key; label = Self.label(event)
        case .leftMouseDown: kind = .leftClick
        case .rightMouseDown: kind = .rightClick
        case .otherMouseDown: kind = .middleClick
        case .scrollWheel:
            guard frame.contains(point) else { return }
            kind = .scroll; label = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? (event.scrollingDeltaY > 0 ? "↑" : "↓") : (event.scrollingDeltaX > 0 ? "←" : "→")
        default:
            guard mouseEnabled, time - lastPointerTime >= 1.0 / 30 else { return }
            kind = .pointer; lastPointerTime = time
        }
        if kind != .key && kind != .pointer && !frame.contains(point) { return }
        archive.events.append(.init(time: time, kind: kind, x: x, y: y, label: String(label.prefix(200))))
    }
    private static func label(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        var prefix = ""
        if event.modifierFlags.contains(.control) { prefix += "⌃" }
        if event.modifierFlags.contains(.option) { prefix += "⌥" }
        if event.modifierFlags.contains(.shift) { prefix += "⇧" }
        if event.modifierFlags.contains(.command) { prefix += "⌘" }
        return prefix + (special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "")
    }
    private func saveCheckpoint() {
        guard let checkpointURL else { return }
        try? JSONEncoder().encode(archive).write(to: checkpointURL, options: .atomic)
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global) }; global = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        checkpoint?.cancel(); checkpoint = nil; saveCheckpoint(); clock = nil
    }
    func reset(checkpoint: URL) {
        archive = .init(); lastPointerTime = -.infinity; checkpointURL = checkpoint
        seedPointer(); saveCheckpoint()
    }
    func save(for movie: URL) throws { try archive.save(for: movie) }
}
