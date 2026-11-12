import AppKit

struct CaptureScrollSegment:Codable,Sendable,Equatable {
    var filename:String
    var captureNumber:Int
    var origin:Int
    var width:Int
    var height:Int
    var overlapBeforePixels:Int=0
    var gapBeforePixels:Int=0
}
struct CaptureScrollSegmentIndex:Codable,Sendable {
    var version=1
    var axis:String
    var direction:Int
    var segments:[CaptureScrollSegment]
    var containsActiveSegment:Bool
    var note="按文件名顺序查看；相邻分段保留重复区域，overlapBeforePixels 表示重叠像素。封存段不可回滚修改。"
}
enum CaptureScrollSegmentError:LocalizedError {
    case sealedBoundary
    var errorDescription:String? { "已回到封存分段边界。先暂停并返回最后成功画面，再继续沿原方向滚动；之前分段保持不变。" }
}

/// Only the active stitched raster is retained in memory. Closed segments are PNG files on disk.
struct SegmentedScrollCapture {
    private(set) var stitcher:ImageStitcher
    private(set) var segments:[CaptureScrollSegment]=[]
    private(set) var origin=0
    private(set) var direction=0
    private var boundary:Int?
    let directory:URL
    var isSegmented:Bool { !segments.isEmpty }
    var image:CGImage { stitcher.image }
    var viewport:CGRect { stitcher.viewport }
    var axis:StitchAxis { stitcher.axis }
    static var recoveryDirectory:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("app.untitled/Capture/LongCaptures",isDirectory:true)
    }
    init(image:CGImage,axis:StitchAxis,pixelLimit:Int=CaptureImage.maximumPixels,directory:URL?=nil) {
        stitcher=ImageStitcher(image:image,axis:axis,pixelLimit:pixelLimit)
        self.directory=directory ?? Self.recoveryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    }
    mutating func append(_ next:CGImage,trimOnReverse:Bool=false) throws -> Bool {
        guard next.width==stitcher.lastFrame.width,next.height==stitcher.lastFrame.height else { throw PluginError.invalid("截图区域的分辨率已变化，请重新开始。") }
        guard let shift=ImageStitcher.displacement(stitcher.lastFrame,next,axis:axis),shift != 0 else { return false }
        let frameOffset=axis == .vertical ? Int(viewport.minY):Int(viewport.minX)
        let nextOrigin=origin+frameOffset+shift
        if let boundary,(direction>0 && nextOrigin<boundary || direction<0 && nextOrigin>boundary) { throw CaptureScrollSegmentError.sealedBoundary }
        var trial=stitcher
        do {
            let changed=try trial.append(next,trimOnReverse:trimOnReverse)
            origin += trial.imageOrigin-stitcher.imageOrigin;stitcher=trial;return changed
        } catch ImageStitcherCapacity.exceeded {
            // The whole previous viewport is kept as overlap whenever two frames fit in the budget.
            var following=ImageStitcher(image:stitcher.lastFrame,axis:axis,pixelLimit:stitcher.pixelLimit)
            var followingOrigin=origin+frameOffset
            do { _ = try following.append(next);followingOrigin += following.imageOrigin }
            catch ImageStitcherCapacity.exceeded {
                // A huge viewport may itself consume most of the budget. Matching already proves
                // that the two full frames overlap, so retain the next frame without allocating both.
                following=ImageStitcher(image:next,axis:axis,pixelLimit:stitcher.pixelLimit);followingOrigin=nextOrigin
            }
            let nextDirection=direction==0 ? (shift>0 ? 1:-1):direction
            let descriptor=CaptureScrollSegment(filename:String(format:"segment-%05d.png",segments.count+1),captureNumber:segments.count+1,origin:origin,width:image.width,height:image.height)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try CaptureImage.png(image).write(to:directory.appendingPathComponent(descriptor.filename),options:.atomic)
            // Both sides of a seam are committed before dropping the prior raster. On disk-full,
            // no in-memory state advances and the previous image remains exportable.
            let active=CaptureScrollSegment(filename:"active-"+UUID().uuidString+".png",captureNumber:segments.count+2,origin:followingOrigin,width:following.image.width,height:following.image.height)
            try CaptureImage.png(following.image).write(to:directory.appendingPathComponent(active.filename),options:.atomic)
            try writeIndex(segments+[descriptor,active],direction:nextDirection,active:true)
            segments.append(descriptor);direction=nextDirection;boundary=origin+frameOffset
            origin=followingOrigin;stitcher=following
            return true
        }
    }
    func croppedImage(start:Double=0,end:Double=1) -> (CGImage,Int) {
        let a=max(0,min(0.99,start)),b=min(1,max(a+0.01,end))
        let rect=axis == .vertical
            ? CGRect(x:0,y:Double(image.height)*a,width:Double(image.width),height:Double(image.height)*(b-a))
            : CGRect(x:Double(image.width)*a,y:0,width:Double(image.width)*(b-a),height:Double(image.height))
        let bounded=rect.integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        return (image.cropping(to:bounded) ?? image,axis == .vertical ? Int(bounded.minY):Int(bounded.minX))
    }
    @discardableResult func checkpoint(start:Double=0,end:Double=1) throws -> [CaptureScrollSegment] {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let (raster,offset)=croppedImage(start:start,end:end)
        let filename="active-"+UUID().uuidString+".png"
        try CaptureImage.png(raster).write(to:directory.appendingPathComponent(filename),options:.atomic)
        let active=CaptureScrollSegment(filename:filename,captureNumber:segments.count+1,origin:origin+offset,width:raster.width,height:raster.height)
        let all=segments+[active];try writeIndex(all,direction:direction,active:true);return all
    }
    /// Copies files one at a time, then atomically presents the complete export directory.
    /// It never replaces the user-selected directory or an existing export.
    func export(to parent:URL,start:Double=0,end:Double=1) throws -> URL {
        let all=try checkpoint(start:start,end:end)
        let scope=parent.startAccessingSecurityScopedResource();defer { if scope { parent.stopAccessingSecurityScopedResource() } }
        let final=parent.appendingPathComponent("长截图-"+String(UUID().uuidString.prefix(8)),isDirectory:true)
        let staging=parent.appendingPathComponent(".长截图-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:staging) }
        var ordered=Self.ordered(all,axis:axis)
        for index in ordered.indices {
            let original=ordered[index].filename
            ordered[index].filename=String(format:"%04d.png",index+1)
            try FileManager.default.copyItem(at:directory.appendingPathComponent(original),to:staging.appendingPathComponent(ordered[index].filename))
        }
        let manifest=CaptureScrollSegmentIndex(axis:axis.rawValue,direction:direction,segments:ordered,containsActiveSegment:false)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(manifest).write(to:staging.appendingPathComponent("segments.json"),options:.atomic)
        let explanation="""
        滚动长截图 · \(axis.title) · \(ordered.count) 段
        按 0001.png、0002.png 等文件名顺序查看，顺序为上到下或左到右。
        为避免接缝丢失内容，相邻段包含重复区域；segments.json 记录每段原始坐标与重叠像素。
        crop 裁剪只影响最后正在捕获的一段；如裁剪造成间隔，gapBeforePixels 会记录间隔大小。
        封存的分段不会被回滚裁剪。此导出不会把全部图片重新合并进内存。
        """
        try Data(explanation.utf8).write(to:staging.appendingPathComponent("阅读顺序.txt"),options:.atomic)
        try FileManager.default.moveItem(at:staging,to:final)
        return final
    }
    static func ordered(_ values:[CaptureScrollSegment],axis:StitchAxis) -> [CaptureScrollSegment] {
        var values=values.sorted { ($0.origin,$0.captureNumber)<($1.origin,$1.captureNumber) }
        var high:Int?
        for index in values.indices {
            let length=axis == .vertical ? values[index].height:values[index].width
            if let high {
                values[index].overlapBeforePixels=max(0,min(length,high-values[index].origin))
                values[index].gapBeforePixels=max(0,values[index].origin-high)
            }
            high=max(high ?? values[index].origin,values[index].origin+length)
        }
        return values
    }
    private func writeIndex(_ all:[CaptureScrollSegment],direction:Int,active:Bool) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(CaptureScrollSegmentIndex(axis:axis.rawValue,direction:direction,segments:Self.ordered(all,axis:axis),containsActiveSegment:active))
        try data.write(to:directory.appendingPathComponent("segments.json"),options:.atomic)
        let retained=Set(all.map(\.filename))
        for file in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where file.lastPathComponent.hasPrefix("active-") && file.pathExtension=="png" && !retained.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at:file)
        }
    }
}
