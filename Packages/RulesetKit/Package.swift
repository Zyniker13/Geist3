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
        .testTarget(
            name: "RulesetKitTests",
            dependencies: ["RulesetKit", "CardModel", .product(name: "RulesEngine", package: "RulesEngine")],
            path: "Tests"
        ),
    ]
)
