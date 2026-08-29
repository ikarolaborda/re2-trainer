// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RE2Trainer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "re2trainer", targets: ["RE2Trainer"]),
        .executable(name: "RE2TrainerGUI", targets: ["RE2TrainerGUI"]),
    ],
    targets: [
        .target(name: "RE2TrainerCore", path: "Sources/RE2TrainerCore"),
        .executableTarget(name: "RE2Trainer", dependencies: ["RE2TrainerCore"], path: "Sources/RE2Trainer"),
        .executableTarget(name: "RE2TrainerGUI", dependencies: ["RE2TrainerCore"], path: "Sources/RE2TrainerGUI"),
    ]
)
