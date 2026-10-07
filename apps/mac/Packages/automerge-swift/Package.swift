// swift-tools-version:5.9

import Foundation
import PackageDescription

var globalSwiftSettings: [PackageDescription.SwiftSetting] = []
#if swift(>=5.9)

if ProcessInfo.processInfo.environment["LOCAL_BUILD"] != nil {
    globalSwiftSettings.append(.unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"]))

}
#endif

let FFIbinaryTarget: PackageDescription.Target

if ProcessInfo.processInfo.environment["LOCAL_BUILD"] != nil {

    FFIbinaryTarget = .binaryTarget(
        name: "automergeFFI",
        path: "./automergeFFI.xcframework"
    )
} else {
    FFIbinaryTarget = .binaryTarget(
        name: "automergeFFI",
        url: "https://github.com/automerge/automerge-swift/releases/download/0.7.2/automergeFFI.xcframework.zip",
        checksum: "10245378e74229b026f689b039d7df3cf17aeed353706d5f420dfd164f283a86"
    )
}

let package = Package(
    name: "Automerge",
    platforms: [.iOS(.v13), .macOS(.v10_15), .visionOS(.v1)],
    products: [
        .library(name: "Automerge", targets: ["Automerge", "AutomergeUtilities"]),
    ],
    targets: [
        FFIbinaryTarget,
        .target(
            name: "AutomergeUniffi",
            dependencies: [

                .target(name: "automergeFFI", condition: .when(platforms: [
                    .iOS, .macOS, .macCatalyst, .tvOS, .watchOS, .visionOS,
                ])),

                .target(name: "_CAutomergeUniffi", condition: .when(platforms: [.wasi, .linux])),
            ],
            path: "./AutomergeUniffi"
        ),
        .systemLibrary(name: "_CAutomergeUniffi"),
        .target(
            name: "Automerge",
            dependencies: ["AutomergeUniffi"],
            swiftSettings: globalSwiftSettings
        ),
        .target(
            name: "AutomergeUtilities",
            dependencies: ["Automerge"],
            swiftSettings: globalSwiftSettings
        ),
        .testTarget(
            name: "AutomergeTests",
            dependencies: ["Automerge", "AutomergeUtilities"],
            exclude: ["Fixtures"]
        ),
    ]
)
