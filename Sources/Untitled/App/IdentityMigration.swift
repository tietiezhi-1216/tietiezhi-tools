import AppKit
import Foundation

/// Historical identifiers are import inputs only, never runtime aliases.
/// Moves assets without loading/copying model or media payloads; JSON is capped at 16 MiB.
enum IdentityMigration {
    static let legacyBundleID = "com.tietiezhi.tools"
    static let completionKey = "identityMigration.completed.v1"
    static let pluginIDs = [
        "com.tietiezhi.global-shortcuts": "com.untitled.global-shortcuts",
        "com.tietiezhi.screenshot": "com.untitled.screenshot",
        "com.tietiezhi.peripheral-sharing": "com.untitled.peripheral-sharing",
        "com.tietiezhi.doubao-speech-input": "com.untitled.doubao-speech-input",
    ]
    private static let maximumJSONBytes = 16 * 1024 * 1024

    static func legacyService(for service: String) -> String? {
        switch service {
        case HostInfo.bundleIdentifier + ".capture": legacyBundleID + ".capture"
        case HostInfo.bundleIdentifier + ".peripheral-sharing": legacyBundleID + ".peripheral-sharing"
        default: nil
        }
    }

    private static func isPublishedSource(_ url: URL) -> Bool {
        let parts = url.pathComponents
        return url.scheme == "https" && url.host == "github.com" && url.port == nil &&
            url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
            parts.count >= 3 && parts[1] == "tietiezhi-1216" && ["untitled", "tietiezhi-tools"].contains(parts[2])
    }

    static func manifest(_ value: PluginManifest) -> PluginManifest {
        guard let id = pluginIDs[value.id], isPublishedSource(value.repository) else { return value }
        return PluginManifest(schemaVersion: value.schemaVersion, id: id, name: value.name, version: value.version,
                              summary: value.summary, author: value.author, repository: value.repository,
                              minimumHostVersion: value.minimumHostVersion, actions: value.actions,
                              templates: value.templates, ui: value.ui, permissions: value.permissions)
    }

    /// Keep published URLs, versions and SHA-256 intact; only the installed identity changes.
    static func catalogEntry(_ value: CatalogEntry) -> CatalogEntry {
        guard let id = pluginIDs[value.id], isPublishedSource(value.downloadURL) else { return value }
        return CatalogEntry(id: id, name: value.name, version: value.version, summary: value.summary,
                            author: value.author, downloadURL: value.downloadURL, sha256: value.sha256)
    }

