// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TietiezhiTools",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TietiezhiTools", targets: ["TietiezhiTools"])
    ],
    targets: [
        .executableTarget(name: "TietiezhiTools"),
        .testTarget(name: "TietiezhiToolsTests", dependencies: ["TietiezhiTools"])
    ]
)
