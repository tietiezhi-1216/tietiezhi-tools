// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Untitled",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Untitled", targets: ["Untitled"])
    ],
    targets: [
        .executableTarget(name: "Untitled", resources: [.copy("Resources/Project.json")]),
        .testTarget(name: "UntitledTests", dependencies: ["Untitled"])
    ]
)
