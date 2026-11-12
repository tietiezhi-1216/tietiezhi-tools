import Foundation
import CoreGraphics

enum CaptureWebP {
    static var encoder: URL? {
        var candidates: [URL?] = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/img2webp"), Bundle.main.url(forResource: "img2webp", withExtension: nil)]
        #if DEBUG
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/helpers/img2webp"))
        #endif
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func write(_ image: CGImage, to destination: URL) throws {
        guard let encoder else { throw PluginError.invalid("当前构建缺少 WebP 编码组件，请重新安装完整应用。") }
        guard image.width <= 16383, image.height <= 16383 else { throw PluginError.invalid("WebP 的宽高不能超过 16383 像素，请使用 PNG 或 TIFF。") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input.png"), output = temp.appendingPathComponent("output.webp")
        try CaptureImage.png(image).write(to: input, options: .atomic)
        let process = Process(), errors = Pipe()
        process.executableURL = encoder
        process.arguments = ["-lossy", "-q", String(Int(min(1, max(0.1, CaptureOutputPreferences.quality)) * 100)), input.path, "-o", output.path]
        process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PluginError.invalid("WebP 编码失败，请尝试 PNG 格式。") }
        try Data(contentsOf: output).write(to: destination, options: .atomic)
    }
}
