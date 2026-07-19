# Changelog

Notable user-facing changes to Audio Monster are documented here. The project
follows [Semantic Versioning](https://semver.org/) while its public API and user
experience mature.

## [0.2.1] - 2026-07-20

### Changed

- Updated to SwiftReadability 0.3.0 and moved the selected non-Mozilla extension
  combination into an application-owned policy. The reusable library no longer
  contains an Audio Monster preset or product references.
- Preserved the existing native extraction behavior while making the package
  and application boundaries explicit and independently testable.

## [0.2.0] - 2026-07-20

### Changed

- Replaced the production Mozilla JavaScript extractor with a native Swift
  Readability pipeline pinned to an immutable package revision.
- Kept WebKit only for browser rendering and a minimal rendered-DOM snapshot
  bridge, then moved article selection, cleanup, and narration projection into
  independently tested Swift components.
- Pinned SwiftSoup 2.13.6 and WebURL 0.4.2, then verified the Swift extractor's
  exact serialized content, scalar results, and canonical content DOM against
  official Mozilla Readability across all 136 compatibility fixtures.
- Isolated Audio Monster's publisher and media recovery rules behind an
  app-owned opt-in extension policy so default SwiftReadability behavior remains
  Mozilla compatible.
- Preserved Readability-selected tables of contents, editorial asides, and
  correction footers while rejecting navigation-only pages and browser
  challenges without suppressing legitimate articles with challenge-like titles.
- Added a reproducible Finder and Dock icon generated from the existing monster
  vector artwork.
- Bundled and independently signed the Swift compatibility runtime required by
  the macOS 14 deployment target.
- Hardened dependency, bundle, release-tag, archive, signing, notarization, and
  legacy-runtime verification for the Apple Silicon release.

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

[0.2.1]: https://github.com/wolfyy970/audio-monster/releases/tag/v0.2.1
[0.2.0]: https://github.com/wolfyy970/audio-monster/releases/tag/v0.2.0
[0.1.0]: https://github.com/wolfyy970/audio-monster/releases/tag/v0.1.0
