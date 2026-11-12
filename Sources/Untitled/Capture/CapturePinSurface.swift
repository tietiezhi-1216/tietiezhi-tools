import AppKit
import SwiftUI
import WebKit

struct CapturePinSurface: NSViewRepresentable {
    let image:CGImage
    let manager:CapturePinManager
    let id:UUID
    func makeNSView(context:Context) -> Surface { Surface() }
    func updateNSView(_ view:Surface,context:Context) {
        view.manager=manager;view.id=id;view.image=image;view.configure();view.needsDisplay=true
    }
    final class Surface:NSView,NSDraggingSource,NSTextViewDelegate,WKNavigationDelegate {
        weak var manager:CapturePinManager?
        var id:UUID?
        var image:CGImage?
        private var anchor:CGPoint?
        private var lastScreen:CGPoint?
        private var selecting=false
        private var dragText=false
        private var dragImage=false
        private var rightDragOrigin:CGPoint?
        private var pendingViewport:CGRect?
        private var selectedRanges:[Int:Range<Int>]=[:]
        private var textScroll:NSScrollView?
        private var textView:PinTextView?
        private var formulaView:WKWebView?
        private var formulaSnapshotTask:Task<Void,Never>?
        private var formulaTimeoutTask:Task<Void,Never>?
        private var contentKey=""
        override var isFlipped:Bool { true }
        override var acceptsFirstResponder:Bool { true }
        override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
        private var viewport:CGRect { guard let id else { return CGRect(x:0,y:0,width:1,height:1) };return manager?.record(id)?.viewport ?? CGRect(x:0,y:0,width:1,height:1) }
        private var lines:[RecognizedLine] { guard let id else { return [] };return manager?.recognized[id]?.lines ?? [] }
        func configure() {
            guard let id,let item=manager?.record(id) else { return }
            let key="\(id)-\(item.payload?.kind.rawValue ?? "image")-\(item.payload?.ignoreFormatting ?? false)-\(item.text ?? "")"
            if key != contentKey {
                contentKey=key;textScroll?.removeFromSuperview();textScroll=nil;textView=nil;cancelFormula()
                if let text=item.text,[.text,.richText].contains(item.payload?.kind ?? .image) {
                    let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=true;scroll.backgroundColor = .textBackgroundColor
                    let view=PinTextView(frame:CGRect(x:0,y:0,width:max(100,bounds.width-12),height:bounds.height))
                    view.surface=self;view.isEditable=false;view.isSelectable=UserDefaults.standard.object(forKey:"capture.pin.selectText") as? Bool ?? true;view.isRichText=true;view.drawsBackground=true;view.backgroundColor = .textBackgroundColor
                    view.textContainerInset=CGSize(width:10,height:10);view.autoresizingMask=[.width];view.isVerticallyResizable=true;view.isHorizontallyResizable=false
                    view.textContainer?.widthTracksTextView=true
                    view.textStorage?.setAttributedString(CapturePinMedia.attributed(text,html:item.payload?.html,ignore:item.payload?.ignoreFormatting ?? false));view.delegate=self
                    scroll.documentView=view;addSubview(scroll);textScroll=scroll;textView=view
                } else if item.payload?.kind == .formula,let text=item.text { makeFormula(text) }
            }
            if manager?.selectedTexts[id]==nil { selectedRanges=[:] }
            if textView==nil && manager?.selectedTexts[id] == manager?.recognized[id]?.text && !lines.isEmpty {
                selectedRanges=Dictionary(uniqueKeysWithValues:lines.enumerated().map { ($0.offset,0..<$0.element.text.count) })
            }
            needsLayout=true
            setAccessibilityLabel("贴图；拖动移动，⌃点击多选，⌘拖动导出，右键拖动选择缩略范围")
        }
        override func layout() {
            super.layout();textScroll?.frame=CGRect(x:0,y:22,width:bounds.width,height:max(0,bounds.height-22));formulaView?.frame=CGRect(x:0,y:22,width:bounds.width,height:max(0,bounds.height-22))
        }
        override func draw(_ dirtyRect:NSRect) {
            guard let image else { return }
            if textScroll != nil || formulaView?.isHidden == false {
                NSColor.windowBackgroundColor.setFill();bounds.fill()
                ("拖动此处移动贴图" as NSString).draw(at:CGPoint(x:8,y:3),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.secondaryLabelColor]);return
            }
            let source=viewport
            let crop=image.cropping(to:CGRect(x:source.minX*CGFloat(image.width),y:source.minY*CGFloat(image.height),width:source.width*CGFloat(image.width),height:source.height*CGFloat(image.height))) ?? image
            NSImage(cgImage:crop,size:bounds.size).draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).setFill()
            for (index,range) in selectedRanges where lines.indices.contains(index) {
                let line=lines[index]
                normalizedToView(CapturePinTextGeometry.bounds(line,characters:range)).fill()
            }
            if let rect=pendingViewport { NSColor.controlAccentColor.setStroke();let path=NSBezierPath(rect:rect);path.lineWidth=2;path.stroke() }
        }
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea);addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect],owner:self));super.updateTrackingAreas()
        }
        override func mouseMoved(with event:NSEvent) {
            if lineAt(convert(event.locationInWindow,from:nil)) != nil && !event.modifierFlags.contains(.option) { NSCursor.iBeam.set() } else { NSCursor.openHand.set() }
        }
        override func mouseDown(with event:NSEvent) {
            guard let id,let manager else { return }
            window?.makeKey();window?.makeFirstResponder(self)
            let point=convert(event.locationInWindow,from:nil)
            let selectingWord=event.clickCount==2 && lineAt(point) != nil && !event.modifierFlags.contains(.option) && (UserDefaults.standard.object(forKey:"capture.pin.selectText") as? Bool ?? true)
            if !selectingWord,let action=CapturePinMouseSettings.shared.action(event,phase:"click"),handle(action,event:event) { return }
            manager.select(id,extending:false)
            anchor=point;lastScreen=NSEvent.mouseLocation
            let dragAction=CapturePinMouseSettings.shared.action(event,phase:"drag")
            dragImage=dragAction == .export;dragText=false
            if dragImage { return }
            if dragAction != .moveIgnoringText,(UserDefaults.standard.object(forKey:"capture.pin.selectText") as? Bool ?? true),let index=lineAt(point) {
                if let range=selectedRanges[index],range.contains(character(in:lines[index],at:point.x)) { dragText=true;return }
                selecting=true;updateSelection(point,point)
                if event.clickCount==2 { selectedRanges=[index:0..<lines[index].text.count];syncSelection() }
            } else {
                selecting=false;selectedRanges=[:];manager.selectedTexts[id]=nil
                if dragAction != .move && dragAction != .moveIgnoringText { anchor=nil }
            }
        }
        override func mouseDragged(with event:NSEvent) {
            guard let id,let manager,let anchor else { return }
            let point=convert(event.locationInWindow,from:nil)
            if dragImage || dragText {
                guard hypot(point.x-anchor.x,point.y-anchor.y)>4 else { return }
                if dragImage,manager.selection(id).count>1 {
                    do {
                        let items=try manager.exportSelection(id).map { file -> NSDraggingItem in
                            let dragging=NSDraggingItem(pasteboardWriter:file as NSURL)
                            dragging.setDraggingFrame(CGRect(x:point.x,y:point.y,width:64,height:64),contents:NSWorkspace.shared.icon(forFile:file.path));return dragging
                        }
                        beginDraggingSession(with:items,event:event,source:self);self.anchor=nil;return
                    } catch { manager.reportError?(error.localizedDescription);return }
                }
                let item=NSPasteboardItem()
                if dragText,let text=manager.selectedTexts[id] { item.setString(text,forType:.string) }
                else {
                    if let image=manager.visibleImage(id),let data=try? CaptureImage.png(image) { item.setData(data,forType:.png) }
                    if let file=manager.assetURL(id) { item.setString(file.absoluteString,forType:.fileURL) }
                    if let text=manager.record(id)?.text { item.setString(text,forType:.string) }
                }
                let dragging=NSDraggingItem(pasteboardWriter:item)
                dragging.setDraggingFrame(bounds,contents:image.map { NSImage(cgImage:$0,size:bounds.size) })
                beginDraggingSession(with:[dragging],event:event,source:self);self.anchor=nil;return
            }
            if selecting { updateSelection(anchor,point);return }
            if event.modifierFlags.contains(.shift),manager.record(id)?.viewport != nil {
                let v=viewport;let dx=(point.x-anchor.x)/max(1,bounds.width)*v.width,dy=(point.y-anchor.y)/max(1,bounds.height)*v.height
                manager.setViewport(id,CGRect(x:min(1-v.width,max(0,v.minX-dx)),y:min(1-v.height,max(0,v.minY-dy)),width:v.width,height:v.height));self.anchor=point
            } else if let lastScreen {
                let screen=NSEvent.mouseLocation;manager.dragSelection(id,delta:CGSize(width:screen.x-lastScreen.x,height:screen.y-lastScreen.y));self.lastScreen=screen
            }
        }
        override func mouseUp(with event:NSEvent) { anchor=nil;lastScreen=nil;selecting=false;dragImage=false;dragText=false }
        override func rightMouseDown(with event:NSEvent) {
            if let action=CapturePinMouseSettings.shared.action(event,phase:"click"),action != .menu,handle(action,event:event) { return }
            if CapturePinMouseSettings.shared.action(event,phase:"drag") != nil { mouseDown(with:event);return }
            rightDragOrigin=convert(event.locationInWindow,from:nil)
        }
        override func rightMouseDragged(with event:NSEvent) {
            guard let a=rightDragOrigin else { mouseDragged(with:event);return };let b=convert(event.locationInWindow,from:nil)
            pendingViewport=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y));needsDisplay=true
        }
        override func rightMouseUp(with event:NSEvent) {
            if let id,let rect=pendingViewport,rect.width>5,rect.height>5 {
                let v=viewport;manager?.setViewport(id,CGRect(x:v.minX+rect.minX/bounds.width*v.width,y:v.minY+rect.minY/bounds.height*v.height,width:rect.width/bounds.width*v.width,height:rect.height/bounds.height*v.height))
            } else if rightDragOrigin != nil { super.rightMouseDown(with:event) }
            rightDragOrigin=nil;pendingViewport=nil;needsDisplay=true;mouseUp(with:event)
        }
        override func keyDown(with event:NSEvent) {
            guard let id,let manager else { return }
            if event.keyCode==0,event.modifierFlags.contains(.command) { manager.selectAllText(id);configure();return }
            if event.charactersIgnoringModifiers?.lowercased()=="r",event.modifierFlags.intersection([.command,.option,.control]).isEmpty {
                if let animation=manager.animations[id] { animation.speed=1 } else { manager.toggleViewport(id) };return
            }
            super.keyDown(with:event)
        }
        override func scrollWheel(with event:NSEvent) {
            guard let id else { return }
            let action=CapturePinMouseSettings.shared.action(event,phase:"wheel")
            if action == .zoom || action == .opacity { manager?.scroll(id,delta:event.scrollingDeltaY,opacity:action == .opacity) }
            else if event.modifierFlags == .option { manager?.scroll(id,delta:event.scrollingDeltaY*0.1,opacity:false) }
        }
        override func magnify(with event:NSEvent) { if let id { manager?.scroll(id,delta:event.magnification*50,opacity:false) } }
        override func otherMouseDown(with event:NSEvent) { mouseDown(with:event) }
        override func otherMouseDragged(with event:NSEvent) { mouseDragged(with:event) }
        override func otherMouseUp(with event:NSEvent) { mouseUp(with:event) }
        private func handle(_ action:CapturePinMouseAction,event:NSEvent) -> Bool {
            guard let id,let manager else { return false }
            switch action {
            case .close:manager.closeSelection(id)
            case .copyClose:manager.copy(id);manager.closeSelection(id)
            case .reset:manager.resetSize(id)
            case .thumbnail:manager.toggleViewport(id)
            case .copy:manager.copy(id)
            case .text:manager.copyText(id)
            case .select:manager.select(id,extending:true)
            case .menu:super.rightMouseDown(with:event)
            default:return false
            };return true
        }
        func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .copy }
        func textViewDidChangeSelection(_ notification:Notification) {
            guard let id,let textView else { return };let range=textView.selectedRange()
            manager?.selectedTexts[id]=range.length>0 ? (textView.string as NSString).substring(with:range):nil
        }
        private func lineRect(_ line:RecognizedLine) -> CGRect {
            normalizedToView(line.rect)
        }
        private func normalizedToView(_ r:CGRect) -> CGRect {
            let v=viewport
            return CGRect(x:(r.minX-v.minX)/v.width*bounds.width,y:(1-r.maxY-v.minY)/v.height*bounds.height,width:r.width/v.width*bounds.width,height:r.height/v.height*bounds.height)
        }
        private func lineAt(_ point:CGPoint) -> Int? { lines.indices.first { lineRect(lines[$0]).insetBy(dx:-2,dy:-2).contains(point) } }
        private func character(in line:RecognizedLine,at x:CGFloat) -> Int {
            let normalized=viewport.minX+x/max(1,bounds.width)*viewport.width
            return CapturePinTextGeometry.characterOffset(line,normalizedX:normalized)
        }
        private func updateSelection(_ start:CGPoint,_ end:CGPoint) {
            selectedRanges=[:]
            let ordered=lines.indices.sorted { lineRect(lines[$0]).midY < lineRect(lines[$1]).midY }
            guard let first=lineAt(start),let a=ordered.firstIndex(of:first) else { return }
            let last=lineAt(end) ?? ordered.min(by: { abs(lineRect(lines[$0]).midY-end.y) < abs(lineRect(lines[$1]).midY-end.y) }) ?? first
            guard let b=ordered.firstIndex(of:last) else { return }
            let lower=min(a,b),upper=max(a,b)
            for position in lower...upper {
                let index=ordered[position],count=lines[index].text.count
                if a==b {
                    let x=character(in:lines[index],at:start.x),y=character(in:lines[index],at:end.x)
                    selectedRanges[index]=min(x,y)..<max(x,y)
                } else {
                    let forward=a<b
                    let lo=position==lower ? character(in:lines[index],at:forward ? start.x:end.x):0
                    let hi=position==upper ? character(in:lines[index],at:forward ? end.x:start.x):count
                    selectedRanges[index]=min(lo,hi)..<max(lo,hi)
                }
            }
            syncSelection()
        }
        private func syncSelection() {
            guard let id else { return }
            manager?.selectedTexts[id]=selectedRanges.keys.sorted { lineRect(lines[$0]).midY < lineRect(lines[$1]).midY }.compactMap { index in
                guard let range=selectedRanges[index],!range.isEmpty else { return nil };return String(Array(lines[index].text)[range])
            }.joined(separator:"\n");needsDisplay=true
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window==nil { cancelFormula() }
            else if formulaView==nil,let id,let item=manager?.record(id),item.payload?.kind == .formula,let text=item.text { makeFormula(text) }
        }
        private func cancelFormula() {
            formulaSnapshotTask?.cancel();formulaSnapshotTask=nil
            formulaTimeoutTask?.cancel();formulaTimeoutTask=nil
            let previous=formulaView;formulaView=nil
            previous?.navigationDelegate=nil;previous?.stopLoading();previous?.removeFromSuperview()
        }
        private func formulaFailed(_ web:WKWebView,_ message:String?) {
            guard formulaView === web else { return }
            cancelFormula();needsDisplay=true
            // The existing source card / last successful PNG is kept throughout loading and failure.
            if let message,let id,manager?.record(id)?.isOpen==true { manager?.reportError?(message) }
        }
        private func makeFormula(_ formula:String) {
            guard let resource=CapturePinFormula.resources else { return }
            let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
            let web=WKWebView(frame:CGRect(x:0,y:22,width:max(1,bounds.width),height:max(1,bounds.height-22)),configuration:configuration)
            web.isHidden=true;web.navigationDelegate=self;addSubview(web);formulaView=web
            web.loadHTMLString(CapturePinFormula.html(formula:formula,resources:resource),baseURL:nil)
            formulaTimeoutTask=Task { [weak self,weak web] in
                do { try await Task.sleep(for:.seconds(15)) } catch { return }
                guard let self,let web else { return }
                self.formulaFailed(web,"公式渲染超时，已保留公式源码贴图。")
            }
        }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
            guard formulaView === webView else { return }
            formulaSnapshotTask?.cancel()
            formulaSnapshotTask=Task { [weak self,weak webView] in
                guard let self,let web=webView,let id=self.id,let manager=self.manager else { return }
                do {
                    _ = try await web.callAsyncJavaScript("""
                    await document.fonts.ready;
                    const math=document.querySelector('#math .katex');
                    if(!math || !math.textContent.trim()) throw new Error('Formula did not render');
                    const bounds=math.getBoundingClientRect();
                    if(bounds.width<=0 || bounds.height<=0) throw new Error('Formula has no visible content');
                    return true;
                    """,arguments:[:],in:nil,contentWorld:.page)
                    try Task.checkCancellation()
                    guard self.formulaView === web,manager.record(id)?.isOpen==true,self.window != nil else { return }
                    self.layoutSubtreeIfNeeded()
                    guard web.bounds.width>1,web.bounds.height>1 else { throw PluginError.invalid("公式贴图尺寸无效。") }
                    web.isHidden=false;self.needsDisplay=true
                    let config=WKSnapshotConfiguration();config.afterScreenUpdates=true
                    let snapshot=try await web.takeSnapshot(configuration:config)
                    try Task.checkCancellation()
                    guard self.formulaView === web,let item=manager.record(id),item.isOpen,item.payload?.kind == .formula,
                          let image=snapshot.cgImage(forProposedRect:nil,context:nil,hints:nil),image.width>1,image.height>1 else { return }
                    let data=try CaptureImage.png(image)
                    try data.write(to:manager.url(item),options:.atomic)
                    manager.images[id]=image;manager.rebuildImage(id);manager.objectWillChange.send()
                    self.formulaTimeoutTask?.cancel();self.formulaTimeoutTask=nil;self.formulaSnapshotTask=nil
                } catch is CancellationError {
                    self.formulaFailed(web,nil)
                } catch {
                    self.formulaFailed(web,"公式渲染失败，已保留公式源码贴图："+error.localizedDescription)
                }
            }
        }
        func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {
            formulaFailed(webView,(error as NSError).code == NSURLErrorCancelled ? nil:"公式页面未能加载，已保留原贴图。")
        }
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
            formulaFailed(webView,(error as NSError).code == NSURLErrorCancelled ? nil:"公式页面未能加载，已保留原贴图。")
        }
        func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {
            formulaFailed(webView,"公式渲染进程已结束，已保留原贴图。")
        }

    }
    final class PinTextView:NSTextView {
        weak var surface:Surface?
        override func mouseDown(with event:NSEvent) {
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) { surface?.mouseDown(with:event) } else { super.mouseDown(with:event) }
        }
        override func mouseDragged(with event:NSEvent) {
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) { surface?.mouseDragged(with:event) } else { super.mouseDragged(with:event) }
        }
        override func mouseUp(with event:NSEvent) { surface?.mouseUp(with:event);super.mouseUp(with:event) }
    }
}

