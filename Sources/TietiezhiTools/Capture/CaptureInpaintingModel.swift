import AppKit
import CoreML
import CryptoKit
import SwiftUI

enum CaptureInpaintingModel {
    static let version="lama-b57b8451"
    static let archiveBytes=196_237_256
    static let archiveSHA256="b57b8451a1a86c00aea52d75230fb5f49d3076eec67403192758c9d2b59c0e69"
    static let downloadURL=URL(string:"https://huggingface.co/mlboydaisuke/coreml-zoo/resolve/a3d12de43e1b6131cd05cdd9027e0c4978d436e5/lama/LaMa.mlpackage.zip")!
    static let attribution="""
    LaMa — Resolution-robust Large Mask Inpainting with Fourier Convolutions.
    Roman Suvorov et al. (2021/2022), https://github.com/advimman/lama
    Core ML conversion: Daisuke Majima (john-rocky).
    https://huggingface.co/mlboydaisuke/LaMa-CoreML
    Apache-2.0. Original model weights and conversion are unmodified.
    Archive revision: a3d12de43e1b6131cd05cdd9027e0c4978d436e5.
    SHA-256: b57b8451a1a86c00aea52d75230fb5f49d3076eec67403192758c9d2b59c0e69
    """
    static var directory:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("com.tietiezhi.tools/Capture/Models/\(version)",isDirectory:true)
    }
    static var compiledURL:URL { directory.appendingPathComponent("LaMa.mlmodelc",isDirectory:true) }
    static var installed:Bool {
        FileManager.default.fileExists(atPath:compiledURL.appendingPathComponent("coremldata.bin").path)
        && (try? String(contentsOf:directory.appendingPathComponent("sha256"),encoding:.utf8))==archiveSHA256
    }
    static func verifyArchive(_ url:URL) throws {
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize
        guard size==archiveBytes else { throw PluginError.invalid("模型下载不完整，请重新下载。") }
        let handle=try FileHandle(forReadingFrom:url);defer { try? handle.close() }
        var hasher=SHA256()
        while let bytes=try handle.read(upToCount:1024*1024),!bytes.isEmpty {
            try Task.checkCancellation();hasher.update(data:bytes)
        }
        let actual=hasher.finalize().map { String(format:"%02x",$0) }.joined()
        guard actual==archiveSHA256 else { throw PluginError.invalid("模型校验失败，已取消安装。") }
    }
    /// Only the immutable, hash-verified archive is extracted. User-selected ZIPs
    /// and arbitrary download URLs are deliberately not accepted by this installer.
    static func prepareVerifiedArchive(_ url:URL,at staging:URL) throws -> URL {
        try verifyArchive(url);try Task.checkCancellation()
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["-x","-k",url.path,staging.path]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit();try Task.checkCancellation()
        let package=staging.appendingPathComponent("LaMa.mlpackage",isDirectory:true)
        guard process.terminationStatus==0,FileManager.default.fileExists(atPath:package.appendingPathComponent("Manifest.json").path) else { throw PluginError.invalid("无法解压本地修复模型。") }
        return package
    }
}

