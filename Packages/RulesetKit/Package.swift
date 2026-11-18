// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RulesetKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "RulesetKit", targets: ["RulesetKit"])
    ],
    dependencies: [
        .package(path: "../CardExpr")
    ],
    targets: [
        .target(name: "RulesetKit", dependencies: ["CardExpr"], path: "Sources"),
        .testTarget(name: "RulesetKitTests", dependencies: ["RulesetKit"], path: "Tests"),
    ]
)
