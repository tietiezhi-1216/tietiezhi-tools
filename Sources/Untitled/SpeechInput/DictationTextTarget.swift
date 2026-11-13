import AppKit
import ApplicationServices
import Carbon
import os

enum DictationTargetError: LocalizedError {
    case secure, unavailable, changed, unconfirmed
    var errorDescription: String? {
        switch self {
        case .secure: "安全输入或密码框中不能开始听写。"
        case .unavailable: "请先点击目标应用的可编辑输入框，再按听写快捷键；不能安全定位输入框时不会开始录音。"
        case .changed: "输入焦点、光标或文字已改变，已停止自动写入；识别结果保留在插件面板。"
        case .unconfirmed: "输入框没有确认文字写入，已停止自动输入；请在插件面板复制识别文字，不会反复重发或盲目删除。"
        }
    }
}

private func sameText(_ lhs: String, _ rhs: String) -> Bool {
    // Swift String equality normalizes canonically equivalent Unicode. AX offsets do not.
    lhs.utf16.elementsEqual(rhs.utf16)
}

struct DictationEditorSnapshot: Sendable {
    let value: String
    let selection: NSRange
}

/// Pure UTF-16 ownership model. A revision replaces only the changed suffix of our own span.
struct DictationTextAnchor {
    struct Edit {
        let range: NSRange
        let removed: String
        let replacement: String
        let value: String
    }
    let original: String
    let selection: NSRange
    private(set) var inserted = ""
    private(set) var hasWritten = false
    var range: NSRange { hasWritten ? NSRange(location: selection.location, length: inserted.utf16.count) : selection }
    var expectedValue: String { (original as NSString).replacingCharacters(in: selection, with: inserted) }
    var expectedSelection: NSRange {
        hasWritten ? NSRange(location: selection.location + inserted.utf16.count, length: 0) : selection
    }
    var currentValue: String { hasWritten ? expectedValue : original }

    init(value: String, selection: NSRange) throws {
        guard value.utf16.count <= 131_072, selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location,
              Range(selection, in: value) != nil else { throw DictationTargetError.unavailable }
        original = value; self.selection = selection
    }
    func replacement(_ text: String, value: String, selected: NSRange) throws -> String {
        guard sameText(value, currentValue), selected == expectedSelection else { throw DictationTargetError.changed }
        guard text.utf16.count <= DoubaoASRLimits.textLength else { throw PluginError.invalid("听写文字超过长度预算。") }
        return (original as NSString).replacingCharacters(in: selection, with: text)
    }
    func edit(_ text: String, snapshot: DictationEditorSnapshot) throws -> Edit {
        let expected = try replacement(text, value: snapshot.value, selected: snapshot.selection)
        if !hasWritten {
            return Edit(range: selection, removed: (original as NSString).substring(with: selection), replacement: text, value: expected)
        }
        var prefix = "", count = 0
        for (old, new) in zip(inserted, text) {
            guard sameText(String(old), String(new)) else { break }
            prefix.append(old); count += 1
        }
        let removed = String(inserted.dropFirst(count)), added = String(text.dropFirst(count))
        return Edit(range: NSRange(location: selection.location + prefix.utf16.count, length: removed.utf16.count),
                    removed: removed, replacement: added, value: expected)
    }
    mutating func commit(_ text: String) { inserted = text; hasWritten = true }
}

@MainActor protocol DictationTextInserting: AnyObject {
    func validate() async throws
    func update(_ text: String) async throws
    func commitFinal(_ text: String) async throws
    func cancel()
}

extension DictationTextInserting {
    func commitFinal(_ text: String) async throws { try await update(text) }
    func cancel() {}
}

