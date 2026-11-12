import AppKit
import ImageIO
import Testing
@testable import TietiezhiTools

struct CaptureParityTests {
    @Test @MainActor func liveRecordingAnnotationsCanReturnToScreenOperationAndUndoNumbers() {
        let annotations = CaptureRecordingAnnotations()
        #expect(annotations.tool == nil)
        annotations.begin(.zero); annotations.end(CGPoint(x: 80, y: 20))
        #expect(annotations.marks.isEmpty)
        annotations.tool = .number
        annotations.begin(CGPoint(x: 20, y: 20)); annotations.end(CGPoint(x: 20, y: 20))
        annotations.begin(CGPoint(x: 80, y: 20)); annotations.end(CGPoint(x: 80, y: 20))
        #expect(annotations.marks.compactMap(\.numberValue) == [1, 2])
        annotations.undo()
        annotations.begin(CGPoint(x: 120, y: 20)); annotations.end(CGPoint(x: 120, y: 20))
        #expect(annotations.marks.compactMap(\.numberValue) == [1, 2])
        annotations.clear(); #expect(annotations.marks.isEmpty)
        annotations.tool = .arrow
        annotations.begin(.zero); annotations.end(CGPoint(x: 80, y: 20))
        #expect(annotations.marks.first?.points == [.zero, CGPoint(x: 80, y: 20)])
        annotations.tool = nil
        annotations.begin(.zero); annotations.end(.zero)
        #expect(annotations.marks.count == 1)
    }
    @Test func bundledEncoderCreatesARealStaticWebP() throws {
        guard CaptureWebP.encoder != nil else { return }
        let context = try CaptureImage.context(width: 48, height: 24)
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 24))
        let image = try #require(context.makeImage())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webp")
        defer { try? FileManager.default.removeItem(at: file) }
        try CaptureImage.write(image, to: file)
        let data = try Data(contentsOf: file)
        #expect(String(data: data[8..<12], encoding: .ascii) == "WEBP")
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 48 && decoded.height == 24)
        #expect(CGImageSourceGetCount(source) == 1)
    }
    @Test func legacyAnnotationStylesDecodeWithTypographyDefaults() throws {
        let data = try JSONEncoder().encode(CaptureMarkStyle())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["fontName", "textOutline", "textWrapWidth", "captionOffset"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(CaptureMarkStyle.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.fontName == nil && decoded.captionOffset == nil)
        try decoded.validate()
    }
    @Test func fileTemplatesCannotEscapeChosenDirectory() {
        let result = CaptureOutputPreferences.filename(width: 240, height: 120, template: "../../{width}x{height}\n{date}")
        #expect(!result.contains("/") && !result.contains("\n"))
        #expect(result.contains("240x120"))
        #expect(CaptureOutputPreferences.supportedFormats.contains("png"))
    }
    @Test @MainActor func translatedImagePreservesDimensionsAndPixelsOutsideText() throws {
        let context = try CaptureImage.context(width: 320, height: 180)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let source = try #require(context.makeImage())
        let line = RecognizedLine(text: "Hello", rect: CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.2))
        let result = try CaptureImageTranslation.render(source, lines: [line], translations: ["你好"])
        #expect(result.width == 320 && result.height == 180)
        let pixels = NSBitmapImageRep(cgImage: result), original = NSBitmapImageRep(cgImage: source)
        #expect(pixels.colorAt(x: 5, y: 175) == original.colorAt(x: 5, y: 175))
        var ink = 0
        for y in 54..<90 { for x in 64..<256 { if pixels.colorAt(x: x, y: y)!.brightnessComponent < 0.5 { ink += 1 } } }
        #expect(ink > 10)
        #expect(throws: (any Error).self) { try CaptureImageTranslation.render(source, lines: [line], translations: []) }
    }
    @Test @MainActor func movingArrowCaptionKeepsArrowGeometry() {
        var mark = CaptureMark(tool: .arrow, points: [CGPoint(x: 20, y: 20), CGPoint(x: 200, y: 100)], color: .red, width: 3, text: "说明")
        mark = mark.adjusting(.caption, to: CGPoint(x: 180, y: 160))
        #expect(mark.points == [CGPoint(x: 20, y: 20), CGPoint(x: 200, y: 100)])
        #expect(mark.captionPoint == CGPoint(x: 180, y: 160))
        #expect(mark.hit(CGPoint(x: 180, y: 160), tolerance: 2))
    }
}
