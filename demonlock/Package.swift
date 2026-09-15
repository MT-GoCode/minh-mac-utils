// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "demonlock",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../MacUtilsCore")],
    targets: [
        .target(name: "DemonlockCore", dependencies: ["MacUtilsCore"], path: "Sources/DemonlockCore",
            linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation"),
                             .linkedFramework("AppKit"), .linkedFramework("MapKit")]),
        .executableTarget(name: "demonlock", dependencies: ["DemonlockCore"], path: "Sources/demonlock"),
        .testTarget(name: "DemonlockCoreTests", dependencies: ["DemonlockCore"], path: "Tests/DemonlockCoreTests"),
    ]
)
