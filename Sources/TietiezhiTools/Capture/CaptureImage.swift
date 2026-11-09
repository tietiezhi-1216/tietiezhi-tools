import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum CaptureTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, line, pen, highlight, text, number, mosaic, cover, erase, magnify, crop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .arrow: "箭头"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .pen: "画笔"
        case .highlight: "荧光笔"
        case .text: "文字 / 水印"
        case .number: "序号"
        case .mosaic: "马赛克"
        case .cover: "实色遮挡"
        case .erase: "背景擦除"
        case .magnify: "放大镜"
        case .crop: "裁剪"
        }
    }
    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .number: "1.circle"
        case .mosaic: "square.grid.3x3.fill"
        case .cover: "rectangle.fill"
        case .erase: "eraser"
        case .magnify: "plus.magnifyingglass"
        case .crop: "crop"
        }
    }
}

struct CaptureMark {
    var tool: CaptureTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }
}

enum CaptureImage {
    static let maximumPixels = 80_000_000

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { throw PluginError.invalid("图片无法读取，或超过 8000 万像素。") }
        return image
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PluginError.invalid("无法创建图片。")
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw PluginError.invalid("图片编码失败。") }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL) throws {
        if url.pathExtension.lowercased() == "pdf" {
            var bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let pdf = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw PluginError.invalid("无法创建 PDF。") }
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: bounds)
            pdf.endPDFPage()
            pdf.closePDF()
            return
        }
        let type = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? UTType.jpeg : UTType.png
        guard let target = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw PluginError.invalid("无法写入图片。")
        }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw PluginError.invalid("保存图片失败。") }
    }

    static func context(width: Int, height: Int, colorSpace: CGColorSpace? = nil) throws -> CGContext {
        guard width > 0, height > 0, width <= maximumPixels / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace?.model == .rgb ? colorSpace! : CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PluginError.invalid("图像过大，最多支持 8000 万像素。") }
        return context
    }

    // 所有编辑坐标使用原图像素，左上角为原点，与 Retina 缩放无关。
    @MainActor static func render(_ image: CGImage, marks: [CaptureMark]) throws -> CGImage {
        let context = try context(width: image.width, height: image.height, colorSpace: image.colorSpace)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for mark in marks {
            guard let first = mark.points.first, let last = mark.points.last else { continue }
            context.saveGState()
            context.setStrokeColor(mark.color.cgColor)
            context.setFillColor(mark.color.cgColor)
            context.setLineWidth(mark.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            switch mark.tool {
            case .arrow, .line:
                context.move(to: first); context.addLine(to: last); context.strokePath()
                if mark.tool == .arrow {
                    let angle = atan2(last.y - first.y, last.x - first.x)
                    let length = max(14, mark.width * 4)
                    context.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                    context.addLine(to: last)
                    context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                    context.strokePath()
                }
            case .rectangle: context.stroke(mark.rect)
            case .ellipse: context.strokeEllipse(in: mark.rect)
            case .pen, .highlight:
                if mark.tool == .highlight { context.setAlpha(0.28); context.setLineWidth(mark.width * 6) }
                context.addLines(between: mark.points); context.strokePath()
            case .cover: context.fill(mark.rect)
            case .erase:
                let area = mark.rect.integral.intersection(bounds)
                if let current = context.makeImage(), area.width >= 1, area.height >= 1 {
                    let bitmap = NSBitmapImageRep(cgImage: current)
                    func color(_ x: CGFloat, _ y: CGFloat) -> [CGFloat] {
                        let x = max(0, min(current.width - 1, Int(x))), y = max(0, min(current.height - 1, Int(y)))
                        let value = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .white
                        return [value.redComponent, value.greenComponent, value.blueComponent]
                    }
                    let columns = min(96, max(1, Int(area.width))), rows = min(96, max(1, Int(area.height)))
                    context.setAllowsAntialiasing(false)
                    for y in 0..<rows {
                        for x in 0..<columns {
                            let u = (CGFloat(x) + 0.5) / CGFloat(columns), v = (CGFloat(y) + 0.5) / CGFloat(rows)
                            let px = area.minX + u * area.width, py = area.minY + v * area.height
                            let top = color(px, area.minY - 2), bottom = color(px, area.maxY + 1)
                            let left = color(area.minX - 2, py), right = color(area.maxX + 1, py)
                            let values = (0..<3).map { ((1 - v) * top[$0] + v * bottom[$0] + (1 - u) * left[$0] + u * right[$0]) / 2 }
                            context.setFillColor(NSColor(deviceRed: values[0], green: values[1], blue: values[2], alpha: 1).cgColor)
                            context.fill(CGRect(x: area.minX + CGFloat(x) * area.width / CGFloat(columns),
                                                y: area.minY + CGFloat(y) * area.height / CGFloat(rows),
                                                width: area.width / CGFloat(columns) + 0.5, height: area.height / CGFloat(rows) + 0.5))
                        }
                    }
                }
            case .mosaic:
                // 先缩小再最近邻放大；输出文件写入实际打码像素。
                let area = mark.rect.integral.intersection(bounds)
                if let source = context.makeImage()?.cropping(to: area), area.width > 0, area.height > 0 {
                    let block = max(8, Int(mark.width * 4))
                    let tiny = try Self.context(width: max(1, Int(area.width) / block), height: max(1, Int(area.height) / block))
                    tiny.interpolationQuality = .low
                    tiny.draw(source, in: CGRect(x: 0, y: 0, width: tiny.width, height: tiny.height))
                    if let pixels = tiny.makeImage() {
                        context.interpolationQuality = .none
                        context.translateBy(x: area.minX, y: area.maxY)
                        context.scaleBy(x: 1, y: -1)
                        context.draw(pixels, in: CGRect(origin: .zero, size: area.size))
                    }
                }
            case .text, .number:
                let fontSize = max(16, mark.width * 6)
                let text = mark.text as NSString
                if mark.tool == .number {
                    let diameter = fontSize * 1.6
                    let circle = CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter)
                    context.fillEllipse(in: circle)
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.white]
                    let size = text.size(withAttributes: attrs)
                    text.draw(at: CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2), withAttributes: attrs)
                } else {
                    text.draw(at: first, withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: mark.color])
                }
            case .magnify:
                let area = mark.rect.integral.intersection(bounds)
                if let source = image.cropping(to: area), area.width > 0, area.height > 0 {
                    context.addEllipse(in: area); context.clip()
                    context.translateBy(x: area.midX, y: area.midY)
                    context.scaleBy(x: 2, y: -2)
                    context.draw(source, in: CGRect(x: -area.width / 2, y: -area.height / 2, width: area.width, height: area.height))
                    context.restoreGState()
                    context.saveGState()
                    context.setStrokeColor(mark.color.cgColor); context.setLineWidth(mark.width)
                    context.strokeEllipse(in: area)
                }
            case .crop: break
            }
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw PluginError.invalid("无法生成图片。") }
        return result
    }

    static func rotate(_ image: CGImage) throws -> CGImage {
        let context = try context(width: image.height, height: image.width, colorSpace: image.colorSpace)
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }

    static func thumbnail(_ image: CGImage, maximum: CGFloat = 480) -> CGImage {
        let ratio = min(1, maximum / CGFloat(max(image.width, image.height)))
        guard let context = try? context(width: max(1, Int(CGFloat(image.width) * ratio)), height: max(1, Int(CGFloat(image.height) * ratio))) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage() ?? image
    }
}

