import Foundation
import Testing
@testable import Untitled

@Suite(.serialized) struct IdentityMigrationTests {
    private func fixture() throws -> (URL, PreviousIdentity, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UntitledMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = "app.untitled.migration-tests." + UUID().uuidString
        let identity = PreviousIdentity([
            "bundleIdentifier": domain, "pictureDirectory": "Previous Pictures",
            "exportIndex": ".previous-exports.json", "plugins": ["legacy.test.plugin": "app.untitled.test"]
        ])!
        return (root, identity, UserDefaults(suiteName: domain + ".new")!)
    }

    private func record() -> InstalledPlugin {
        let manifest = PluginManifest(schemaVersion: 1, id: "legacy.test.plugin", name: "Previous",
            version: "1.0.0", summary: "", author: "Tests", repository: HostInfo.repository,
            minimumHostVersion: "0.2.0", actions: [.openURL], templates: [])
        var result = InstalledPlugin(manifest: manifest, commands: [PluginCommand(action: .openURL)])
        result.isEnabled = false
        result.commands[0].target = "https://example.com/user-choice"
        result.initializedDefaultTemplateIDs = ["deleted-by-user"]
        return result
    }

    @Test func migratesPreferencesMediaAndCommandsWithoutResettingChoices() throws {
        let (root, identity, defaults) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: identity.bundleIdentifier)
            defaults.removePersistentDomain(forName: identity.bundleIdentifier + ".new")
            try? FileManager.default.removeItem(at: root)
        }
        defaults.setPersistentDomain(["appearance": "dark", "capture.saveFormat": "jpg"], forName: identity.bundleIdentifier)
        defaults.set("png", forKey: "capture.saveFormat")
        let prior = root.appendingPathComponent(identity.bundleIdentifier)
        let plugins = prior.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let original = record()
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: plugins.appendingPathComponent(original.id + ".json"))
        try Data("media-must-survive".utf8).write(to: prior.appendingPathComponent("capture.png"))
        let pictures = root.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: pictures.appendingPathComponent(identity.pictureDirectory), withIntermediateDirectories: true)
        try IdentityMigration.migrate(identity, support: root, pictures: pictures, defaults: defaults)
        let destination = root.appendingPathComponent(HostInfo.bundleIdentifier)
        let migrated = try JSONDecoder().decode(InstalledPlugin.self, from: Data(contentsOf: destination.appendingPathComponent("Plugins/app.untitled.test.json")))
        #expect(migrated.id == "app.untitled.test")
        #expect(migrated.commands == original.commands)
        #expect(migrated.initializedDefaultTemplateIDs == original.initializedDefaultTemplateIDs)
        #expect(!migrated.isEnabled)
        #expect(defaults.string(forKey: "appearance") == "dark")
        #expect(defaults.string(forKey: "capture.saveFormat") == "png")
        #expect(defaults.string(forKey: "capture.saveDirectory") == pictures.appendingPathComponent(identity.pictureDirectory).path)
        #expect(try Data(contentsOf: destination.appendingPathComponent("capture.png")) == Data("media-must-survive".utf8))
        let backups = try FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent("MigrationBackups/Plugins"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == bytes)
        defaults.removeObject(forKey: "appearance")
        try IdentityMigration.migrate(identity, support: root, pictures: pictures, defaults: defaults)
        #expect(defaults.string(forKey: "appearance") == nil)
        #expect(try FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent("MigrationBackups/Plugins"), includingPropertiesForKeys: nil).count == 1)
    }

    @Test func preservesExistingDestinationAndPreviousData() throws {
        let (root, identity, defaults) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: identity.bundleIdentifier + ".new")
            try? FileManager.default.removeItem(at: root)
        }
        let prior = root.appendingPathComponent(identity.bundleIdentifier)
        let current = root.appendingPathComponent(HostInfo.bundleIdentifier)
        for folder in [prior, current] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("old".utf8).write(to: prior.appendingPathComponent("history"))
        try Data("current".utf8).write(to: current.appendingPathComponent("history"))
        #expect(throws: (any Error).self) {
            try IdentityMigration.migrate(identity, support: root, pictures: root, defaults: defaults)
        }
        #expect(try Data(contentsOf: prior.appendingPathComponent("history")) == Data("old".utf8))
        #expect(try Data(contentsOf: current.appendingPathComponent("history")) == Data("current".utf8))
    }

    @Test func corruptConfigurationIsKeptForRecovery() throws {
        let (root, identity, defaults) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: identity.bundleIdentifier + ".new")
            try? FileManager.default.removeItem(at: root)
        }
        let plugins = root.appendingPathComponent(identity.bundleIdentifier + "/Plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let bytes = Data("unreadable configuration".utf8)
        try bytes.write(to: plugins.appendingPathComponent("legacy.test.plugin.json"))
        #expect(throws: (any Error).self) {
            try IdentityMigration.migrate(identity, support: root, pictures: root, defaults: defaults)
        }
        let preserved = root.appendingPathComponent(HostInfo.bundleIdentifier + "/Plugins/legacy.test.plugin.json")
        #expect(try Data(contentsOf: preserved) == bytes)
        #expect(!FileManager.default.fileExists(atPath: preserved.deletingLastPathComponent().appendingPathComponent("app.untitled.test.json").path))
    }

    @Test func exportIndexMovesOnceAndNeverOverwritesCurrentIndex() throws {
        let (root, identity, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent(identity.exportIndex)
        let current = root.appendingPathComponent(".untitled-exports.json")
        try Data("previous".utf8).write(to: previous)
        IdentityMigration.prepareExportIndex(in: root, previous: identity)
        #expect(try Data(contentsOf: current) == Data("previous".utf8))
        try Data("leave this copy".utf8).write(to: previous)
        IdentityMigration.prepareExportIndex(in: root, previous: identity)
        #expect(try Data(contentsOf: current) == Data("previous".utf8))
        #expect(try Data(contentsOf: previous) == Data("leave this copy".utf8))
    }
}
