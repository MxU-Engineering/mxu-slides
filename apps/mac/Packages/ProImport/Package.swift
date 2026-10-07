// swift-tools-version: 6.0
import Foundation
import PackageDescription

let hasGeneratedProto = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/Sources/ProImport/Generated"
)

let package = Package(
    name: "ProImport",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ProImport", targets: ["ProImport"]),
    ],
    dependencies: [
        .package(path: "../PresenterCore"),
    ] + (hasGeneratedProto ? [.package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")] : []),
    targets: hasGeneratedProto
        ? [
            .target(
                name: "ProImport",
                dependencies: [
                    "PresenterCore",
                    .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                ],
                exclude: ["Stub"]
            ),
            .testTarget(name: "ProImportTests", dependencies: ["ProImport"]),
        ]
        : [
            .target(
                name: "ProImport",
                dependencies: ["PresenterCore"],
                sources: [
                    "ProImportProgress.swift", "ProImportTypes.swift",
                    "WorkspaceImportOptions.swift", "Stub",
                ]
            ),
            .testTarget(name: "ProImportStubTests", dependencies: ["ProImport"]),
        ]
)
