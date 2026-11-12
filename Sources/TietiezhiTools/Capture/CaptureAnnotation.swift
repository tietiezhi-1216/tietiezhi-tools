import AppKit

enum CaptureSelectionAction { case duplicate, delete, front, back, straighten }

protocol CaptureStyleOption: RawRepresentable, CaseIterable, Identifiable where RawValue == String {
    var title: String { get }
}
extension CaptureStyleOption { var id: String { rawValue } }
enum CaptureLinePattern: String, Codable, CaptureStyleOption {
    case solid, dashed, dotted, dashDot
    var title: String { switch self { case .solid: "实线"; case .dashed: "虚线"; case .dotted: "点线"; case .dashDot: "点划线" } }
    func lengths(_ width: CGFloat) -> [CGFloat] {
        switch self { case .solid: []; case .dashed: [width * 4, width * 3]; case .dotted: [0, width * 2.5]; case .dashDot: [width * 4, width * 2, 0, width * 2] }
    }
}
enum CaptureFill: String, Codable, CaptureStyleOption {
    case outline, translucent, solid
    var title: String { switch self { case .outline: "轮廓"; case .translucent: "半透明填充"; case .solid: "实心填充" } }
}
enum CaptureArrowStyle: String, Codable, CaptureStyleOption {
    case open, filled, tapered, taperedOutline, double, dimension
    var title: String { switch self { case .open: "线条箭头"; case .filled: "实心箭头"; case .tapered: "渐宽实心"; case .taperedOutline: "渐宽轮廓"; case .double: "双向箭头"; case .dimension: "尺寸标注" } }
}
enum CaptureNumberStyle: String, Codable, CaptureStyleOption {
    case circle, outlineCircle, square, outlineSquare, plain
    var title: String { switch self { case .circle: "实心圆"; case .outlineCircle: "空心圆"; case .square: "圆角方形"; case .outlineSquare: "空心方形"; case .plain: "仅数字" } }
}
enum CaptureNumberFormat: String, Codable, CaptureStyleOption {
    case decimal, padded, upperAlpha, lowerAlpha, roman
    var title: String { switch self { case .decimal: "1, 2, 3"; case .padded: "01, 02, 03"; case .upperAlpha: "A, B, C"; case .lowerAlpha: "a, b, c"; case .roman: "I, II, III" } }
    func label(_ number: Int) -> String {
        let n = min(9999, max(0, number))
        switch self {
        case .decimal: return String(n)
        case .padded: return String(format: "%02d", n)
        case .upperAlpha, .lowerAlpha:
            guard n > 0 else { return "0" }
            var value = n, result = ""
            while value > 0 { value -= 1; result = String(UnicodeScalar(65 + value % 26)!) + result; value /= 26 }
            return self == .lowerAlpha ? result.lowercased() : result
        case .roman:
            guard (1...3999).contains(n) else { return String(n) }
            var value = n, result = ""
            for (amount, symbol) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")] {
                while value >= amount { result += symbol; value -= amount }
            }
            return result
        }
    }
}
enum CaptureMosaicMode: String, Codable, CaptureStyleOption {
    case pixels, blur, solid
    var title: String { switch self { case .pixels: "马赛克"; case .blur: "模糊"; case .solid: "实色遮挡" } }
}
enum CaptureCoverage: String, Codable, CaptureStyleOption {
    case rectangle, brush
    var title: String { self == .rectangle ? "矩形" : "画笔" }
}

enum CaptureEllipseKind:String,Codable,CaptureStyleOption {
    case ellipse, ring, sector, ringSector
    var title:String { switch self { case .ellipse:"椭圆";case .ring:"圆环";case .sector:"扇形";case .ringSector:"环形扇形" } }
}

