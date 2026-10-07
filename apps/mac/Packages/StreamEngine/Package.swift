// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "StreamEngine", targets: ["StreamEngine"])
    ],
    dependencies: [
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift", from: "2.2.5")
    ],
    targets: [
        .target(
            name: "StreamEngine",
            dependencies: [
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift"),
                .product(name: "SRTHaishinKit", package: "HaishinKit.swift"),
            ],
            exclude: ["HLS/Vendored/VendoredLICENSE.md"]
        ),
        .testTarget(name: "StreamEngineTests", dependencies: ["StreamEngine"]),
    ]
)
