// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AudioEngine", targets: ["AudioEngine"])
    ],
    targets: [
        .target(name: "AudioEngine"),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine"]),
    ]
)