/// Testable editor boundary: AX reads establish ownership; real key events drive the app's
/// normal input/undo/DOM event path. A reported-success AXSelectedText setter is NOT proof.
@MainActor protocol DictationEditor: AnyObject {
    func validateFocus() async throws
    func snapshot() async throws -> DictationEditorSnapshot
    func select(_ range: NSRange) async throws -> Bool
    func selectBackward(_ characters: Int) async throws
    func insert(_ text: String, replacing snapshot: DictationEditorSnapshot) async throws
    func deleteSelection(matching snapshot: DictationEditorSnapshot) async throws
    func cancel()
}
extension DictationEditor {
    func cancel() {}
    func readableSnapshot() async throws -> DictationEditorSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(700))
        while true {
            try Task.checkCancellation()
            do { return try await snapshot() }
            catch DictationTargetError.unavailable {
                // Chromium can temporarily expose a new caret with an old value (or no
                // range) while updating AX. Wait for a readable snapshot; NEVER resend.
                guard ContinuousClock.now < deadline else { throw DictationTargetError.unconfirmed }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

@MainActor final class DictationTextTarget: DictationTextInserting {
    private let editor: any DictationEditor
    private var anchor: DictationTextAnchor
    private var writing = false
    private var cancelled = false
    private var revision: UInt64 = 0

    static func capture() throws -> DictationTextTarget {
        let (editor, snapshot) = try AXDictationEditor.capture()
        return try DictationTextTarget(editor: editor, snapshot: snapshot)
    }
    init(editor: any DictationEditor) async throws {
        self.editor = editor
        let value = try await editor.readableSnapshot()
        anchor = try DictationTextAnchor(value: value.value, selection: value.selection)
    }
    private init(editor: any DictationEditor, snapshot: DictationEditorSnapshot) throws {
        self.editor = editor
        anchor = try DictationTextAnchor(value: snapshot.value, selection: snapshot.selection)
    }
    func validate() async throws {
        try check()
        // Acknowledgement owns intermediate states. Do not validate a stale snapshot
        // against a newer revision when another actor hop allowed the writer to finish.
        if writing { try await editor.validateFocus(); return }
        let version = revision
        let value = try await editor.readableSnapshot()
        try check()
        guard !writing, version == revision else { return }
        _ = try anchor.replacement(anchor.inserted, value: value.value, selected: value.selection)
    }
    func cancel() { cancelled = true; editor.cancel() }

    func update(_ text: String) async throws { try await write(text, final: false) }
    func commitFinal(_ text: String) async throws { try await write(text, final: true) }

    private func write(_ rawText: String, final: Bool) async throws {
        let text = Self.keyboardSafeText(rawText)
        guard !cancelled, !writing else { throw CancellationError() }
        writing = true
        defer { writing = false }
        try check()
        let before = try await editor.readableSnapshot()
        try check()
        let edit = try anchor.edit(text, snapshot: before)
        if anchor.hasWritten, sameText(text, anchor.inserted) { return }
        if before.selection != edit.range {
            try await select(edit, before: before)
        }
        let selected = try await editor.readableSnapshot()
        try check()
        guard sameText(selected.value, before.value), selected.selection == edit.range else { throw DictationTargetError.changed }
        if edit.replacement.isEmpty {
            if edit.range.length > 0 {
                try check()
                try await editor.deleteSelection(matching: selected) // Never an unselected/backspace deletion.
                try await acknowledge(value: edit.value, selection: NSRange(location: edit.range.location, length: 0))
            }
        } else {
            var expected = before.value, selection = edit.range
            // Partial hypotheses stay small. The authoritative final suffix is one
            // checked Unicode event; we no longer shrink/regrow it with our own fragments.
            let parts = final ? [edit.replacement] : Self.chunks(edit.replacement, limit: 16)
            for chunk in parts {
                try check()
                let current = try await editor.readableSnapshot()
                try check()
                guard sameText(current.value, expected), current.selection == selection else { throw DictationTargetError.changed }
                expected = (expected as NSString).replacingCharacters(in: selection, with: chunk)
                let end = NSRange(location: selection.location + chunk.utf16.count, length: 0)
                try await editor.insert(chunk, replacing: current)
                try await acknowledge(value: expected, selection: end)
                selection = end
            }
        }
        try check()
        let after = try await editor.readableSnapshot()
        try check()
        guard sameText(after.value, edit.value), after.selection == NSRange(location: anchor.selection.location + text.utf16.count, length: 0) else {
            throw DictationTargetError.unconfirmed
        }
        anchor.commit(text); revision &+= 1
    }

    private func select(_ edit: DictationTextAnchor.Edit, before: DictationEditorSnapshot) async throws {
        try check()
        if try await editor.select(edit.range) {
            if try await acknowledgeSelection(edit.range, value: before.value, timeout: .milliseconds(160)) { return }
        }
        let current = try await editor.readableSnapshot()
        try check()
        guard sameText(current.value, before.value), current.selection == before.selection,
              current.selection.length == 0, NSMaxRange(edit.range) == current.selection.location else { throw DictationTargetError.changed }
        // Fallback is Shift-Left selection, not blind deletion. Check full grapheme boundaries
        // in document context (including emoji / combining marks) before moving anything.
        let prefix = (current.value as NSString).substring(to: current.selection.location)
        guard sameText(String(prefix.suffix(edit.removed.count)), edit.removed), edit.removed.count <= 512 else {
            throw DictationTargetError.unconfirmed
        }
        let characters = Array(edit.removed)
        var selectedUnits = 0
        for offset in stride(from: characters.count, to: 0, by: -16) {
            try check()
            let start = max(0, offset - 16)
            selectedUnits += String(characters[start..<offset]).utf16.count
            try await editor.selectBackward(offset - start)
            let range = NSRange(location: before.selection.location - selectedUnits, length: selectedUnits)
            guard try await acknowledgeSelection(range, value: before.value, timeout: .milliseconds(400)) else {
                throw DictationTargetError.unconfirmed
            }
        }
    }
    private func check() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
    }
    private func acknowledge(value: String, selection: NSRange) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(700))
        repeat {
            try check()
            let actual = try await editor.readableSnapshot()
            try check()
            if sameText(actual.value, value), actual.selection == selection { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw DictationTargetError.unconfirmed
    }
    private func acknowledgeSelection(_ range: NSRange, value: String, timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            try check()
            let actual = try await editor.readableSnapshot()
            try check()
            guard sameText(actual.value, value) else { throw DictationTargetError.changed }
            if actual.selection == range { return true }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return false
    }
    static func keyboardSafeText(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: result.append(" ")
            default: result.append(scalar)
            }
        }
        return String(result)
    }
    static func chunks(_ text: String, limit: Int) -> [String] {
        var result: [String] = [], current = "", count = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf16.count
            if count + size > limit, !current.isEmpty { result.append(current); current = ""; count = 0 }
            current.unicodeScalars.append(scalar); count += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Bounded, checked event encoding; constructing it does not post any input.
/// Quartz stores the whole UTF-16 string, not just a single 16-unit fragment.
enum DictationUnicodeInput {
    static func keyDown(_ text: String, source: CGEventSource) throws -> CGEvent {
        let characters = Array(text.utf16)
        guard !characters.isEmpty, characters.count <= DoubaoASRLimits.textLength,
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { throw DictationTargetError.unconfirmed }
        event.flags = []
        characters.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: $0.baseAddress) }
        var actual = 0
        var readback = [UniChar](repeating: 0, count: characters.count)
        readback.withUnsafeMutableBufferPointer {
            event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &actual, unicodeString: $0.baseAddress)
        }
        guard actual == characters.count, readback == characters else { throw DictationTargetError.unconfirmed }
        return event
    }
}

