import AppKit
import Testing
@testable import Untitled

struct CaptureScrollSegmentTests {
    @Test func segmentsKeepPixelContentAndOrderedOverlapsInBothDirections() throws {
        for axis in StitchAxis.allCases {
            for backwards in [false,true] {
                let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
                let source=pattern(axis:axis),start=backwards ? 650:0
                var capture=SegmentedScrollCapture(image:crop(source,at:start,axis:axis),axis:axis,pixelLimit:180*570,directory:root.appendingPathComponent("recovery"))
                let positions=backwards ? [520,390,260,130,0]:[130,260,390,520,650]
                for position in positions {
                    #expect(try capture.append(crop(source,at:position,axis:axis)))
                    #expect(capture.image.width*capture.image.height<=180*570)
                }
                #expect(capture.segments.count==2)
                let exported=try capture.export(to:root)
                let manifest=try JSONDecoder().decode(CaptureScrollSegmentIndex.self,from:Data(contentsOf:exported.appendingPathComponent("segments.json")))
                #expect(!manifest.containsActiveSegment)
                #expect(manifest.direction==(backwards ? -1:1))
                #expect(manifest.segments.count==3)
                #expect(manifest.segments.first?.origin==(-start))
                #expect(manifest.segments.last.map { $0.origin+(axis == .vertical ? $0.height:$0.width) }==950-start)
                let expected=NSBitmapImageRep(cgImage:source)
                for (index,segment) in manifest.segments.enumerated() {
                    #expect(segment.filename==String(format:"%04d.png",index+1))
                    #expect(segment.gapBeforePixels==0)
                    if index>0 { #expect(segment.overlapBeforePixels>=300) }
                    let decoded=try CaptureImage.load(exported.appendingPathComponent(segment.filename))
                    let output=NSBitmapImageRep(cgImage:decoded),length=axis == .vertical ? decoded.height:decoded.width
                    for along in stride(from:10,to:length-10,by:37) {
                        let x=axis == .vertical ? 80:along,y=axis == .vertical ? along:80
                        let sourceX=axis == .vertical ? x:x+segment.origin+start,sourceY=axis == .vertical ? y+segment.origin+start:y
                        let actualColor=try #require(output.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))
                        let expectedColor=try #require(expected.colorAt(x:sourceX,y:sourceY)?.usingColorSpace(.sRGB))
                        #expect(abs(actualColor.redComponent-expectedColor.redComponent)<0.005)
                        #expect(abs(actualColor.greenComponent-expectedColor.greenComponent)<0.005)
                        #expect(abs(actualColor.blueComponent-expectedColor.blueComponent)<0.005)
                    }
                }
                #expect(FileManager.default.fileExists(atPath:exported.appendingPathComponent("阅读顺序.txt").path))
                #expect(FileManager.default.fileExists(atPath:capture.directory.appendingPathComponent("segments.json").path))
            }
        }
    }

    @Test func rollbackStopsAtSealedBoundaryWithoutChangingFilesOrActiveImage() throws {
        for axis in StitchAxis.allCases {
            for backwards in [false,true] {
                let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
                let source=pattern(axis:axis),start=backwards ? 650:0,sign=backwards ? -1:1
                var capture=SegmentedScrollCapture(image:crop(source,at:start,axis:axis),axis:axis,pixelLimit:180*570,directory:root)
                for step in 1...3 { _ = try capture.append(crop(source,at:start+step*130*sign,axis:axis)) }
                let indexData=try Data(contentsOf:root.appendingPathComponent("segments.json"))
                _ = try capture.append(crop(source,at:start+260*sign,axis:axis),trimOnReverse:true)
                let before=try CaptureImage.png(capture.image),origin=capture.origin
                #expect(throws:CaptureScrollSegmentError.self) {
                    _ = try capture.append(crop(source,at:start+130*sign,axis:axis),trimOnReverse:true)
                }
                #expect(capture.origin==origin)
                #expect(try CaptureImage.png(capture.image)==before)
                #expect(try Data(contentsOf:root.appendingPathComponent("segments.json"))==indexData)
                #expect(try capture.append(crop(source,at:start+390*sign,axis:axis)))
            }
        }
    }

    @Test func hugeViewportRollsWithoutAllocatingTwoFullFrames() throws {
        let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let source=pattern(axis:.vertical)
        var capture=SegmentedScrollCapture(image:crop(source,at:0,axis:.vertical),axis:.vertical,pixelLimit:180*300,directory:root)
        #expect(try capture.append(crop(source,at:130,axis:.vertical)))
        #expect(capture.image.height==300)
        let all=SegmentedScrollCapture.ordered(try capture.checkpoint(),axis:.vertical)
        #expect(all.count==2 && all[1].origin==130 && all[1].overlapBeforePixels==170)
    }

    @Test func diskFailureDoesNotAdvanceStateAndCheckpointRemovesOnlySupersededActiveFiles() throws {
        let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let source=pattern(axis:.vertical),blocked=root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to:blocked)
        var capture=SegmentedScrollCapture(image:crop(source,at:0,axis:.vertical),axis:.vertical,pixelLimit:180*430,directory:blocked)
        _ = try capture.append(crop(source,at:130,axis:.vertical))
        let before=try CaptureImage.png(capture.image)
        #expect(throws:(any Error).self) { _ = try capture.append(crop(source,at:260,axis:.vertical)) }
        #expect(capture.segments.isEmpty && capture.origin==0)
        #expect(try CaptureImage.png(capture.image)==before)
        try FileManager.default.removeItem(at:blocked)
        #expect(try capture.append(crop(source,at:260,axis:.vertical)))
        let first=try capture.checkpoint(),second=try capture.checkpoint()
        #expect(first.last?.filename != second.last?.filename)
        #expect(!FileManager.default.fileExists(atPath:blocked.appendingPathComponent(first.last!.filename).path))
        for segment in second { #expect(FileManager.default.fileExists(atPath:blocked.appendingPathComponent(segment.filename).path)) }
    }

    @Test func cropOffsetAndExportGapAreExplicit() throws {
        let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let source=pattern(axis:.vertical)
        var capture=SegmentedScrollCapture(image:crop(source,at:0,axis:.vertical),axis:.vertical,pixelLimit:180*430,directory:root)
        _ = try capture.append(crop(source,at:130,axis:.vertical))
        _ = try capture.append(crop(source,at:260,axis:.vertical))
        let all=SegmentedScrollCapture.ordered(try capture.checkpoint(start:0.9,end:1),axis:.vertical)
        #expect(all[1].origin==517 && all[1].height==43)
        #expect(all[1].gapBeforePixels==87)
        #expect(all[0].height==430)
    }

    private func temporary() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("CaptureScrollTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    private func crop(_ image:CGImage,at position:Int,axis:StitchAxis) -> CGImage {
        image.cropping(to:axis == .vertical ? CGRect(x:0,y:position,width:180,height:300):CGRect(x:position,y:0,width:300,height:180))!
    }
    private func pattern(axis:StitchAxis) -> CGImage {
        let width=axis == .vertical ? 180:1000,height=axis == .vertical ? 1000:180
        var bytes=[UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let i=(y*width+x)*4,value=UInt64(x/5)&*73_856_093 ^ UInt64(y/7)&*19_349_663
            bytes[i]=UInt8(truncatingIfNeeded:value);bytes[i+1]=UInt8(truncatingIfNeeded:value>>8);bytes[i+2]=UInt8(truncatingIfNeeded:value>>16)
        } }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
}
