import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey?
    @Binding var error: String?
    var allowsUnmodified = false

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.startRecording)
        button.setAccessibilityLabel(allowsUnmodified ? "录制窗口内快捷键" : "录制全局快捷键")
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.hotKey = hotKey
        button.allowsUnmodified = allowsUnmodified
        button.onRecord = { hotKey = $0; error = nil }
        button.onError = { error = $0 }
        button.updateTitle()
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stopRecording() }

    final class RecorderButton: NSButton {
        var hotKey: HotKey?
        var onRecord: ((HotKey) -> Void)?
        var onError: ((String) -> Void)?
        var allowsUnmodified = false
        private var isRecording = false

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            startRecording()
        }

        @objc func startRecording() {
            window?.makeFirstResponder(self)
            isRecording = true
            HotKeyRecordingSession.setRecording(true)
            updateTitle()
        }

        override func resignFirstResponder() -> Bool {
            stopRecording()
            return super.resignFirstResponder()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == 53 && !allowsUnmodified {
                stopRecording()
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                           122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
            let shortcut = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
            do {
                if allowsUnmodified { try shortcut.validateLocal() } else { try shortcut.validate() }
                hotKey = shortcut
                stopRecording()
                onRecord?(shortcut)
                updateTitle()
            } catch { onError?(error.localizedDescription) }
        }

        func stopRecording() {
            guard isRecording else { return }
            isRecording = false
            HotKeyRecordingSession.setRecording(false)
            updateTitle()
        }

        func updateTitle() { title = isRecording ? (allowsUnmodified ? "按下按键；点击其他位置取消" : "按下组合键（Esc 取消）") : hotKey?.display ?? "点击录制快捷键" }
    }
}
