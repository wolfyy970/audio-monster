# Third-party notices

Audio Monster is MIT-licensed, but the software and model components it uses
retain their own licenses and copyright notices. `apps/macos/Package.resolved`
is the authoritative, immutable dependency inventory for each build.

Release builds include this notice, Audio Monster's MIT license, and the exact
`LICENSE`, `COPYING`, and `NOTICE` files from every resolved Swift package under
`Contents/Resources/ThirdPartyLicenses/`. This preserves the legal material for
the complete compiled dependency graph in the downloadable app, rather than
maintaining a second, manually copied set that could drift from the resolved
versions.

## Native article extraction

- [SwiftReadability](https://github.com/wolfyy970/swift-readability), BSD
  3-Clause. Copyright © 2025 Lake of Fire. Audio Monster pins revision
  `6b38590ad7e86d6919a29c5045f67b3bc533deb6` and links only its native Swift
  product. The package preserves the intermediate port's attribution and is
  governed behaviorally by Mozilla Readability commit
  [`ab4027a8b37669745016869a37a504727992b2ba`](https://github.com/mozilla/readability/commit/ab4027a8b37669745016869a37a504727992b2ba).
- [Mozilla Readability](https://github.com/mozilla/readability), Apache License
  2.0. Copyright © 2010 Arc90 Inc. Its official source is the differential-test
  authority for SwiftReadability; Audio Monster does not ship or execute the
  JavaScript reference product.
- [Readability4J](https://github.com/dankito/Readability4J), Apache License 2.0.
  It is credited in SwiftReadability's lineage; it is not an Audio Monster
  runtime dependency or behavioral authority.
- [SwiftSoup](https://github.com/scinfu/SwiftSoup), MIT. Copyright © 2009–2025
  Jonathan Hedley and © 2016–2025 Nabil Chatbi. Audio Monster and
  SwiftReadability use exact version 2.13.6 for native HTML DOM operations.
- [swift-url (WebURL)](https://github.com/karwa/swift-url), Apache License 2.0.
  Copyright Karl Wagner and the swift-url contributors. SwiftReadability uses
  exact version 0.4.2 for browser-compatible WHATWG URL parsing and relative
  reference resolution; its upstream `NOTICE` ships with the app.

## Native speech and supporting packages

- [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), MIT.
  Copyright © 2025 Prince Canuma.
- [MLX Swift](https://github.com/ml-explore/mlx-swift), MIT. Copyright © 2023
  ml-explore.
- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm), MIT. Copyright ©
  2024 ml-explore.
- [swift-huggingface](https://github.com/huggingface/swift-huggingface) and
  [swift-transformers](https://github.com/huggingface/swift-transformers),
  Apache License 2.0.

The remaining transitive Swift packages and their exact versions are recorded
in `apps/macos/Package.resolved`; their unmodified license and notice files are
included in the release app as described above.

## Model artifacts

The application downloads
[`mlx-community/Kokoro-82M-bf16`](https://huggingface.co/mlx-community/Kokoro-82M-bf16)
at runtime. The converted model and its original
[`hexgrad/Kokoro-82M`](https://huggingface.co/hexgrad/Kokoro-82M) lineage are
published under the Apache License 2.0. Model weights are not stored in this
repository; distributors remain responsible for reviewing and preserving the
model-card notices that accompany the weights they distribute.
