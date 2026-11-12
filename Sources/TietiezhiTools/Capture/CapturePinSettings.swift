import AppKit
import SwiftUI

// Names describe physical inputs on macOS; bindings are stored separately from global shortcuts.
enum CapturePinMouseAction:String,CaseIterable,Identifiable,Codable {
    case zoom,opacity,close,copyClose,reset,thumbnail,copy,text,menu,move,moveIgnoringText,export,select
    var id:String { rawValue }
    var title:String {
        switch self { case .zoom:"缩放";case .opacity:"透明度";case .close:"关闭";case .copyClose:"复制并关闭";case .reset:"重置大小和透明度";case .thumbnail:"缩略图";case .copy:"复制内容";case .text:"复制文本";case .menu:"菜单";case .move:"移动贴图";case .moveIgnoringText:"忽略文字移动";case .export:"拖出内容";case .select:"多选贴图" }
    }
    var phase:String { switch self { case .zoom,.opacity:"wheel";case .move,.moveIgnoringText,.export:"drag";default:"click" } }
    var defaultGesture:String {
        switch self { case .zoom:"0:0:wheel";case .opacity:"256:0:wheel";case .close:"0:0:double";case .copyClose:"";case .reset:"0:2:click";case .thumbnail:"512:0:double";case .copy:"";case .text:"512:1:click";case .menu:"0:1:click";case .move:"0:0:drag";case .moveIgnoringText:"2048:0:drag";case .export:"256:0:drag";case .select:"4096:0:click" }
    }
}
@MainActor final class CapturePinMouseSettings:ObservableObject {
    static let shared=CapturePinMouseSettings()
    @Published private(set) var values:[String:String]
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults;values=defaults.dictionary(forKey:"capture.pin.mouse") as? [String:String] ?? [:]
    }
    func gesture(_ action:CapturePinMouseAction) -> String { values[action.rawValue] ?? action.defaultGesture }
    func set(_ gesture:String,for action:CapturePinMouseAction) throws {
        if !gesture.isEmpty,let conflict=CapturePinMouseAction.allCases.first(where:{ $0 != action && self.gesture($0)==gesture }) { throw PluginError.invalid("该操作已用于「\(conflict.title)」。") }
        values[action.rawValue]=gesture;defaults.set(values,forKey:"capture.pin.mouse")
    }
    func reset() { values=[:];defaults.removeObject(forKey:"capture.pin.mouse") }
    func action(_ event:NSEvent,phase:String) -> CapturePinMouseAction? {
        let modifiers=CaptureShortcutSettings.modifiers(event.modifierFlags)
        let input="\(modifiers):\(phase=="wheel" ? 0:event.buttonNumber):\(phase=="click" && event.clickCount==2 ? "double":phase)"
        return CapturePinMouseAction.allCases.first { gesture($0)==input }
    }
    static func options(for action:CapturePinMouseAction) -> [(String,String)] {
        let modifiers:[(String,Int)]=[("",0),("⇧ ",512),("⌘ ",256),("⌥ ",2048),("⌃ ",4096),("⌘⇧ ",768),("⌥⇧ ",2560)]
        var result=[("无","")]
        if action.phase=="wheel" { return result+modifiers.map { ($0.0+"滚轮","\($0.1):0:wheel") } }
        for (prefix,mask) in modifiers {
            for (button,name) in [(0,"左键"),(1,"右键"),(2,"中键"),(3,"侧键 1"),(4,"侧键 2")] {
                if action.phase=="drag" { result.append((prefix+name+"拖动","\(mask):\(button):drag")) }
                else {
                    if button != 0 || mask != 0 { result.append((prefix+name+"单击","\(mask):\(button):click")) }
                    result.append((prefix+name+"双击","\(mask):\(button):double"))
                }
            }
        }
        return result
    }
}
struct CapturePinSettingsView:View {
    @ObservedObject private var mouse=CapturePinMouseSettings.shared
    @AppStorage("capture.pin.selectText") private var selectText=true
    @AppStorage("capture.pin.keepHTML") private var keepHTML=true
    @AppStorage("capture.pin.lockPreventsClose") private var lockPreventsClose=true
    @ViewState private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Toggle("图片及文本贴图中的文字可选择",isOn:$selectText)
            Toggle("保留 HTML 文本格式",isOn:$keepHTML)
            Toggle("锁定时禁止快捷键和鼠标关闭",isOn:$lockPreventsClose)
            ForEach(CapturePinMouseAction.allCases) { action in
                Picker(action.title,selection:Binding(get:{mouse.gesture(action)},set:{ value in
                    do { try mouse.set(value,for:action);error=nil } catch { self.error=error.localizedDescription }
                })) { ForEach(CapturePinMouseSettings.options(for:action),id:\.1) { Text($0.0).tag($0.1) } }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Button("恢复默认鼠标操作") { mouse.reset();error=nil }
        }
    }
}
