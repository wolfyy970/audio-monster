// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AudioMonster",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AudioMonsterCore", targets: ["AudioMonsterCore"]),
        .executable(name: "AudioMonster", targets: ["AudioMonster"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "542fffacb3be8de47024b3b54888f71d72d46d30"
        )
    ],
    targets: [
        .target(
            name: "AudioMonsterCore",
            dependencies: [],
            path: "Sources/AudioMonsterCore"
        ),
        .executableTarget(
            name: "AudioMonster",
            dependencies: [
                "AudioMonsterCore",
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ],
            path: "Sources/AudioMonster",
            resources: [
                .copy("Resources/Extraction"),
                .copy("Resources/Readability")
            ]
        ),
        .testTarget(
            name: "AudioMonsterTests",
            dependencies: ["AudioMonster", "AudioMonsterCore"],
            path: "Tests/AudioMonsterTests"
        ),
        .testTarget(
            name: "AudioMonsterCoreTests",
            dependencies: ["AudioMonsterCore"],
            path: "Tests/AudioMonsterCoreTests"
        )
    ]
)
