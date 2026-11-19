// swift-tools-version: 6.0
import PackageDescription

// The rules-cli tool (§11.4): validate and fmt today; simulate and
// conformance join in P2.8. Lives in its own package so the app packages
// stay free of tool dependencies.
let package = Package(
    name: "rules-cli",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../../Packages/RulesetKit")
    ],
    targets: [
        .executableTarget(
            name: "rules-cli",
            dependencies: [.product(name: "RulesetKit", package: "RulesetKit")],
            path: "Sources/rules-cli"
        )
    ]
)
