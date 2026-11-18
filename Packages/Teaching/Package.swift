// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Teaching",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Teaching", targets: ["Teaching"])
    ],
    targets: [
        .target(name: "Teaching", path: "Sources"),
        .testTarget(name: "TeachingTests", dependencies: ["Teaching"], path: "Tests"),
    ]
)
