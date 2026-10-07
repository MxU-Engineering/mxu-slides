// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MediaEngine", targets: ["MediaEngine"])
    ],
    dependencies: [
        .package(path: "../RenderEngine"),
        .package(path: "../AudioEngine"),
    ],
    targets: [
        .target(name: "MediaEngine", dependencies: ["RenderEngine", "AudioEngine"]),
        .testTarget(name: "MediaEngineTests", dependencies: ["MediaEngine"]),
    ]
)
