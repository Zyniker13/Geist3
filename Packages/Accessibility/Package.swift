// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Accessibility",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Accessibility", targets: ["Accessibility"])
    ],
    targets: [
        .target(name: "Accessibility", path: "Sources"),
        .testTarget(name: "AccessibilityTests", dependencies: ["Accessibility"], path: "Tests"),
    ]
)
