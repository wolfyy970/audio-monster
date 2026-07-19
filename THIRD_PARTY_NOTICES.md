# Third-party notices

Audio Monster is MIT-licensed, but components it uses retain their own licenses.
This file is a guide, not a substitute for the license text shipped by each
project.

## Included in this repository and app

- [Mozilla Readability](https://github.com/mozilla/readability), licensed under
  Apache License 2.0. Its pinned source, attribution, checksum, and license are
  stored in
  `apps/macos/Sources/AudioMonster/Resources/Readability/` and packaged with the
  app.

## Swift package dependencies

- [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), MIT.
- [MLX Swift](https://github.com/ml-explore/mlx-swift), MIT.
- [swift-huggingface](https://github.com/huggingface/swift-huggingface),
  Apache License 2.0.

The complete, pinned dependency graph is recorded in
`apps/macos/Package.resolved`. Transitive dependencies retain the licenses in
their respective repositories and Swift package checkouts.

## Model artifacts

The application downloads `mlx-community/Kokoro-82M-bf16` at runtime. Model
weights are not stored in this repository and are governed by the terms and
metadata published with the model on Hugging Face. Distributors are responsible
for reviewing and preserving the applicable model notices.
