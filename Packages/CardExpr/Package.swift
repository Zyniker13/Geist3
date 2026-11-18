// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CardExpr",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "CardExpr", targets: ["CardExpr"]),
    ],
    targets: [
        .target(name: "CardExpr", path: "Sources"),
        .testTarget(name: "CardExprTests", dependencies: ["CardExpr"], path: "Tests"),
    ]
)
