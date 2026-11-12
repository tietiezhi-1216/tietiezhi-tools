import AppKit

struct CaptureSelectionContour {
    var points:[CGPoint]
    var subtract=false
}

enum CaptureSelectionHandle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var left: Bool { [.topLeft, .bottomLeft, .left].contains(self) }
    var right: Bool { [.topRight, .bottomRight, .right].contains(self) }
    var top: Bool { [.topLeft, .topRight, .top].contains(self) }
    var bottom: Bool { [.bottomLeft, .bottomRight, .bottom].contains(self) }
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: left ? rect.minX : right ? rect.maxX : rect.midX,
                y: top ? rect.minY : bottom ? rect.maxY : rect.midY)
    }
}

enum CaptureSelectionGeometry {
    static func constrain(_ rect: CGRect, in bounds: CGRect, minimum: CGFloat = 8) -> CGRect {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return .zero }
        let size = CGSize(width: min(bounds.width, max(minimum, rect.width)), height: min(bounds.height, max(minimum, rect.height)))
        return CGRect(x: min(max(bounds.minX, rect.minX), bounds.maxX-size.width),
                      y: min(max(bounds.minY, rect.minY), bounds.maxY-size.height), width: size.width, height: size.height)
    }
    static func resize(_ rect: CGRect, handle: CaptureSelectionHandle, delta: CGSize, bounds: CGRect,
                       ratio: CGFloat? = nil, centered: Bool = false) -> CGRect {
        var x0=rect.minX, x1=rect.maxX, y0=rect.minY, y1=rect.maxY
        if handle.left { x0 += delta.width; if centered { x1 -= delta.width } }
        if handle.right { x1 += delta.width; if centered { x0 -= delta.width } }
        if handle.top { y0 += delta.height; if centered { y1 -= delta.height } }
        if handle.bottom { y1 += delta.height; if centered { y0 -= delta.height } }
        var width=max(8,x1-x0), height=max(8,y1-y0)
        if let ratio, ratio.isFinite, ratio > 0 {
            if handle == .top || handle == .bottom { width=height*ratio }
            else { height=width/ratio }
        }
        let x=centered ? rect.midX-width/2 : handle.left ? rect.maxX-width : handle.right ? rect.minX : rect.midX-width/2
        let y=centered ? rect.midY-height/2 : handle.top ? rect.maxY-height : handle.bottom ? rect.minY : rect.midY-height/2
        // Scale the size at an edge without breaking a requested aspect ratio.
        let factor=min(1,bounds.width/width,bounds.height/height)
        return constrain(CGRect(x:x,y:y,width:width*factor,height:height*factor),in:bounds)
    }
    static func transform(_ points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        guard old.width>0,old.height>0 else { return points }
        return points.map { CGPoint(x:new.minX+($0.x-old.minX)/old.width*new.width,y:new.minY+($0.y-old.minY)/old.height*new.height) }
    }
    static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first=points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin:first,size:.zero)) { partial,point in
            CGRect(x:min(partial.minX,point.x),y:min(partial.minY,point.y),
                   width:max(partial.maxX,point.x)-min(partial.minX,point.x),height:max(partial.maxY,point.y)-min(partial.minY,point.y))
        }
    }
    static func masked(_ image: CGImage, points: [CGPoint], rect: CGRect, scale: CGFloat) throws -> CGImage {
        guard points.count>=3 else { return image }
        return try masked(image,contours:[CaptureSelectionContour(points:points)],rect:rect,scale:scale)
    }
    static func masked(_ image: CGImage, contours:[CaptureSelectionContour], rect:CGRect, scale:CGFloat) throws -> CGImage {
        guard !contours.isEmpty else { return image }
        let context=try CaptureImage.context(width:image.width,height:image.height,colorSpace:image.colorSpace)
        for contour in contours {
            guard contour.points.count>=3 else { continue }
            let path=CGMutablePath()
            for (index,p) in contour.points.enumerated() {
                let point=CGPoint(x:(p.x-rect.minX)*scale,y:CGFloat(image.height)-(p.y-rect.minY)*scale)
                if index==0 { path.move(to:point) } else { path.addLine(to:point) }
            }
            path.closeSubpath();context.addPath(path)
            context.setBlendMode(contour.subtract ? .clear:.normal);context.setFillColor(NSColor.white.cgColor);context.fillPath()
        }
        context.setBlendMode(.sourceIn)
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let result=context.makeImage() else { throw PluginError.invalid("无法生成不规则截图。") }
        return result
    }
    static func rectangle(_ rect:CGRect) -> [CGPoint] {
        [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)]
    }
    static func decorationPadding(shadow:Bool,blur:CGFloat=10,offset:CGFloat=2) -> Int {
        let blur=blur.isFinite ? max(0,min(80,blur)):10
        let offset=offset.isFinite ? min(60,abs(offset)):2
        return shadow ? Int(ceil(blur*1.4+offset)):0
    }
    static func decorate(_ image:CGImage,cornerRadius:CGFloat,shadow:Bool,border:Bool,
                         shadowBlur:CGFloat=10,shadowOpacity:CGFloat=0.6,shadowOffset:CGFloat=2,
                         borderWidth:CGFloat=2,borderColor:NSColor=NSColor.white.withAlphaComponent(0.8)) throws -> CGImage {
        let cornerRadius=cornerRadius.isFinite ? max(0,min(CGFloat(min(image.width,image.height))/2,cornerRadius)):0
        let shadowBlur=shadowBlur.isFinite ? max(0,min(80,shadowBlur)):10
        let shadowOffset=shadowOffset.isFinite ? max(-60,min(60,shadowOffset)):2
        let shadowOpacity=shadowOpacity.isFinite ? max(0,min(1,shadowOpacity)):0.6
        let borderWidth=borderWidth.isFinite ? max(0,borderWidth):2
        guard cornerRadius>0 || shadow || border else { return image }
        // A shadow adds transparent padding; source pixels retain their original size.
        let padding=decorationPadding(shadow:shadow,blur:shadowBlur,offset:shadowOffset)
        let context=try CaptureImage.context(width:image.width+padding*2,height:image.height+padding*2,colorSpace:image.colorSpace)
        let rect=CGRect(x:padding,y:padding,width:image.width,height:image.height)
        let source:CGRect=CGRect(x:0,y:0,width:image.width,height:image.height)
        let rounded=try CaptureImage.context(width:image.width,height:image.height,colorSpace:image.colorSpace)
        rounded.addPath(CGPath(roundedRect:source,cornerWidth:cornerRadius,cornerHeight:cornerRadius,transform:nil));rounded.clip();rounded.draw(image,in:source)
        guard let roundedImage=rounded.makeImage() else { throw PluginError.invalid("无法添加截图圆角。") }
        context.saveGState()
        if shadow { context.setShadow(offset:CGSize(width:0,height:-shadowOffset),blur:shadowBlur,color:NSColor.black.withAlphaComponent(shadowOpacity).cgColor) }
        // Draw actual alpha, so adding a shadow never fills freehand/subtracted
        // areas with a solid rectangle behind the screenshot.
        context.draw(roundedImage,in:rect);context.restoreGState()
        if border {
            let width=max(0,min(min(rect.width,rect.height)/2,borderWidth))
            let outline=CGPath(roundedRect:rect.insetBy(dx:width/2,dy:width/2),cornerWidth:max(0,cornerRadius-width/2),cornerHeight:max(0,cornerRadius-width/2),transform:nil)
            context.addPath(outline);context.setStrokeColor(borderColor.cgColor);context.setLineWidth(width);context.strokePath()
        }
        guard let result=context.makeImage() else { throw PluginError.invalid("无法添加截图边框。") };return result
    }
}
