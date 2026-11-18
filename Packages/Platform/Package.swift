// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Platform",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Platform", targets: ["Platform"])
    ],
    targets: [
        .target(name: "Platform", path: "Sources"),
        .testTarget(name: "PlatformTests", dependencies: ["Platform"], path: "Tests"),
    ]
)
