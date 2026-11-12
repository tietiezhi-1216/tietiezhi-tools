import AppKit
import ImageIO

/// A single atomic sidecar keeps source pixels and editable marks together.
struct CaptureEditableArchive: Codable {
    let version: Int
    let source: Data
    let marks: [CaptureMark]
    static func url(for rendered:URL)->URL { rendered.deletingPathExtension().appendingPathExtension("editing") }
    @MainActor static func save(_ document:CaptureDocument, for rendered:URL) throws {
        let file=url(for:rendered)
        guard !document.marks.isEmpty else {
            if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
            return
        }
        let archive=CaptureEditableArchive(version:1,source:try CaptureImage.png(document.unmarkedImage),marks:document.marks)
        let encoder=PropertyListEncoder();encoder.outputFormat = .binary
        try encoder.encode(archive).write(to:file,options:.atomic)
    }
    @MainActor static func restore(_ document:CaptureDocument, for rendered:URL) throws {
        let file=url(for:rendered)
        guard FileManager.default.fileExists(atPath:file.path) else { return }
        let size=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size<=512*1024*1024 else { throw PluginError.invalid("可编辑标注文件过大。") }
        let archive=try PropertyListDecoder().decode(Self.self,from:Data(contentsOf:file,options:.mappedIfSafe))
        guard archive.version==1,archive.marks.count<=10_000,Set(archive.marks.map(\.id)).count==archive.marks.count,
              let source=CGImageSourceCreateWithData(archive.source as CFData,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=CaptureImage.maximumPixels/height,
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw PluginError.invalid("可编辑标注文件无效。") }
        try document.restoreAnnotations(base:image,marks:archive.marks)
    }
    static func trash(for rendered:URL) throws {
        let file=url(for:rendered)
        if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.trashItem(at:file,resultingItemURL:nil) }
    }
}
