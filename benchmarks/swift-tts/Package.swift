// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AudioMonsterSwiftTTSBench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-tts-bench", targets: ["SwiftTTSBench"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "542fffacb3be8de47024b3b54888f71d72d46d30"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SwiftTTSBench",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ]
        ),
        .testTarget(
            name: "SwiftTTSBenchTests",
            dependencies: ["SwiftTTSBench"]
        ),
    ]
)
