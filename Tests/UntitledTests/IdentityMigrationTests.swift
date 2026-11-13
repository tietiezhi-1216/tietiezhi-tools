import AppKit
import Foundation
import Security
import Testing
@testable import Untitled

@Suite(.serialized) @MainActor
struct IdentityMigrationTests {
    @Test func movesAssetsAndPreservesPluginEditsWithoutResumingWork() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let record = try legacyRecord()
        let original = try JSONEncoder().encode(record)
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["futureField"] = ["preserve": true]
        try fixture.write(try JSONSerialization.data(withJSONObject: json), to: fixture.oldRoot.appendingPathComponent("Plugins/" + record.id + ".json"))
        try fixture.write(Data("model-payload".utf8), to: fixture.oldRoot.appendingPathComponent("Capture/Models/model.mlmodelc/weights.bin"))
        let preference = fixture.oldRoot.appendingPathComponent("Plugins/Preferences/" + record.id + ".dictation.json")
        try fixture.write(Data("{\"liveInput\":false}".utf8), to: preference)
        let oldPictures = fixture.pictures.appendingPathComponent("Tietiezhi Tools")
        try fixture.write(Data("export".utf8), to: oldPictures.appendingPathComponent("keep.png"))
        try fixture.write(Data("[]".utf8), to: oldPictures.appendingPathComponent(".tietiezhi-exports.json"))
        fixture.defaults.set("light", forKey: "appearance")
        try fixture.migrate(preferences: ["appearance": "dark", "capture.saveDirectory": oldPictures.path,
                                          "capture.saveTemplate": "Tietiezhi Tools user content", "sharing.sessionEnabled": true,
                                          "sharing.lastPeerHost": "example.local", "unrelated": "not imported"])
        let migratedFile = fixture.newRoot.appendingPathComponent("Plugins/com.untitled.global-shortcuts.json")
        let data = try Data(contentsOf: migratedFile)
        let migrated = try JSONDecoder().decode(InstalledPlugin.self, from: data)
        #expect(migrated.id == "com.untitled.global-shortcuts")
        #expect(migrated.commands == record.commands && migrated.isEnabled == record.isEnabled)
        #expect(migrated.installedAt == record.installedAt && migrated.initializedDefaultTemplateIDs == record.initializedDefaultTemplateIDs)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["futureField"] != nil)
        #expect(try Data(contentsOf: fixture.newRoot.appendingPathComponent("Capture/Models/model.mlmodelc/weights.bin")) == Data("model-payload".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.newRoot.appendingPathComponent("Plugins/Preferences/com.untitled.global-shortcuts.dictation.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.oldRoot.path))
        #expect(FileManager.default.fileExists(atPath: fixture.pictures.appendingPathComponent("Untitled/keep.png").path))
        #expect(FileManager.default.fileExists(atPath: fixture.pictures.appendingPathComponent("Untitled/.untitled-exports.json").path))
        #expect(fixture.defaults.string(forKey: "appearance") == "light")
        #expect(fixture.defaults.string(forKey: "capture.saveTemplate") == "Tietiezhi Tools user content")
        #expect(fixture.defaults.string(forKey: "capture.saveDirectory") == fixture.pictures.appendingPathComponent("Untitled").path)
        #expect(fixture.defaults.string(forKey: "sharing.lastPeerHost") == "example.local")
        #expect(!fixture.defaults.bool(forKey: "sharing.sessionEnabled") && fixture.defaults.object(forKey: "unrelated") == nil)
        #expect(fixture.defaults.bool(forKey: IdentityMigration.completionKey))
        try fixture.migrate(preferences: ["appearance": "dark"])
        #expect(try Data(contentsOf: migratedFile) == data)
        _ = NSApplication.shared
        let store = PluginStore(directory: fixture.newRoot.appendingPathComponent("Plugins"))
        #expect(store.errorMessage == nil && store.installed == [migrated])
    }

    @Test func existingDestinationWinsAndConflictsAreBackedUp() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write(Data("old-media".utf8), to: fixture.oldRoot.appendingPathComponent("Capture/same.png"))
        try fixture.write(Data("new-media".utf8), to: fixture.newRoot.appendingPathComponent("Capture/same.png"))
        let record = try legacyRecord()
        try fixture.write(try JSONEncoder().encode(record), to: fixture.oldRoot.appendingPathComponent("Plugins/" + record.id + ".json"))
        let current = fixture.newRoot.appendingPathComponent("Plugins/com.untitled.global-shortcuts.json")
        let newRecord = InstalledPlugin(manifest: IdentityMigration.manifest(record.manifest), commands: [])
        let newData = try JSONEncoder().encode(newRecord)
        try fixture.write(newData, to: current)
        try fixture.migrate()
        #expect(try Data(contentsOf: current) == newData)
        #expect(try Data(contentsOf: fixture.newRoot.appendingPathComponent("Capture/same.png")) == Data("new-media".utf8))
        let entries = try #require(FileManager.default.enumerator(at: fixture.newRoot.appendingPathComponent("MigrationBackups"), includingPropertiesForKeys: nil))
        let archived = entries.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "png" || $0.pathExtension == "json" }
        #expect(archived.count == 2)
        #expect(archived.contains { (try? Data(contentsOf: $0)) == Data("old-media".utf8) })
    }

    @Test func malformedRecordRemainsRecoverableAndRetrySucceeds() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let record = try legacyRecord()
        let relative = "Plugins/" + record.id + ".json"
        try fixture.write(Data("not-json".utf8), to: fixture.oldRoot.appendingPathComponent(relative))
        #expect(throws: (any Error).self) { try fixture.migrate() }
        #expect(!fixture.defaults.bool(forKey: IdentityMigration.completionKey))
        let retained = fixture.newRoot.appendingPathComponent(relative)
        #expect(try Data(contentsOf: retained) == Data("not-json".utf8))
        try fixture.write(try JSONEncoder().encode(record), to: retained)
        try fixture.migrate()
        #expect(fixture.defaults.bool(forKey: IdentityMigration.completionKey))
        #expect(FileManager.default.fileExists(atPath: fixture.newRoot.appendingPathComponent("Plugins/com.untitled.global-shortcuts.json").path))
    }

    @Test func symlinkRootIsNotTraversed() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try fixture.write(Data("safe".utf8), to: outside.appendingPathComponent("sentinel"))
        try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.oldRoot, withDestinationURL: outside)
        #expect(throws: PluginError.self) { try fixture.migrate() }
        #expect(try Data(contentsOf: outside.appendingPathComponent("sentinel")) == Data("safe".utf8))
        #expect(!fixture.defaults.bool(forKey: IdentityMigration.completionKey))
    }

    @Test func customOutputIndexMergesWithoutChangingUserFiles() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("custom")
        try fixture.write(Data("[{\"name\":\"old.png\"},{\"name\":\"same.png\",\"date\":1}]".utf8), to: folder.appendingPathComponent(".tietiezhi-exports.json"))
        try fixture.write(Data("[{\"name\":\"same.png\",\"date\":2}]".utf8), to: folder.appendingPathComponent(".untitled-exports.json"))
        try IdentityMigration.migrateExportIndex(in: folder)
        let records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".untitled-exports.json"))) as? [[String: Any]])
        #expect(records.count == 2 && records[0]["date"] as? Int == 2)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".tietiezhi-exports.json").path))
        try fixture.migrate(preferences: ["capture.saveDirectory": folder.path])
        #expect(fixture.defaults.string(forKey: "capture.saveDirectory") == folder.path)
    }

    @Test func historicalPackagesUseNewInstalledIdentityAndUnchangedIntegrityMetadata() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let record = try legacyRecord()
        _ = NSApplication.shared
        let store = PluginStore(directory: fixture.newRoot.appendingPathComponent("Plugins"))
        try store.installManifest(record.manifest)
        #expect(store.installed.map(\.id) == ["com.untitled.global-shortcuts"])
        let catalog = try JSONDecoder().decode(PluginCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/catalog.json")))
        for entry in catalog.plugins {
            let migrated = IdentityMigration.catalogEntry(entry)
            #expect(migrated.id.hasPrefix("com.untitled."))
            #expect(migrated.sha256 == entry.sha256 && migrated.version == entry.version && migrated.downloadURL == entry.downloadURL)
        }
        let manifest = record.manifest
        let independent = PluginManifest(schemaVersion: manifest.schemaVersion, id: manifest.id, name: manifest.name, version: manifest.version,
                                         summary: manifest.summary, author: manifest.author, repository: URL(string: "https://github.com/alice/plugin")!,
                                         minimumHostVersion: manifest.minimumHostVersion, actions: manifest.actions, templates: manifest.templates,
                                         ui: manifest.ui, permissions: manifest.permissions)
        #expect(IdentityMigration.manifest(independent) == independent)
    }

    @Test func migrationFailureBlocksInstallationWithoutWritingConfiguration() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = NSApplication.shared
        let directory = fixture.newRoot.appendingPathComponent("Plugins")
        let store = PluginStore(directory: directory, startupError: "test migration failure")
        #expect(store.installed.isEmpty && store.errorMessage != nil)
        #expect(throws: PluginError.self) { try store.installManifest(IdentityMigration.manifest(legacyRecord().manifest)) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func keychainMigrationPublishesNewItemBeforeDeletingLegacy() throws {
        let fake = FakeCredentials()
        let service = HostInfo.bundleIdentifier + ".capture", account = "vision-api-key"
        let old = try #require(IdentityMigration.legacyService(for: service))
        let secret = Data("synthetic-key-not-a-real-credential".utf8)
        fake.items[old] = secret
        #expect(try AppCredentials.read(service: service, account: account, backend: fake.backend) == secret)
        #expect(fake.items[service] == secret && fake.items[old] == nil)
        #expect(fake.operations.firstIndex(of: "add:" + service)! < fake.operations.firstIndex(of: "delete:" + old)!)
        fake.operations = []
        fake.items[old] = Data("older".utf8)
        #expect(try AppCredentials.read(service: service, account: account, backend: fake.backend) == secret)
        #expect(!fake.operations.contains("read:" + old))
        try AppCredentials.delete(service: service, account: account, backend: fake.backend)
        #expect(fake.items.isEmpty)
    }

    @Test func deniedOrFailedKeychainMigrationNeverDeletesOriginal() throws {
        let service = HostInfo.bundleIdentifier + ".peripheral-sharing", account = "pairing-v1"
        let old = try #require(IdentityMigration.legacyService(for: service))
        let secret = Data("synthetic-pairing-fixture".utf8)
        for failRead in [false, true] {
            let fake = FakeCredentials(); fake.items[old] = secret
            fake.failAdd = !failRead; fake.deniedService = failRead ? old : nil
            #expect(throws: PluginError.self) { try AppCredentials.read(service: service, account: account, backend: fake.backend) }
            #expect(fake.items[old] == secret && fake.items[service] == nil)
            #expect(!fake.operations.contains("delete:" + old))
        }
    }

    @Test func keychainVerificationAndCleanupFailuresPreserveBothItems() throws {
        let service = HostInfo.bundleIdentifier + ".capture", account = "vision-api-key"
        let old = try #require(IdentityMigration.legacyService(for: service))
        let secret = Data("synthetic-original".utf8), concurrent = Data("synthetic-newer".utf8)
        for mode in 0..<3 {
            let fake = FakeCredentials(); fake.items[old] = secret
            fake.failVerification = mode == 0
            fake.mismatchedVerification = mode == 1 ? concurrent : nil
            fake.deniedDeleteService = mode == 2 ? old : nil
            if mode == 1 {
                #expect(try AppCredentials.read(service: service, account: account, backend: fake.backend) == concurrent)
                #expect(fake.items[service] == concurrent)
            } else {
                #expect(throws: PluginError.self) { try AppCredentials.read(service: service, account: account, backend: fake.backend) }
                #expect(fake.items[service] == secret)
            }
            #expect(fake.items[old] == secret)
        }
    }

    @Test func failedRevocationDoesNotDeleteNewItemAndReimportLegacy() throws {
        let service = HostInfo.bundleIdentifier + ".peripheral-sharing", account = "pairing-v1"
        let old = try #require(IdentityMigration.legacyService(for: service))
        let fake = FakeCredentials(), secret = Data("synthetic-pairing".utf8)
        fake.items[old] = secret; fake.items[service] = secret; fake.deniedDeleteService = old
        #expect(throws: PluginError.self) { try AppCredentials.delete(service: service, account: account, backend: fake.backend) }
        #expect(fake.items[old] == secret && fake.items[service] == secret)
        #expect(!fake.operations.contains("delete:" + service))
        fake.deniedDeleteService = nil
        try AppCredentials.delete(service: service, account: account, backend: fake.backend)
        #expect(fake.items.isEmpty)
    }

    private func legacyRecord() throws -> InstalledPlugin {
        let path = URL(fileURLWithPath: "Plugins/global-shortcuts/manifest.json")
        var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        value["id"] = try #require(IdentityMigration.pluginIDs.first { $0.value == "com.untitled.global-shortcuts" }?.key)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: value))
        var command = PluginCommand(action: .showMainWindow)
        command.hotKey = .init(keyCode: 18, modifiers: 4096, key: "1")
        command.templateID = "main"
        var record = InstalledPlugin(manifest: manifest, commands: [command])
        record.isEnabled = false; record.installedAt = Date(timeIntervalSince1970: 100)
        record.initializedDefaultTemplateIDs = ["main", "deleted-default"]
        return record
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Untitled-Migration-" + UUID().uuidString)
        let domain = "com.untitled.migration-tests." + UUID().uuidString
        let defaults: UserDefaults
        var support: URL { root.appendingPathComponent("Support") }
        var caches: URL { root.appendingPathComponent("Caches") }
        var pictures: URL { root.appendingPathComponent("Pictures") }
        var oldRoot: URL { support.appendingPathComponent(IdentityMigration.legacyBundleID) }
        var newRoot: URL { support.appendingPathComponent(HostInfo.bundleIdentifier) }
        init() throws { defaults = UserDefaults(suiteName: domain)!; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func remove() { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        func migrate(preferences: [String: Any] = [:]) throws {
            try IdentityMigration.migrate(applicationSupport: support, caches: caches, pictures: pictures, defaults: defaults, legacyPreferences: preferences)
        }
    }

    private final class FakeCredentials {
        var items: [String: Data] = [:]
        var operations: [String] = []
        var failAdd = false
        var deniedService: String?
        var failVerification = false
        var mismatchedVerification: Data?
        var deniedDeleteService: String?
        private var addedNewItem = false
        var backend: CredentialBackend {
            .init(read: { service, _ in
                self.operations.append("read:" + service)
                if service == self.deniedService { return (errSecInteractionNotAllowed, nil) }
                if self.addedNewItem && service.hasPrefix(HostInfo.bundleIdentifier + ".") {
                    if self.failVerification { return (errSecAuthFailed, nil) }
                    if let concurrent = self.mismatchedVerification { self.items[service] = concurrent }
                }
                return self.items[service].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
            }, update: { service, _, data in
                guard self.items[service] != nil else { return errSecItemNotFound }
                self.items[service] = data; return errSecSuccess
            }, add: { service, _, data in
                self.operations.append("add:" + service)
                if self.failAdd { return errSecAuthFailed }
                guard self.items[service] == nil else { return errSecDuplicateItem }
                self.items[service] = data; self.addedNewItem = true; return errSecSuccess
            }, delete: { service, _ in
                self.operations.append("delete:" + service)
                if service == self.deniedDeleteService { return errSecAuthFailed }
                return self.items.removeValue(forKey: service) == nil ? errSecItemNotFound : errSecSuccess
            })
        }
    }
}
