// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wupsy", defaultLocalization: "en", platforms: [.macOS(.v14)],
    products: [.executable(name: "Wupsy", targets: ["Wupsy"])],
    targets: [
        .systemLibrary(name: "CArchive"),
        .executableTarget(
            name: "Wupsy", dependencies: ["CArchive"],
            resources: [.process("Resources")]),
        .testTarget(name: "WupsyTests", dependencies: ["Wupsy"]),
    ])
