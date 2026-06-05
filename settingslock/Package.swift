// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "settingslock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "settingslock",
            path: "Sources/settingslock",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
