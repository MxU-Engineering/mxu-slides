// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyphonKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SyphonKit", targets: ["SyphonKit"])
    ],
    targets: [
        .target(
            name: "Syphon",
            exclude: ["VendoredLICENSE.txt", "VENDORED.md"],
            cSettings: [
                .headerSearchPath("include/Syphon"),
                .define("SYPHONLOG(...)", to: ""),
                .unsafeFlags(["-fno-objc-exceptions"]),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
            ]
        ),
        .target(name: "SyphonKit", dependencies: ["Syphon"]),
        .testTarget(name: "SyphonKitTests", dependencies: ["SyphonKit", "Syphon"]),
    ]
)
