import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit

@MainActor final class CaptureSelector {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureSelection?) -> Void)?
    func show(_ screens: [(NSScreen, SCDisplay, SCContentFilter, CGImage)], windows: [SCWindow], allowsShapes: Bool,
              completion: @escaping (CaptureSelection?) -> Void) {
        self.completion=completion
        if allowsShapes,screens.count>1 {
            do { try showAcrossScreens(screens,windows:windows) }
            catch { finish(nil) }
            return
        }
        for (screen,display,filter,image) in screens {
            let panel=CaptureSelectionPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            CaptureWindowPolicy.markControl(panel,name:"selector")
            panel.isReleasedWhenClosed=false;panel.level = .screenSaver
            panel.collectionBehavior=CaptureWindowPolicy.floatingBehavior;panel.hasShadow=false;panel.acceptsMouseMovedEvents=true
            let view=CaptureSelectionView(image:image,allowsShapes:allowsShapes)
            view.screenOrigin=display.frame.origin
            view.historyRegions=Self.regionHistory.filter { $0.displayID==display.displayID }.map(\.rect)
            view.elementTargets=windows.filter { $0.windowLayer==0 }.compactMap { window in window.owningApplication.map { (window.frame,$0.processID) } }
            view.windows=windows.filter { $0.windowLayer==0 }.map {
                $0.frame.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY).intersection(CGRect(origin:.zero,size:screen.frame.size))
            }.filter { !$0.isEmpty }
            view.refresh = {
                let config=SCStreamConfiguration();config.width=image.width;config.height=image.height;config.showsCursor=false
                return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            }
            view.completed = { [weak self,weak view] rect,contours in
                guard let rect,let view else { self?.finish(nil);return }
                let image=view.image,scale=CGFloat(image.width)/screen.frame.width
                let pixels=CGRect(x:rect.minX*scale,y:rect.minY*scale,width:rect.width*scale,height:rect.height*scale).integral
                guard let cropped=image.cropping(to:pixels) else { return }
                let aligned=CGRect(x:pixels.minX/scale,y:pixels.minY/scale,width:pixels.width/scale,height:pixels.height/scale)
                do {
                    let masked=try CaptureSelectionGeometry.masked(cropped,contours:contours,rect:aligned,scale:scale)
                    let result=try view.decorate(masked,scale:scale)
                    let window=contours.count<=1 && contours.first?.points == CaptureSelectionGeometry.rectangle(rect) && contours.first?.subtract != true && view.rounded.state == .off && view.shadowButton.state == .off && view.border.state == .off ? windows.first { $0.frame.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY).intersection(CGRect(origin:.zero,size:screen.frame.size))==rect } : nil
                    let padding=CGFloat(view.decorationPadding)/scale
                    let presentation=CaptureFloatingLayout.screenRect(aligned,on:screen.frame).insetBy(dx:-padding,dy:-padding)
                    self?.finish(CaptureSelection(display:display,filter:filter,rect:aligned,scale:scale,image:result,windowID:window?.windowID,presentationFrameOverride:presentation,initialTool:view.initialTool,postAction:view.postAction))
                } catch { view.showError(error.localizedDescription) }
            }
            panel.contentView=view;panels.append(panel);panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(view)
        }
    }
    private static var regionHistory:[CaptureRegionMemory] {
        guard let data=UserDefaults.standard.data(forKey:"capture.regionHistory") else { return [] }
        return (try? JSONDecoder().decode([CaptureRegionMemory].self,from:data)) ?? []
    }
    private func composite(_ screens:[(NSScreen,SCDisplay,SCContentFilter,CGImage)], union:CGRect, scale:CGFloat) throws -> CGImage {
        let context=try CaptureImage.context(width:Int((union.width*scale).rounded()),height:Int((union.height*scale).rounded()))
        for (_,display,_,image) in screens {
            let rect=CGRect(x:(display.frame.minX-union.minX)*scale,y:(union.maxY-display.frame.maxY)*scale,width:display.frame.width*scale,height:display.frame.height*scale)
            context.draw(image,in:rect)
        }
        guard let result=context.makeImage() else { throw PluginError.invalid("无法合成多屏截图。") };return result
    }
    private func showAcrossScreens(_ screens:[(NSScreen,SCDisplay,SCContentFilter,CGImage)],windows:[SCWindow]) throws {
        let frame=screens.dropFirst().reduce(screens[0].0.frame) { $0.union($1.0.frame) }
        let world=screens.dropFirst().reduce(screens[0].1.frame) { $0.union($1.1.frame) }
        let scale=screens.map { CGFloat($0.3.width)/$0.0.frame.width }.max() ?? 1
        let image=try composite(screens,union:world,scale:scale)
        let panel=CaptureSelectionPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        CaptureWindowPolicy.markControl(panel,name:"selector")
        panel.isReleasedWhenClosed=false;panel.level = .screenSaver;panel.collectionBehavior=CaptureWindowPolicy.floatingBehavior
        panel.hasShadow=false;panel.acceptsMouseMovedEvents=true
        let view=CaptureSelectionView(image:image,allowsShapes:true)
        view.screenOrigin=world.origin
        view.historyRegions=Self.regionHistory.compactMap { memory in
            guard let display=screens.first(where:{ $0.1.displayID==memory.displayID })?.1 else { return nil }
            return memory.rect.offsetBy(dx:display.frame.minX-world.minX,dy:display.frame.minY-world.minY)
        }
        view.displayRects=screens.map { $0.1.frame.offsetBy(dx:-world.minX,dy:-world.minY) }
        view.windows=windows.filter { $0.windowLayer==0 }.map { $0.frame.offsetBy(dx:-world.minX,dy:-world.minY).intersection(CGRect(origin:.zero,size:world.size)) }.filter { !$0.isEmpty }
        view.elementTargets=windows.filter { $0.windowLayer==0 }.compactMap { window in window.owningApplication.map { (window.frame,$0.processID) } }
        view.refresh = { [weak self] in
            guard let self else { throw CancellationError() }
            var fresh:[(NSScreen,SCDisplay,SCContentFilter,CGImage)]=[]
            for (screen,display,filter,image) in screens {
                let config=SCStreamConfiguration();config.width=image.width;config.height=image.height;config.showsCursor=false
                let next=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                fresh.append((screen,display,filter,next))
            }
            return try self.composite(fresh,union:world,scale:scale)
        }
        view.completed = { [weak self,weak view] rect,contours in
            guard let rect,let view else { self?.finish(nil);return }
            let pixels=CGRect(x:rect.minX*scale,y:rect.minY*scale,width:rect.width*scale,height:rect.height*scale).integral
            guard let cropped=view.image.cropping(to:pixels) else { return }
            let aligned=CGRect(x:pixels.minX/scale,y:pixels.minY/scale,width:pixels.width/scale,height:pixels.height/scale)
            let global=aligned.offsetBy(dx:world.minX,dy:world.minY)
            let contained=screens.first { $0.1.frame.contains(global) },source=contained ?? screens[0]
            do {
                let masked=try CaptureSelectionGeometry.masked(cropped,contours:contours,rect:aligned,scale:scale)
                let result=try view.decorate(masked,scale:scale)
                let padding=CGFloat(view.decorationPadding)/scale
                let presentation=CGRect(x:frame.minX+aligned.minX,y:frame.maxY-aligned.maxY,width:aligned.width,height:aligned.height).insetBy(dx:-padding,dy:-padding)
                self?.finish(CaptureSelection(display:source.1,filter:source.2,rect:global.offsetBy(dx:-source.1.frame.minX,dy:-source.1.frame.minY),scale:scale,image:result,presentationFrameOverride:presentation,isComposite:contained==nil,initialTool:view.initialTool,postAction:view.postAction))
            } catch { view.showError(error.localizedDescription) }
        }
        panel.contentView=view;panels.append(panel);panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(view)
    }
    func finish(_ selection: CaptureSelection?) {
        guard let completion else { return };self.completion=nil
        for panel in panels { (panel.contentView as? CaptureSelectionView)?.cancelRefresh();panel.orderOut(nil);panel.close() }
        panels.removeAll();completion(selection)
    }
}

