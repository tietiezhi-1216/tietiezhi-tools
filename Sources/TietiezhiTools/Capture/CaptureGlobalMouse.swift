import AppKit
import ApplicationServices
import SwiftUI

enum CaptureGlobalMouseAction:String,CaseIterable,Identifiable,Codable,Sendable {
    case edit,copy,pin,text,save
    var id:String { rawValue }
    var title:String { switch self { case .edit:"截图并编辑";case .copy:"截图并复制";case .pin:"截图并贴图";case .text:"识别文字并复制";case .save:"截图并快速保存" } }
}

struct CaptureGlobalMouseBinding:Identifiable,Codable,Equatable,Sendable {
    var id=UUID()
    var enabled=true
    var modifier="option"
    var button=0
    var action:CaptureGlobalMouseAction = .edit
    static let modifiers:[(String,String,CGEventFlags)] = [
        ("shift","⇧",.maskShift),("control","⌃",.maskControl),("option","⌥",.maskAlternate),("command","⌘",.maskCommand),
        ("shiftControl","⇧⌃",[.maskShift,.maskControl]),("shiftOption","⇧⌥",[.maskShift,.maskAlternate]),("shiftCommand","⇧⌘",[.maskShift,.maskCommand]),
        ("controlOption","⌃⌥",[.maskControl,.maskAlternate]),("controlCommand","⌃⌘",[.maskControl,.maskCommand]),("commandOption","⌘⌥",[.maskCommand,.maskAlternate]),
        ("shiftControlOption","⇧⌃⌥",[.maskShift,.maskControl,.maskAlternate]),("shiftControlCommand","⇧⌃⌘",[.maskShift,.maskControl,.maskCommand]),
        ("shiftCommandOption","⇧⌘⌥",[.maskShift,.maskCommand,.maskAlternate]),("controlCommandOption","⌃⌘⌥",[.maskControl,.maskCommand,.maskAlternate]),
        ("all","⇧⌃⌘⌥",[.maskShift,.maskControl,.maskCommand,.maskAlternate])
    ]
    var flags:CGEventFlags { Self.modifiers.first { $0.0==modifier }?.2 ?? [] }
    var isValid:Bool { !flags.isEmpty && (0...4).contains(button) }
    var gestureKey:String { "\(modifier):\(button)" }
}

struct CaptureGlobalMousePreferences {
    static let bindingsKey="capture.mouse.bindings"
    var enabled:Bool
    var bindings:[CaptureGlobalMouseBinding]
    var ignored:[String]
    init(defaults:UserDefaults = .standard) {
        enabled=defaults.bool(forKey:"capture.mouse.enabled")
        if let data=defaults.data(forKey:Self.bindingsKey) {
            // An explicitly empty or malformed new configuration must never
            // reactivate legacy bindings that the user removed.
            bindings=(try? JSONDecoder().decode([CaptureGlobalMouseBinding].self,from:data)) ?? []
        } else if defaults.object(forKey:Self.bindingsKey) != nil { bindings=[] }
        else {
            let legacy=CaptureGlobalMouseBinding(modifier:defaults.string(forKey:"capture.mouse.modifier") ?? "option",button:defaults.integer(forKey:"capture.mouse.button"),action:CaptureGlobalMouseAction(rawValue:defaults.string(forKey:"capture.mouse.action") ?? "") ?? .edit)
            bindings=legacy.isValid ? [legacy]:[]
            if let data=try? JSONEncoder().encode(bindings) { defaults.set(data,forKey:Self.bindingsKey) }
        }
        ignored=(defaults.string(forKey:"capture.mouse.ignored") ?? "").components(separatedBy:CharacterSet(charactersIn:",\n")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }
    var hasEnabledBindings:Bool { bindings.contains { $0.enabled && $0.isValid } }
    static func save(_ values:[CaptureGlobalMouseBinding],defaults:UserDefaults = .standard) throws {
        guard values.count<=64,Set(values.map(\.id)).count==values.count,values.allSatisfy(\.isValid) else { throw PluginError.invalid("请选择有效的辅助键和鼠标键，最多保留 64 组操作。") }
        var used=Set<String>()
        for value in values where value.enabled {
            guard used.insert(value.gestureKey).inserted else { throw PluginError.invalid("该组合已被其他启用的操作使用，请更换组合或先停用原操作。") }
        }
        defaults.set(try JSONEncoder().encode(values),forKey:bindingsKey)
    }
    func match(button:Int,flags:CGEventFlags,application:String) -> CaptureGlobalMouseBinding? {
        guard enabled,!ignores(application) else { return nil }
        let relevant=flags.intersection([.maskShift,.maskControl,.maskCommand,.maskAlternate])
        let matches=bindings.filter { $0.enabled && $0.isValid && $0.button==button && $0.flags==relevant }
        // A corrupted configuration with duplicate active combinations must pass
        // input through, rather than choose an arbitrary destructive action.
        return matches.count==1 ? matches[0]:nil
    }
    func ignores(_ identifier:String) -> Bool {
        let lower=identifier.lowercased()
        return ignored.contains { pattern in
            let expression="^"+pattern.components(separatedBy:"*").map(NSRegularExpression.escapedPattern(for:)).joined(separator:".*")+"$"
            return lower.range(of:expression,options:.regularExpression) != nil
        }
    }
}

/// Installed on the main run loop. Only an explicitly enabled modifier + button
/// gesture is suppressed; ordinary pointer input is returned unchanged.
@MainActor final class CaptureGlobalMouse:ObservableObject {
    @Published private(set) var status=""
    private var tap:CFMachPort?
    private var source:CFRunLoopSource?
    private var timer:Timer?
    private var startPoint:CGPoint?
    private var lastPoint:CGPoint?
    private var initialEvent:CGEvent?
    private static let replayMarker:Int64=0x5449454D4F555345
    private var action:CaptureGlobalMouseAction = .edit
    private var activeButton:Int64=0
    private var overlay:NSPanel?
    private var task:Task<Void,Never>?
    private var permissions:PluginPermissionClient?
    private var allowed:(()->Bool)?
    private var completion:((CaptureSelection,CaptureGlobalMouseAction) async throws -> Void)?
    private var service=CaptureService()
    private var generation=0

