// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "multistreamviewer",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure durability logic (no AppKit) split out so it's unit-testable; the app is an
        // executable target, which XCTest can't import.
        .target(name: "MSVCore"),
        .executableTarget(name: "multistreamviewer", dependencies: ["MSVCore"]),
        .testTarget(name: "MSVCoreTests", dependencies: ["MSVCore"])
    ]
)
