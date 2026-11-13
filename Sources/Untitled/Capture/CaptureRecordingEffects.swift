import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreText
import SwiftUI

struct RecordingEffectOptions: Codable, Equatable, Sendable {
    var cursor = true
    var clicks = true
    var keys = true
    var cursorScale = 1.0
    var clickScale = 1.0
    var keySize = 24.0
    var keyDuration = 1.5
    var background = "dark"
}

struct RecordingEffectsControls: View {
    @Binding var options: RecordingEffectOptions
    var body: some View {
        DisclosureGroup("键鼠效果") {
            HStack {
                Toggle("光标", isOn: $options.cursor)
                Toggle("点击 / 滚轮", isOn: $options.clicks)
                Toggle("按键", isOn: $options.keys)
                Spacer()
                Picker("背景", selection: $options.background) {
                    Text("深色").tag("dark"); Text("浅色").tag("light"); Text("蓝色").tag("blue")
                }.frame(width: 145)
            }
            HStack {
                Text("光标大小"); Slider(value: $options.cursorScale, in: 0.5...2).frame(width: 90)
                Text("点击大小"); Slider(value: $options.clickScale, in: 0.5...2).frame(width: 90)
                Text("字号"); Slider(value: $options.keySize, in: 16...48).frame(width: 90)
                Text("持续"); Slider(value: $options.keyDuration, in: 0.5...4).frame(width: 90)
            }.font(.caption)
        }.toggleStyle(.checkbox).controlSize(.small)
    }
}

/// Uses the same Core Image composition in AVPlayer, movie export and animation frames.
@MainActor enum RecordingEffects {
    static func composition(asset: AVAsset, cgTransform: CGAffineTransform, sourceSize: CGSize, outputSize: CGSize,
                            orientedSize: CGSize, crop: CGRect, frameDuration: CMTime,
                            events: [RecordingEvent], options: RecordingEffectOptions, start: Double, speed: Double) -> AVMutableVideoComposition {
        let renderer = RecordingEventRenderer(events: events, options: options, size: outputSize, originalSize: orientedSize, crop: crop)
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceSize.height)
        let flipOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outputSize.height)
        let transform = flipSource.concatenating(cgTransform).concatenating(flipOutput)
        let extent = CGRect(origin: .zero, size: outputSize)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!])
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let input = request.sourceImage.transformed(by: transform).cropped(to: extent)
            let image = renderer.render(on: input, time: start + request.compositionTime.seconds * speed)
            request.finish(with: image, context: context)
        }
        composition.renderSize = outputSize; composition.frameDuration = frameDuration
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }
}