struct CaptureMarkStyle: Codable, Equatable {
    var line = CaptureLinePattern.solid
    var fill = CaptureFill.outline
    var cornerRadius: CGFloat = 0
    var opacity: Double = 1
    var arrow = CaptureArrowStyle.filled
    var number = CaptureNumberStyle.circle
    var numberFormat = CaptureNumberFormat.decimal
    var fontSize: CGFloat = 24
    var bold = false
    var italic = false
    var textBackground = false
    var fontName: String?
    var textOutline: Bool?
    var textWrapWidth: CGFloat?
    var captionOffset: CGSize?
    var mosaic = CaptureMosaicMode.pixels
    var coverage = CaptureCoverage.rectangle
    var strength: CGFloat = 16
    var brushSize: CGFloat = 28
    var smooth = true
    var polyline = false
    var rotation: CGFloat = 0
    var magnification: CGFloat = 2
    var ellipse = false
    var dimming: Double = 0.55
    var watermarkTiled = true
    var detachedMagnifier = true
    var magnifierShadow = true
    var ellipseKind = CaptureEllipseKind.ellipse
    var arcStart: CGFloat = 0
    var arcSpan: CGFloat = 360
    var innerRatio: CGFloat = 0.55
    func validate() throws {
        if let textWrapWidth { guard textWrapWidth.isFinite, (20...10000).contains(textWrapWidth) else { throw PluginError.invalid("文字宽度无效。") } }
        if let captionOffset { guard captionOffset.width.isFinite, captionOffset.height.isFinite else { throw PluginError.invalid("说明位置无效。") } }
        let values:[CGFloat]=[cornerRadius,fontSize,strength,brushSize,rotation,magnification,arcStart,arcSpan,innerRatio,CGFloat(opacity),CGFloat(dimming)]
        guard values.allSatisfy({ $0.isFinite && abs($0)<100_000 }), (0...1).contains(opacity),(0...1).contains(dimming),
              (1...999).contains(fontSize),(1...256).contains(strength),(1...9999).contains(brushSize),
              (1...20).contains(magnification),(0...1).contains(innerRatio),(0...360).contains(arcSpan) else { throw PluginError.invalid("标注样式无效。") }
    }
}

enum CaptureMarkHandle: Hashable {
    case vertex(Int), corner(Int), bend, radius, rotation, arcStart, arcEnd, innerRadius, callout, caption
}
struct CaptureHandle {
    let kind: CaptureMarkHandle
    let point: CGPoint
    var round: Bool { switch kind { case .bend, .radius, .rotation, .arcStart, .arcEnd, .innerRadius, .callout, .caption: true; default: false } }
}