private final class DictationDeliveryCancellation: Sendable {
    private struct State { var stopped = false; var lostFocus = false; var foreground: pid_t }
    private let state: OSAllocatedUnfairLock<State>
    private let initialPID: pid_t
    init(foreground: pid_t) {
        initialPID = foreground
        state = OSAllocatedUnfairLock(initialState: State(foreground: foreground))
    }
    func cancel() { state.withLock { $0.stopped = true } }
    func foregroundChanged(_ pid: pid_t) {
        state.withLock { $0.foreground = pid; if pid != initialPID { $0.lostFocus = true } }
    }
    func check(foreground pid: pid_t) throws {
        try Task.checkCancellation()
        let current = state.withLock { $0 }
        guard !current.stopped else { throw CancellationError() }
        guard !current.lostFocus, current.foreground == pid else { throw DictationTargetError.changed }
    }
}

/// Only Sendable text/range snapshots cross this boundary. CoreFoundation handles are
/// uniquely transferred once and all subsequent AX IPC runs on this one worker actor.
@MainActor private final class AXDictationEditor: DictationEditor {
    private let worker: DictationAXWorker
    private let cancellation: DictationDeliveryCancellation
    private let pid: pid_t
    private var observers: [NSObjectProtocol] = []
    private init(worker: DictationAXWorker, cancellation: DictationDeliveryCancellation, pid: pid_t) {
        self.worker = worker; self.cancellation = cancellation; self.pid = pid
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [cancellation] _ in
            MainActor.assumeIsolated {
                cancellation.foregroundChanged(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [cancellation] note in
            if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid {
                cancellation.foregroundChanged(0)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [cancellation] _ in
            cancellation.cancel()
        })
    }
    isolated deinit { cancel() }
    private func refreshFocus() throws {
        cancellation.foregroundChanged(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        try cancellation.check(foreground: pid)
    }
    static func capture() throws -> (AXDictationEditor, DictationEditorSnapshot) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw DictationTargetError.unavailable }
        let cancellation = DictationDeliveryCancellation(foreground: front.processIdentifier)
        let state = try DictationAXState.capture(pid: front.processIdentifier, cancellation: cancellation)
        let snapshot = try state.snapshot()
        let worker = DictationAXWorker(state: state)
        let editor = AXDictationEditor(worker: worker, cancellation: cancellation, pid: front.processIdentifier)
        try editor.refreshFocus()
        return (editor, snapshot)
    }
    func validateFocus() async throws { try refreshFocus(); try await worker.validateFocus(); try refreshFocus() }
    func snapshot() async throws -> DictationEditorSnapshot {
        try refreshFocus()
        let value = try await worker.snapshot()
        try refreshFocus()
        return value
    }
    func select(_ range: NSRange) async throws -> Bool { try refreshFocus(); return try await worker.select(range) }
    func selectBackward(_ characters: Int) async throws { try refreshFocus(); try await worker.selectBackward(characters) }
    func insert(_ text: String, replacing snapshot: DictationEditorSnapshot) async throws {
        try refreshFocus(); try await worker.insert(text, replacing: snapshot)
    }
    func deleteSelection(matching snapshot: DictationEditorSnapshot) async throws { try refreshFocus(); try await worker.deleteSelection(matching: snapshot) }
    func cancel() {
        cancellation.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}

private actor DictationAXWorker {
    private let state: DictationAXState
    init(state: sending DictationAXState) { self.state = state }
    func validateFocus() throws { try state.validateFocus() }
    func snapshot() throws -> DictationEditorSnapshot { try state.snapshot() }
    func select(_ range: NSRange) throws -> Bool { try state.select(range) }
    func selectBackward(_ characters: Int) throws { try state.selectBackward(characters) }
    func insert(_ text: String, replacing snapshot: DictationEditorSnapshot) throws { try state.insert(text, replacing: snapshot) }
    func deleteSelection(matching snapshot: DictationEditorSnapshot) throws { try state.deleteSelection(matching: snapshot) }
}

private final class DictationAXState {
    private let pid: pid_t
    private let application: AXUIElement
    private let element: AXUIElement
    private let selectionWritable: Bool
    private let events: CGEventSource
    private let cancellation: DictationDeliveryCancellation