private final class CaptureSelectionPanel: NSPanel { override var canBecomeKey: Bool { true } }

@MainActor private final class CaptureSelectionColorWell:NSColorWell {
    private var previousLevel:NSWindow.Level?
    override func activate(_ exclusive:Bool) {
        let panel=NSColorPanel.shared
        if previousLevel==nil { previousLevel=panel.level }
        panel.level=NSWindow.Level(rawValue:NSWindow.Level.screenSaver.rawValue+1)
        super.activate(exclusive)
    }
    override func deactivate() {
        super.deactivate()
        if let previousLevel { NSColorPanel.shared.level=previousLevel;self.previousLevel=nil }
    }
}

@MainActor private final class CaptureSelectionView: NSView, NSTextFieldDelegate {
    enum Shape: Int { case rectangle, freehand, polygon, windows }
    enum Drag { case create, move, resize(CaptureSelectionHandle) }
    var image: CGImage
    var windows:[CGRect]=[]
    var displayRects:[CGRect]=[]
    var historyRegions:[CGRect]=[]
    var elementTargets:[(CGRect,pid_t)]=[]
    var screenOrigin=CGPoint.zero
    var completed:((CGRect?,[CaptureSelectionContour])->Void)?
    var initialTool:CaptureTool?
    var postAction:CaptureSelectionPostAction?
    private var actionButtons:[NSButton]=[]
    var refresh:(() async throws -> CGImage)?
    private var refreshTask:Task<Void,Never>?
    private let allowsShapes:Bool
    private var selected:CGRect?
    private var confirmed=false
    private var points:[CGPoint]=[]
    private var contours:[CaptureSelectionContour]=[]
    private var originalContours:[CaptureSelectionContour]=[]
    private var anchor:CGPoint?
    private var original:CGRect?
    private var originalPoints:[CGPoint]=[]
    private var drag:Drag = .create
    private var mouse=CGPoint.zero
    private var modifiers:NSEvent.ModifierFlags=[]
    private var ratio:CGFloat?
    private var detectElements=true
    private var lastDetection=Date.distantPast
    private var shape:Shape = .rectangle
    private let controls=NSVisualEffectView()
    private let modes=NSSegmentedControl(labels:["矩形","自由","折线","多窗口"],trackingMode:.selectOne,target:nil,action:nil)
    private let operations=NSSegmentedControl(labels:["替换","增加","扣除"],trackingMode:.selectOne,target:nil,action:nil)
    private let history=NSPopUpButton(frame:.zero,pullsDown:true)
    let rounded=NSButton(checkboxWithTitle:"圆角",target:nil,action:nil)
    let shadowButton=NSButton(checkboxWithTitle:"阴影",target:nil,action:nil)
    let border=NSButton(checkboxWithTitle:"边框",target:nil,action:nil)
    private var appearancePopover:NSPopover?
    private var appearanceSliders:[String:NSSlider]=[:]
    private var appearanceValues:[String:NSTextField]=[:]
    private let borderColorWell=CaptureSelectionColorWell()
    private let rememberAppearance=NSButton(checkboxWithTitle:"以后截图沿用这些效果",target:nil,action:nil)
    private let lock=NSButton(checkboxWithTitle:"固定比例",target:nil,action:nil)
    private let refreshButton=NSButton(title:"刷新",target:nil,action:nil)
    private let finishButton=NSButton(title:"编辑",target:nil,action:nil)
    private var fields:[NSTextField]=[]
    private let message=NSTextField(labelWithString:"")
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    init(image:CGImage,allowsShapes:Bool) {
        self.image=image;self.allowsShapes=allowsShapes;super.init(frame:.zero)
        controls.material = .hudWindow;controls.blendingMode = .withinWindow;controls.state = .active
        controls.wantsLayer=true;controls.layer?.cornerRadius=12;controls.layer?.masksToBounds=true;addSubview(controls)
        let rows=NSStackView();rows.orientation = .vertical;rows.spacing=8;rows.alignment = .leading
        let top=NSStackView();top.spacing=9
        if allowsShapes { modes.selectedSegment=0;modes.target=self;modes.action=#selector(modeChanged);top.addArrangedSubview(modes) }
        for (i,title) in ["X","Y","宽","高"].enumerated() {
            top.addArrangedSubview(NSTextField(labelWithString:title))
            let field=NSTextField(string:"");field.tag=i;field.alignment = .right;field.delegate=self;field.target=self;field.action=#selector(applyFields)
            let formatter=NumberFormatter();formatter.minimum=0;formatter.maximumFractionDigits=0;field.formatter=formatter
            field.widthAnchor.constraint(equalToConstant:52).isActive=true;fields.append(field);top.addArrangedSubview(field)
        }
        let bottom=NSStackView();bottom.spacing=10
        if allowsShapes { operations.selectedSegment=0;operations.target=self;operations.action=#selector(operationChanged);bottom.addArrangedSubview(operations) }
        history.addItem(withTitle:"历史选区");history.target=self;history.action=#selector(restoreHistory);bottom.addArrangedSubview(history)
        lock.target=self;lock.action=#selector(lockChanged);bottom.addArrangedSubview(lock)
        refreshButton.target=self;refreshButton.action=#selector(refreshImage);bottom.addArrangedSubview(refreshButton)
        let reset=NSButton(title:"重新框选",target:self,action:#selector(resetSelection));bottom.addArrangedSubview(reset)
        let cancel=NSButton(title:"取消",target:self,action:#selector(cancelSelection));bottom.addArrangedSubview(cancel)
        finishButton.target=self;finishButton.action=#selector(finishSelection);finishButton.bezelStyle = .rounded;finishButton.keyEquivalent="\r";bottom.addArrangedSubview(finishButton)
        message.font = .systemFont(ofSize:11);message.textColor = .secondaryLabelColor
        rows.addArrangedSubview(top);rows.addArrangedSubview(bottom)
        if allowsShapes {
            let appearance=NSStackView();appearance.spacing=12
            for button in [rounded,shadowButton,border] { button.target=self;button.action=#selector(appearanceChanged);appearance.addArrangedSubview(button) }
            if UserDefaults.standard.bool(forKey:"capture.selection.remember") {
                rounded.state=UserDefaults.standard.bool(forKey:"capture.selection.rounded") ? .on:.off
                shadowButton.state=UserDefaults.standard.bool(forKey:"capture.selection.shadow") ? .on:.off
                border.state=UserDefaults.standard.bool(forKey:"capture.selection.border") ? .on:.off
            }
            let parameters=NSButton(title:"样式",target:self,action:#selector(showAppearance(_:)));appearance.addArrangedSubview(parameters)
            let tools:[CaptureTool]=[.arrow,.rectangle,.mosaic,.text]
            for (index,tool) in tools.enumerated() {
                let button=NSButton(image:NSImage(systemSymbolName:tool.symbol,accessibilityDescription:tool.title)!,target:self,action:#selector(chooseTool(_:)))
                button.tag=index;button.toolTip=tool.title;button.bezelStyle = .texturedRounded;appearance.addArrangedSubview(button);actionButtons.append(button)
            }
            for (index,title) in ["复制","贴图","保存"].enumerated() {
                let button=NSButton(title:title,target:self,action:#selector(chooseAction(_:)));button.tag=index;appearance.addArrangedSubview(button);actionButtons.append(button)
            }
            rows.addArrangedSubview(appearance)
        }
        rows.addArrangedSubview(message)
        rows.translatesAutoresizingMaskIntoConstraints=false;controls.addSubview(rows)
        NSLayoutConstraint.activate([rows.leadingAnchor.constraint(equalTo:controls.leadingAnchor,constant:12),rows.trailingAnchor.constraint(equalTo:controls.trailingAnchor,constant:-12),rows.topAnchor.constraint(equalTo:controls.topAnchor,constant:10),rows.bottomAnchor.constraint(equalTo:controls.bottomAnchor,constant:-10)])
        updateControls()
    }
    required init?(coder:NSCoder) { nil }
    override func layout() { super.layout();positionControls() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();if let window { mouse=convert(window.mouseLocationOutsideOfEventStream,from:nil) };rebuildHistory();updateControls() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.activeAlways,.inVisibleRect],owner:self));super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor:confirmed ? .openHand : .crosshair) }
    private var scale:CGFloat { bounds.width>0 ? CGFloat(image.width)/bounds.width : 1 }
    private func selectionPath() -> NSBezierPath? {
        if points.count>=3 {
            let path=NSBezierPath();path.move(to:points[0]);points.dropFirst().forEach(path.line);path.close();return path
        }
        return selected.map(NSBezierPath.init(rect:))
    }
    override func draw(_ dirtyRect:NSRect) {
        let snapshot=NSImage(cgImage:image,size:bounds.size)
        snapshot.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        NSColor.black.withAlphaComponent(0.44).setFill();bounds.fill()
        for contour in contours {
            guard let first=contour.points.first else { continue }
            let path=NSBezierPath();path.move(to:first);contour.points.dropFirst().forEach(path.line);path.close()
            NSGraphicsContext.saveGraphicsState();path.addClip()
            snapshot.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            if contour.subtract { NSColor.black.withAlphaComponent(0.44).setFill();bounds.fill() }
            NSGraphicsContext.restoreGraphicsState()
            (contour.subtract ? NSColor.systemRed:NSColor.controlAccentColor).setStroke();path.lineWidth=1.5;path.stroke()
        }
        if contours.isEmpty || !confirmed,let path=selectionPath() {
            NSGraphicsContext.saveGraphicsState();path.addClip()
            snapshot.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil);NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke();path.lineWidth=1.5;path.stroke()
        }
        if shape == .polygon,!confirmed,!points.isEmpty {
            let path=NSBezierPath();path.move(to:points[0]);points.dropFirst().forEach(path.line);path.line(to:mouse)
            NSColor.controlAccentColor.setStroke();path.lineWidth=2;path.stroke()
        }
        if let selected,confirmed {
            for handle in CaptureSelectionHandle.allCases {
                let point=handle.point(in:selected),box=CGRect(x:point.x-3,y:point.y-3,width:6,height:6)
                NSColor.white.setFill();box.fill();NSColor.controlAccentColor.setStroke();NSBezierPath(rect:box).stroke()
            }
            if modifiers.contains(.option) {
                let path=NSBezierPath()
                for f in [CGFloat(1)/3,CGFloat(2)/3] {
                    path.move(to:CGPoint(x:selected.minX+selected.width*f,y:selected.minY));path.line(to:CGPoint(x:selected.minX+selected.width*f,y:selected.maxY))
                    path.move(to:CGPoint(x:selected.minX,y:selected.minY+selected.height*f));path.line(to:CGPoint(x:selected.maxX,y:selected.minY+selected.height*f))
                }
                NSColor.white.withAlphaComponent(0.5).setStroke();path.setLineDash([3,3],count:2,phase:0);path.stroke()
            }
        }
        if modifiers.contains(.option),!controls.frame.contains(mouse) { drawLoupe() }
    }
    private func drawLoupe() {
        let area=displayRects.first { $0.contains(mouse) } ?? bounds
        let side:CGFloat=120, origin=CGPoint(x:min(max(area.minX+8,mouse.x+24),area.maxX-side-8),y:min(max(area.minY+8,mouse.y+24),area.maxY-side-48))
        let frame=CGRect(origin:origin,size:CGSize(width:side,height:side+34))
        NSColor.windowBackgroundColor.setFill();NSBezierPath(roundedRect:frame,xRadius:8,yRadius:8).fill()
        let x=Int(mouse.x*scale),y=Int(mouse.y*scale)
        let sample=CGRect(x:x-6,y:y-6,width:13,height:13).intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        if let crop=image.cropping(to:sample) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage:crop,size:.zero).draw(in:CGRect(x:origin.x+4,y:origin.y+4,width:side-8,height:side-8),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        let cross=NSBezierPath();cross.move(to:CGPoint(x:origin.x+side/2,y:origin.y+4));cross.line(to:CGPoint(x:origin.x+side/2,y:origin.y+side-4));cross.move(to:CGPoint(x:origin.x+4,y:origin.y+side/2));cross.line(to:CGPoint(x:origin.x+side-4,y:origin.y+side/2));NSColor.systemRed.setStroke();cross.stroke()
        let text="\(x), \(y)  \(pixelColor())\nC 复制颜色 · ⌥C 复制坐标"
        (text as NSString).draw(in:CGRect(x:origin.x+5,y:origin.y+side,width:side-10,height:32),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:9,weight:.regular),.foregroundColor:NSColor.labelColor])
    }
    private func pixelColor() -> String {
        let x=min(image.width-1,max(0,Int(mouse.x*scale))),y=min(image.height-1,max(0,Int(mouse.y*scale)))
        guard let crop=image.cropping(to:CGRect(x:x,y:y,width:1,height:1)),let context=try? CaptureImage.context(width:1,height:1) else { return "" }
        context.draw(crop,in:CGRect(x:0,y:0,width:1,height:1))
        guard let data=context.data?.assumingMemoryBound(to:UInt8.self) else { return "" }
        return String(format:"#%02X%02X%02X",data[0],data[1],data[2])
    }
    override func flagsChanged(with event:NSEvent) { modifiers=event.modifierFlags;needsDisplay=true }
    override func mouseMoved(with event:NSEvent) {
        mouse=convert(event.locationInWindow,from:nil);modifiers=event.modifierFlags
        if !confirmed,anchor==nil,(shape == .rectangle || shape == .windows) {
            selected=windows.first { $0.contains(mouse) }
            if shape != .windows,detectElements,AXIsProcessTrusted(),Date().timeIntervalSince(lastDetection)>0.08 {
                lastDetection=Date();if let element=elementRect(at:mouse) { selected=element }
            }
        }
        if confirmed,let selected {
            let handle=CaptureSelectionHandle.allCases.first { hypot($0.point(in:selected).x-mouse.x,$0.point(in:selected).y-mouse.y)<9 }
            if let handle { (handle == .top || handle == .bottom ? NSCursor.resizeUpDown : .resizeLeftRight).set() }
            else if selected.contains(mouse) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
        }
        needsDisplay=true
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self);mouse=convert(event.locationInWindow,from:nil);modifiers=event.modifierFlags
        if confirmed, event.clickCount==2, selected?.contains(mouse)==true { finishSelection();return }
        if shape == .polygon,!confirmed {
            if event.clickCount==2,points.count>=3 { finalizeShape();return }
            if points.count>=3,let first=points.first,hypot(first.x-mouse.x,first.y-mouse.y)<8 { finalizeShape();return }
            points.append(mouse);selected=CaptureSelectionGeometry.bounds(of:points);needsDisplay=true;return
        }
        anchor=mouse;original=selected;originalPoints=points;originalContours=contours
        if shape == .windows {
            original=windows.first { $0.contains(mouse) };selected=original;confirmed=false;drag = .create;points=[];updateControls();return
        }
        if confirmed,let selected {
            if let handle=CaptureSelectionHandle.allCases.first(where:{ hypot($0.point(in:selected).x-mouse.x,$0.point(in:selected).y-mouse.y)<9 }) { drag = .resize(handle) }
            else if selected.contains(mouse) { drag = .move }
            else { drag = .create;confirmed=false;points=[];if operations.selectedSegment==0 && shape != .windows { contours=[] } }
        } else { drag = .create;points=shape == .freehand ? [mouse] : [];if operations.selectedSegment==0 && shape != .windows { contours=[] } }
        updateControls()
    }
    override func mouseDragged(with event:NSEvent) {
        guard let anchor else { return };mouse=convert(event.locationInWindow,from:nil);modifiers=event.modifierFlags
        let point=CGPoint(x:min(bounds.maxX,max(0,mouse.x)),y:min(bounds.maxY,max(0,mouse.y)))
        let delta=CGSize(width:point.x-anchor.x,height:point.y-anchor.y)
        switch drag {
        case .create:
            if shape == .freehand { points.append(point);selected=CaptureSelectionGeometry.bounds(of:points) }
            else {
                var dx=delta.width,dy=delta.height
                if let r=modifiers.contains(.shift) ? 1 : ratio { dy=(dy<0 ? -1:1)*abs(dx)/r }
                if modifiers.contains(.option) { dx=abs(dx);dy=abs(dy);selected=CGRect(x:anchor.x-dx,y:anchor.y-dy,width:dx*2,height:dy*2).intersection(bounds) }
                else { selected=CGRect(x:min(anchor.x,anchor.x+dx),y:min(anchor.y,anchor.y+dy),width:abs(dx),height:abs(dy)).intersection(bounds) }
            }
        case .move:
            guard let original else { return }
            var move=delta
            if modifiers.contains(.shift) { if abs(move.width)>abs(move.height) { move.height=0 } else { move.width=0 } }
            selected=CaptureSelectionGeometry.constrain(original.offsetBy(dx:move.width,dy:move.height),in:bounds)
        case .resize(let handle):
            guard let original else { return }
            selected=CaptureSelectionGeometry.resize(original,handle:handle,delta:delta,bounds:bounds,ratio:modifiers.contains(.shift) ? 1 : ratio,centered:modifiers.contains(.option))
        }
        if confirmed,let original,let selected { points=CaptureSelectionGeometry.transform(originalPoints,from:original,to:selected);contours=originalContours.map { CaptureSelectionContour(points:CaptureSelectionGeometry.transform($0.points,from:original,to:selected),subtract:$0.subtract) } }
        updateControls();needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        guard let anchor else { return };let point=convert(event.locationInWindow,from:nil)
        if case .create=drag,(shape == .rectangle || shape == .windows),hypot(point.x-anchor.x,point.y-anchor.y)<4 { selected=original ?? windows.first { $0.contains(point) } }
        self.anchor=nil
        if let selected,selected.width>=8,selected.height>=8,shape != .freehand || points.count>=3 { if case .create=drag { commitContour() };confirmed=true }
        else { if !contours.isEmpty { self.selected=CaptureSelectionGeometry.bounds(of:contours.flatMap(\.points));confirmed=true } else { self.selected=nil };points=[] }
        updateControls();needsDisplay=true;window?.invalidateCursorRects(for:self)
    }
    override func rightMouseDown(with event:NSEvent) {
        if shape == .polygon,!confirmed,points.count>=3 { finalizeShape() }
        else if confirmed || !points.isEmpty { resetSelection() } else { cancelSelection() }
    }
    override func keyDown(with event:NSEvent) {
        modifiers=event.modifierFlags
        switch event.keyCode {
        case 53: if confirmed || !points.isEmpty { resetSelection() } else { cancelSelection() }
        case 36,76: if shape == .polygon,!confirmed { finalizeShape() } else { finishSelection() }
        case 96: refreshImage()
        case 48: detectElements.toggle();updateControls()
        case 8:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(modifiers.contains(.option) ? "\(Int(mouse.x*scale)), \(Int(mouse.y*scale))" : pixelColor(),forType:.string)
        case 0 where modifiers.contains(.command):
            let current=displayRects.first { $0.contains(mouse) } ?? bounds
            selected=confirmed && selected==current ? bounds : current;points=[];contours=[];commitContour();confirmed=true;updateControls()
        case 123...126:
            guard let old=selected,confirmed else { return }
            let pixel:CGFloat=1/scale
            let dx:CGFloat=event.keyCode==123 ? -pixel : event.keyCode==124 ? pixel : 0
            let dy:CGFloat=event.keyCode==126 ? -pixel : event.keyCode==125 ? pixel : 0
            if modifiers.contains(.shift) || modifiers.contains(.command) {
                let handle:CaptureSelectionHandle=event.keyCode==123 ? .left : event.keyCode==124 ? .right : event.keyCode==126 ? .top : .bottom
                let multiplier:CGFloat=modifiers.contains(.command) ? 1 : -1
                setRect(CaptureSelectionGeometry.resize(old,handle:handle,delta:CGSize(width:dx*multiplier,height:dy*multiplier),bounds:bounds,ratio:ratio))
            } else { setRect(CaptureSelectionGeometry.constrain(old.offsetBy(dx:dx,dy:dy),in:bounds)) }
        default: super.keyDown(with:event)
        }
        needsDisplay=true
    }
    private func setRect(_ rect:CGRect) { if let old=selected { points=CaptureSelectionGeometry.transform(points,from:old,to:rect);contours=contours.map { CaptureSelectionContour(points:CaptureSelectionGeometry.transform($0.points,from:old,to:rect),subtract:$0.subtract) } };selected=rect;updateControls();needsDisplay=true }
    private func finalizeShape() { guard points.count>=3,let rect=CaptureSelectionGeometry.bounds(of:points),rect.width>=8,rect.height>=8 else { return };selected=rect;commitContour();confirmed=true;updateControls();needsDisplay=true }
    private func positionControls() {
        let size=controls.fittingSize, width=max(allowsShapes ? 620 : 430,size.width),height=max(100,size.height)
        let rect=selected ?? CGRect(x:bounds.midX-width/2,y:bounds.midY,width:width,height:0)
        let area=displayRects.max { first,second in
            let a=first.intersection(rect),b=second.intersection(rect)
            return (a.isNull ? 0:a.width*a.height)<(b.isNull ? 0:b.width*b.height)
        } ?? bounds
        let y=confirmed ? (rect.maxY+height+12<area.maxY ? rect.maxY+12 : max(area.minY+8,rect.minY-height-12)) : max(area.minY+8,area.maxY-height-30)
        controls.frame=CGRect(x:max(area.minX+8,min(area.maxX-width-8,rect.minX)),y:min(y,area.maxY-height-8),width:width,height:height)
    }
    private func updateControls() {
        fields.forEach { $0.isEnabled=confirmed };actionButtons.forEach { $0.isEnabled=confirmed };finishButton.isEnabled=confirmed;lock.isEnabled=confirmed
        if let selected {
            let values=[selected.minX,selected.minY,selected.width,selected.height]
            for (field,value) in zip(fields,values) where window?.firstResponder !== field.currentEditor() { field.integerValue=Int((value*scale).rounded()) }
        }
        message.stringValue=confirmed ? "拖动边角调整范围 · 双击或回车编辑 · ⌥ 放大镜 · F5 刷新" : shape == .polygon ? "逐点点击，双击或回车闭合 · 右键完成 · Esc 取消" : "拖动框选 · ⌥ 放大镜 · Tab 切换元素/窗口 · \(detectElements && AXIsProcessTrusted() ? "元素检测":"窗口检测")"
        positionControls()
    }
    private func commitContour() {
        guard let selected else { return }
        if operations.selectedSegment==0 && shape != .windows { contours=[] }
        let path=points.count>=3 ? points:CaptureSelectionGeometry.rectangle(selected)
        if operations.selectedSegment != 2 || !contours.isEmpty { contours.append(CaptureSelectionContour(points:path,subtract:operations.selectedSegment==2)) }
        points=[]
        self.selected=CaptureSelectionGeometry.bounds(of:contours.filter { !$0.subtract }.flatMap(\.points))
    }
    @objc private func modeChanged() { shape=Shape(rawValue:modes.selectedSegment) ?? .rectangle;resetSelection();if shape == .windows { operations.selectedSegment=1 } }
    @objc private func operationChanged() { if operations.selectedSegment != 0 { confirmed=false;points=[];selected=nil;updateControls();needsDisplay=true } }
    private func rebuildHistory() {
        history.removeAllItems();history.addItem(withTitle:"历史选区")
        for rect in historyRegions { history.addItem(withTitle:"\(Int(rect.width*scale)) × \(Int(rect.height*scale))  (\(Int(rect.minX*scale)), \(Int(rect.minY*scale)))") }
        history.isEnabled = !historyRegions.isEmpty
    }
    @objc private func restoreHistory() {
        let index=history.indexOfSelectedItem-1;guard historyRegions.indices.contains(index) else { return }
        selected=CaptureSelectionGeometry.constrain(historyRegions[index],in:bounds);points=[];contours=[];operations.selectedSegment=0;shape = .rectangle;modes.selectedSegment=0;commitContour();confirmed=true;updateControls();needsDisplay=true
    }
    @objc private func chooseTool(_ sender:NSButton) { initialTool=[CaptureTool.arrow,.rectangle,.mosaic,.text][sender.tag];finishSelection() }
    @objc private func chooseAction(_ sender:NSButton) { postAction=[CaptureSelectionPostAction.copy,.pin,.save][sender.tag];finishSelection() }
    private func parameter(_ name:String,_ fallback:Double) -> CGFloat {
        let value=UserDefaults.standard.object(forKey:"capture.selection."+name) as? Double ?? fallback
        return CGFloat(value.isFinite ? value:fallback)
    }
    var decorationPadding:Int { CaptureSelectionGeometry.decorationPadding(shadow:shadowButton.state == .on,blur:parameter("shadowBlur",10),offset:parameter("shadowOffset",2)) }
    private var decorationColor:NSColor {
        guard let values=UserDefaults.standard.array(forKey:"capture.selection.borderColor") as? [Double],values.count==4,values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return NSColor.white.withAlphaComponent(0.8) }
        return NSColor(srgbRed:values[0],green:values[1],blue:values[2],alpha:values[3])
    }
    func decorate(_ image:CGImage,scale:CGFloat) throws -> CGImage {
        try CaptureSelectionGeometry.decorate(image,cornerRadius:rounded.state == .on ? parameter("radius",12)*scale:0,shadow:shadowButton.state == .on,border:border.state == .on,shadowBlur:parameter("shadowBlur",10),shadowOpacity:parameter("shadowOpacity",0.6),shadowOffset:parameter("shadowOffset",2),borderWidth:parameter("borderWidth",2),borderColor:decorationColor)
    }
    @objc private func appearanceChanged() {
        if UserDefaults.standard.bool(forKey:"capture.selection.remember") { saveAppearanceFlags() }
        needsDisplay=true
    }
    private func saveAppearanceFlags() {
        for (key,button) in [("rounded",rounded),("shadow",shadowButton),("border",border)] { UserDefaults.standard.set(button.state == .on,forKey:"capture.selection."+key) }
    }
    @objc private func showAppearance(_ sender:NSButton) {
        appearancePopover?.close()
        let popover=NSPopover();popover.behavior = .transient
        let controller=NSViewController(),stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
        appearanceSliders=[:];appearanceValues=[:]
        for (key,title,minimum,maximum,fallback) in [("radius","圆角半径",0.0,120.0,12.0),("shadowBlur","阴影模糊",0.0,80.0,10.0),("shadowOpacity","阴影浓度",0.0,1.0,0.6),("shadowOffset","阴影偏移",0.0,60.0,2.0),("borderWidth","边框宽度",1.0,20.0,2.0)] {
            let row=NSStackView();row.spacing=8
            let label=NSTextField(labelWithString:title);label.widthAnchor.constraint(equalToConstant:70).isActive=true;row.addArrangedSubview(label)
            let slider=NSSlider(value:Double(parameter(key,fallback)),minValue:minimum,maxValue:maximum,target:self,action:#selector(appearanceParameterChanged));slider.widthAnchor.constraint(equalToConstant:170).isActive=true;row.addArrangedSubview(slider)
            let value=NSTextField(labelWithString:key=="shadowOpacity" ? String(format:"%.0f%%",slider.doubleValue*100):String(Int(slider.doubleValue)));value.alignment = .right;value.widthAnchor.constraint(equalToConstant:38).isActive=true;row.addArrangedSubview(value)
            appearanceSliders[key]=slider;appearanceValues[key]=value;stack.addArrangedSubview(row)
        }
        let colorRow=NSStackView();colorRow.spacing=12;colorRow.addArrangedSubview(NSTextField(labelWithString:"边框颜色"))
        borderColorWell.color=decorationColor;borderColorWell.target=self;borderColorWell.action=#selector(appearanceParameterChanged);borderColorWell.widthAnchor.constraint(equalToConstant:50).isActive=true;colorRow.addArrangedSubview(borderColorWell);stack.addArrangedSubview(colorRow)
        rememberAppearance.state=UserDefaults.standard.bool(forKey:"capture.selection.remember") ? .on:.off
        rememberAppearance.target=self;rememberAppearance.action=#selector(appearanceParameterChanged);stack.addArrangedSubview(rememberAppearance)
        let view=NSView(frame:CGRect(x:0,y:0,width:330,height:260));stack.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:12),stack.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-12)])
        controller.view=view;popover.contentViewController=controller;appearancePopover=popover;popover.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY)
    }
    @objc private func appearanceParameterChanged() {
        for (key,slider) in appearanceSliders {
            UserDefaults.standard.set(slider.doubleValue,forKey:"capture.selection."+key)
            appearanceValues[key]?.stringValue=key=="shadowOpacity" ? String(format:"%.0f%%",slider.doubleValue*100):String(Int(slider.doubleValue))
        }
        if let color=borderColorWell.color.usingColorSpace(.sRGB) { UserDefaults.standard.set([color.redComponent,color.greenComponent,color.blueComponent,color.alphaComponent],forKey:"capture.selection.borderColor") }
        UserDefaults.standard.set(rememberAppearance.state == .on,forKey:"capture.selection.remember")
        if rememberAppearance.state == .on { saveAppearanceFlags() }
        needsDisplay=true
    }
    @objc private func resetSelection() { selected=nil;confirmed=false;points=[];contours=[];anchor=nil;ratio=nil;lock.state = .off;updateControls();needsDisplay=true }
    @objc private func cancelSelection() { completed?(nil,[]) }
    @objc private func finishSelection() { guard confirmed,let selected else { return };window?.makeFirstResponder(self);completed?(selected,contours) }
    @objc private func lockChanged() { ratio=lock.state == .on ? selected.map { $0.width/$0.height } : nil }
    @objc private func applyFields() {
        guard confirmed,let old=selected else { return }
        var width=CGFloat(fields[2].doubleValue)/scale,height=CGFloat(fields[3].doubleValue)/scale
        if let ratio { if abs(width-old.width)>0.1 { height=width/ratio } else { width=height*ratio } }
        setRect(CaptureSelectionGeometry.constrain(CGRect(x:CGFloat(fields[0].doubleValue)/scale,y:CGFloat(fields[1].doubleValue)/scale,width:width,height:height),in:bounds))
    }
    func controlTextDidEndEditing(_ obj:Notification) { applyFields() }
    @objc private func refreshImage() {
        guard refreshTask==nil,let refresh else { return };refreshButton.isEnabled=false
        refreshTask=Task { [weak self] in
            do { let image=try await refresh();guard !Task.isCancelled else { return };self?.image=image;self?.needsDisplay=true }
            catch { self?.showError(error.localizedDescription) }
            self?.refreshTask=nil;self?.refreshButton.isEnabled=true
        }
    }
    func cancelRefresh() {
        refreshTask?.cancel();refreshTask=nil;appearancePopover?.close();appearancePopover=nil
        if borderColorWell.isActive { NSColorPanel.shared.orderOut(nil) }
        borderColorWell.deactivate()
    }
    func showError(_ text:String) { message.stringValue=text }
    private func elementRect(at point:CGPoint) -> CGRect? {
        var element:AXUIElement?
        let global=CGPoint(x:screenOrigin.x+point.x,y:screenOrigin.y+point.y)
        guard let target=elementTargets.first(where:{ $0.0.contains(global) }),target.1 != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application=AXUIElementCreateApplication(target.1)
        AXUIElementSetMessagingTimeout(application,0.08)
        guard AXUIElementCopyElementAtPosition(application,Float(screenOrigin.x+point.x),Float(screenOrigin.y+point.y),&element) == .success,let element else { return nil }
        var position:CFTypeRef?,size:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&position) == .success,
              AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&size) == .success,
              let position,let size,CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID() else { return nil }
        var origin=CGPoint.zero,dimensions=CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position,to:AXValue.self),.cgPoint,&origin),AXValueGetValue(unsafeDowncast(size,to:AXValue.self),.cgSize,&dimensions) else { return nil }
        let rect=CGRect(origin:CGPoint(x:origin.x-screenOrigin.x,y:origin.y-screenOrigin.y),size:dimensions).intersection(bounds)
        return rect.width>=8 && rect.height>=8 ? rect : nil
    }
}
