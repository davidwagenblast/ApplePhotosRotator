// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoRotator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoRotator", targets: ["PhotoRotator"]),
        .executable(name: "train-orientation-model", targets: ["TrainOrientationModel"]),
        .library(name: "RotatorCore", targets: ["RotatorCore"]),
    ],
    targets: [
        // Pure Swift decision logic and the orientation classifier, with no Apple-framework dependencies.
        .target(name: "RotatorCore"),
        // Vision code shared by the app and the training tool, so both compute image features identically.
        .target(name: "RotatorVision", dependencies: ["RotatorCore"]),
        // The macOS app: PhotoKit, Vision, ImageIO, SQLite, SwiftUI.
        .executableTarget(
            name: "PhotoRotator",
            dependencies: ["RotatorCore", "RotatorVision"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Trains the built-in scene orientation model (see .github/workflows/train-scene-model.yml).
        .executableTarget(
            name: "TrainOrientationModel",
            dependencies: ["RotatorCore", "RotatorVision"],
            path: "Tools/TrainOrientationModel",
            exclude: ["prepare_unsplash.py"]
        ),
        .testTarget(name: "RotatorCoreTests", dependencies: ["RotatorCore"]),
        // Runs the real Vision pipeline on synthetic images (macOS only).
        .testTarget(name: "PhotoRotatorTests", dependencies: ["PhotoRotator", "RotatorCore", "RotatorVision"]),
    ]
)
