// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PresenterCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PresenterCore", targets: ["PresenterCore"]),
        .executable(name: "library-bench", targets: ["library-bench"]),
    ],
    dependencies: [

        .package(path: "../automerge-swift")
    ],
    targets: [
        .target(
            name: "PresenterCore",
            dependencies: [
                .product(name: "Automerge", package: "automerge-swift")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "library-bench",
            dependencies: ["PresenterCore"]
        ),
        .testTarget(name: "PresenterCoreTests", dependencies: ["PresenterCore"]),
    ]
)