extension CaptureMark {
    var captionPoint: CGPoint {
        let base = tool == .arrow ? curveMidpoint : CGPoint(x: (points.first?.x ?? 0) + style.fontSize * 1.2, y: (points.first?.y ?? 0) - style.fontSize / 2)
        return CGPoint(x: base.x + (style.captionOffset?.width ?? 0), y: base.y + (style.captionOffset?.height ?? 0))
    }
    var numberLabel: String { style.numberFormat.label(numberValue ?? Int(text) ?? 1) }
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    var curveMidpoint: CGPoint {
        guard let a = points.first, let b = points.last else { return .zero }
        guard let control else { return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        return CGPoint(x: (a.x + 2 * control.x + b.x) / 4, y: (a.y + 2 * control.y + b.y) / 4)
    }
    func rotated(_ point: CGPoint, inverse: Bool = false) -> CGPoint {
        let angle = style.rotation * (inverse ? -1 : 1), c = center
        return CGPoint(x: c.x + (point.x - c.x) * cos(angle) - (point.y - c.y) * sin(angle),
                       y: c.y + (point.x - c.x) * sin(angle) + (point.y - c.y) * cos(angle))
    }
    func calloutRect(in bounds:CGRect) -> CGRect {
        let size=CGSize(width:min(bounds.width,rect.width*style.magnification),height:min(bounds.height,rect.height*style.magnification))
        let fallbackX=rect.maxX+16+size.width<=bounds.maxX ? rect.maxX+16:rect.minX-16-size.width
        let center=control ?? CGPoint(x:fallbackX+size.width/2,y:rect.midY)
        return CGRect(x:min(max(bounds.minX,center.x-size.width/2),bounds.maxX-size.width),
                      y:min(max(bounds.minY,center.y-size.height/2),bounds.maxY-size.height),width:size.width,height:size.height)
    }
    @MainActor func handles(scale: CGFloat) -> [CaptureHandle] {
        var result: [CaptureHandle] = []
        if [.arrow, .line].contains(tool) {
            result = points.enumerated().map { CaptureHandle(kind: .vertex($0.offset), point: $0.element) }
            if tool == .arrow { result.append(CaptureHandle(kind: .bend, point: curveMidpoint)) }
        } else if [.rectangle, .ellipse, .mosaic, .cover, .erase, .spotlight, .magnify].contains(tool), !(tool == .mosaic && style.coverage == .brush) {
            let r = rect
            result = [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)].enumerated().map { CaptureHandle(kind: .corner($0.offset), point: $0.element) }
            if tool == .magnify,style.detachedMagnifier,let control { result.append(CaptureHandle(kind:.callout,point:control)) }
            if tool == .rectangle { result.append(CaptureHandle(kind: .radius, point: CGPoint(x: r.minX + max(8 / scale, min(style.cornerRadius, min(r.width, r.height) / 2)), y: r.minY + max(8 / scale, min(style.cornerRadius, min(r.width, r.height) / 2))))) }
            if tool == .ellipse {
                func arcPoint(_ angle:CGFloat,_ radius:CGFloat=1)->CGPoint { CGPoint(x:r.midX+cos(angle * .pi/180)*r.width/2*radius,y:r.midY+sin(angle * .pi/180)*r.height/2*radius) }
                result.append(CaptureHandle(kind:.arcEnd,point:arcPoint(style.arcStart+style.arcSpan)))
                if [.sector,.ringSector].contains(style.ellipseKind) { result.append(CaptureHandle(kind:.arcStart,point:arcPoint(style.arcStart))) }
                result.append(CaptureHandle(kind:.innerRadius,point:arcPoint(style.arcStart+style.arcSpan/2,style.ellipseKind == .ellipse ? 0:style.innerRatio)))
            }
            if [.rectangle, .ellipse, .cover].contains(tool) { result.append(CaptureHandle(kind: .rotation, point: CGPoint(x: r.midX, y: r.minY - 24 / scale))) }
        } else if tool == .number, points.count > 1, let a = points.first, let b = points.last, hypot(a.x-b.x,a.y-b.y) > 10 {
            result = [CaptureHandle(kind: .vertex(points.count - 1), point: b)]
        }
        if (tool == .arrow && !text.isEmpty) || (tool == .number && !caption.isEmpty) { result.append(CaptureHandle(kind: .caption, point: captionPoint)) }
        return result.map { CaptureHandle(kind: $0.kind, point: rotated($0.point)) }
    }
    @MainActor func hit(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let p = rotated(point, inverse: true)
        if tool == .arrow && !text.isEmpty || tool == .number && !caption.isEmpty {
            let size = CaptureAnnotationRenderer.labelSize(tool == .arrow ? text : caption, mark: self)
            let r = CGRect(x: captionPoint.x - (tool == .arrow ? size.width / 2 : 0), y: captionPoint.y - (tool == .arrow ? size.height / 2 : 0), width: size.width, height: size.height)
            if r.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return true }
        }
        if tool == .arrow, let a = points.first, let b = points.last {
            let c = control ?? CGPoint(x: (a.x+b.x)/2,y:(a.y+b.y)/2)
            var previous = a
            for i in 1...40 {
                let t = CGFloat(i)/40, u = 1-t
                let next = CGPoint(x:u*u*a.x+2*u*t*c.x+t*t*b.x,y:u*u*a.y+2*u*t*c.y+t*t*b.y)
                if Self.distance(p, from: previous, to: next) <= max(tolerance, width * 2) { return true }; previous = next
            }
            return false
        }
        if [.line, .pen, .highlight].contains(tool) || (tool == .mosaic && style.coverage == .brush) {
            let radius = tool == .mosaic ? style.brushSize/2 : tool == .highlight ? width*3 : width/2
            return zip(points,points.dropFirst()).contains { Self.distance(p,from:$0.0,to:$0.1) <= max(tolerance,radius) }
        }
        if tool == .rectangle,style.fill == .outline {
            return rect.insetBy(dx:-tolerance,dy:-tolerance).contains(p) && !rect.insetBy(dx:tolerance+width/2,dy:tolerance+width/2).contains(p)
        }
        if tool == .ellipse {
            let rx=max(1,rect.width/2),ry=max(1,rect.height/2),r=hypot((p.x-rect.midX)/rx,(p.y-rect.midY)/ry)
            if style.fill == .outline { return abs(r-1)<tolerance/min(rx,ry)+width/min(rx,ry) }
            if [.ring,.ringSector].contains(style.ellipseKind) { return r<=1+tolerance/min(rx,ry) && r>=style.innerRatio-tolerance/min(rx,ry) }
            return r<=1+tolerance/min(rx,ry)
        }
        return selectionBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
    }
    static func distance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
        let t = length == 0 ? 0 : min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/length))
        return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)
    }
    func moving(by delta: CGSize) -> CaptureMark {
        var value = self
        value.points = points.map { CGPoint(x:$0.x+delta.width,y:$0.y+delta.height) }
        if let control { value.control = CGPoint(x:control.x+delta.width,y:control.y+delta.height) }
        return value
    }
    func adjusting(_ handle: CaptureMarkHandle, to point: CGPoint, constrained: Bool = false) -> CaptureMark {
        var value = self
        let local = rotated(point, inverse: true)
        switch handle {
        case .caption:
            let base = CGPoint(x: captionPoint.x - (style.captionOffset?.width ?? 0), y: captionPoint.y - (style.captionOffset?.height ?? 0))
            value.style.captionOffset = CGSize(width: local.x - base.x, height: local.y - base.y)
        case .callout: value.control=local
        case .vertex(let index): if value.points.indices.contains(index) { value.points[index] = local }
        case .bend:
            guard let a = points.first, let b = points.last else { return value }
            value.control = CGPoint(x: 2*local.x-(a.x+b.x)/2,y:2*local.y-(a.y+b.y)/2)
        case .corner(let index):
            let r = rect
            let corners = [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]
            let opposite = corners[(index+2)%4]
            var end = local
            if constrained { let d = max(abs(end.x-opposite.x),abs(end.y-opposite.y)); end = CGPoint(x:opposite.x+(end.x<opposite.x ? -d:d),y:opposite.y+(end.y<opposite.y ? -d:d)) }
            value.points = [opposite,end]
            let originalAnchor=rotated(opposite),newAnchor=value.rotated(opposite)
            value=value.moving(by:CGSize(width:originalAnchor.x-newAnchor.x,height:originalAnchor.y-newAnchor.y))
        case .radius: value.style.cornerRadius = min(min(rect.width,rect.height)/2,max(0,min(local.x-rect.minX,local.y-rect.minY)))
        case .arcStart, .arcEnd:
            let angle=(atan2((local.y-center.y)/max(1,rect.height/2),(local.x-center.x)/max(1,rect.width/2))*180 / .pi+360).truncatingRemainder(dividingBy:360)
            if handle == .arcStart { value.style.arcStart=angle }
            else { value.style.arcSpan=max(5,(angle-style.arcStart+360).truncatingRemainder(dividingBy:360)) }
            value.style.ellipseKind=style.ellipseKind == .ring || style.ellipseKind == .ringSector ? .ringSector:.sector
        case .innerRadius:
            value.style.innerRatio=min(0.95,max(0.05,hypot((local.x-center.x)/max(1,rect.width/2),(local.y-center.y)/max(1,rect.height/2))))
            if style.ellipseKind == .ellipse { value.style.ellipseKind = .ring }
        case .rotation:
            var angle = atan2(point.y-center.y,point.x-center.x) + .pi/2
            if constrained { angle = (angle / (.pi/12)).rounded() * (.pi/12) }
            value.style.rotation = angle
        }
        return value
    }
}

