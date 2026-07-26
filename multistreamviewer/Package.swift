// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MultiStreamViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "msv",
            path: "Sources/msv"
        )
    ]
)
