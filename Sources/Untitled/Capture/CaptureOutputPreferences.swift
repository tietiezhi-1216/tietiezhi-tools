import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import CryptoKit

enum CaptureOutputPreferences {
    static var directory: URL {
        let path = UserDefaults.standard.string(forKey: "capture.saveDirectory") ?? ""
        if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent(HostInfo.name, isDirectory: true)
    }
    static var format: String { UserDefaults.standard.string(forKey: "capture.saveFormat") ?? "png" }
    static var quality: Double { UserDefaults.standard.object(forKey: "capture.saveQuality") as? Double ?? 0.95 }
    static var supportedFormats: [String] {
        let types = CGImageDestinationCopyTypeIdentifiers() as! [String]
        return ["png", "jpg", "tiff", "bmp", "heic", "webp", "avif"].filter { ext in
            (ext == "webp" && CaptureWebP.encoder != nil) || (UTType(filenameExtension: ext).map { types.contains($0.identifier) } ?? false)
        }
    }
    static func filename(width: Int, height: Int, date: Date = Date(), template: String? = nil) -> String {
        var value = template ?? UserDefaults.standard.string(forKey: "capture.saveTemplate") ?? "截图_{date}_{time}"
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        value = value.replacingOccurrences(of: "{date}", with: formatter.string(from: date))
        formatter.dateFormat = "HH-mm-ss"
        value = value.replacingOccurrences(of: "{time}", with: formatter.string(from: date))
            .replacingOccurrences(of: "{width}", with: String(width)).replacingOccurrences(of: "{height}", with: String(height))
            .replacingOccurrences(of: "{uuid}", with: UUID().uuidString)
        value = value.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r")).joined(separator: "_")
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "截图" : String(value.prefix(180))
    }
    static func save(_ image: CGImage, folder: URL? = nil) throws -> URL {
        let folder = folder ?? directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = filename(width: image.width, height: image.height)
        var destination = folder.appendingPathComponent(base).appendingPathExtension(format)
        var index = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(base + "_\(index)").appendingPathExtension(format); index += 1
        }
        try CaptureImage.write(image, to: destination)
        trackExport(destination)
        return destination
    }
    private struct ExportRecord: Codable { let name: String; let date: Date; let sha256: String? }
    private static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func trackExport(_ destination: URL) {
        let folder = destination.deletingLastPathComponent()
        IdentityMigration.prepareExportIndex(in: folder)
        let index = folder.appendingPathComponent(".untitled-exports.json")
        var records = (try? Data(contentsOf: index)).flatMap { try? JSONDecoder().decode([ExportRecord].self, from: $0) } ?? []
        records.append(ExportRecord(name: destination.lastPathComponent, date: Date(), sha256: digest(destination)))
        let days = UserDefaults.standard.integer(forKey: "capture.exportRetentionDays")
        if days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            records.removeAll { record in
                guard record.date < cutoff, record.name == URL(fileURLWithPath: record.name).lastPathComponent else { return false }
                let file = folder.appendingPathComponent(record.name)
                guard FileManager.default.fileExists(atPath: file.path) else { return true }
                // Keep files subsequently edited or replaced by the user.
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]), values.isSymbolicLink != true,
                      let modified = values.contentModificationDate, modified <= record.date.addingTimeInterval(5),
                      let expected = record.sha256, digest(file) == expected else { return false }
                do { try FileManager.default.trashItem(at: file, resultingItemURL: nil); return true } catch { return false }
            }
        }
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: index, options: .atomic) }
    }
}

struct CaptureOutputSettingsView: View {
    @AppStorage("capture.saveDirectory") private var directory = ""
    @AppStorage("capture.saveTemplate") private var template = "截图_{date}_{time}"
    @AppStorage("capture.saveFormat") private var format = "png"
    @AppStorage("capture.saveQuality") private var quality = 0.95
    @AppStorage("capture.autoSaveCopy") private var saveCopy = false
    @AppStorage("capture.autoSavePin") private var savePin = false
    @AppStorage("capture.numberGlobal") private var numberGlobal = false
    @AppStorage("capture.exportRetentionDays") private var retention = 0
    var body: some View {
        Section("保存") {
            HStack { Text(CaptureOutputPreferences.directory.path).lineLimit(1).truncationMode(.middle); Spacer(); Button("选择文件夹") { chooseFolder() } }
            TextField("文件名", text: $template)
            Text("{date} 日期 · {time} 时间 · {width}/{height} 尺寸 · {uuid} 唯一编号").font(.caption).foregroundStyle(.secondary)
            Picker("快速保存格式", selection: $format) { ForEach(CaptureOutputPreferences.supportedFormats, id: \.self) { Text($0.uppercased()).tag($0) } }
            Slider(value: $quality, in: 0.1...1) { Text("有损格式质量") }
            Toggle("复制截图时自动保存文件", isOn: $saveCopy)
            Toggle("创建图像贴图时自动保存文件", isOn: $savePin)
            Picker("旧导出文件", selection: $retention) {
                Text("一直保留").tag(0)
                ForEach([7,30,90,365], id: \.self) { Text("\($0) 天后移到废纸篓").tag($0) }
            }
            Text("仅管理本应用记录的导出文件；修改过的文件会保留。").font(.caption).foregroundStyle(.secondary)
        }
        Section("标注") {
            Toggle("序号在多张截图间连续计数", isOn: $numberGlobal)
            Button("重置全局序号") {
                for format in CaptureNumberFormat.allCases { UserDefaults.standard.removeObject(forKey: "capture.numberGlobal.\(format.rawValue)") }
            }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.directoryURL = CaptureOutputPreferences.directory
        panel.begin { response in if response == .OK, let url = panel.url { directory = url.path } }
    }
}
