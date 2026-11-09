import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey?
    @Binding var error: String?

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.startRecording)
        button.setAccessibilityLabel("录制全局快捷键")
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.hotKey = hotKey
        button.onRecord = { hotKey = $0; error = nil }
        button.onError = { error = $0 }
        button.updateTitle()
    }

    final class RecorderButton: NSButton {
        var hotKey: HotKey?
        var onRecord: ((HotKey) -> Void)?
        var onError: ((String) -> Void)?
        private var isRecording = false

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            startRecording()
        }

        @objc func startRecording() {
            isRecording = true
            window?.makeFirstResponder(self)
            updateTitle()
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            updateTitle()
            return super.resignFirstResponder()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == 53 {
                isRecording = false
                updateTitle()
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                           122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
            let shortcut = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
            do {
                try shortcut.validate()
                hotKey = shortcut
                isRecording = false
                onRecord?(shortcut)
                updateTitle()
            } catch { onError?(error.localizedDescription) }
        }

        func updateTitle() { title = isRecording ? "按下组合键（Esc 取消）" : hotKey?.display ?? "点击录制快捷键" }
    }
}
