# Contributing to Audio Monster

Thanks for helping make narrated reading better on Apple platforms. Bug fixes,
tests, accessibility improvements, performance work, documentation, and focused
feature proposals are welcome.

## Before you begin

Audio Monster is an early native-macOS project. Please open an issue before a
large architectural change so that implementation work starts with a shared
understanding of the user experience and platform constraints.

By participating, you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Development setup

You need an Apple Silicon Mac, macOS 14 or later, Xcode with its Metal Toolchain,
and Swift 6.2 or later. No Python, Node.js, local server, or external encoder is
required.

```sh
make setup
make dev
```

The first synthesis downloads the Kokoro model from Hugging Face. Model files
are cached outside the repository by the SDK.

Quit Audio Monster before a release or signed build replaces the app under
`dist/`. This is enforced to protect the new bundle's code signature.

Official artifacts use the pinned Fastlane version and the maintainer-only
process in [docs/releasing.md](docs/releasing.md). Contributor and pull-request
builds must never receive release credentials.

## Making a change

1. Keep changes narrow and explain the user-visible outcome.
2. Add or update tests for behavior, regressions, and failure paths.
3. Preserve the dependency-free `AudioMonsterCore` boundary.
4. Do not add signing credentials, provisioning profiles, generated audio,
   model weights, build products, or personal absolute paths.
5. Run the relevant verification commands before opening a pull request.

```sh
make format-check
make test
make test-benchmark
```

Use `make verify` for the complete local gate. It also creates an ad-hoc-signed
release app in `dist/`, so maintainers with a provisioned iCloud build should
run their signed lane again afterward.

To apply the repository's Swift formatting rules:

```sh
make format
```

## Pull requests

A good pull request includes a concise problem statement, the chosen approach,
verification evidence, and screenshots or recordings for visible UI changes.
Call out changes to storage, network access, model behavior, permissions,
metadata, licensing, or dependencies explicitly.

Avoid drive-by formatting, generated reports, and unrelated cleanup in a
functional change. User-facing changes should update the README or relevant
document under `docs/`.

## Licensing

Contributions are accepted under the repository's [MIT License](LICENSE). By
submitting a contribution, you represent that you have the right to license it
on those terms. Preserve third-party notices and license files.
