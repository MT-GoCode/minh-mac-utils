// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nextdns-sidecar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "nextdns-sidecar",
            path: "Sources/nextdns-sidecar"
        )
    ]
)
