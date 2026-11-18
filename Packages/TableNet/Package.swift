// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TableNet",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "TableNet", targets: ["TableNet"])
    ],
    targets: [
        .target(name: "TableNet", path: "Sources"),
        .testTarget(name: "TableNetTests", dependencies: ["TableNet"], path: "Tests"),
    ]
)