    static func capture(pid: pid_t, cancellation: DictationDeliveryCancellation) throws -> sending DictationAXState {
        guard !IsSecureEventInputEnabled() else { throw DictationTargetError.secure }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let focused = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw DictationTargetError.unavailable
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole as String else { throw DictationTargetError.secure }
        let role = attribute(element, kAXRoleAttribute) as? String
        let settable = [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute].contains { writable(element, $0) }
        guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(where: { $0 as String == role }), settable,
              let source = CGEventSource(stateID: .privateState) else { throw DictationTargetError.unavailable }
        return DictationAXState(pid: pid, application: application, element: element,
                                selectionWritable: writable(element, kAXSelectedTextRangeAttribute), events: source, cancellation: cancellation)
    }
    private init(pid: pid_t, application: AXUIElement, element: AXUIElement,
                 selectionWritable: Bool, events: CGEventSource, cancellation: DictationDeliveryCancellation) {
        self.pid = pid; self.application = application; self.element = element
        self.selectionWritable = selectionWritable; self.events = events; self.cancellation = cancellation
    }
    func validateFocus() throws {
        try cancellation.check(foreground: pid)
        guard !IsSecureEventInputEnabled(),
              let focused = Self.attribute(application, kAXFocusedUIElementAttribute), CFEqual(focused, element) else {
            throw DictationTargetError.changed
        }
    }
    func snapshot() throws -> DictationEditorSnapshot {
        try validateFocus()
        var copied: CFArray?
        let attributes = [kAXValueAttribute, kAXSelectedTextRangeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &copied) == .success,
              let values = copied as? [Any], values.count == 2,
              let value = values[0] as? String, value.utf16.count <= 196_608 else { throw DictationTargetError.unavailable }
        let raw = values[1] as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { throw DictationTargetError.unavailable }
        let ax = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= value.utf16.count, range.length <= value.utf16.count - range.location else {
            throw DictationTargetError.unavailable
        }
        return .init(value: value, selection: NSRange(location: range.location, length: range.length))
    }
    func select(_ range: NSRange) throws -> Bool {
        try validateFocus()
        guard selectionWritable else { return false }
        var selected = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &selected) else { return false }
        try cancellation.check(foreground: pid)
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
    func selectBackward(_ characters: Int) throws {
        try validateFocus()
        for _ in 0..<characters { try key(CGKeyCode(kVK_LeftArrow), flags: .maskShift) }
    }
    func insert(_ text: String, replacing expected: DictationEditorSnapshot) throws {
        try require(expected)
        let down = try DictationUnicodeInput.keyDown(text, source: events)
        guard let up = CGEvent(keyboardEventSource: events, virtualKey: 0, keyDown: false) else { throw DictationTargetError.unconfirmed }
        up.flags = []
        try cancellation.check(foreground: pid)
        down.postToPid(pid); up.postToPid(pid)
    }
    func deleteSelection(matching expected: DictationEditorSnapshot) throws {
        try require(expected)
        guard expected.selection.length > 0 else { throw DictationTargetError.changed }
        try key(CGKeyCode(kVK_Delete))
    }
    private func require(_ expected: DictationEditorSnapshot) throws {
        let actual = try snapshot()
        guard sameText(actual.value, expected.value), actual.selection == expected.selection else { throw DictationTargetError.changed }
    }
    private func key(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        try validateFocus()
        guard let down = CGEvent(keyboardEventSource: events, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: events, virtualKey: key, keyDown: false) else { throw DictationTargetError.unconfirmed }
        down.flags = flags; up.flags = flags
        try cancellation.check(foreground: pid)
        down.postToPid(pid); up.postToPid(pid)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func writable(_ element: AXUIElement, _ name: String) -> Bool {
        var value: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }
}
