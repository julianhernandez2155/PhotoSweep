// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoSweep",
    platforms: [.macOS(.v14)],
    targets: [
        // Queue, decision, undo and persistence logic. No PhotoKit, so it is testable on its own.
        .target(name: "SweepCore"),
        .executableTarget(name: "PhotoSweep", dependencies: ["SweepCore"]),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"]),
    ],
    swiftLanguageModes: [.v5]
)
