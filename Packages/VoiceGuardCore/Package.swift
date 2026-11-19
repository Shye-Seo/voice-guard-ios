// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceGuardCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VoiceGuardCore",
            targets: ["VoiceGuardCore"]
        )
    ],
    targets: [
        .target(
            name: "VoiceGuardCore",
            dependencies: []
        ),
        .testTarget(
            name: "VoiceGuardCoreTests",
            dependencies: ["VoiceGuardCore"]
        )
    ]
)
