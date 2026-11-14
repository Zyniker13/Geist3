// SPDX-License-Identifier: MIT OR Apache-2.0
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ZTopKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ZTopKit", targets: ["ZTopKit"]),
    ],
    targets: [
        .target(name: "ZTopKit"),
        .testTarget(name: "ZTopKitTests", dependencies: ["ZTopKit"]),
    ]
)
