// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "blockrem",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../MacUtilsCore")],
    targets: [
        .executableTarget(
            name: "blockrem",
            dependencies: ["MacUtilsCore"],
            path: "Sources/blockrem",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
