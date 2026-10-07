// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PPTXImport",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PPTXImport", targets: ["PPTXImport"]),
    ],
    dependencies: [
        .package(path: "../PresenterCore"),
    ],
    targets: [
        .target(
            name: "PPTXImport",
            dependencies: [
                "PresenterCore",
            ]
        ),
        .testTarget(name: "PPTXImportTests", dependencies: ["PPTXImport"]),
    ]
)
