// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalAPI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LocalAPI", targets: ["LocalAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.27.0")
    ],
    targets: [
        .target(
            name: "LocalAPI",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox")
            ],
            resources: [
                .copy("Resources/document-schemas.json")
            ]
        ),
        .testTarget(name: "LocalAPITests", dependencies: ["LocalAPI"]),
    ]
)
