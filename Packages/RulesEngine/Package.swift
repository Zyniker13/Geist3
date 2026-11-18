// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RulesEngine",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "RulesEngine", targets: ["RulesEngine"]),
    ],
    targets: [
        .target(name: "RulesEngine", path: "Sources"),
        .testTarget(name: "RulesEngineTests", dependencies: ["RulesEngine"], path: "Tests"),
    ]
)
