// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "demonlock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "demonlock",
            path: "Sources/demonlock",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AppKit"),
                .linkedFramework("MapKit"),
            ]
        )
    ]
)