@MainActor final class CaptureInpaintingModelManager:ObservableObject {
    static let shared=CaptureInpaintingModelManager()
    @Published private(set) var installed=CaptureInpaintingModel.installed
    @Published private(set) var busy=false
    @Published private(set) var status=""
    private var task:Task<Void,Never>?
    func download() {
        guard !busy else { return };busy=true;status="正在下载 LaMa（187 MiB）"
        task=Task { [weak self] in
            guard let self else { return }
            let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("Tietiezhi-LaMa-\(UUID())",isDirectory:true)
            defer { try? FileManager.default.removeItem(at:scratch);busy=false;task=nil;installed=CaptureInpaintingModel.installed }
            do {
                try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
                let request=URLRequest(url:CaptureInpaintingModel.downloadURL,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:300)
                let (download,response)=try await URLSession.shared.download(for:request)
                guard let http=response as? HTTPURLResponse,http.statusCode==200 else { throw PluginError.invalid("模型下载失败，请稍后重试。") }
                let archive=scratch.appendingPathComponent("model.zip");try FileManager.default.moveItem(at:download,to:archive)
                status="正在校验并编译本地模型"
                let package=try await Task.detached { try CaptureInpaintingModel.prepareVerifiedArchive(archive,at:scratch.appendingPathComponent("source")) }.value
                try Task.checkCancellation()
                let compiled=try await MLModel.compileModel(at:package)
                try await Task.detached {
                    let config=MLModelConfiguration();config.computeUnits = .all
                    let model=try MLModel(contentsOf:compiled,configuration:config)
                    try CaptureInpaintingEngine.validate(model)
                }.value
                try Task.checkCancellation()
                let ready=scratch.appendingPathComponent("ready",isDirectory:true)
                try FileManager.default.createDirectory(at:ready,withIntermediateDirectories:true)
                try FileManager.default.copyItem(at:compiled,to:ready.appendingPathComponent("LaMa.mlmodelc"))
                try CaptureInpaintingLicense.text.write(to:ready.appendingPathComponent("LICENSE"),atomically:true,encoding:.utf8)
                try CaptureInpaintingModel.attribution.write(to:ready.appendingPathComponent("NOTICE"),atomically:true,encoding:.utf8)
                try CaptureInpaintingModel.archiveSHA256.write(to:ready.appendingPathComponent("sha256"),atomically:true,encoding:.utf8)
                let destination=CaptureInpaintingModel.directory
                try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                if FileManager.default.fileExists(atPath:destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination,withItemAt:ready)
                } else { try FileManager.default.moveItem(at:ready,to:destination) }
                await CaptureInpaintingEngine.shared.unload();status="已安装 · 图像修复完全在本机执行"
            } catch is CancellationError { status="已取消下载" }
            catch let error as URLError where error.code == .cancelled { status="已取消下载" }
            catch { status=error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
    func remove() {
        guard !busy else { return };busy=true
        Task { [weak self] in
            guard let self else { return };defer { busy=false;installed=CaptureInpaintingModel.installed }
            await CaptureInpaintingEngine.shared.unload()
            do { if FileManager.default.fileExists(atPath:CaptureInpaintingModel.directory.path) { try FileManager.default.removeItem(at:CaptureInpaintingModel.directory) };status="已移除本地模型" }
            catch { status=error.localizedDescription }
        }
    }
}

struct CaptureInpaintingSettingsView:View {
    @ObservedObject private var manager=CaptureInpaintingModelManager.shared
    @ViewState private var showLicense=false
    var body:some View {
        Section("本地智能擦除") {
            HStack {
                VStack(alignment:.leading,spacing:4) { Text("LaMa 图像修复模型");Text(manager.installed ? "已安装 · 本地 Core ML 推理":"可选下载 187 MiB · 不上传图片").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if manager.busy { ProgressView().controlSize(.small);Button("取消") { manager.cancel() } }
                else if manager.installed { Button("移除模型",role:.destructive) { manager.remove() } }
                else { Button("下载模型（187 MiB）") { manager.download() } }
            }
            if !manager.status.isEmpty { Text(manager.status).font(.caption).foregroundStyle(.secondary) }
            HStack { Link("模型来源",destination:URL(string:"https://huggingface.co/mlboydaisuke/LaMa-CoreML")!);Button("Apache-2.0 许可") { showLicense=true }.buttonStyle(.link) }
        }.sheet(isPresented:$showLicense) {
            VStack(alignment:.leading) {
                ScrollView { Text(CaptureInpaintingModel.attribution+"\n\n"+CaptureInpaintingLicense.text).textSelection(.enabled).font(.system(size:11,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading) }
                HStack { Spacer();Button("完成") { showLicense=false }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width:620,height:500)
        }
    }
}
