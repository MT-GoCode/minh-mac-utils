// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "stayup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "stayup")
    ]
)