    @MainActor static func prepare() throws {
        let defaults = UserDefaults.standard
        guard NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).isEmpty else {
            throw PluginError.invalid("请先退出旧版本，再重新打开 Untitled；两个身份不能同时写入数据或配对信息。")
        }
        guard !defaults.bool(forKey: completionKey) else { return }
        let files = FileManager.default
        try migrate(applicationSupport: files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    caches: files.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                    pictures: files.urls(for: .picturesDirectory, in: .userDomainMask)[0], defaults: defaults,
                    legacyPreferences: defaults.persistentDomain(forName: legacyBundleID) ?? [:])
    }

    /// Injectable roots and defaults keep tests entirely outside real user data.
    static func migrate(applicationSupport: URL, caches: URL, pictures: URL, defaults: UserDefaults,
                        legacyPreferences: [String: Any]) throws {
        guard !defaults.bool(forKey: completionKey) else { return }
        let root = applicationSupport.appendingPathComponent(HostInfo.bundleIdentifier, isDirectory: true)
        let backups = root.appendingPathComponent("MigrationBackups", isDirectory: true)
        if exists(root) { try check(root) }
        if exists(backups) { try check(backups) }
        var remaining = 100_000
        try merge(applicationSupport.appendingPathComponent(legacyBundleID), into: root, backups: backups, remaining: &remaining)
        try merge(caches.appendingPathComponent(legacyBundleID), into: caches.appendingPathComponent(HostInfo.bundleIdentifier),
                  backups: backups, remaining: &remaining)
        try migratePlugins(in: root, backups: backups)
        for (key, value) in legacyPreferences where defaults.object(forKey: key) == nil &&
            (key == "appearance" || key.hasPrefix("capture.") || key.hasPrefix("sharing.")) && key != "sharing.sessionEnabled" {
            defaults.set(value, forKey: key)
        }
        // A new macOS identity must not resume control, capture or a network listener on launch.
        defaults.set(false, forKey: "sharing.sessionEnabled")
        let oldPictures = pictures.appendingPathComponent("Tietiezhi Tools", isDirectory: true)
        let newPictures = pictures.appendingPathComponent(HostInfo.name, isDirectory: true)
        try merge(oldPictures, into: newPictures, backups: backups, remaining: &remaining)
        if let path = defaults.string(forKey: "capture.saveDirectory"),
           path == oldPictures.path || path.hasPrefix(oldPictures.path + "/") {
            defaults.set(newPictures.path + String(path.dropFirst(oldPictures.path.count)), forKey: "capture.saveDirectory")
        }
        try migrateExportIndex(in: newPictures)
        defaults.set(true, forKey: completionKey)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func check(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw PluginError.invalid("迁移遇到符号链接，请检查数据目录后重试。") }
    }

    private static func archive(_ source: URL, in backups: URL) throws {
        let folder = backups.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
    }

    private static func merge(_ source: URL, into destination: URL, backups: URL, remaining: inout Int, depth: Int = 0) throws {
        guard exists(source) else { return }
        guard remaining > 0, depth < 64 else { throw PluginError.invalid("迁移数据量超出单次预算；原文件已保留，请整理后重试。") }
        remaining -= 1
        try check(source)
        let files = FileManager.default
        if !exists(destination) {
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: source, to: destination)
            return
        }
        try check(destination)
        let sourceDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let destinationDirectory = try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        guard sourceDirectory && destinationDirectory else { try archive(source, in: backups); return }
        // Streaming directory enumeration; never load media/model files into memory.
        guard let entries = files.enumerator(at: source, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants],
                                            errorHandler: { _, _ in false }) else {
            throw PluginError.invalid("无法读取迁移目录；请检查文件权限后重试。")
        }
        for case let entry as URL in entries {
            try merge(entry, into: destination.appendingPathComponent(entry.lastPathComponent), backups: backups,
                      remaining: &remaining, depth: depth + 1)
        }
        // removeItem only after proving the directory is empty (including hidden files).
        guard try files.contentsOfDirectory(atPath: source.path).isEmpty else {
            throw PluginError.invalid("部分文件未能迁移；原文件已保留，请检查权限后重试。")
        }
        try files.removeItem(at: source)
    }

    private static func json(at url: URL) throws -> Any {
        try check(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumJSONBytes else { throw PluginError.invalid("迁移配置超过 16 MiB；原文件已保留。") }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    private static func migratePlugins(in root: URL, backups: URL) throws {
        let plugins = root.appendingPathComponent("Plugins", isDirectory: true)
        for directory in [plugins, plugins.appendingPathComponent("Preferences")] where exists(directory) { try check(directory) }
        for (old, new) in pluginIDs.sorted(by: { $0.key < $1.key }) {
            let source = plugins.appendingPathComponent(old + ".json")
            if exists(source) {
                guard var record = try json(at: source) as? [String: Any],
                      var manifest = record["manifest"] as? [String: Any], manifest["id"] as? String == old,
                      let repository = manifest["repository"] as? String, let url = URL(string: repository), isPublishedSource(url) else {
                    throw PluginError.invalid("历史插件配置身份不一致；原文件已保留，请从备份恢复后重试。")
                }
                let destination = plugins.appendingPathComponent(new + ".json")
                if exists(destination) { try check(destination) }
                else {
                    manifest["id"] = new; record["manifest"] = manifest
                    try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: destination, options: .atomic)
                }
                try archive(source, in: backups)
            }
            let preference = plugins.appendingPathComponent("Preferences/" + old + ".dictation.json")
            if exists(preference) {
                var remaining = 1
                try merge(preference, into: plugins.appendingPathComponent("Preferences/" + new + ".dictation.json"),
                          backups: backups, remaining: &remaining)
            }
        }
    }

    /// Custom output folders migrate their index on the next explicit save, not at app launch.
    static func migrateExportIndex(in folder: URL) throws {
        let source = folder.appendingPathComponent(".tietiezhi-exports.json")
        guard exists(source) else { return }
        let destination = folder.appendingPathComponent(".untitled-exports.json")
        try check(folder)
        guard exists(destination) else { try check(source); try FileManager.default.moveItem(at: source, to: destination); return }
        guard let legacy = try json(at: source) as? [[String: Any]],
              let current = try json(at: destination) as? [[String: Any]] else {
            throw PluginError.invalid("导出索引无法迁移，原文件已保留；请检查文件后重试。")
        }
        let names = Set(current.compactMap { $0["name"] as? String })
        let merged = current + legacy.filter { ($0["name"] as? String).map { !names.contains($0) } ?? false }
        try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]).write(to: destination, options: .atomic)
        try FileManager.default.removeItem(at: source)
    }
}
