// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "multistreamviewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "multistreamviewer")
    ]
)
