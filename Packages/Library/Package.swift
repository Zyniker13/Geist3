// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Library",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Library", targets: ["Library"])
    ],
    targets: [
        .target(name: "Library", path: "Sources"),
        .testTarget(name: "LibraryTests", dependencies: ["Library"], path: "Tests"),
    ]
)
