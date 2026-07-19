# iCloud storage and distribution

Audio Monster treats the native client as the owner of the user's narrated-document collection. The native Kokoro engine produces an artifact and a recommended filename; the app decides where to save it. For a user who has iCloud Drive available, the default is the `Documents` directory inside Audio Monster's ubiquity container. This makes the files available through iCloud Drive to other Apple devices signed into the same account.

This design uses iCloud Documents rather than CloudKit because the current data is a collection of user-visible audio files. CloudKit may be appropriate later for structured job history, indexes, or service state. Apple distinguishes these services in [Configuring iCloud services](https://developer.apple.com/documentation/Xcode/configuring-icloud-services).

## Runtime resolution

The client resolves the recommended location in this order:

1. A custom folder previously selected in Settings remains active through its security-scoped bookmark.
2. Otherwise, the app calls `FileManager.url(forUbiquityContainerIdentifier: nil)` on a background task. Apple notes that resolving a ubiquity container can take time and should not run on the main thread. The API returns `nil` when the container is unavailable. See [`url(forUbiquityContainerIdentifier:)`](https://developer.apple.com/documentation/Foundation/FileManager/url%28forUbiquityContainerIdentifier%3A%29).
3. When resolution succeeds, the destination is the container's `Documents` directory. The app's `NSUbiquitousContainers` configuration makes this document directory visible in iCloud Drive; Apple's [iCloud fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html) describes `Documents` as the public part of a ubiquity container.
4. When resolution returns `nil`, the client falls back to `~/Library/Application Support/Audio Monster/Library`. This covers a user without iCloud Drive, an offline or signed-out account, and a development build without working iCloud entitlements. The folder remains available through Settings and Finder, but does not pretend to be a provisioned iCloud container.

Settings displays whether the active destination is iCloud Drive, the local fallback, or a custom folder. Choosing “Use Recommended Location” clears the custom override and repeats iCloud resolution.

While the menu-bar app is running, it observes [`NSUbiquityIdentityDidChange`](https://developer.apple.com/documentation/foundation/nsubiquityidentitydidchangenotification) and resolves the recommended location again after an iCloud sign-in, sign-out, or Documents-sync setting change. A custom folder remains authoritative across those account changes.

## Staging and final placement

Every completed download is first staged on local storage and collision-checked before final placement. The client then uses a destination-specific path:

- For the app-owned iCloud Documents container, it calls `FileManager.setUbiquitous(_:itemAt:destinationURL:)` on a background task to move the staged file into iCloud. Apple documents that this operation may take time, should not run on the main thread, and performs file coordination internally. It must not be wrapped in a separate `NSFileCoordinator` operation. See [`setUbiquitous(_:itemAt:destinationURL:)`](https://developer.apple.com/documentation/foundation/filemanager/setubiquitous%28_%3Aitemat%3Adestinationurl%3A%29).
- For the Application Support fallback or a custom security-scoped folder, it copies the staged file through `NSFileCoordinator`. This preserves coordinated local/document-provider access without applying the iCloud-specific transfer API to destinations the app does not own.

Apple's broader document guidance explains coordinated access for iCloud documents and document-based clients; see [Designing Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html) and [`NSFileCoordinator`](https://developer.apple.com/documentation/foundation/nsfilecoordinator).

The source URL remains embedded in the audio tags and in macOS “Where from” metadata regardless of which location is active.

## Production configuration

The current identifiers are:

- macOS bundle: `org.audiomonster.AudioMonster`
- iCloud container: `iCloud.org.audiomonster.AudioMonster`

The Apple Developer team now has the bundle identifier and iCloud container
registered, with iCloud Documents enabled and the container assigned. The
repository keeps those stable identifiers in source but never stores private
keys or provisioning profiles.

For a signed build:

1. Keep the `NSUbiquitousContainers` entry in the production `Info.plist`, including the public-document setting and display name.
2. Download the `Audio Monster Developer ID` provisioning profile and keep it outside the repository.
3. Set `AUDIO_MONSTER_SIGNING_IDENTITY` to the matching Developer ID Application identity and `AUDIO_MONSTER_PROVISIONING_PROFILE` to the downloaded profile, then run `bundle exec fastlane mac signed`.
4. Test signed-in, signed-out, offline, first-launch, and conflict scenarios on real devices before notarization or broader distribution.

The signed build embeds the profile and uses
`apps/macos/Resources/AudioMonster.entitlements`. The current Developer ID
profile was issued in Apple's “Compatible with Xcode 5” iCloud Documents mode,
so its allow-list uses the team-qualified
`com.apple.developer.ubiquity-container-identifiers` form:
`<Team ID>.iCloud.org.audiomonster.AudioMonster`. The source entitlement uses
Apple's `$(TeamIdentifierPrefix)` placeholder, and the signed-build script
resolves it from the selected profile rather than committing a contributor's
Team ID. Do not add the newer
`com.apple.developer.icloud-services` or
`com.apple.developer.icloud-container-identifiers` keys to this build unless a
replacement profile explicitly authorizes them; macOS rejects an app at launch
when its restricted entitlements exceed the embedded profile. Apple's legacy
[iCloud entitlement reference](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingiCloud.html)
documents the team-qualified ubiquity-container form.

The default `.app` remains ad-hoc signed so contributors can build without Apple credentials. Ad-hoc signing does not provision the registered iCloud container, so its normal behavior is to receive no ubiquity URL and use the Application Support fallback. The `bundle exec fastlane mac signed` lane produces the provisioned Developer ID variant that can resolve the app-owned iCloud Documents folder. The `mac release` lane notarizes and staples that build for distribution.

## Future iPhone and iPad clients

A future iOS or iPadOS target can access the same files by using the same registered iCloud container under the same Apple Developer team and including that container in its entitlements. Sharing the container should be an explicit product decision: both apps then operate on the same user-visible document library and must use coordinated, conflict-aware file access.

Only completed audio artifacts live in the shared document container today. Menu settings and temporary synthesis files do not sync through iCloud. A future mobile client can use the same shared Swift domain and storage conventions while choosing either on-device synthesis or a future hosted API.

## Hosted-service boundary

A hosted backend does not receive access to a user's personal iCloud Drive container. If a hosted conversion service is added later, the native app remains responsible for downloading its artifact and placing it in iCloud Documents. A future web frontend can offer browser downloads, but it cannot write into this FileManager ubiquity container directly.

If product requirements later include server-visible libraries, web/mobile history synchronization, or server-side sharing, model that as a separate authenticated storage system or a deliberate CloudKit design. Do not expose a local iCloud path to a future service API: that service should return bytes and a filename while each Apple client owns persistence.
