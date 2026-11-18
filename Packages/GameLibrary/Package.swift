// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameLibrary",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "GameLibrary", targets: ["GameLibrary"])
    ],
    targets: [
        .target(name: "GameLibrary", path: "Sources"),
        .testTarget(name: "GameLibraryTests", dependencies: ["GameLibrary"], path: "Tests"),
    ]
)
