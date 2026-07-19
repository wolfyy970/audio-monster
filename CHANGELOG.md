# Changelog

Notable user-facing changes to Audio Monster are documented here. The project
follows [Semantic Versioning](https://semver.org/) while its public API and user
experience mature.

## [0.1.0] - 2026-07-19

### Added

- Native SwiftUI menu-bar app for turning readable web articles into audio.
- On-device Kokoro speech generation through MLX Swift on Apple Silicon.
- Fifty-four grouped voices with automatically batched previews and selection
  autoplay.
- Progressive playback, cancellation, incremental conversion progress, and
  pitch-preserving playback from 0.2× to 3×.
- M4A output with source-URL metadata and collision-safe article filenames.
- iCloud Documents storage with local and security-scoped custom-folder paths.
- Saved-file library, Finder reveal, and playback controls.
- Pinned Mozilla Readability extraction inside Apple WebKit.
- Native test suites, benchmark harness, signed-release verification, Fastlane
  notarization, and GitHub repository automation.

[0.1.0]: https://github.com/wolfyy970/audio-monster/releases/tag/v0.1.0
