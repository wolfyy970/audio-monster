# Native Swift TTS benchmark

This harness compares the viable native models in Blaizzy's `mlx-audio-swift` on the
same machine, text, and four-run protocol (one cold plus three warm). The dependency is pinned to commit
`542fffacb3be8de47024b3b54888f71d72d46d30` so results can be reproduced.

Each model runs in its own process. The harness records:

- model load time;
- cold synthesis time and the median of three warm runs;
- time to first audio chunk;
- generated duration and speed relative to real time;
- peak process resident memory and any memory reported by MLX;
- basic audio validity, clipping, and amplitude checks;
- WAV artifacts for listening at normal speed and at 0.4x with Apple's high-quality
  rate conversion.

Kitten is intentionally excluded. Soprano is measured only as a speed baseline, not
as a product recommendation, because it currently exposes only one voice.

## Build

MLX's Metal shaders cannot be produced by `swift build`. Install Apple's Metal
compiler component once, then build the executable with Xcode's command-line driver:

```sh
xcodebuild -downloadComponent MetalToolchain
xcodebuild build -quiet \
  -scheme AudioMonsterSwiftTTSBench \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release \
  -derivedDataPath .xcode-derived \
  CODE_SIGNING_ALLOWED=NO \
  -skipPackagePluginValidation
```

Run one model from this directory:

```sh
.xcode-derived/Build/Products/Release/swift-tts-bench \
  --model kokoro \
  --output results/kokoro
```

List the matrix, or listen to an artifact at 0.4x with Apple's high-quality rate
converter:

```sh
.xcode-derived/Build/Products/Release/swift-tts-bench --list
afplay -r 0.4 -q 1 results/2026-07-18/kokoro/kokoro-warm-1.wav
```

The metric and catalog unit tests do not execute MLX kernels, so they can run through
SwiftPM:

```sh
swift test -c release
```

From the repository root, the same benchmark-analysis suite is available as
`make test-benchmark` and is included in the full `make verify` gate.
