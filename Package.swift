// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RE2Trainer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RE2Trainer",
            path: "Sources/RE2Trainer"
        )
    ]
)
