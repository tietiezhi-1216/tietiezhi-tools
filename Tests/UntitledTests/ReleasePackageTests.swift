import Foundation
import Testing
@testable import Untitled

struct ReleasePackageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNTITLED_PACKAGE_CANDIDATES_FILE"] != nil))
    @MainActor func validateReleasePackages() throws {
        let filename = try #require(ProcessInfo.processInfo.environment["UNTITLED_PACKAGE_CANDIDATES_FILE"])
        let packages = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: filename)))
        #expect(!packages.isEmpty)
        let registry = PluginComposition.makeUIRegistry()
        let permissions = PluginComposition.makePermissionCenter()
        for path in packages {
            let manifest = try PluginArchive.read(URL(fileURLWithPath: path))
            try manifest.validate()
            try registry.validate(manifest)
            try permissions.validate(manifest)
        }
    }
}
