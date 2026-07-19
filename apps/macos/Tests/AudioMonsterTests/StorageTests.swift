import Darwin
import Foundation
import Testing

@testable import AudioMonster

private final class PlaybackRatePlayerSpy: PlaybackRatePlayer {
    var rate: Float = 0
    var defaultRate: Float = 0
    var startedRate: Float?

    func playImmediately(atRate rate: Float) {
        startedRate = rate
        self.rate = rate
    }
}

@MainActor
struct PlaybackRateControllerTests {
    @Test
    func sendsTheFullSelectedRangeToThePlayerAndUpdatesActivePlayback() {
        let player = PlaybackRatePlayerSpy()

        PlaybackRateController.start(player, at: 0.2)
        #expect(player.defaultRate == 0.2)
        #expect(player.startedRate == 0.2)

        PlaybackRateController.update(player, to: 3.0, whilePlaying: true)
        #expect(player.defaultRate == 3.0)
        #expect(player.rate == 3.0)
    }
}

@MainActor
struct AppSettingsStorageTests {
    @Test
    func playbackRateUsesTheFullRangeAndPersistsThroughTheAppModel() {
        let suiteName = "AudioMonsterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults) { nil }
        let model = AppModel(settings: settings)

        model.playbackRate = 0.2
        #expect(settings.playbackRate == 0.2)
        #expect(defaults.double(forKey: "playbackRate") == 0.2)

        model.playbackRate = 3.0
        #expect(settings.playbackRate == 3.0)
        #expect(defaults.double(forKey: "playbackRate") == 3.0)

        let restoredSettings = AppSettings(defaults: defaults) { nil }
        let restoredModel = AppModel(settings: restoredSettings)
        #expect(restoredModel.playbackRate == 3.0)
    }

    @Test
    func playbackRateMigratesTheFormerSpeedPreferenceAndClampsInvalidValues() {
        let suiteName = "AudioMonsterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(1.7, forKey: "speed")
        var settings = AppSettings(defaults: defaults) { nil }
        #expect(settings.playbackRate == 1.7)

        defaults.set(9.0, forKey: "playbackRate")
        settings = AppSettings(defaults: defaults) { nil }
        #expect(settings.playbackRate == 3.0)

        defaults.set(0.01, forKey: "playbackRate")
        settings = AppSettings(defaults: defaults) { nil }
        #expect(settings.playbackRate == 0.2)
    }

    @Test
    func playbackRateReplacesNonFiniteValuesWithTheDefault() {
        let suiteName = "AudioMonsterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for invalidValue in [Double.nan, .infinity, -.infinity] {
            defaults.set(invalidValue, forKey: "playbackRate")
            let settings = AppSettings(defaults: defaults) { nil }
            #expect(settings.playbackRate == 1.0)
        }
    }

    @Test
    func choosesICloudDocumentsWhenTheUbiquityContainerIsAvailable() async {
        let suiteName = "AudioMonsterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = URL(fileURLWithPath: "/tmp/AudioMonster-iCloud-test", isDirectory: true)
        let settings = AppSettings(defaults: defaults) { container }

        await settings.resolveRecommendedSaveFolder()

        #expect(settings.saveLocationKind == .iCloudDrive)
        #expect(
            settings.saveFolderURL
                == container.appendingPathComponent("Documents", isDirectory: true)
        )
    }

    @Test
    func fallsBackToApplicationSupportWhenICloudIsUnavailable() async {
        let suiteName = "AudioMonsterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults) { nil }

        await settings.resolveRecommendedSaveFolder()

        #expect(settings.saveLocationKind == .localFallback)
        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        #expect(
            settings.saveFolderURL
                == applicationSupport
                .appendingPathComponent("Audio Monster", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        )
    }

    @Test
    func aCustomFolderChosenDuringICloudLookupWins() async throws {
        let suiteName = "AudioMonsterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let providerStarted = AsyncStream<Void>.makeStream()
        let releaseProvider = DispatchSemaphore(value: 0)
        let container = URL(fileURLWithPath: "/tmp/AudioMonster-delayed-iCloud", isDirectory: true)
        let settings = AppSettings(defaults: defaults) {
            providerStarted.continuation.yield()
            releaseProvider.wait()
            return container
        }

        let resolution = Task { await settings.resolveRecommendedSaveFolder() }
        var providerEvents = providerStarted.stream.makeAsyncIterator()
        _ = await providerEvents.next()

        let customFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-custom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: customFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customFolder) }
        do {
            try settings.setSaveFolder(customFolder)
        } catch {
            releaseProvider.signal()
            await resolution.value
            throw error
        }

        releaseProvider.signal()
        await resolution.value

        #expect(settings.saveLocationKind == .custom)
        #expect(
            settings.saveFolderURL.resolvingSymlinksInPath()
                == customFolder.resolvingSymlinksInPath()
        )
    }
}

struct AudioFileStoreTests {
    @Test
    func copiesBytesMetadataAndUsesCollisionSafeNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-store-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("download.tmp")
        let destinationFolder = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectedBytes = Data("audio fixture".utf8)
        try expectedBytes.write(to: source)
        let sourceURL = try #require(URL(string: "https://example.com/narrated-document"))

        let first = try AudioFileStore.persist(
            from: source,
            in: destinationFolder,
            requestedName: "Narrated Document.mp3",
            sourceURL: sourceURL,
            locationKind: .localFallback
        )
        let second = try AudioFileStore.persist(
            from: source,
            in: destinationFolder,
            requestedName: "Narrated Document.mp3",
            sourceURL: sourceURL,
            locationKind: .localFallback
        )

        #expect(first.lastPathComponent == "Narrated Document.mp3")
        #expect(second.lastPathComponent == "Narrated Document (2).mp3")
        #expect(try Data(contentsOf: first) == expectedBytes)
        #expect(try whereFromValues(on: first) == [sourceURL.absoluteString])
    }

    @Test
    func omitsCredentialBearingSourceFromWhereFromMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-store-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("download.tmp")
        let destinationFolder = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("audio fixture".utf8).write(to: source)
        let sourceURL = try #require(
            URL(
                string: "https://private-reader:super-secret@example.com/narrated-document"
            ))
        let output = try AudioFileStore.persist(
            from: source,
            in: destinationFolder,
            requestedName: "Narrated Document.mp3",
            sourceURL: sourceURL,
            locationKind: .localFallback
        )

        #expect(try whereFromValues(on: output) == nil)
    }

    private func whereFromValues(on url: URL) throws -> [String]? {
        let attributeName = "com.apple.metadata:kMDItemWhereFroms"
        let size: Int = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return attributeName.withCString { getxattr(path, $0, nil, 0, 0, 0) }
        }
        if size < 0, errno == ENOATTR {
            return nil
        }
        guard size >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var data = Data(count: size)
        let readCount: Int = data.withUnsafeMutableBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return attributeName.withCString {
                    getxattr(path, $0, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard readCount == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String]
        )
    }
}
