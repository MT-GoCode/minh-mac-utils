// swift-tools-version:5.9
// MacUtilsCore — shared plumbing for Minh Trinh's macOS self-discipline tools (minh-mac-utils).
// Edit here; nothing is vendored anywhere. Foundation-only: anything that needs AppKit stays in the app.
import PackageDescription
let package = Package(
    name: "MacUtilsCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "MacUtilsCore", targets: ["MacUtilsCore"])],
    targets: [
        .target(name: "MacUtilsCore"),
        .testTarget(name: "MacUtilsCoreTests", dependencies: ["MacUtilsCore"]),
    ]
)
