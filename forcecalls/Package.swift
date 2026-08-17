// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "forcecalls",
    platforms: [.macOS(.v13)],
    targets: [
        // Root daemon + no-sudo CLI. Plain binary: no GUI, no TCC prompts, so no bundle needed.
        .executableTarget(name: "forcecalls", path: "Sources/forcecalls"),
        // GUI agent, bundled + signed as Forcecalls.app. Invisible until a call is live.
        .executableTarget(name: "forcecalls-agent", path: "Sources/forcecalls-agent"),
    ]
)
