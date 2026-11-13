import AppKit
import CoreImage
import CoreML
import CoreVideo

/// LaMa's image/mask contract is fixed at 800 × 800. Inference runs on this
/// actor's executor; only the masked pixels are composited into the source.
actor CaptureInpaintingEngine {
    static let shared=CaptureInpaintingEngine()
    private var model:MLModel?
    private var loadedURL:URL?
    private let context=CIContext(options:[.cacheIntermediates:false])
    func unload() { model=nil;loadedURL=nil }
    nonisolated static func validate(_ model:MLModel) throws {
        let inputs=model.modelDescription.inputDescriptionsByName
        let outputs=model.modelDescription.outputDescriptionsByName
        guard let image=inputs["image"]?.imageConstraint,let mask=inputs["mask"]?.imageConstraint,
              let output=outputs["output"]?.imageConstraint,
              image.pixelsWide==800,image.pixelsHigh==800,image.pixelFormatType==kCVPixelFormatType_32BGRA,
              mask.pixelsWide==800,mask.pixelsHigh==800,mask.pixelFormatType==kCVPixelFormatType_OneComponent8,
              output.pixelsWide==800,output.pixelsHigh==800 else { throw PluginError.invalid("本地修复模型的图像格式不匹配。") }
    }
    func repair(_ image:CGImage,rect:CGRect,compiledURL:URL = CaptureInpaintingModel.compiledURL) throws -> CGImage {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath:compiledURL.path) else { throw PluginError.invalid("请先在截图设置中下载本地智能擦除模型。") }
        let bounds=CGRect(x:0,y:0,width:image.width,height:image.height)
        let mask=rect.integral.intersection(bounds)
        guard !mask.isNull,mask.width>=2,mask.height>=2 else { throw PluginError.invalid("请选择需要修复的图像区域。") }
        let crop=Self.contextRegion(mask:mask,imageBounds:bounds)
        guard let source=image.cropping(to:crop) else { throw PluginError.invalid("无法读取修复区域。") }
        if model==nil || loadedURL != compiledURL {
            let configuration=MLModelConfiguration();configuration.computeUnits = .all
            let loaded=try MLModel(contentsOf:compiledURL,configuration:configuration)
            try Self.validate(loaded);model=loaded;loadedURL=compiledURL
        }
        guard let model else { throw PluginError.invalid("无法载入本地修复模型。") }
        let input=try Self.imageBuffer(source)
        // Include a narrow guard band so resampling cannot leak object colors
        // from an antialiased mask edge into LaMa's surrounding context.
        let inferenceMask=mask.insetBy(dx:-3,dy:-3).intersection(crop)
        let relative=inferenceMask.offsetBy(dx:-crop.minX,dy:-crop.minY)
        let maskInput=try Self.maskBuffer(mask:relative,cropSize:crop.size)
        let provider=try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(pixelBuffer:input),"mask":MLFeatureValue(pixelBuffer:maskInput)])
        let prediction=try model.prediction(from:provider)
        try Task.checkCancellation()
        guard let buffer=prediction.featureValue(for:"output")?.imageBufferValue else { throw PluginError.invalid("修复模型未返回图像。") }
        let result=CIImage(cvPixelBuffer:buffer)
        guard let output=context.createCGImage(result,from:result.extent) else { throw PluginError.invalid("无法读取修复后的图像。") }
        return try Self.composite(image,patch:output,crop:crop,mask:mask)
    }
    nonisolated static func contextRegion(mask:CGRect,imageBounds:CGRect) -> CGRect {
        let margin=max(32,max(mask.width,mask.height)*0.7)
        return mask.insetBy(dx:-margin,dy:-margin).integral.intersection(imageBounds)
    }
    nonisolated static func imageBuffer(_ image:CGImage) throws -> CVPixelBuffer {
        let buffer=try buffer(format:kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer,[]);defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        guard let address=CVPixelBufferGetBaseAddress(buffer),let cg=CGContext(data:address,width:800,height:800,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw PluginError.invalid("无法准备模型图像。") }
        cg.interpolationQuality = .high;cg.draw(image,in:CGRect(x:0,y:0,width:800,height:800));return buffer
    }
    nonisolated static func maskBuffer(mask:CGRect,cropSize:CGSize) throws -> CVPixelBuffer {
        let buffer=try buffer(format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(buffer,[]);defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        guard let address=CVPixelBufferGetBaseAddress(buffer),let cg=CGContext(data:address,width:800,height:800,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { throw PluginError.invalid("无法准备模型遮罩。") }
        cg.setFillColor(gray:0,alpha:1);cg.fill(CGRect(x:0,y:0,width:800,height:800))
        let rect=CGRect(x:mask.minX/cropSize.width*800,y:(cropSize.height-mask.maxY)/cropSize.height*800,width:mask.width/cropSize.width*800,height:mask.height/cropSize.height*800)
        cg.setShouldAntialias(false);cg.setFillColor(gray:1,alpha:1);cg.fill(rect.integral)
        return buffer
    }
    nonisolated private static func buffer(format:OSType) throws -> CVPixelBuffer {
        var buffer:CVPixelBuffer?
        let attributes=[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary
        guard CVPixelBufferCreate(nil,800,800,format,attributes,&buffer)==kCVReturnSuccess,let buffer else { throw PluginError.invalid("无法创建模型图像缓冲区。") };return buffer
    }
    nonisolated static func composite(_ image:CGImage,patch:CGImage,crop:CGRect,mask:CGRect) throws -> CGImage {
        let context=try CaptureImage.context(width:image.width,height:image.height,colorSpace:image.colorSpace)
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let height=CGFloat(image.height)
        context.clip(to:CGRect(x:mask.minX,y:height-mask.maxY,width:mask.width,height:mask.height))
        context.interpolationQuality = .high
        context.draw(patch,in:CGRect(x:crop.minX,y:height-crop.maxY,width:crop.width,height:crop.height))
        guard let result=context.makeImage() else { throw PluginError.invalid("无法合成修复图像。") };return result
    }
}
