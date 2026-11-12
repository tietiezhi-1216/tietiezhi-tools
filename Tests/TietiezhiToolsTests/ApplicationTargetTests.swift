import AppKit
import Foundation
import Testing

@testable import TietiezhiTools

@Suite(.serialized) @MainActor
struct ApplicationTargetTests {
    @Test(arguments: [false, true])
    func configuredPathWorksWithoutAUsableBookmark(corruptBookmark: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try application(in: directory, name: "测试 App")
        let command = PluginCommand(action: .openApplication, target: app.path,
                                    applicationBookmark: corruptBookmark ? Data("broken bookmark".utf8) : nil)
        var opened: [URL] = []
        try await ActionExecutor.withApplicationURL(for: command) { opened.append($0) }
        #expect(opened.map { $0.resolvingSymlinksInPath() } == [app.resolvingSymlinksInPath()])
    }

    @Test func ordinaryBookmarksRemainCompatibleWithApplicationLaunches() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try application(in: directory, name: "Ordinary")
        let bookmark = try app.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        // The saved path is unavailable: success must come from ordinary bookmark resolution.
        let command = PluginCommand(action: .openApplication, target: directory.appendingPathComponent("Old.app").path,
                                    applicationBookmark: bookmark)
        var opened: [URL] = []
        try await ActionExecutor.withApplicationURL(for: command) { opened.append($0) }
        #expect(opened.map { $0.resolvingSymlinksInPath() } == [app.resolvingSymlinksInPath()])
    }

    @Test func staleBookmarkStillOpensTheMovedApplication() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try application(in: directory, name: "Before")
        let bookmark = try original.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let moved = directory.appendingPathComponent("After.app", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        #expect(stale)
        #expect(resolved.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        let command = PluginCommand(action: .openApplication, target: original.path, applicationBookmark: bookmark)
        var opened: [URL] = []
        try await ActionExecutor.withApplicationURL(for: command) { opened.append($0) }
        #expect(opened.map { $0.resolvingSymlinksInPath() } == [moved.resolvingSymlinksInPath()])
    }

    @Test func missingBookmarkedApplicationFallsBackToTheSavedPath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try application(in: directory, name: "Removed")
        let bookmark = try previous.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.removeItem(at: previous)
        let app = try application(in: directory, name: "Current")
        let command = PluginCommand(action: .openApplication, target: app.path, applicationBookmark: bookmark)
        var opened: [URL] = []
        try await ActionExecutor.withApplicationURL(for: command) { opened.append($0) }
        #expect(opened.map { $0.resolvingSymlinksInPath() } == [app.resolvingSymlinksInPath()])
    }

    @Test func nonApplicationBookmarkCannotReplaceTheSelectedApplication() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try application(in: directory, name: "Selected")
        let bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let command = PluginCommand(action: .openApplication, target: app.path, applicationBookmark: bookmark)
        var opened: [URL] = []
        try await ActionExecutor.withApplicationURL(for: command) { opened.append($0) }
        #expect(opened.map { $0.resolvingSymlinksInPath() } == [app.resolvingSymlinksInPath()])
    }

    @Test(arguments: [false, true])
    func missingOrNonDirectoryApplicationsRequestReselection(createFile: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Invalid.app")
        if createFile { try Data("not an application".utf8).write(to: target) }
        let command = PluginCommand(action: .openApplication, target: target.path,
                                    applicationBookmark: Data("broken bookmark".utf8))
        var launches = 0
        await #expect(throws: PluginError.self) {
            try await ActionExecutor.withApplicationURL(for: command) { _ in launches += 1 }
        }
        #expect(launches == 0)
    }

    @Test func invalidTargetsAreRejectedEvenWithAValidBookmark() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try application(in: directory, name: "Valid")
        let bookmark = try app.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let command = PluginCommand(action: .openApplication, target: "/bin/sh", applicationBookmark: bookmark)
        var launches = 0
        await #expect(throws: PluginError.self) {
            try await ActionExecutor.withApplicationURL(for: command) { _ in launches += 1 }
        }
        #expect(launches == 0)
    }

    @Test func launchErrorsAreNotMaskedOrRetried() async throws {
        enum LaunchFailure: Error { case failed }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try application(in: directory, name: "FailsToLaunch")
        let bookmark = try app.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let command = PluginCommand(action: .openApplication, target: app.path, applicationBookmark: bookmark)
        var launches = 0
        await #expect(throws: LaunchFailure.self) {
            try await ActionExecutor.withApplicationURL(for: command) { _ in
                launches += 1
                await Task.yield()
                throw LaunchFailure.failed
            }
        }
        #expect(launches == 1)
    }

    @Test func newlySelectedApplicationBookmarkRoundTrips() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try application(in: directory, name: "New Selection")
        let bookmark = try ActionExecutor.applicationBookmark(for: app)
        let command = PluginCommand(action: .openApplication, target: directory.appendingPathComponent("Old.app").path,
                                    applicationBookmark: bookmark)
        var opened: [URL] = []
        try await ActionExecutor.withApplicationURL(for: command) { opened.append($0) }
        #expect(opened.map { $0.resolvingSymlinksInPath() } == [app.resolvingSymlinksInPath()])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationTargetTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func application(in directory: URL, name: String) throws -> URL {
        let app = directory.appendingPathComponent(name + ".app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.tietiezhi.application-target-tests", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}
