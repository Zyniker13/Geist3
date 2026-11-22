// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RulesetKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "RulesetKit", targets: ["RulesetKit"])
    ],
    dependencies: [
        .package(path: "../CardExpr"),
        .package(path: "../CardModel"),
        .package(path: "../RulesEngine"),
    ],
    targets: [
        .target(
            name: "RulesetKit",
            dependencies: ["CardExpr", "CardModel", .product(name: "RulesEngine", package: "RulesEngine")],
            path: "Sources"),
        // Golden-replay generator for the four base games (P3.5); run via
        // Tools/make-game-replays.sh.
        .executableTarget(
            name: "RulesetKitGoldenGen",
            dependencies: ["RulesetKit", "CardModel", .product(name: "RulesEngine", package: "RulesEngine")],
            path: "GoldenGen"),
        .testTarget(
            name: "RulesetKitTests",
            dependencies: ["RulesetKit", "CardModel", .product(name: "RulesEngine", package: "RulesEngine")],
            path: "Tests",
            // The toy fixture is read from the source tree via #filePath,
            // not through Bundle.module.
            exclude: ["RulesetKitTests/Fixtures/toy.ruleset.json"]
        ),
    ]
)
