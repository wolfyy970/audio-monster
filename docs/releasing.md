# Releasing Audio Monster

Official releases are built on a trusted maintainer Mac through Fastlane. Pull
requests and contributor builds never receive Apple or GitHub credentials.

The release lane runs the static gate, all native tests, a Developer ID build,
bundle verification, Apple notarization, ticket stapling, Gatekeeper assessment,
archive validation, and SHA-256 generation. It produces:

```text
artifacts/Audio-Monster-v<VERSION>-macOS-arm64.zip
artifacts/Audio-Monster-v<VERSION>-macOS-arm64.zip.sha256
```

The version comes from `CFBundleShortVersionString` in the source `Info.plist`.
The app must not be running from `dist/` during a release.

## Install the pinned Fastlane toolchain

```sh
bundle install
```

`Gemfile.lock` pins the complete Ruby dependency graph. Homebrew Fastlane remains
convenient for development, but official release commands should use
`bundle exec fastlane`.

## Signing inputs

Keep the Developer ID identity in the login keychain and the provisioning
profile outside the repository:

```sh
export AUDIO_MONSTER_SIGNING_IDENTITY='Developer ID Application: …'
export AUDIO_MONSTER_PROVISIONING_PROFILE='/path/to/Audio_Monster.provisionprofile'
```

The profile authorizes the iCloud Documents entitlement. The build derives the
Apple Team ID from the profile; no personal Team ID belongs in source control.

## Notarization authentication

An App Store Connect API key is preferred. Download its `.p8` file once and
store it securely outside the repository:

```sh
export AUDIO_MONSTER_ASC_KEY_ID='KEY_ID'
export AUDIO_MONSTER_ASC_ISSUER_ID='ISSUER_UUID'
export AUDIO_MONSTER_ASC_KEY_PATH='/secure/path/AuthKey_KEY_ID.p8'
```

The fallback is an Apple ID app-specific password:

```sh
export AUDIO_MONSTER_NOTARY_APPLE_ID='developer@example.com'
export AUDIO_MONSTER_NOTARY_TEAM_ID='APPLE_TEAM_ID'
export FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD='app-specific-password'
```

Do not put any of these values in `.env`, shell history, Fastfiles, commits, or
issue logs. Prefer a password manager or an ephemeral shell session.

## Produce the release artifact

Quit Audio Monster, then run:

```sh
make release
```

Success requires all of the following:

- `codesign --verify --deep --strict` accepts the app.
- `stapler validate` finds the attached notarization ticket.
- Gatekeeper reports `source=Notarized Developer ID`.
- The final ZIP passes an integrity test and has a matching checksum file.

The temporary ZIP uploaded by Fastlane's notarization action is deleted. The
final ZIP is created only after stapling so the ticket is included.

## Create a draft GitHub release

Publishing is intentionally separate and requires a clean, committed repository
with a matching `v<VERSION>` tag:

```sh
export AUDIO_MONSTER_GITHUB_REPOSITORY='owner/audio-monster'
export FL_GITHUB_RELEASE_API_TOKEN='github-token'
bundle exec fastlane mac publish
```

The lane rebuilds and revalidates the artifact, then creates a **draft** GitHub
prerelease with generated notes, the ZIP, and its checksum. A maintainer must
review and publish that draft in GitHub. The lane will not create an implicit
tag or publish a dirty working tree.

## Release checklist

1. Update `CFBundleShortVersionString`, `CFBundleVersion`, README, and notices.
2. Commit the complete change and create the matching version tag.
3. Quit the running app.
4. Run `make release` and inspect the artifact locally.
5. Extract the ZIP in a clean location and launch it through Finder.
6. Run the publish lane and review the draft release.
7. Publish the GitHub release only after the download is tested on another Mac.
