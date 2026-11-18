// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    targets: [
        .target(name: "Persistence", path: "Sources"),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"], path: "Tests"),
    ]
)
