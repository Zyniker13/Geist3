// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "A11yKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "A11yKit", targets: ["A11yKit"])
    ],
    targets: [
        .target(name: "A11yKit", path: "Sources"),
        .testTarget(name: "A11yKitTests", dependencies: ["A11yKit"], path: "Tests"),
    ]
)
