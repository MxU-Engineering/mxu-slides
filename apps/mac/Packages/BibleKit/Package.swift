// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BibleKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BibleKit", targets: ["BibleKit"])],
    dependencies: [.package(path: "../PresenterCore"), .package(path: "../SlideScene")],
    targets: [
        .target(name: "BibleKit", dependencies: ["PresenterCore"], resources: [.copy("Resources/WEB.json")]),
        .testTarget(name: "BibleKitTests", dependencies: ["BibleKit", "SlideScene"]),
    ]
)
