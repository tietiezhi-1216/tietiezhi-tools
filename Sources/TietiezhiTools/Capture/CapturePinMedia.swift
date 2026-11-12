import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct CapturePinPayload: Codable {
    enum Kind: String, Codable { case image, text, richText, color, formula, animation }
    var kind: Kind
    var html: Data?
    var assetFilename: String?
    var ignoreFormatting: Bool?
}
struct CapturePinAdjustments: Codable, Equatable {
    var quarterTurns = 0
    var flipX = false
    var flipY = false
    var grayscale = false
    var inverted = false
    var brightness = 0.0
}

enum CapturePinMedia {
    static func safeAssetFilename(_ filename:String) -> Bool {
        let parts=filename.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==2,let id=UUID(uuidString:String(parts[0])),["gif","apng","webp","png","tiff","tif","heic"].contains(String(parts[1])) else { return false }
        return filename==id.uuidString+"."+parts[1]
    }
    static func color(_ input:String) -> NSColor? {
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let named:[String:NSColor] = ["red":.red,"green":.green,"blue":.blue,"orange":.orange,"yellow":.yellow,"purple":.purple,"pink":.systemPink,"black":.black,"white":.white,"gray":.gray,"transparent":.clear]
        if let result=named[value] { return result }
        if value.hasPrefix("#") {
            var hex=String(value.dropFirst()); if hex.count==3 { hex=hex.map { "\($0)\($0)" }.joined() }
            guard hex.count==6 || hex.count==8, let n=UInt64(hex,radix:16) else { return nil }
            let alpha=hex.count==8 ? CGFloat(n & 255)/255 : 1
            let rgb=hex.count==8 ? n >> 8:n
            return NSColor(srgbRed:CGFloat((rgb >> 16)&255)/255,green:CGFloat((rgb >> 8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:alpha)
        }
        let components=value.replacingOccurrences(of:"rgb(",with:"").replacingOccurrences(of:")",with:"").split(separator:",").map { Double($0.trimmingCharacters(in:.whitespaces)) }
        if components.count==3,components.allSatisfy({ $0 != nil && (0...255).contains($0!) }) {
            return NSColor(srgbRed:components[0]!/255,green:components[1]!/255,blue:components[2]!/255,alpha:1)
        }
        return nil
    }
    static func formula(_ input:String) -> String? {
        let s=input.trimmingCharacters(in:.whitespacesAndNewlines)
        for pair in [("$$","$$"),("\\[","\\]"),("\\(","\\)"),("$","$")] where s.hasPrefix(pair.0) && s.hasSuffix(pair.1) && s.count>pair.0.count+pair.1.count {
            return String(s.dropFirst(pair.0.count).dropLast(pair.1.count))
        }
        if s.hasPrefix("\\") && ["\\frac","\\sum","\\int","\\sqrt","\\begin","\\alpha"].contains(where:s.contains) { return s }
        return nil
    }
    // Imported HTML is reduced to local formatting. No images, URLs, scripts or external styles survive.
    static func sanitizedHTML(_ data:Data) -> Data? {
        guard data.count<=1_000_000, let source=String(data:data,encoding:.utf8) else { return nil }
        let expression=try! NSRegularExpression(pattern:"<[^>]*>",options:[])
        let allowed=Set(["p","div","span","b","strong","i","em","u","s","br","pre","code","ul","ol","li","table","tr","td","th","h1","h2","h3","blockquote"])
        let ns=source as NSString
        var result=source
        for match in expression.matches(in:source,range:NSRange(location:0,length:ns.length)).reversed() {
            let tag=ns.substring(with:match.range)
            let name=tag.dropFirst(tag.hasPrefix("</") ? 2:1).prefix { $0.isLetter || $0.isNumber }.lowercased()
            var replacement=""
            if allowed.contains(name) {
                replacement="<\(tag.hasPrefix("</") ? "/":"")\(name)>"
                if !tag.hasPrefix("</"), let styleRange=tag.range(of:#"style\s*=\s*["']([^"']*)["']"#,options:.regularExpression) {
                    let style=String(tag[styleRange]).replacingOccurrences(of:#"^style\s*=\s*["']|["']$"#,with:"",options:.regularExpression)
                    let rules=style.split(separator:";").filter { rule in
                        let property=rule.split(separator:":").first?.trimmingCharacters(in:.whitespaces).lowercased() ?? ""
                        return ["color","background-color","font-size","font-weight","font-style","text-decoration","text-align"].contains(property) && !rule.contains("(") && !rule.contains("\\") && !rule.contains("<") && !rule.contains(">")
                    }.joined(separator:";")
                    replacement="<\(name) style=\"\(rules.replacingOccurrences(of:"\"",with:""))\">"
                }
            }
            if let range=Range(match.range,in:result) { result.replaceSubrange(range,with:replacement) }
        }
        return ("<meta charset='utf-8'>"+result).data(using:.utf8)
    }
    @MainActor static func attributed(_ text:String, html:Data?, ignore:Bool=false) -> NSAttributedString {
        if !ignore,let html,let value=try? NSAttributedString(data:html,options:[.documentType:NSAttributedString.DocumentType.html,.characterEncoding:String.Encoding.utf8.rawValue],documentAttributes:nil) { return value }
        return NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.textColor])
    }
    @MainActor static func card(_ text:String,html:Data?=nil,color:NSColor?=nil) throws -> CGImage {
        let value=attributed(text,html:html)
        let height=color == nil ? min(4000,max(100,value.boundingRect(with:CGSize(width:440,height:100000),options:[.usesLineFragmentOrigin,.usesFontLeading]).height+40)):220
        let image=NSImage(size:CGSize(width:480,height:height));image.lockFocus()
        NSColor.textBackgroundColor.setFill();CGRect(x:0,y:0,width:480,height:height).fill()
        if let color { color.setFill();NSBezierPath(roundedRect:CGRect(x:20,y:70,width:440,height:130),xRadius:10,yRadius:10).fill() }
        value.draw(in:CGRect(x:20,y:20,width:440,height:color == nil ? height-40:35))
        image.unlockFocus()
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw PluginError.invalid("无法生成贴图。") };return cg
    }
    static func render(_ source:CGImage,adjustments:CapturePinAdjustments) -> CGImage? {
        var ci=CIImage(cgImage:source)
        let orientation:Int32
        switch (adjustments.quarterTurns % 4 + 4) % 4 { case 1:orientation=6;case 2:orientation=3;case 3:orientation=8;default:orientation=1 }
        ci=ci.oriented(forExifOrientation:orientation)
        if adjustments.flipX { ci=ci.oriented(forExifOrientation:2) }
        if adjustments.flipY { ci=ci.oriented(forExifOrientation:4) }
        ci=ci.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:adjustments.grayscale ? 0:1,kCIInputBrightnessKey:adjustments.brightness])
        if adjustments.inverted { ci=ci.applyingFilter("CIColorInvert") }
        return CIContext(options:[.cacheIntermediates:false]).createCGImage(ci,from:ci.extent)
    }
}

