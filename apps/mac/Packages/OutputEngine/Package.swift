// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OutputEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OutputEngine", targets: ["OutputEngine"])
    ],
    dependencies: [
        .package(path: "../RenderEngine")
    ],
    targets: [
        .target(name: "OutputEngine", dependencies: ["RenderEngine"]),

        .executableTarget(
            name: "recorder-kill-harness",
            dependencies: ["OutputEngine"]
        ),
        .testTarget(name: "OutputEngineTests", dependencies: ["OutputEngine"]),
    ]
)
