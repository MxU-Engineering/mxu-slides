// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeckLinkKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DeckLinkKit", targets: ["DeckLinkKit"])
    ],
    targets: [
        .target(
            name: "CDeckLink",
            cxxSettings: [
                .headerSearchPath("Vendor")
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(name: "DeckLinkKit", dependencies: ["CDeckLink"]),
        .testTarget(name: "DeckLinkKitTests", dependencies: ["DeckLinkKit"]),
    ],
    cxxLanguageStandard: .cxx17
)