@MainActor final class CapturePinAnimation {
    let source:CGImageSource
    let count:Int
    var index=0
    var paused=false
    var speed=1.0
    var changed:((CGImage)->Void)?
    private var task:Task<Void,Never>?
    init?(url:URL) {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceGetCount(source)>1 else { return nil }
        self.source=source;count=CGImageSourceGetCount(source)
    }
    func start() {
        stop()
        task=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay=self.delay/self.speed
                do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                if !self.paused { self.index=(self.index+1)%self.count;self.emit() }
            }
        }
    }
    func stop() { task?.cancel();task=nil }
    func toggle() { paused.toggle();emit() }
    func step(_ amount:Int) { paused=true;index=(index+amount+count)%count;emit() }
    func changeSpeed(_ factor:Double) { speed=min(8,max(0.1,speed*factor)) }
    private var delay:Double {
        let properties=CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [String:Any] ?? [:]
        for key in [kCGImagePropertyGIFDictionary as String,kCGImagePropertyPNGDictionary as String,"{WebP}"] {
            if let dict=properties[key] as? [String:Any],let number=(dict["UnclampedDelayTime"] ?? dict["DelayTime"]) as? Double { return max(0.02,number) }
        }
        return 0.1
    }
    private func emit() { if let image=CGImageSourceCreateImageAtIndex(source,index,[kCGImageSourceShouldCache:false] as CFDictionary) { changed?(image) } }
}

