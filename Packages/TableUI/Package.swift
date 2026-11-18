// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TableUI",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "TableUI", targets: ["TableUI"]),
    ],
    targets: [
        .target(name: "TableUI", path: "Sources"),
        .testTarget(name: "TableUITests", dependencies: ["TableUI"], path: "Tests"),
    ]
)
