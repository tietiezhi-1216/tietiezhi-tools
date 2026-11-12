import Foundation
import Security
import LocalAuthentication

/// Previous identities are data in Info.plist, never identifiers for new builds.
struct PreviousIdentity: Sendable {
    let bundleIdentifier: String
    let pictureDirectory: String
    let exportIndex: String
    let plugins: [String: String]

    init?(_ value: [String: Any]?) {
        guard let value,
              let bundle = value["bundleIdentifier"] as? String,
              let pictures = value["pictureDirectory"] as? String,
              let index = value["exportIndex"] as? String,
              let plugins = value["plugins"] as? [String: String],
              !bundle.isEmpty, !bundle.contains("/"),
              [pictures, index].allSatisfy({ !$0.isEmpty && URL(fileURLWithPath: $0).lastPathComponent == $0 }),
              plugins.allSatisfy({ !$0.key.contains("/") && !$0.value.contains("/") })
        else { return nil }
        bundleIdentifier = bundle; pictureDirectory = pictures
        exportIndex = index; self.plugins = plugins
    }

    static var bundled: Self? {
        Self(Bundle.main.object(forInfoDictionaryKey: "UntitledIdentityMigration") as? [String: Any])
    }
}

enum IdentityMigration {
    static func prepare() -> String? {
        guard let previous = PreviousIdentity.bundled else { return nil }
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let pictures = manager.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        do {
            try migrate(previous, support: support, pictures: pictures, defaults: .standard)
            return nil
        } catch {
            return "部分旧数据尚未迁移，原文件已保留，请检查数据目录后重试：\(error.localizedDescription)"
        }
    }

    static func migrate(_ previous: PreviousIdentity, support: URL, pictures: URL, defaults: UserDefaults) throws {
        let manager = FileManager.default
        if !defaults.bool(forKey: "identity.preferencesMigrated") {
            // Import once, otherwise a deliberately cleared preference could reappear on restart.
            for (key, value) in defaults.persistentDomain(forName: previous.bundleIdentifier) ?? [:]
                where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            let priorPictures = pictures.appendingPathComponent(previous.pictureDirectory, isDirectory: true)
            if (defaults.string(forKey: "capture.saveDirectory") ?? "").isEmpty,
               manager.fileExists(atPath: priorPictures.path) {
                defaults.set(priorPictures.path, forKey: "capture.saveDirectory")
            }
            defaults.set(true, forKey: "identity.preferencesMigrated")
        }
        let priorRoot = support.appendingPathComponent(previous.bundleIdentifier, isDirectory: true)
        let destination = support.appendingPathComponent(HostInfo.bundleIdentifier, isDirectory: true)
        if manager.fileExists(atPath: priorRoot.path) {
            guard !manager.fileExists(atPath: destination.path) else {
                throw PluginError.invalid("新旧数据目录同时存在，已保留两份数据，请按迁移说明检查后手动导入。")
            }
            let values = try priorRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw PluginError.invalid("旧数据来源不是普通目录，请手动选择数据来源。")
            }
            // A same-volume rename keeps large media/model files in place without duplicating them.
            try manager.moveItem(at: priorRoot, to: destination)
        }
        let plugins = destination.appendingPathComponent("Plugins", isDirectory: true)
        for (oldID, newID) in previous.plugins.sorted(by: { $0.key < $1.key }) {
            let oldFile = plugins.appendingPathComponent(oldID + ".json")
            guard manager.fileExists(atPath: oldFile.path) else { continue }
            guard try oldFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  (try oldFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 5 * 1024 * 1024 else {
                throw PluginError.invalid("旧插件配置不是可迁移的普通小文件。")
            }
            let original = try Data(contentsOf: oldFile)
            var record = try JSONDecoder().decode(InstalledPlugin.self, from: original)
            guard record.id == oldID else { throw PluginError.invalid("旧插件配置与文件名不一致。") }
            // Preserve every command, UUID, shortcut, enable state and initialized default marker.
            var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var manifest = object["manifest"] as! [String: Any]
            manifest["id"] = newID; object["manifest"] = manifest
            record = try JSONDecoder().decode(InstalledPlugin.self, from: JSONSerialization.data(withJSONObject: object))
            try record.manifest.validate()
            let newFile = plugins.appendingPathComponent(newID + ".json")
            if !manager.fileExists(atPath: newFile.path) {
                let temporary = plugins.appendingPathComponent(".migration-" + UUID().uuidString)
                defer { try? manager.removeItem(at: temporary) }
                try JSONEncoder().encode(record).write(to: temporary, options: .atomic)
                try manager.moveItem(at: temporary, to: newFile)
            }
            let backups = destination.appendingPathComponent("MigrationBackups/Plugins", isDirectory: true)
            try manager.createDirectory(at: backups, withIntermediateDirectories: true)
            let backup = backups.appendingPathComponent(oldID + "-" + UUID().uuidString + ".json")
            try manager.moveItem(at: oldFile, to: backup)
        }
    }

    static func prepareExportIndex(in folder: URL, previous: PreviousIdentity? = .bundled) {
        guard let previous else { return }
        let manager = FileManager.default
        let old = folder.appendingPathComponent(previous.exportIndex)
        let current = folder.appendingPathComponent(".untitled-exports.json")
        guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: current.path),
              (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? manager.moveItem(at: old, to: current)
    }

    static func previousPassword(suffix: String, account: String) -> Data? {
        guard !UserDefaults.standard.bool(forKey: secretMarker(suffix)),
              let previous = PreviousIdentity.bundled else { return nil }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: previous.bundleIdentifier + "." + suffix,
            kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            // A name migration must not prompt for access before the user needs the feature.
            kSecUseAuthenticationContext: context
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func finishPasswordMigration(suffix: String) {
        // Explicit deletion must not resurrect the preserved previous Keychain item.
        UserDefaults.standard.set(true, forKey: secretMarker(suffix))
    }

    private static func secretMarker(_ suffix: String) -> String { "identity.secretMigrated." + suffix }
}
