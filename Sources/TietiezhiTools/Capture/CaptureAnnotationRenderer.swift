import AppKit
import CoreImage

enum CaptureAnnotationRenderer {
    @MainActor private static let imageContext=CIContext()
    @MainActor static func path(_ mark: CaptureMark) -> CGPath {
        let path = CGMutablePath()
        guard let first = mark.points.first else { return path }
        path.move(to: first)
        if let control = mark.control, mark.tool == .arrow, let last = mark.points.last {
            path.addQuadCurve(to: last, control: control)
        } else if mark.style.smooth, [.pen, .highlight].contains(mark.tool), mark.points.count > 2 {
            for i in 0..<(mark.points.count-1) {
                let a = mark.points[max(0,i-1)], b = mark.points[i], c = mark.points[i+1], d = mark.points[min(mark.points.count-1,i+2)]
                path.addCurve(to:c,control1:CGPoint(x:b.x+(c.x-a.x)/6,y:b.y+(c.y-a.y)/6),control2:CGPoint(x:c.x-(d.x-b.x)/6,y:c.y-(d.y-b.y)/6))
            }
        } else { for point in mark.points.dropFirst() { path.addLine(to: point) } }
        return path
    }
    @MainActor static func shape(_ mark: CaptureMark) -> CGPath {
        if mark.tool == .ellipse {
            if mark.style.ellipseKind == .ellipse { return CGPath(ellipseIn:mark.rect,transform:nil) }
            let path=CGMutablePath(),r=mark.rect
            if mark.style.ellipseKind == .ring {
                path.addEllipse(in:r);path.addEllipse(in:r.insetBy(dx:r.width*(1-mark.style.innerRatio)/2,dy:r.height*(1-mark.style.innerRatio)/2));return path
            }
            let start=mark.style.arcStart * .pi/180,end=start+mark.style.arcSpan * .pi/180
            path.addArc(center:.zero,radius:1,startAngle:start,endAngle:end,clockwise:false)
            if mark.style.ellipseKind == .ringSector {
                path.addArc(center:.zero,radius:mark.style.innerRatio,startAngle:end,endAngle:start,clockwise:true)
            } else { path.addLine(to:.zero) }
            path.closeSubpath()
            var transform=CGAffineTransform(translationX:r.midX,y:r.midY).scaledBy(x:r.width/2,y:r.height/2)
            return path.copy(using:&transform) ?? path
        }
        if mark.style.ellipse { return CGPath(ellipseIn:mark.rect,transform:nil) }
        let radius = max(0,min(mark.style.cornerRadius,min(mark.rect.width,mark.rect.height)/2))
        return CGPath(roundedRect: mark.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    @MainActor static func drawArrow(_ mark: CaptureMark, in context: CGContext) {
        guard let a = mark.points.first, let b = mark.points.last else { return }
        let c = mark.control ?? CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2)
        func point(_ t: CGFloat) -> CGPoint { let u=1-t; return CGPoint(x:u*u*a.x+2*u*t*c.x+t*t*b.x,y:u*u*a.y+2*u*t*c.y+t*t*b.y) }
        func tangent(_ t: CGFloat) -> CGFloat { atan2((1-t)*(c.y-a.y)+t*(b.y-c.y),(1-t)*(c.x-a.x)+t*(b.x-c.x)) }
        var length: CGFloat = 0, previous = a
        for i in 1...40 { let p=point(CGFloat(i)/40); length += hypot(p.x-previous.x,p.y-previous.y); previous=p }
        guard length > 1 else { return }
        let head = min(length*0.45,max(14,mark.width*4.5))
        if [.tapered, .taperedOutline].contains(mark.style.arrow) {
            let tEnd=max(0.15,1-head/length), polygon=CGMutablePath()
            var left:[CGPoint]=[],right:[CGPoint]=[]
            for i in 0...30 {
                let t=tEnd*CGFloat(i)/30,p=point(t),angle=tangent(t),half=max(0.6,mark.width*(0.15+t*0.9))
                left.append(CGPoint(x:p.x-sin(angle)*half,y:p.y+cos(angle)*half)); right.append(CGPoint(x:p.x+sin(angle)*half,y:p.y-cos(angle)*half))
            }
            let shoulder=point(tEnd),angle=tangent(1),span=head*0.48
            polygon.addLines(between:left)
            polygon.addLine(to:CGPoint(x:shoulder.x-sin(angle)*span,y:shoulder.y+cos(angle)*span)); polygon.addLine(to:b)
            polygon.addLine(to:CGPoint(x:shoulder.x+sin(angle)*span,y:shoulder.y-cos(angle)*span))
            for p in right.reversed() { polygon.addLine(to:p) };polygon.closeSubpath()
            context.addPath(polygon)
            if mark.style.arrow == .tapered { context.fillPath() }
            else { context.setLineWidth(max(1,mark.width*0.55));context.strokePath() }
        } else {
            if mark.style.arrow == .open { context.addPath(path(mark)) }
            else {
                let startT:CGFloat=[.double,.dimension].contains(mark.style.arrow) ? head*0.75/length:0
                let endT=1-head*0.75/length
                context.move(to:point(startT))
                for i in 1...40 { context.addLine(to:point(startT+(endT-startT)*CGFloat(i)/40)) }
            }
            context.strokePath()
            func headAt(_ tip: CGPoint, angle: CGFloat) {
                let left=CGPoint(x:tip.x-head*cos(angle - .pi/7),y:tip.y-head*sin(angle - .pi/7))
                let right=CGPoint(x:tip.x-head*cos(angle + .pi/7),y:tip.y-head*sin(angle + .pi/7))
                context.setLineDash(phase:0,lengths:[]);context.move(to:left);context.addLine(to:tip);context.addLine(to:right)
                if mark.style.arrow == .open { context.strokePath() } else { context.closePath();context.fillPath() }
            }
            headAt(b,angle:tangent(1))
            if [.double,.dimension].contains(mark.style.arrow) { headAt(a,angle:tangent(0) + .pi) }
            if mark.style.arrow == .dimension {
                for (tip,angle) in [(a,tangent(0)),(b,tangent(1))] {
                    let span=max(7,mark.width*2.5)
                    context.move(to:CGPoint(x:tip.x-sin(angle)*span,y:tip.y+cos(angle)*span))
                    context.addLine(to:CGPoint(x:tip.x+sin(angle)*span,y:tip.y-cos(angle)*span));context.strokePath()
                }
            }
        }
        if !mark.text.isEmpty { label(mark.text, at:mark.captionPoint, mark:mark, centered:true, background:true) }
    }
    @MainActor static func font(_ mark: CaptureMark) -> NSFont {
        var base = mark.style.fontName.flatMap { NSFont(name: $0, size: max(10, mark.style.fontSize)) } ?? NSFont.systemFont(ofSize: max(10, mark.style.fontSize))
        if mark.style.bold { base = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) }
        if mark.style.italic { base = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) }
        return base
    }
    @MainActor static func labelAttributes(_ mark: CaptureMark, color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: font(mark), .foregroundColor: color ?? mark.color, .paragraphStyle: paragraph]
        if mark.style.textOutline == true { attrs[.strokeWidth] = -3; attrs[.strokeColor] = NSColor.white }
        return attrs
    }
    @MainActor static func labelSize(_ text: String, mark: CaptureMark) -> CGSize {
        let attrs = labelAttributes(mark)
        guard let width = mark.style.textWrapWidth else { return (text as NSString).size(withAttributes: attrs) }
        let r = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        return CGSize(width: width, height: ceil(r.height))
    }
    @MainActor static func label(_ text: String, at point: CGPoint, mark: CaptureMark, centered: Bool, background: Bool = false, color: NSColor? = nil) {
        let attrs = labelAttributes(mark, color: color), size = labelSize(text, mark: mark)
        let rect = CGRect(x: point.x-(centered ? size.width/2:0), y: point.y-(centered ? size.height/2:0), width: size.width, height: size.height)
        if background || mark.style.textBackground {
            NSColor.textBackgroundColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx:-5,dy:-3), xRadius:4, yRadius:4).fill()
        }
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
    }
    @MainActor static func drawNumber(_ mark: CaptureMark, in context: CGContext) {
        guard let first=mark.points.first else { return }
        if let last=mark.points.last,hypot(first.x-last.x,first.y-last.y)>max(12,mark.style.fontSize) {
            var arrow=mark;arrow.tool = .arrow;arrow.text="";arrow.style.arrow = .filled
            drawArrow(arrow,in:context)
        }
        let label=mark.numberLabel, size=(label as NSString).size(withAttributes:[.font:font(mark)])
        let diameter=max(mark.style.fontSize*1.65,size.width+mark.style.fontSize*0.65)
        let rect=CGRect(x:first.x-diameter/2,y:first.y-diameter/2,width:diameter,height:diameter)
        let filled = mark.style.number == .circle || mark.style.number == .square
        if mark.style.number != .plain {
            if [.circle,.outlineCircle].contains(mark.style.number) { context.addEllipse(in:rect) }
            else { context.addPath(CGPath(roundedRect:rect,cornerWidth:diameter*0.22,cornerHeight:diameter*0.22,transform:nil)) }
            if filled { context.fillPath() } else { context.strokePath() }
        }
        self.label(label,at:first,mark:mark,centered:true,color:filled ? .white:mark.color)
        if !mark.caption.isEmpty { self.label(mark.caption,at:mark.captionPoint,mark:mark,centered:false,background:true) }
    }
    @MainActor static func drawWatermark(_ mark:CaptureMark,in bounds:CGRect) {
        let date=DateFormatter();date.dateFormat="yyyy-MM-dd"
        let time=DateFormatter();time.dateFormat="HH:mm:ss"
        let value=(mark.text.isEmpty ? "水印":mark.text).replacingOccurrences(of:"{date}",with:date.string(from:mark.createdAt)).replacingOccurrences(of:"{time}",with:time.string(from:mark.createdAt))
        if !mark.style.watermarkTiled { label(value,at:mark.points.first ?? .zero,mark:mark,centered:false);return }
        let size=(value as NSString).size(withAttributes:[.font:font(mark)])
        let origin=mark.points.first ?? .zero
        for y in stride(from:origin.y-bounds.height,through:bounds.height*2,by:max(60,size.height*3)) {
            for x in stride(from:origin.x-bounds.width,through:bounds.width*2,by:max(100,size.width+70)) {
                label(value,at:CGPoint(x:x,y:y),mark:mark,centered:false)
            }
        }
    }
    @MainActor static func drawMagnifier(_ mark:CaptureMark,source:CGImage,in context:CGContext,bounds:CGRect) {
        let area=mark.rect.integral.intersection(bounds)
        guard area.width>1,area.height>1,let crop=source.cropping(to:area) else { return }
        let destination=mark.calloutRect(in:bounds)
        context.setLineDash(phase:0,lengths:[]);context.setLineWidth(max(1,mark.width))
        context.move(to:CGPoint(x:area.midX,y:area.midY));context.addLine(to:CGPoint(x:destination.midX,y:destination.midY));context.strokePath()
        context.stroke(area)
        let path=mark.style.ellipse ? CGPath(ellipseIn:destination,transform:nil):CGPath(roundedRect:destination,cornerWidth:8,cornerHeight:8,transform:nil)
        if mark.style.magnifierShadow {
            context.saveGState();context.setShadow(offset:CGSize(width:2,height:3),blur:8,color:NSColor.black.withAlphaComponent(0.3).cgColor)
            context.setFillColor(NSColor.white.cgColor);context.addPath(path);context.fillPath();context.restoreGState()
        }
        context.saveGState();context.addPath(path);context.clip()
        context.translateBy(x:destination.minX,y:destination.maxY);context.scaleBy(x:1,y:-1);context.interpolationQuality = .high
        context.draw(crop,in:CGRect(origin:.zero,size:destination.size));context.restoreGState()
        context.addPath(path);context.strokePath()
    }
    @MainActor static func drawMosaic(_ mark: CaptureMark, in context: CGContext, bounds: CGRect) throws {
        guard let current=context.makeImage() else { return }
        let area: CGRect
        if mark.style.coverage == .brush {
            let xs=mark.points.map(\.x),ys=mark.points.map(\.y)
            guard let x=xs.min(),let y=ys.min(),let maxX=xs.max(),let maxY=ys.max() else { return }
            area=CGRect(x:x,y:y,width:maxX-x,height:maxY-y).insetBy(dx:-mark.style.brushSize/2,dy:-mark.style.brushSize/2).integral.intersection(bounds)
            context.setLineWidth(mark.style.brushSize);context.setLineCap(.round);context.setLineJoin(.round)
            context.addPath(path(mark));context.replacePathWithStrokedPath();context.clip()
        } else { area=mark.rect.integral.intersection(bounds);context.addPath(shape(mark));context.clip() }
        guard area.width>=1,area.height>=1 else { return }
        if mark.style.mosaic == .solid { context.fill(area);return }
        let output: CGImage
        if mark.style.mosaic == .blur {
            let input=CIImage(cgImage:current)
            let filtered=input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(2,mark.style.strength*0.7)]).cropped(to:input.extent)
            guard let image=imageContext.createCGImage(filtered,from:input.extent),let cropped=image.cropping(to:area) else { return }
            output=cropped
        } else {
            guard let source=current.cropping(to:area) else { return }
            let block=max(3,Int(mark.style.strength))
            let tiny=try CaptureImage.context(width:max(1,Int(area.width)/block),height:max(1,Int(area.height)/block),colorSpace:current.colorSpace)
            tiny.interpolationQuality = .low;tiny.draw(source,in:CGRect(x:0,y:0,width:tiny.width,height:tiny.height))
            guard let pixels=tiny.makeImage() else { return };output=pixels
        }
        context.interpolationQuality = mark.style.mosaic == .blur ? .high:.none
        context.translateBy(x:area.minX,y:area.maxY);context.scaleBy(x:1,y:-1)
        context.draw(output,in:CGRect(origin:.zero,size:area.size))
    }
}