enum StitchAxis: String, CaseIterable, Identifiable {
    case vertical, horizontal
    var id: String { rawValue }
    var title: String { self == .vertical ? "纵向" : "横向" }
}

struct ImageStitcher {
    private(set) var image: CGImage
    private var previous: CGImage
    private var position: Int = 0
    private var minimum: Int = 0
    let axis: StitchAxis

    init(image: CGImage, axis: StitchAxis) {
        self.image = image; previous = image; self.axis = axis
    }

    mutating func append(_ next: CGImage) throws -> Bool {
        guard next.width == previous.width, next.height == previous.height else {
            throw PluginError.invalid("截图区域的分辨率已变化，请重新开始。")
        }
        guard let shift = Self.displacement(previous, next, axis: axis), shift != 0 else { return false }
        let newPosition = position + shift
        let low = min(minimum, newPosition)
        let length = axis == .vertical ? next.height : next.width
        let high = max(minimum + (axis == .vertical ? image.height : image.width), newPosition + length)
        let width = axis == .vertical ? image.width : high - low
        let height = axis == .vertical ? high - low : image.height
        let context = try CaptureImage.context(width: width, height: height, colorSpace: image.colorSpace)
        // CGImage 的裁剪坐标自左上角起；绘制坐标自左下角起。
        let oldRect = axis == .vertical
            ? CGRect(x: 0, y: height - (minimum - low) - image.height, width: image.width, height: image.height)
            : CGRect(x: minimum - low, y: 0, width: image.width, height: image.height)
        let newRect = axis == .vertical
            ? CGRect(x: 0, y: height - (newPosition - low) - next.height, width: next.width, height: next.height)
            : CGRect(x: newPosition - low, y: 0, width: next.width, height: next.height)
        context.draw(image, in: oldRect)
        context.draw(next, in: newRect)
        image = context.makeImage()!
        position = newPosition; minimum = low; previous = next
        return true
    }

