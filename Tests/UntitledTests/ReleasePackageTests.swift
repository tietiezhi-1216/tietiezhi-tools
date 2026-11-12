import Foundation
import Testing
@testable import Untitled

struct ReleasePackageTests {
    private struct Candidates: Decodable {
        let catalog: String
        let packages: [String]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNTITLED_PACKAGE_CANDIDATES_FILE"] != nil))
    @MainActor func validateReleasePackages() throws {
        let filename = try #require(ProcessInfo.processInfo.environment["UNTITLED_PACKAGE_CANDIDATES_FILE"])
        let candidates = try JSONDecoder().decode(Candidates.self, from: Data(contentsOf: URL(fileURLWithPath: filename)))
        let catalog = try JSONDecoder().decode(PluginCatalog.self,
            from: Data(contentsOf: URL(fileURLWithPath: candidates.catalog)))
        try catalog.validate()
        #expect(!candidates.packages.isEmpty)
        #expect(catalog.plugins.count == candidates.packages.count)
        var packageIDs = Set<String>()
        let registry = PluginComposition.makeUIRegistry()
        let permissions = PluginComposition.makePermissionCenter()
        for path in candidates.packages {
            let manifest = try PluginArchive.read(URL(fileURLWithPath: path))
            #expect(packageIDs.insert(manifest.id).inserted)
            let entry = try #require(catalog.plugins.first { $0.id == manifest.id })
            #expect(entry.version == manifest.version)
            try manifest.validate()
            try registry.validate(manifest)
            try permissions.validate(manifest)
        }
        #expect(packageIDs == Set(catalog.plugins.map(\.id)))
    }
}
