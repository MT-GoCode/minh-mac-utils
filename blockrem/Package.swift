// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "blockrem",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "blockrem",
            path: "Sources/blockrem",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
