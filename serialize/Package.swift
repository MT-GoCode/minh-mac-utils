// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "serialize",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "serialize",
            path: "Sources/serialize",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