    func start(isAllowed:@escaping ()->Bool,permissions:PluginPermissionClient,
               completion:@escaping (CaptureSelection,CaptureGlobalMouseAction) async throws -> Void) {
        stop();self.allowed=isAllowed;self.permissions=permissions;self.completion=completion
        refresh()
        timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func stop() {
        generation += 1;timer?.invalidate();timer=nil;task?.cancel();task=nil
        removeTap();clearGesture();allowed=nil;completion=nil;permissions=nil
    }
    func requestPermissions() {
        do { try permissions?.require([.screenRecording,.accessibility]);refresh() }
        catch { status=error is HostPermissionError ? "请在应用权限管理中授权":"\(error.localizedDescription)" }
    }
    private func refresh() {
        let preferences=CaptureGlobalMousePreferences()
        guard preferences.enabled,preferences.hasEnabledBindings,allowed?()==true else { removeTap();clearGesture();status="";return }
        guard AXIsProcessTrusted(),CGPreflightScreenCaptureAccess() else { removeTap();status="需要屏幕录制和辅助功能权限";return }
        guard tap==nil else { return }
        let mask:[CGEventType]=[.leftMouseDown,.leftMouseDragged,.leftMouseUp,.rightMouseDown,.rightMouseDragged,.rightMouseUp,.otherMouseDown,.otherMouseDragged,.otherMouseUp]
        let eventMask=mask.reduce(CGEventMask(0)) { $0 | (CGEventMask(1)<<$1.rawValue) }
        let pointer=Unmanaged.passUnretained(self).toOpaque()
        guard let tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:eventMask,callback:{ _,type,event,info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let suppressed=MainActor.assumeIsolated { Unmanaged<CaptureGlobalMouse>.fromOpaque(info).takeUnretainedValue().handle(type,event:event) }
            return suppressed ? nil : Unmanaged.passUnretained(event)
        },userInfo:pointer),let source=CFMachPortCreateRunLoopSource(nil,tap,0) else { status="鼠标监听未启动，请检查辅助功能权限";return }
        self.tap=tap;self.source=source;CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes);CGEvent.tapEnable(tap:tap,enable:true);status=""
    }
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        tap=nil;source=nil
    }
    private func handle(_ type:CGEventType,event:CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData)==Self.replayMarker { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            clearGesture();if let tap { CGEvent.tapEnable(tap:tap,enable:true) };return false
        }
        let button=event.getIntegerValueField(.mouseEventButtonNumber)
        let down=[CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type)
        let up=[CGEventType.leftMouseUp,.rightMouseUp,.otherMouseUp].contains(type)
        if let startPoint,button==activeButton {
            lastPoint=event.location;updateOverlay(from:startPoint,to:event.location)
            if up {
                let rect=CGRect(x:min(startPoint.x,event.location.x),y:min(startPoint.y,event.location.y),width:abs(event.location.x-startPoint.x),height:abs(event.location.y-startPoint.y))
                let original=initialEvent
                clearGesture()
                if rect.width>=8,rect.height>=8,allowed?()==true { capture(rect,action:action) }
                else if let original,let end=event.copy() {
                    // A click or tiny movement is ordinary input, not a capture.
                    // Replay its complete down/up pair once, bypassing this tap.
                    original.setIntegerValueField(.eventSourceUserData,value:Self.replayMarker)
                    end.setIntegerValueField(.eventSourceUserData,value:Self.replayMarker)
                    original.post(tap:.cghidEventTap);end.post(tap:.cghidEventTap)
                }
            }
            return true
        }
        guard startPoint==nil,down,task==nil,allowed?()==true else { return false }
        let prefs=CaptureGlobalMousePreferences()
        guard let binding=prefs.match(button:Int(button),flags:event.flags,application:NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""),let original=event.copy() else { return false }
        startPoint=event.location;lastPoint=event.location;initialEvent=original;activeButton=button;action=binding.action
        return true
    }
    private func updateOverlay(from:CGPoint,to:CGPoint) {
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        let rect=CGRect(x:min(from.x,to.x),y:top-max(from.y,to.y),width:max(1,abs(to.x-from.x)),height:max(1,abs(to.y-from.y)))
        if overlay==nil {
            let panel=NSPanel(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            CaptureWindowPolicy.markControl(panel,name:"globalMouse")
            panel.isReleasedWhenClosed=false;panel.level = .screenSaver;panel.isOpaque=false;panel.backgroundColor = .clear;panel.ignoresMouseEvents=true
            panel.collectionBehavior=CaptureWindowPolicy.floatingBehavior
            let view=NSView();view.wantsLayer=true;view.layer?.borderWidth=2;view.layer?.borderColor=NSColor.controlAccentColor.cgColor;view.layer?.backgroundColor=NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            panel.contentView=view;overlay=panel
        }
        overlay?.setFrame(rect,display:true);overlay?.orderFrontRegardless()
    }
    private func clearGesture() { startPoint=nil;lastPoint=nil;initialEvent=nil;overlay?.orderOut(nil);overlay?.close();overlay=nil }
    private func capture(_ rect:CGRect,action:CaptureGlobalMouseAction) {
        let current=generation
        task=Task { [weak self] in
            guard let self,let permissions=self.permissions else { return }
            defer { self.task=nil }
            do {
                try permissions.require([.screenRecording,.accessibility])
                let selection=try await service.captureGlobalRegion(rect,permissions:permissions)
                guard !Task.isCancelled,generation==current,allowed?()==true else { return }
                try await completion?(selection,action)
            } catch { status=error is HostPermissionError ? "请在应用权限管理中授权":error.localizedDescription }
        }
    }
}

