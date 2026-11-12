import Carbon
import Foundation

struct HotKey: Codable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    var display: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + key
    }

    var identity: String { "\(keyCode):\(modifiers)" }

    func validate() throws {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard keyCode < 128, !key.isEmpty, key.count <= 20,
              modifiers & ~allowed == 0,
              modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            throw PluginError.invalid("快捷键至少需要包含 ⌘、⌥ 或 ⌃，并搭配一个按键。")
        }
    }

    func validateLocal() throws {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard keyCode < 128, !key.isEmpty, key.count <= 20, modifiers & ~allowed == 0 else {
            throw PluginError.invalid("请选择有效的窗口内按键。")
        }
    }
}


@MainActor enum HotKeyRecordingSession {
    static let changed = Notification.Name("TietiezhiTools.hotKeyRecordingChanged")
    private(set) static var isRecording = false
    static func setRecording(_ value: Bool) {
        guard isRecording != value else { return }
        isRecording = value
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
