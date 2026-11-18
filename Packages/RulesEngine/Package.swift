// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RulesEngine",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "RulesEngine", targets: ["RulesEngine"])
    ],
    dependencies: [
        .package(path: "../CardModel")
    ],
    targets: [
        .target(name: "RulesEngine", dependencies: ["CardModel"], path: "Sources"),
        .testTarget(name: "RulesEngineTests", dependencies: ["RulesEngine"], path: "Tests"),
    ]
)
