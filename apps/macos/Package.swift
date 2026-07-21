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
        ),
        .package(
            url: "https://github.com/wolfyy970/swift-readability.git",
            revision: "531c4adbb342def2904440df13da06ee2258d697"
        ),
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            exact: "2.13.6"
        ),
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
                .product(name: "SwiftReadability", package: "swift-readability"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/AudioMonster"
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