    static func displacement(_ first: CGImage, _ second: CGImage, axis: StitchAxis) -> Int? {
        let factor = max(1, max(first.width, first.height) / 240)
        let width = max(1, first.width / factor), height = max(1, first.height / factor)
        func gray(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height)
            bytes.withUnsafeMutableBytes { memory in
                let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
        let a = gray(first), b = gray(second)
        let length = axis == .vertical ? height : width
        let cross = axis == .vertical ? width : height
        guard length >= 12, cross >= 8 else { return nil }
        func score(_ shift: Int) -> Double {
            let start = max(0, shift) + length / 12
            let end = min(length, length + shift) - length / 12
            guard end - start >= length / 6 else { return .infinity }
            var total = 0.0, count = 0
            for along in stride(from: start, to: end, by: 2) {
                for across in stride(from: cross / 12, to: cross - cross / 12, by: 3) {
                    let i = axis == .vertical ? along * width + across : across * width + along
                    let j = axis == .vertical ? (along - shift) * width + across : across * width + along - shift
                    total += abs(Double(a[i]) - Double(b[j])); count += 1
                }
            }
            return total / Double(max(1, count))
        }
        let unchanged = score(0)
        if unchanged < 1.2 { return 0 }
        let limit = length * 3 / 4
        var best = 0, error = Double.infinity
        for shift in -limit...limit where abs(shift) >= 2 {
            let value = score(shift)
            if value < error { best = shift; error = value }
        }
        guard error < 18, error < unchanged * 0.55 else { return nil }
        guard factor > 1 else { return best }
        // 仅压缩垂直于滚动方向的维度，沿滚动轴保留原始像素，避免 Retina 接缝累计漂移。
        let exactWidth = axis == .vertical ? min(64, first.width) : first.width
        let exactHeight = axis == .vertical ? first.height : min(64, first.height)
        func strip(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: exactWidth * exactHeight)
            data.withUnsafeMutableBytes {
                let context = CGContext(data: $0.baseAddress, width: exactWidth, height: exactHeight, bitsPerComponent: 8,
                                        bytesPerRow: exactWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: exactWidth, height: exactHeight))
            }
            return data
        }
        let originalA = strip(first), originalB = strip(second)
        let originalLength = axis == .vertical ? exactHeight : exactWidth
        let originalCross = axis == .vertical ? exactWidth : exactHeight
        var exact = best * factor, exactError = Double.infinity
        for candidate in (best * factor - factor * 2)...(best * factor + factor * 2) {
            let low = max(0, candidate) + originalLength / 12
            let high = min(originalLength, originalLength + candidate) - originalLength / 12
            guard high > low else { continue }
            var sum = 0.0, samples = 0
            for along in stride(from: low, to: high, by: 3) {
                for across in stride(from: originalCross / 12, to: originalCross - originalCross / 12, by: 3) {
                    let i = axis == .vertical ? along * exactWidth + across : across * exactWidth + along
                    let j = axis == .vertical ? (along - candidate) * exactWidth + across : across * exactWidth + along - candidate
                    sum += abs(Double(originalA[i]) - Double(originalB[j])); samples += 1
                }
            }
            let value = sum / Double(max(1, samples))
            if value < exactError { exact = candidate; exactError = value }
        }
        return exact
    }
}
