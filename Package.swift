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
            checksum: "661a4ca6032bda2c8406e452db0c6664b764132374d7b6286f2ab2a6d92a8c98"
        ),
        // Dynamic library wrapping libaacs.
        .binaryTarget(
            name: "LibAACS",
            url: "https://github.com/themooer1/bluekit/releases/download/v0.1.0/LibAACS.xcframework.zip",
            checksum: "9678a9b2c8730208609b074a0a4483e775162f7b2218c2532cc8a3345a6b9160"
        ),
        // Dynamic library wrapping libbdplus.
        .binaryTarget(
            name: "LibBDPlus",
            url: "https://github.com/themooer1/bluekit/releases/download/v0.1.0/LibBDPlus.xcframework.zip",
            checksum: "ae34405393b9d9857514c765fede0c2fd4ffcb89de18e3f82c6e265f42536c0a"
        ),
        // Thin Swift umbrella that re-exports the C modules.
        .target(
            name: "BlueKit",
            dependencies: ["LibBluray", "LibAACS", "LibBDPlus"],
            path: "Sources/BlueKit"
        ),
    ]
)
