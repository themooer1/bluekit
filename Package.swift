// swift-tools-version:5.9
//
// BlueKit — prebuilt macOS XCFrameworks of the native C libraries used to
// read, navigate and interact with Blu-ray discs.
//
// The binary targets below are produced by `scripts/build-xcframeworks.sh`
// and published as GitHub release assets.

import PackageDescription

let package = Package(
    name: "BlueKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BlueKit",
            targets: ["BlueKit"]
        ),
        .library(
            name: "LibBluray",
            targets: ["LibBluray"]
        ),
        .library(
            name: "LibAACS",
            targets: ["LibAACS"]
        ),
        .library(
            name: "LibBDPlus",
            targets: ["LibBDPlus"]
        ),
    ],
    targets: [
        // Dynamic library wrapping libbluray.
        .binaryTarget(
            name: "LibBluray",
            url: "https://github.com/themooer1/bluekit/releases/download/v0.1.0/LibBluray.xcframework.zip",
            checksum: "REPLACE_WITH_LibBluray_CHECKSUM"
        ),
        // Dynamic library wrapping libaacs.
        .binaryTarget(
            name: "LibAACS",
            url: "https://github.com/themooer1/bluekit/releases/download/v0.1.0/LibAACS.xcframework.zip",
            checksum: "REPLACE_WITH_LibAACS_CHECKSUM"
        ),
        // Dynamic library wrapping libbdplus.
        .binaryTarget(
            name: "LibBDPlus",
            url: "https://github.com/themooer1/bluekit/releases/download/v0.1.0/LibBDPlus.xcframework.zip",
            checksum: "REPLACE_WITH_LibBDPlus_CHECKSUM"
        ),
        // Thin Swift umbrella that re-exports the C modules.
        .target(
            name: "BlueKit",
            dependencies: ["LibBluray", "LibAACS", "LibBDPlus"],
            path: "Sources/BlueKit"
        ),
    ]
)