@MainActor enum CapturePinFormula {
    static var resources:URL? {
        let candidates=[Bundle.main.resourceURL?.appendingPathComponent("KaTeX"),URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/KaTeX")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath:$0.appendingPathComponent("katex.min.js").path) }
    }
    static func html(formula:String,resources:URL) -> String {
        let script=(try? String(contentsOf:resources.appendingPathComponent("katex.min.js"),encoding:.utf8)) ?? ""
        var css=(try? String(contentsOf:resources.appendingPathComponent("katex.min.css"),encoding:.utf8)) ?? ""
        let pattern=try! NSRegularExpression(pattern:#"url\((fonts/[^)]+)\)"#)
        for match in pattern.matches(in:css,range:NSRange(css.startIndex...,in:css)).reversed() {
            guard let range=Range(match.range,in:css),let fileRange=Range(match.range(at:1),in:css) else { continue }
            let file=String(css[fileRange]);if let data=try? Data(contentsOf:resources.appendingPathComponent(file)) {
                let type=file.hasSuffix("woff2") ? "font/woff2":file.hasSuffix("woff") ? "font/woff":"font/ttf"
                css.replaceSubrange(range,with:"url(data:\(type);base64,\(data.base64EncodedString()))")
            }
        }
        let encoded=Data(formula.utf8).base64EncodedString()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none';script-src 'unsafe-inline';style-src 'unsafe-inline';font-src data:;img-src data:"><style>\(css) html,body{margin:0;background:white;color:#202020}body{padding:20px;font-size:24px;overflow:auto}#math{display:inline-block}</style></head><body><div id="math"></div><script>\(script)</script><script>const source=new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0)));katex.render(source,document.getElementById('math'),{throwOnError:false,displayMode:true,trust:false,maxExpand:1000,maxSize:30});</script></body></html>
        """
    }
}

// Work in extended grapheme offsets for UI selection; Vision fragments carry UTF-16 ranges.
enum CapturePinTextGeometry {
    static func bounds(_ line:RecognizedLine,characters:Range<Int>) -> CGRect {
        guard !characters.isEmpty else { return .zero }
        let lower=line.text.index(line.text.startIndex,offsetBy:min(line.text.count,max(0,characters.lowerBound)))
        let upper=line.text.index(line.text.startIndex,offsetBy:min(line.text.count,max(0,characters.upperBound)))
        if !line.fragments.isEmpty { return line.bounds(for:NSRange(lower..<upper,in:line.text)) }
        let count=CGFloat(max(1,line.text.count))
        return CGRect(x:line.rect.minX+line.rect.width*CGFloat(characters.lowerBound)/count,y:line.rect.minY,width:line.rect.width*CGFloat(characters.count)/count,height:line.rect.height)
    }
    static func characterOffset(_ line:RecognizedLine,normalizedX:CGFloat) -> Int {
        guard let fragment=line.fragments.min(by:{ abs($0.rect.midX-normalizedX) < abs($1.rect.midX-normalizedX) }) else {
            return min(line.text.count,max(0,Int(((normalizedX-line.rect.minX)/max(0.000001,line.rect.width)*CGFloat(line.text.count)).rounded())))
        }
        let offset=normalizedX < fragment.rect.midX ? fragment.range.location:NSMaxRange(fragment.range)
        let index=String.Index(utf16Offset:min(line.text.utf16.count,max(0,offset)),in:line.text)
        return line.text.distance(from:line.text.startIndex,to:index)
    }
}