extension CaptureMark: Codable {
    private enum CodingKeys:String,CodingKey { case id,tool,points,color,width,text,style,control,numberValue,caption,createdAt }
    init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id);tool=try c.decode(CaptureTool.self,forKey:.tool)
        points=try c.decode([CGPoint].self,forKey:.points)
        let rgba=try c.decode([Double].self,forKey:.color)
        guard rgba.count==4,rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }),points.count<=100_000,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw PluginError.invalid("标注数据无效。") }
        color=NSColor(deviceRed:rgba[0],green:rgba[1],blue:rgba[2],alpha:rgba[3])
        width=try c.decode(CGFloat.self,forKey:.width);text=try c.decode(String.self,forKey:.text)
        style=try c.decode(CaptureMarkStyle.self,forKey:.style);control=try c.decodeIfPresent(CGPoint.self,forKey:.control)
        numberValue=try c.decodeIfPresent(Int.self,forKey:.numberValue);caption=try c.decode(String.self,forKey:.caption)
        createdAt=try c.decodeIfPresent(Date.self,forKey:.createdAt) ?? Date()
        try style.validate()
        guard control.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else { throw PluginError.invalid("标注控制点无效。") }
        guard width.isFinite,(0.1...999).contains(width),text.count<=100_000,caption.count<=10_000 else { throw PluginError.invalid("标注参数无效。") }
    }
    func encode(to encoder:any Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(id,forKey:.id);try c.encode(tool,forKey:.tool);try c.encode(points,forKey:.points)
        let rgb=color.usingColorSpace(.deviceRGB) ?? .red
        try c.encode([rgb.redComponent,rgb.greenComponent,rgb.blueComponent,rgb.alphaComponent],forKey:.color)
        try c.encode(width,forKey:.width);try c.encode(text,forKey:.text);try c.encode(style,forKey:.style)
        try c.encodeIfPresent(control,forKey:.control);try c.encodeIfPresent(numberValue,forKey:.numberValue);try c.encode(caption,forKey:.caption);try c.encode(createdAt,forKey:.createdAt)
    }
}
