// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nextdns-sidecar",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../MacUtilsCore")],
    targets: [
        .executableTarget(
            name: "nextdns-sidecar",
            dependencies: ["MacUtilsCore"],
            path: "Sources/nextdns-sidecar"
        )
    ]
)
