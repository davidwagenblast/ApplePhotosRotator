// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoRotator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoRotator", targets: ["PhotoRotator"]),
        .library(name: "RotatorCore", targets: ["RotatorCore"]),
    ],
    targets: [
        // Pure Swift decision logic with no Apple-framework dependencies, so it is unit-testable anywhere.
        .target(name: "RotatorCore"),
        // The macOS app: PhotoKit, Vision, ImageIO, SQLite, SwiftUI.
        .executableTarget(
            name: "PhotoRotator",
            dependencies: ["RotatorCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "RotatorCoreTests", dependencies: ["RotatorCore"]),
        // Runs the real Vision pipeline on synthetic images (macOS only).
        .testTarget(name: "PhotoRotatorTests", dependencies: ["PhotoRotator", "RotatorCore"]),
    ]
)
