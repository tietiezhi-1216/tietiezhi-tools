import AppKit
import CoreVideo
import Testing
@testable import Untitled

struct CaptureInpaintingTests {
    @Test func contextIncludesSurroundingPixelsAndStaysInsideImage() {
        let bounds=CGRect(x:0,y:0,width:200,height:100),mask=CGRect(x:0,y:10,width:40,height:30)
        let crop=CaptureInpaintingEngine.contextRegion(mask:mask,imageBounds:bounds)
        #expect(crop.contains(mask));#expect(bounds.contains(crop));#expect(crop.width>mask.width);#expect(crop.height>mask.height)
    }
    @Test func grayscaleMaskPreservesTopLeftImageCoordinates() throws {
        let buffer=try CaptureInpaintingEngine.maskBuffer(mask:CGRect(x:10,y:20,width:20,height:30),cropSize:CGSize(width:100,height:100))
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        let bytes=try #require(CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to:UInt8.self)),row=CVPixelBufferGetBytesPerRow(buffer)
        #expect(bytes[200*row+100]==255)
        #expect(bytes[500*row+100]==0)
        #expect(bytes[200*row+600]==0)
    }
    @Test func compositingChangesOnlyMaskPixels() throws {
        let original=try image(width:100,height:80,color:.blue)
        let patch=try image(width:800,height:800,color:.red)
        let result=try CaptureInpaintingEngine.composite(original,patch:patch,crop:CGRect(x:10,y:10,width:70,height:60),mask:CGRect(x:20,y:20,width:20,height:15))
        let pixels=NSBitmapImageRep(cgImage:result)
        #expect((pixels.colorAt(x:25,y:25)?.redComponent ?? 0)>0.95)
        #expect((pixels.colorAt(x:45,y:25)?.blueComponent ?? 0)>0.95)
        #expect((pixels.colorAt(x:25,y:45)?.blueComponent ?? 0)>0.95)
    }
    @Test func truncatedModelCannotBeInstalled() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("model-test-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at:file) }
        try Data("fake model".utf8).write(to:file)
        #expect(throws:(any Error).self) { try CaptureInpaintingModel.verifyArchive(file) }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["UNTITLED_INPAINTING_MODEL"] != nil))
    func actualLaMaInferenceRemovesSyntheticObjectLocally() async throws {
        let url=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["UNTITLED_INPAINTING_MODEL"]))
        let context=try CaptureImage.context(width:240,height:160)
        context.setFillColor(NSColor(white:0.92,alpha:1).cgColor);context.fill(CGRect(x:0,y:0,width:240,height:160))
        let mask=CGRect(x:70,y:35,width:40,height:30)
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:mask.minX,y:160-mask.maxY,width:mask.width,height:mask.height))
        let source=try #require(context.makeImage())
        let result=try await CaptureInpaintingEngine().repair(source,rect:mask,compiledURL:url)
        let output=NSBitmapImageRep(cgImage:result),input=NSBitmapImageRep(cgImage:source)
        let repaired=try #require(output.colorAt(x:90,y:50))
        #expect(repaired.greenComponent>0.8)
        #expect(repaired.blueComponent>0.8)
        #expect(abs(repaired.redComponent-repaired.greenComponent)<0.05)
        #expect(output.colorAt(x:10,y:10)==input.colorAt(x:10,y:10))
        #expect(result.width==240);#expect(result.height==160)
        try CaptureImage.png(result).write(to:URL(fileURLWithPath:"/tmp/untitled-lama-validation/result.png"))
    }
    private func image(width:Int,height:Int,color:NSColor) throws -> CGImage {
        let context=try CaptureImage.context(width:width,height:height)
        context.setFillColor(color.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
        return try #require(context.makeImage())
    }
}
