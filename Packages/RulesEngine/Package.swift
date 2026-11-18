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
        // Package-internal: the P1 toy game shared by tests and the golden
        // replay generator. Not shipped as a product.
        .target(name: "ToyGame", dependencies: ["RulesEngine"], path: "ToyGame"),
        .executableTarget(name: "golden-gen", dependencies: ["ToyGame"], path: "GoldenGen"),
        .testTarget(name: "RulesEngineTests", dependencies: ["RulesEngine", "ToyGame"], path: "Tests"),
    ]
)
