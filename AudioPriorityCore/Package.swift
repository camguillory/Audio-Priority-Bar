// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudioPriorityCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "AudioPriorityCore",
            targets: ["AudioPriorityCore"]
        ),
    ],
    targets: [
        .target(name: "AudioPriorityCore"),
        .testTarget(
            name: "AudioPriorityCoreTests",
            dependencies: ["AudioPriorityCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
