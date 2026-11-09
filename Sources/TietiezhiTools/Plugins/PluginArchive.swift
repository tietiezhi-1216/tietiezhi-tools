import CryptoKit
import Foundation

enum PluginArchive {
    static let maximumPackageSize = 2 * 1024 * 1024

    static func read(_ url: URL, expectedSHA256: String? = nil) throws -> PluginManifest {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maximumPackageSize else {
            throw PluginError.invalid("插件包超过 2 MB 限制。")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let expectedSHA256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expectedSHA256 else { throw PluginError.invalid("插件包校验失败，请重新下载。") }
        }
        // 只读取声明文件，不将 ZIP 解压到磁盘，也不加载包内代码。
        let listing = try output(arguments: ["-Z1", url.path], limit: 16_384)
        guard let names = String(data: listing, encoding: .utf8)?.split(separator: "\n").map(String.init),
              names.count == Set(names).count, names.contains("manifest.json"),
              names.allSatisfy({ ["manifest.json", "README.md", "LICENSE"].contains($0) }) else {
            throw PluginError.invalid("插件 ZIP 根目录只能包含 manifest.json、README.md 和 LICENSE。")
        }
        let manifestData = try output(arguments: ["-p", url.path, "manifest.json"], limit: 256 * 1024)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        try manifest.validate()
        return manifest
    }

    private static func output(arguments: [String], limit: Int) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var result = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                result.append(chunk)
                guard result.count <= limit else { throw PluginError.invalid("插件包内容超过大小限制。") }
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PluginError.invalid("无法读取 ZIP 插件包。") }
        return result
    }
}
