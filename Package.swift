// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeLights",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClaudeLightsCore"),
        .executableTarget(name: "ClaudeLights", dependencies: ["ClaudeLightsCore"]),
        .testTarget(name: "ClaudeLightsCoreTests", dependencies: ["ClaudeLightsCore"]),
    ]
)
