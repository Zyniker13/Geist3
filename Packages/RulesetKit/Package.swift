// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RulesetKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "RulesetKit", targets: ["RulesetKit"]),
    ],
    targets: [
        .target(name: "RulesetKit", path: "Sources"),
        .testTarget(name: "RulesetKitTests", dependencies: ["RulesetKit"], path: "Tests"),
    ]
)
