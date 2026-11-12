import AppKit

enum CaptureImageTranslation {
    /// OCR rectangles are normalized with a bottom-left origin; rendering uses top-left pixels.
    @MainActor static func render(_ image: CGImage, lines: [RecognizedLine], translations: [String]) throws -> CGImage {
        guard lines.count == translations.count else { throw PluginError.invalid("译文与原图文字区域不匹配，请重新翻译。") }
        let context = try CaptureImage.context(width: image.width, height: image.height, colorSpace: image.colorSpace)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        let bitmap = NSBitmapImageRep(cgImage: image)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (line, translation) in zip(lines, translations) where !translation.isEmpty {
            let r = line.rect
            let rect = CGRect(x: r.minX * CGFloat(image.width), y: (1-r.maxY) * CGFloat(image.height), width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)).insetBy(dx: -2, dy: -2).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard rect.width > 2, rect.height > 2 else { continue }
            var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
            for x in stride(from: Int(rect.minX), through: Int(rect.maxX)-1, by: max(1, Int(rect.width)/20)) {
                for y in [max(0, Int(rect.minY)-2), min(image.height-1, Int(rect.maxY)+1)] {
                    if let c = bitmap.colorAt(x: max(0, min(image.width-1, x)), y: y)?.usingColorSpace(.deviceRGB) {
                        red += c.redComponent; green += c.greenComponent; blue += c.blueComponent; count += 1
                    }
                }
            }
            count = max(1, count); red /= count; green /= count; blue /= count
            NSColor(deviceRed: red, green: green, blue: blue, alpha: 1).setFill(); rect.fill()
            let foreground: NSColor = red*0.2126 + green*0.7152 + blue*0.0722 > 0.5 ? .black : .white
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            var size = max(6, rect.height * 0.8)
            var attrs: [NSAttributedString.Key: Any] = [:]
            repeat {
                attrs = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: foreground, .paragraphStyle: paragraph]
                let bounds = (translation as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
                if bounds.height <= rect.height { break }
                if size <= 6 { throw PluginError.invalid("部分译文超出原文字区域，已保留文字结果；可将文字贴出后调整排版。") }
                size -= 0.5
            } while true
            context.saveGState(); context.clip(to: rect)
            (translation as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            context.restoreGState()
        }
        guard let output = context.makeImage() else { throw PluginError.invalid("无法生成译图。") }
        return output
    }
}
