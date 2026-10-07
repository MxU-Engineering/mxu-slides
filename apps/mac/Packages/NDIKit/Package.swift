// swift-tools-version: 6.0
import Foundation
import PackageDescription

let hasNDISDK = FileManager.default.fileExists(
    atPath: "/Library/NDI SDK for Apple/include/Processing.NDI.Lib.h"
)

let package = Package(
    name: "NDIKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NDIKit", targets: ["NDIKit"])
    ],
    targets: hasNDISDK
        ? [
            .systemLibrary(name: "CNDI", path: "Sources/CNDI"),
            .target(name: "NDIKit", dependencies: ["CNDI"], exclude: ["Stub"]),
            .testTarget(name: "NDIKitTests", dependencies: ["NDIKit"]),
        ]
        : [
            .target(
                name: "NDIKit",
                sources: ["NDIAdapterList.swift", "NDIRuntimeConfig.swift", "Stub"]
            ),
            .testTarget(
                name: "NDIKitStubTests",
                dependencies: ["NDIKit"],
                path: "Tests",
                sources: [
                    "NDIKitTests/NDIFingerprintTests.swift",
                    "NDIKitTests/NDIRuntimeConfigTests.swift",
                    "NDIKitStubTests",
                ]
            ),
        ]
)