@MainActor extension CapturePinManager {
    @discardableResult func createText(_ text:String,html:Data?=nil) throws -> UUID {
        guard text.count<=100000 else { throw PluginError.invalid("文字过长，请分段贴图。") }
        let color=CapturePinMedia.color(text),formula=CapturePinMedia.formula(text)
        let clean=html.flatMap(CapturePinMedia.sanitizedHTML)
        let kind:CapturePinPayload.Kind = color != nil ? .color:formula != nil ? .formula:clean != nil ? .richText:.text
        let image=try CapturePinMedia.card(formula ?? text,html:kind == .richText ? clean:nil,color:color)
        return try create(image,text:formula ?? text,payload:CapturePinPayload(kind:kind,html:clean,ignoreFormatting:!(UserDefaults.standard.object(forKey:"capture.pin.keepHTML") as? Bool ?? true)))
    }
    @discardableResult func createFile(_ file:URL) throws -> UUID {
        let scope=file.startAccessingSecurityScopedResource();defer { if scope { file.stopAccessingSecurityScopedResource() } }
        guard let source=CGImageSourceCreateWithURL(file as CFURL,nil) else {
            return try create(ScreenshotController.textCard(file.lastPathComponent,file:file),text:nil,sourceFile:file)
        }
        guard let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width<=CaptureImage.maximumPixels/max(1,image.height) else { throw PluginError.invalid("图片尺寸过大或格式无效。") }
        if CGImageSourceGetCount(source)>1 {
            let size=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size<=100*1024*1024 else { throw PluginError.invalid("动图文件超过 100 MB。") }
            let name=UUID().uuidString+"."+file.pathExtension.lowercased()
            let destination=directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at:file,to:destination)
            do { return try create(image,sourceFile:file,payload:CapturePinPayload(kind:.animation,assetFilename:name)) }
            catch { try? FileManager.default.removeItem(at:destination);throw error }
        }
        return try create(image,sourceFile:file)
    }
    func assetURL(_ id:UUID) -> URL? {
        guard let name=record(id)?.payload?.assetFilename,CapturePinMedia.safeAssetFilename(name) else { return nil }
        return directory.appendingPathComponent(name)
    }
    func startAnimation(_ id:UUID) {
        guard let url=assetURL(id),let animation=CapturePinAnimation(url:url) else { return }
        animations[id]=animation
        animation.changed={ [weak self] frame in
            guard let self else { return };self.images[id]=frame;self.rebuildImage(id);self.objectWillChange.send()
        };animation.start()
    }
    func rebuildImage(_ id:UUID) {
        guard let original=images[id] else { return }
        if let adjustments=record(id)?.adjustments { renderedImages[id]=CapturePinMedia.render(original,adjustments:adjustments) }
        else { renderedImages[id]=nil }
    }
    func adjust(_ id:UUID,_ change:(inout CapturePinAdjustments)->Void) {
        for key in selection(id) {
            guard var item=record(key) else { continue }
            var adjustment=item.adjustments ?? CapturePinAdjustments();change(&adjustment);item.adjustments=adjustment;item.viewport=nil
            setRecord(item);rebuildImage(key);recognized[key]=nil;selectedTexts[key]=nil;recognitionTasks[key]?.cancel();recognitionTasks[key]=nil
            sizeForViewport(key);recognizeText(key)
        }
    }
    func visibleImage(_ id:UUID) -> CGImage? {
        guard let image=image(id) else { return nil }
        guard let rect=record(id)?.viewport else { return image }
        return image.cropping(to:CGRect(x:rect.minX*CGFloat(image.width),y:rect.minY*CGFloat(image.height),width:rect.width*CGFloat(image.width),height:rect.height*CGFloat(image.height)))
    }
    func toggleViewport(_ id:UUID) {
        guard var item=record(id) else { return };item.viewport=item.viewport == nil ? CGRect(x:0.25,y:0.25,width:0.5,height:0.5):nil
        setRecord(item);sizeForViewport(id)
    }
    func setViewport(_ id:UUID,_ rect:CGRect) {
        let bounded=rect.standardized.intersection(CGRect(x:0,y:0,width:1,height:1))
        guard bounded.width>0.01,bounded.height>0.01,var item=record(id),!item.locked else { return }
        item.viewport=bounded;setRecord(item);sizeForViewport(id)
    }
    func copyOriginal(_ id:UUID) {
        guard let image=images[id] else { return };NSPasteboard.general.clearContents();NSPasteboard.general.setData(try? CaptureImage.png(image),forType:.png)
    }
    func copyText(_ id:UUID) {
        guard let text=record(id)?.text ?? recognized[id]?.text else { return };NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
    }
    func selectAllText(_ id:UUID) { selectedTexts[id]=record(id)?.text ?? recognized[id]?.text;objectWillChange.send() }
    func toggleRichText(_ id:UUID) {
        guard var item=record(id) else { return };let ignored = !(item.payload?.ignoreFormatting ?? false);item.payload?.ignoreFormatting = ignored;setRecord(item);refreshContent(id)
    }
    func recognizeText(_ id:UUID) {
        guard record(id)?.payload?.kind != .animation,record(id)?.text == nil,recognized[id]==nil,recognitionTasks[id]==nil,let image=image(id) else { return }
        recognitionTasks[id]=Task { [weak self] in
            let result=try? await CaptureRecognition.recognize(image)
            guard !Task.isCancelled,let self else { return };self.recognized[id]=result;self.recognitionTasks[id]=nil;self.objectWillChange.send()
        }
    }
    func exportSelection(_ id:UUID) throws -> [URL] {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TietiezhiTools-PinExport").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return try selection(id).sorted { $0.uuidString < $1.uuidString }.compactMap { key in
            if let asset=assetURL(key) { return asset }
            guard let image=visibleImage(key) else { return nil }
            let file=folder.appendingPathComponent(key.uuidString+".png")
            try CaptureImage.png(image).write(to:file,options:.atomic);return file
        }
    }
    func copySelection(_ id:UUID) {
        do {
            let files=try exportSelection(id)
            NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects(files.map { $0 as NSURL })
        } catch { reportError?(error.localizedDescription) }
    }
    func saveAnimation(_ id:UUID) {
        guard let file=assetURL(id) else { return }
        let panel=NSSavePanel();panel.nameFieldStringValue=record(id)?.sourceFile?.lastPathComponent ?? file.lastPathComponent
        panel.begin { [weak self] response in
            guard response == .OK,let url=panel.url else { return }
            do { try Data(contentsOf:file).write(to:url,options:.atomic) } catch { self?.reportError?(error.localizedDescription) }
        }
    }
}
