// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlideScene",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SlideScene", targets: ["SlideScene"])
    ],
    dependencies: [
        .package(path: "../PresenterCore"),
        .package(path: "../RenderEngine"),
    ],
    targets: [
        .target(
            name: "SlideScene",
            dependencies: ["PresenterCore", "RenderEngine"]
        ),
        .testTarget(name: "SlideSceneTests", dependencies: ["SlideScene"]),
    ]
)
