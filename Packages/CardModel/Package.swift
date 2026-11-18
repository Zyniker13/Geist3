// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CardModel",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "CardModel", targets: ["CardModel"]),
    ],
    targets: [
        .target(name: "CardModel", path: "Sources"),
        .testTarget(name: "CardModelTests", dependencies: ["CardModel"], path: "Tests"),
    ]
)