struct CaptureGlobalMouseSettingsView:View {
    @ObservedObject var mouse:CaptureGlobalMouse
    @AppStorage("capture.mouse.enabled") private var enabled=false
    @AppStorage("capture.mouse.ignored") private var ignored=""
    @ViewState private var bindings:[CaptureGlobalMouseBinding]=[]
    @ViewState private var error=""
    var body:some View {
        Section("全局鼠标") {
            Toggle("辅助键加拖动截图",isOn:$enabled).onChange(of:enabled) { _,value in if value { mouse.requestPermissions() } }
            if enabled {
                ForEach(bindings) { binding in
                    VStack(alignment:.leading,spacing:6) {
                        HStack {
                            Toggle("启用",isOn:value(binding,\.enabled)).labelsHidden().help("启用这组鼠标操作")
                            Picker("操作",selection:value(binding,\.action)) { ForEach(CaptureGlobalMouseAction.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                            Spacer()
                            Button { save(bindings.filter { $0.id != binding.id }) } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless).help("删除这组操作")
                        }
                        HStack {
                            Picker("辅助键",selection:value(binding,\.modifier)) { ForEach(CaptureGlobalMouseBinding.modifiers,id:\.0) { Text($0.1).tag($0.0) } }
                            Picker("鼠标",selection:value(binding,\.button)) { Text("左键拖动").tag(0);Text("右键拖动").tag(1);Text("中键拖动").tag(2);Text("侧键 1 拖动").tag(3);Text("侧键 2 拖动").tag(4) }
                        }.controlSize(.small)
                    }.padding(.vertical,4)
                }
                Button("添加操作",systemImage:"plus") { add() }.disabled(bindings.count>=64)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                TextField("忽略应用",text:$ignored,prompt:Text("应用标识，用逗号分隔，例如 com.apple.Terminal"))
                if !mouse.status.isEmpty { HStack { Text(mouse.status).font(.caption).foregroundStyle(.secondary);Spacer();Button("管理权限") { mouse.requestPermissions() } } }
            }
        }.onAppear { bindings=CaptureGlobalMousePreferences().bindings }
    }
    private func value<Value>(_ binding:CaptureGlobalMouseBinding,_ key:WritableKeyPath<CaptureGlobalMouseBinding,Value>) -> Binding<Value> {
        Binding(get:{ (bindings.first { $0.id==binding.id } ?? binding)[keyPath:key] },set:{ newValue in
            var next=bindings;guard let index=next.firstIndex(where:{ $0.id==binding.id }) else { return }
            next[index][keyPath:key]=newValue;save(next)
        })
    }
    private func save(_ next:[CaptureGlobalMouseBinding]) {
        do { try CaptureGlobalMousePreferences.save(next);bindings=next;error="" }
        catch { self.error=error.localizedDescription }
    }
    private func add() {
        let used=Set(bindings.map(\.gestureKey))
        for modifier in ["option","control","commandOption","controlOption"] {
            for button in 0...4 {
                var binding=CaptureGlobalMouseBinding(enabled:false,modifier:modifier,button:button)
                guard !used.contains(binding.gestureKey) else { continue }
                binding.action=CaptureGlobalMouseAction.allCases[bindings.count % CaptureGlobalMouseAction.allCases.count]
                save(bindings+[binding]);return
            }
        }
        save(bindings+[CaptureGlobalMouseBinding(enabled:false)])
    }
}
