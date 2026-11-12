import AppKit
import Testing
@testable import TietiezhiTools

struct CaptureRedactionTests {
    @Test func repeatedSensitiveTextSharesGroupAndUsesSubstringBounds() throws {
        let line = "邮箱: a@example.com 备注"
        let ns = line as NSString, range = ns.range(of: "a@example.com")
        let first = RecognizedLine(text: line, rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.1),
                                   fragments: [.init(range: range, rect: CGRect(x: 0.25, y: 0.5, width: 0.4, height: 0.1))])
        let second = RecognizedLine(text: "a@example.com", rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1))
        let name = RecognizedLine(text: "张小明", rect: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1))
        let targets = CaptureRedactionDetector.textTargets(CaptureText(lines: [first, second, name], codes: []), size: CGSize(width: 1000, height: 1000))
        #expect(targets.count == 3)
        #expect(targets[0].groupID == targets[1].groupID)
        #expect(targets[0].rect.width < 420)
        #expect(targets[0].isSuggested && targets[1].isSuggested)
        #expect(!targets[2].isSuggested)
        #expect(targets[2].label == "张小明")
    }
    @Test func localTextureRepairKeepsOutsidePixelsAndRemovesSolidObstruction() throws {
        let context = try CaptureImage.context(width: 128, height: 96)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        let mask = CGRect(x: 45, y: 22, width: 20, height: 16)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: mask.minX, y: 96 - mask.maxY, width: mask.width, height: mask.height))
        let original = try #require(context.makeImage())
        let repaired = try CaptureTextureRepair.repair(original, rect: mask)
        let before = NSBitmapImageRep(cgImage: original), after = NSBitmapImageRep(cgImage: repaired)
        let outsideBefore = try #require(before.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        let outsideAfter = try #require(after.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        #expect(abs(outsideBefore.blueComponent - outsideAfter.blueComponent) < 0.01)
        let center = try #require(after.colorAt(x: Int(mask.midX), y: Int(mask.midY))?.usingColorSpace(.deviceRGB))
        #expect(center.blueComponent > 0.5)
    }
}