private final class RecordingEventRenderer: @unchecked Sendable {
    let events: [RecordingEvent]
    let pointers: [RecordingEvent]
    let options: RecordingEffectOptions
    let size: CGSize
    let originalSize: CGSize
    let crop: CGRect
    let cursor: CIImage
    let click: CIImage
    let keyLabels: [String: CIImage]
    init(events: [RecordingEvent], options: RecordingEffectOptions, size: CGSize, originalSize: CGSize, crop: CGRect) {
        self.events = events; pointers = events.filter { $0.kind != .key }; self.options = options; self.size = size; self.originalSize = originalSize; self.crop = crop
        cursor = Self.cursorImage()
        click = Self.clickImage()
        keyLabels = Dictionary(uniqueKeysWithValues: Set(events.filter { $0.kind == .key || $0.kind == .scroll }.map(\.label)).prefix(512).map { ($0, Self.labelImage($0, size: options.keySize, background: options.background)) })
    }
    func render(on base: CIImage, time: Double) -> CIImage {
        var result = base
        var lower = 0, upper = events.count
        while lower < upper { let middle = (lower + upper) / 2; if events[middle].time <= time { lower = middle + 1 } else { upper = middle } }
        let index = lower
        var pointerIndex = 0, pointerEnd = pointers.count
        while pointerIndex < pointerEnd { let middle = (pointerIndex + pointerEnd) / 2; if pointers[middle].time <= time { pointerIndex = middle + 1 } else { pointerEnd = middle } }
        if options.cursor, pointerIndex > 0 {
            let event = pointers[pointerIndex - 1]
            if let point = position(event) {
                let factor = CGFloat(options.cursorScale)
                let image = cursor.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                    .transformed(by: CGAffineTransform(translationX: point.x, y: point.y - cursor.extent.height * factor))
                result = image.composited(over: result)
            }
        }
        var lastKey: RecordingEvent?
        for event in events.prefix(index).reversed() {
            let age = time - event.time
            if age > max(options.keyDuration, 0.7) { break }
            if event.kind == .key, lastKey == nil { lastKey = event }
            if options.clicks, [.leftClick, .rightClick, .middleClick, .scroll].contains(event.kind), age < 0.7, let point = position(event) {
                let factor = CGFloat(options.clickScale * (0.5 + age))
                let overlay = click.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                    .transformed(by: CGAffineTransform(translationX: point.x - click.extent.width * factor / 2, y: point.y - click.extent.height * factor / 2))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, 1 - age / 0.7))])
                result = overlay.composited(over: result)
                if event.kind == .scroll, let label = keyLabels[event.label] {
                    result = label.transformed(by: CGAffineTransform(translationX: point.x + 20, y: point.y)).composited(over: result)
                }
            }
        }
        if options.keys, let event = lastKey, time - event.time < options.keyDuration, let label = keyLabels[event.label] {
            result = label.transformed(by: CGAffineTransform(translationX: (size.width - label.extent.width) / 2, y: 20)).composited(over: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: size))
    }
    private func position(_ event: RecordingEvent) -> CGPoint? {
        let point = CGPoint(x: event.x * originalSize.width - crop.minX, y: size.height - (event.y * originalSize.height - crop.minY))
        return CGRect(origin: .zero, size: size).contains(point) ? point : nil
    }
    private static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    private static func cursorImage() -> CIImage {
        let context = context(28, 40)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.setStrokeColor(CGColor(gray: 0, alpha: 1)); context.setLineWidth(2)
        context.move(to: CGPoint(x: 2, y: 38)); context.addLine(to: CGPoint(x: 2, y: 8)); context.addLine(to: CGPoint(x: 10, y: 16))
        context.addLine(to: CGPoint(x: 17, y: 2)); context.addLine(to: CGPoint(x: 23, y: 5)); context.addLine(to: CGPoint(x: 16, y: 19)); context.addLine(to: CGPoint(x: 27, y: 19)); context.closePath()
        context.drawPath(using: .fillStroke); return CIImage(cgImage: context.makeImage()!)
    }
    private static func clickImage() -> CIImage {
        let context = context(64, 64)
        context.setFillColor(CGColor(red: 0.1, green: 0.55, blue: 1, alpha: 0.3))
        context.setStrokeColor(CGColor(red: 0.1, green: 0.55, blue: 1, alpha: 1)); context.setLineWidth(3)
        context.addEllipse(in: CGRect(x: 3, y: 3, width: 58, height: 58)); context.drawPath(using: .fillStroke)
        return CIImage(cgImage: context.makeImage()!)
    }
    private static func labelImage(_ text: String, size: Double, background: String) -> CIImage {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let light = background == "light"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(text.prefix(30)), attributes: [.font: font, .foregroundColor: light ? NSColor.black : NSColor.white]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let context = context(max(30, Int(bounds.width + 28)), Int(size + 22))
        let color = background == "blue" ? CGColor(red: 0.05, green: 0.35, blue: 0.85, alpha: 0.9) : CGColor(gray: light ? 1 : 0, alpha: 0.82)
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: context.width, height: context.height), cornerWidth: 9, cornerHeight: 9, transform: nil)); context.fillPath()
        context.textPosition = CGPoint(x: 14, y: 11 - bounds.minY); CTLineDraw(line, context)
        return CIImage(cgImage: context.makeImage()!)
    }
}
