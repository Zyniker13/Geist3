// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CardAI",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "CardAI", targets: ["CardAI"])
    ],
    targets: [
        .target(name: "CardAI", path: "Sources"),
        .testTarget(name: "CardAITests", dependencies: ["CardAI"], path: "Tests"),
    ]
)
