// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RenderEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RenderEngine", targets: ["RenderEngine"])
    ],
    targets: [
        .target(name: "RenderEngine"),
        .testTarget(name: "RenderEngineTests", dependencies: ["RenderEngine"]),
    ]
)
