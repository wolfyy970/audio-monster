import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

private actor FakeNativeEngine: AudioConversionEngine {
    func prepare() async throws {}

    func convert(
        article: ReadableArticle,
        voiceID: String,
        workspaceURL: URL,
        onEvent: @escaping @Sendable (SynthesisEvent) async -> Void
    ) async throws -> SynthesisResult {
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        await onEvent(.started(sectionCount: 2))
        for index in 0..<2 {
            let segmentURL = workspaceURL.appendingPathComponent("segment-\(index).wav")
            try Data("segment \(index)".utf8).write(to: segmentURL)
            await onEvent(
                .segment(
                    AudioSegment(index: index, url: segmentURL),
                    completed: index + 1,
                    total: 2
                ))
        }
        await onEvent(.encoding)
        let outputURL = workspaceURL.appendingPathComponent("complete.m4a")
        try Data("native audio".utf8).write(to: outputURL)
        return SynthesisResult(
            audioURL: outputURL,
            recommendedFilename: "native-article.m4a"
        )
    }

    func generatePreview(voiceID: String, destinationURL: URL) async throws -> VoicePreview {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("preview".utf8).write(to: destinationURL)
        return VoicePreview(
            voiceID: voiceID,
            status: .ready,
            audioURL: destinationURL,
            durationSeconds: 1
        )
    }
}

/// Keeps the AppModel integration test focused on orchestration across its
/// service seams. `AudioFileStoreTests` exercise the production coordinator,
/// collision handling, and metadata path independently.
private actor NativeFlowAudioPersister: AudioFilePersisting {
    func persist(_ request: AudioPersistenceRequest) async throws -> URL {
        try FileManager.default.createDirectory(
            at: request.destinationFolderURL,
            withIntermediateDirectories: true
        )
        let destination = request.destinationFolderURL
            .appendingPathComponent(request.requestedFilename)
        try FileManager.default.copyItem(at: request.sourceFileURL, to: destination)
        return destination
    }
}

private actor ControllableNativeEngine: AudioConversionEngine {
    private typealias EventHandler = @Sendable (SynthesisEvent) async -> Void

    private var eventHandler: EventHandler?
    private var conversionContinuation: CheckedContinuation<SynthesisResult, any Error>?
    private var conversionWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare() async throws {}

    func convert(
        article: ReadableArticle,
        voiceID: String,
        workspaceURL: URL,
        onEvent: @escaping @Sendable (SynthesisEvent) async -> Void
    ) async throws -> SynthesisResult {
        try await withCheckedThrowingContinuation { continuation in
            eventHandler = onEvent
            conversionContinuation = continuation
            let waiters = conversionWaiters
            conversionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func generatePreview(voiceID: String, destinationURL: URL) async throws -> VoicePreview {
        VoicePreview(
            voiceID: voiceID,
            status: .ready,
            audioURL: destinationURL,
            durationSeconds: 1
        )
    }

    func waitUntilConversionStarts() async {
        guard eventHandler == nil else { return }
        await withCheckedContinuation { continuation in
            conversionWaiters.append(continuation)
        }
    }

    func emit(_ event: SynthesisEvent) async {
        await eventHandler?(event)
    }

    func failConversion() {
        let continuation = conversionContinuation
        conversionContinuation = nil
        continuation?.resume(throwing: NativeFlowTestError.intentionalSynthesisFailure)
    }

    func cancelConversion() {
        let continuation = conversionContinuation
        conversionContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

private enum NativeFlowTestError: LocalizedError {
    case intentionalExtractionFailure
    case intentionalSaveFailure
    case intentionalSynthesisFailure
    case timedOut

    var errorDescription: String? {
        switch self {
        case .intentionalExtractionFailure: "Intentional extraction failure"
        case .intentionalSaveFailure: "Intentional save failure"
        case .intentionalSynthesisFailure: "Intentional synthesis failure"
        case .timedOut: "The asynchronous test condition timed out"
        }
    }
}

private actor FailOnceAudioPersister: AudioFilePersisting {
    private var attempts = 0

    func persist(_ request: AudioPersistenceRequest) async throws -> URL {
        attempts += 1
        if attempts == 1 { throw NativeFlowTestError.intentionalSaveFailure }
        return try Self.copy(request)
    }

    func attemptCount() -> Int { attempts }

    private static func copy(_ request: AudioPersistenceRequest) throws -> URL {
        try FileManager.default.createDirectory(
            at: request.destinationFolderURL,
            withIntermediateDirectories: true
        )
        let destination = request.destinationFolderURL
            .appendingPathComponent(request.requestedFilename)
        try FileManager.default.copyItem(at: request.sourceFileURL, to: destination)
        return destination
    }
}

private actor BlockingAudioPersister: AudioFilePersisting {
    private let started: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private var attempts = 0

    init(started: AsyncStream<Void>.Continuation, releases: AsyncStream<Void>) {
        self.started = started
        self.releases = releases
    }

    func persist(_ request: AudioPersistenceRequest) async throws -> URL {
        attempts += 1
        if attempts == 1 {
            started.yield()
            var iterator = releases.makeAsyncIterator()
            _ = await iterator.next()
        }
        try FileManager.default.createDirectory(
            at: request.destinationFolderURL,
            withIntermediateDirectories: true
        )
        let destination = request.destinationFolderURL
            .appendingPathComponent("\(attempts)-\(request.requestedFilename)")
        try FileManager.default.copyItem(at: request.sourceFileURL, to: destination)
        return destination
    }
}

private actor FailThenBlockingAudioPersister: AudioFilePersisting {
    private let retryStarted: AsyncStream<Void>.Continuation
    private let retryReleases: AsyncStream<Void>
    private var attempts = 0

    init(retryStarted: AsyncStream<Void>.Continuation, retryReleases: AsyncStream<Void>) {
        self.retryStarted = retryStarted
        self.retryReleases = retryReleases
    }

    func persist(_ request: AudioPersistenceRequest) async throws -> URL {
        attempts += 1
        if attempts == 1 { throw NativeFlowTestError.intentionalSaveFailure }
        retryStarted.yield()
        var iterator = retryReleases.makeAsyncIterator()
        _ = await iterator.next()
        let destination = request.destinationFolderURL
            .appendingPathComponent("retry-\(request.requestedFilename)")
        try FileManager.default.copyItem(at: request.sourceFileURL, to: destination)
        return destination
    }

    func attemptCount() -> Int { attempts }
}

private actor ControllableAudioLibraryScanner: AudioLibraryScanning {
    private var pendingScans: [URL: CheckedContinuation<[AudioLibraryItem], Error>] = [:]
    private var requestedFolders: Set<URL> = []
    private var requestWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func scan(folderURL: URL) async throws -> [AudioLibraryItem] {
        try await withCheckedThrowingContinuation { continuation in
            pendingScans[folderURL] = continuation
            requestedFolders.insert(folderURL)
            let waiters = requestWaiters.removeValue(forKey: folderURL) ?? []
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilRequested(_ folderURL: URL) async {
        guard !requestedFolders.contains(folderURL) else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[folderURL, default: []].append(continuation)
        }
    }

    func complete(folderURL: URL, with items: [AudioLibraryItem]) {
        pendingScans.removeValue(forKey: folderURL)?.resume(returning: items)
    }
}

@MainActor
private final class FakeArticleExtractor: ArticleExtracting {
    let article: ReadableArticle

    init(article: ReadableArticle) { self.article = article }

    func extract(url: URL) async throws -> ReadableArticle { article }
}

@MainActor
private final class FailingArticleExtractor: ArticleExtracting {
    func extract(url: URL) async throws -> ReadableArticle {
        throw NativeFlowTestError.intentionalExtractionFailure
    }
}

@MainActor
private final class NativeFlowPlaybackItem: PlaybackItemReference {
    private let object = NSObject()

    var notificationObject: AnyObject { object }
}

@MainActor
private final class NativeFlowPlaybackPlayer: ManagedPlaybackQueuePlayer {
    var rate: Float = 0
    var defaultRate: Float = 0
    var durationSeconds: Double? = 1
    var hasPlayableItem = false

    func playImmediately(atRate rate: Float) { self.rate = rate }
    func pause() { rate = 0 }
    func seek(to _: Double) {}
    func addPeriodicTimeObserver(
        interval _: Double,
        using _: @escaping @MainActor (Double) -> Void
    ) -> Any { NSObject() }
    func removeTimeObserver(_: Any) {}
    func loadDurationSeconds() async -> Double? { durationSeconds }

    func enqueue(url _: URL) -> any PlaybackItemReference {
        hasPlayableItem = true
        return NativeFlowPlaybackItem()
    }

    func removeAllItems() { hasPlayableItem = false }
}

@MainActor
private final class NativeFlowPlaybackFactory: PlaybackPlayerCreating {
    func makePlayer(
        url _: URL,
        automaticallyWaitsToMinimizeStalling _: Bool
    ) -> PlaybackPlayerSession {
        let player = NativeFlowPlaybackPlayer()
        player.hasPlayableItem = true
        return PlaybackPlayerSession(player: player, item: NativeFlowPlaybackItem())
    }

    func makeQueuePlayer() -> any ManagedPlaybackQueuePlayer {
        NativeFlowPlaybackPlayer()
    }
}

@MainActor
private final class NativeFlowPlaybackObservation: PlaybackObservation {
    func cancel() {}
}

@MainActor
private final class NativeFlowPlaybackEvents: PlaybackEventObserving {
    func observeEnd(
        of _: any PlaybackItemReference,
        using _: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation { NativeFlowPlaybackObservation() }

    func observeFailure(
        of _: any PlaybackItemReference,
        using _: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation { NativeFlowPlaybackObservation() }
}

@MainActor
struct AppModelNativeFlowTests {
    private func makePlaybackCoordinator(rate: Double) -> PlaybackCoordinator {
        PlaybackCoordinator(
            playbackRate: rate,
            playerFactory: NativeFlowPlaybackFactory(),
            eventCenter: NativeFlowPlaybackEvents()
        )
    }

    @Test
    func convertsAndSavesWithoutAServiceOrHTTPPolling() async throws {
        let suiteName = "AudioMonsterNativeFlow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputFolder) }
        let settings = AppSettings(
            defaults: defaults,
            ubiquityContainerProvider: { nil },
            localFallbackFolderProvider: { outputFolder }
        )
        settings.autoPlay = false
        let sourceURL = try #require(URL(string: "https://example.com/native"))
        let article = ReadableArticle(
            sourceURL: sourceURL,
            resolvedURL: sourceURL,
            title: "Native Article",
            text: "A complete readable article body that is synthesized entirely in Swift."
        )
        let model = AppModel(
            settings: settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FakeArticleExtractor(article: article),
            filePersister: NativeFlowAudioPersister(),
            playbackCoordinator: makePlaybackCoordinator(rate: settings.playbackRate),
            voicePreviewDirectory: outputFolder.appendingPathComponent("test-previews")
        )

        model.inputURL = sourceURL.absoluteString
        model.submit()
        for _ in 0..<200 {
            let didFinishSaving =
                model.savedFileURL != nil && model.libraryItems.map(\.filename).contains("native-article.m4a")
            if didFinishSaving || model.currentJob?.status == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.currentJob?.status == .completed)
        #expect(model.currentJob?.segmentsReady == 2)
        #expect(model.currentJob?.progress == 1)
        #expect(model.errorMessage == nil)
        #expect(model.savedFileURL?.lastPathComponent == "native-article.m4a")
        let savedFileURL = try #require(model.savedFileURL)
        #expect(try Data(contentsOf: savedFileURL) == Data("native audio".utf8))
        #expect(model.libraryItems.map(\.filename).contains("native-article.m4a"))
    }

    @Test
    func rejectsCredentialBearingURLsBeforeExtraction() throws {
        let suiteName = "AudioMonsterCredentialURL.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults) { nil }
        let sourceURL = try #require(URL(string: "https://example.com/article"))
        let article = ReadableArticle(
            sourceURL: sourceURL,
            resolvedURL: sourceURL,
            title: "Article",
            text: "Readable article text"
        )
        let model = AppModel(
            settings: settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FakeArticleExtractor(article: article),
            playbackCoordinator: makePlaybackCoordinator(rate: settings.playbackRate)
        )

        model.inputURL = "https://reader:secret@example.com/private-article"
        model.submit()

        #expect(model.currentJob == nil)
        #expect(model.errorMessage == "Enter a complete http:// or https:// URL.")
    }

    @Test
    func extractionFailureLeavesTheJobFailedWithoutChangingEngineAvailability() async throws {
        let fixture = try makeFixture(name: "ExtractionFailure")
        defer { fixture.cleanup() }
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FailingArticleExtractor(),
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )
        await model.refreshEngine()

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        try await waitUntil { model.currentJob?.status == .failed }

        #expect(model.currentJob?.progress == 0.02)
        #expect(
            model.currentJob?.message
                == NativeFlowTestError.intentionalExtractionFailure.localizedDescription
        )
        #expect(
            model.errorMessage
                == NativeFlowTestError.intentionalExtractionFailure.localizedDescription
        )
        #expect(model.engineState == .ready)
    }

    @Test
    func synthesisFailureKeepsEngineReadyAndRejectsLateSameJobEvents() async throws {
        let fixture = try makeFixture(name: "SynthesisFailure")
        defer { fixture.cleanup() }
        let engine = ControllableNativeEngine()
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: engine,
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )
        await model.refreshEngine()

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        await engine.waitUntilConversionStarts()
        await engine.emit(.started(sectionCount: 2))
        await engine.emit(.encoding)
        await engine.failConversion()
        try await waitUntil { model.currentJob?.status == .failed }

        #expect(model.engineState == .ready)
        #expect(
            model.errorMessage
                == NativeFlowTestError.intentionalSynthesisFailure.localizedDescription
        )
        let terminalJob = try #require(model.currentJob)

        let lateSegment = AudioSegment(
            index: 99,
            url: fixture.outputFolder.appendingPathComponent("late.wav")
        )
        await engine.emit(.started(sectionCount: 100))
        await engine.emit(.segment(lateSegment, completed: 100, total: 100))
        await engine.emit(.encoding)

        #expect(model.currentJob == terminalJob)
        #expect(model.engineState == .ready)
    }

    @Test
    func cancellationIsTerminalAndRejectsLateSameJobEvents() async throws {
        let fixture = try makeFixture(name: "Cancellation")
        defer { fixture.cleanup() }
        let engine = ControllableNativeEngine()
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: engine,
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )
        await model.refreshEngine()

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        await engine.waitUntilConversionStarts()
        await engine.emit(.started(sectionCount: 2))
        model.cancelCurrentJob()
        await engine.cancelConversion()
        try await waitUntil { model.currentJob?.status == .cancelled }

        #expect(model.currentJob?.message == "Conversion cancelled")
        #expect(model.errorMessage == nil)
        #expect(model.engineState == .ready)
        let terminalJob = try #require(model.currentJob)

        let lateSegment = AudioSegment(
            index: 99,
            url: fixture.outputFolder.appendingPathComponent("late.wav")
        )
        await engine.emit(.started(sectionCount: 100))
        await engine.emit(.segment(lateSegment, completed: 100, total: 100))
        await engine.emit(.encoding)

        #expect(model.currentJob == terminalJob)
    }

    @Test
    func cancellationIntentWinsWhenTheEngineThrowsAnOrdinaryError() async throws {
        let fixture = try makeFixture(name: "CancellationOrdinaryError")
        defer { fixture.cleanup() }
        let engine = ControllableNativeEngine()
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: engine,
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )
        await model.refreshEngine()

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        await engine.waitUntilConversionStarts()
        await engine.emit(.started(sectionCount: 2))
        model.cancelCurrentJob()
        await engine.failConversion()
        try await waitUntil { model.currentJob?.status.isTerminal == true }

        #expect(model.currentJob?.status == .cancelled)
        #expect(model.currentJob?.message == "Conversion cancelled")
        #expect(model.errorMessage == nil)
        #expect(model.engineState == .ready)
    }

    @Test
    func malformedSynthesisCountsKeepProgressFiniteBoundedAndMonotonic() async throws {
        let fixture = try makeFixture(name: "MalformedProgress")
        defer { fixture.cleanup() }
        let engine = ControllableNativeEngine()
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: engine,
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )
        await model.refreshEngine()

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        await engine.waitUntilConversionStarts()
        var progressValues = [model.currentJob?.progress ?? .nan]

        await engine.emit(.started(sectionCount: 2))
        progressValues.append(model.currentJob?.progress ?? .nan)
        await engine.emit(
            .segment(
                AudioSegment(
                    index: 0,
                    url: fixture.outputFolder.appendingPathComponent("malformed-0.wav")
                ),
                completed: .max,
                total: 0
            ))
        progressValues.append(model.currentJob?.progress ?? .nan)
        await engine.emit(
            .segment(
                AudioSegment(
                    index: 1,
                    url: fixture.outputFolder.appendingPathComponent("malformed-1.wav")
                ),
                completed: -10,
                total: -4
            ))
        progressValues.append(model.currentJob?.progress ?? .nan)
        await engine.emit(.encoding)
        progressValues.append(model.currentJob?.progress ?? .nan)
        await engine.emit(.started(sectionCount: -3))
        progressValues.append(model.currentJob?.progress ?? .nan)

        #expect(progressValues.allSatisfy { $0.isFinite && (0...0.96).contains($0) })
        #expect(zip(progressValues, progressValues.dropFirst()).allSatisfy { $0.0 <= $0.1 })

        model.cancelCurrentJob()
        await engine.cancelConversion()
        try await waitUntil { model.currentJob?.status == .cancelled }
    }

    @Test
    func persistenceFailureLeavesCompletedAudioRetryableAndEngineReady() async throws {
        let fixture = try makeFixture(name: "SaveRetry")
        defer { fixture.cleanup() }
        let persister = FailOnceAudioPersister()
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            filePersister: persister,
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )
        await model.refreshEngine()

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        try await waitUntil {
            !model.isSavingFile && model.currentJob?.progress == 1
        }

        #expect(model.currentJob?.status == .completed)
        #expect(model.savedFileURL == nil)
        #expect(model.engineState == .ready)
        #expect(model.errorMessage == NativeFlowTestError.intentionalSaveFailure.localizedDescription)

        model.retrySavingCompletedJob()
        try await waitUntil { model.savedFileURL != nil }

        #expect(await persister.attemptCount() == 2)
        #expect(model.currentJob?.status == .completed)
        #expect(model.engineState == .ready)
    }

    @Test
    func rapidRetryActionsStartOnlyOnePersistenceAttempt() async throws {
        let fixture = try makeFixture(name: "SaveRetryCoalescing")
        defer { fixture.cleanup() }
        let retryStarted = AsyncStream<Void>.makeStream()
        let retryRelease = AsyncStream<Void>.makeStream()
        let persister = FailThenBlockingAudioPersister(
            retryStarted: retryStarted.continuation,
            retryReleases: retryRelease.stream
        )
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            filePersister: persister,
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        try await waitUntil {
            !model.isSavingFile && model.currentJob?.status == .completed
                && model.errorMessage
                    == NativeFlowTestError.intentionalSaveFailure.localizedDescription
        }

        model.retrySavingCompletedJob()
        model.retrySavingCompletedJob()
        var retryStartedIterator = retryStarted.stream.makeAsyncIterator()
        _ = await retryStartedIterator.next()

        #expect(model.isSavingFile)
        #expect(await persister.attemptCount() == 2)

        retryRelease.continuation.yield()
        try await waitUntil { model.savedFileURL != nil && !model.isSavingFile }
        #expect(await persister.attemptCount() == 2)
    }

    @Test
    func aSecondSubmissionIsRejectedWhilePersistenceOwnsTheWorkspace() async throws {
        let fixture = try makeFixture(name: "BlockedSave")
        defer { fixture.cleanup() }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let persister = BlockingAudioPersister(
            started: started.continuation,
            releases: release.stream
        )
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            filePersister: persister,
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()
        let firstJobID = try #require(model.currentJob?.id)

        model.inputURL = "https://example.com/second-article"
        model.submit()

        #expect(model.currentJob?.id == firstJobID)
        #expect(model.errorMessage == "Finish or cancel the current conversion first.")

        release.continuation.yield()
        try await waitUntil { !model.isSavingFile }
    }

    @Test
    func saveFolderCannotChangeWhilePersistenceOwnsTheDestination() async throws {
        let fixture = try makeFixture(name: "SaveDestinationLock")
        defer { fixture.cleanup() }
        let originalFolder = fixture.settings.saveFolderURL
        let otherFolder = fixture.outputFolder.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let persister = BlockingAudioPersister(
            started: started.continuation,
            releases: release.stream
        )
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            filePersister: persister,
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )

        model.inputURL = fixture.article.sourceURL.absoluteString
        model.submit()
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()

        var folderChangeWasRejected = false
        do {
            try fixture.settings.setSaveFolder(otherFolder)
        } catch {
            folderChangeWasRejected = true
        }
        #expect(folderChangeWasRejected)
        #expect(fixture.settings.saveFolderURL == originalFolder)

        release.continuation.yield()
        try await waitUntil { model.savedFileURL != nil && !model.isSavingFile }

        let savedFileURL = try #require(model.savedFileURL)
        #expect(savedFileURL.deletingLastPathComponent() == originalFolder)
        #expect(fixture.settings.saveFolderURL == originalFolder)
        // File enumeration can resolve the macOS /var -> /private/var alias even
        // though both URLs identify the same file.
        #expect(model.libraryItems.contains { $0.filename == savedFileURL.lastPathComponent })
    }

    @Test
    func anOlderLibraryScanCannotOverwriteTheNewFolderResult() async throws {
        let fixture = try makeFixture(name: "LibraryRefreshRace")
        defer { fixture.cleanup() }
        let firstFolder = fixture.outputFolder.appendingPathComponent("first", isDirectory: true)
        let secondFolder = fixture.outputFolder.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try fixture.settings.setSaveFolder(firstFolder)
        let resolvedFirstFolder = fixture.settings.saveFolderURL

        let scanner = ControllableAudioLibraryScanner()
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            libraryScanner: scanner,
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )
        let oldItem = AudioLibraryItem(
            url: resolvedFirstFolder.appendingPathComponent("old.m4a"),
            modifiedAt: .distantPast
        )

        let olderRefresh = Task { await model.refreshLibrary() }
        await scanner.waitUntilRequested(resolvedFirstFolder)

        try fixture.settings.setSaveFolder(secondFolder)
        let resolvedSecondFolder = fixture.settings.saveFolderURL
        let newItem = AudioLibraryItem(
            url: resolvedSecondFolder.appendingPathComponent("new.m4a"),
            modifiedAt: .now
        )
        let newerRefresh = Task { await model.refreshLibrary() }
        await scanner.waitUntilRequested(resolvedSecondFolder)
        await scanner.complete(folderURL: resolvedSecondFolder, with: [newItem])
        await newerRefresh.value
        #expect(model.libraryItems == [newItem])

        await scanner.complete(folderURL: resolvedFirstFolder, with: [oldItem])
        await olderRefresh.value

        #expect(model.libraryItems == [newItem])
    }

    @Test
    func changingSaveFolderImmediatelyInvalidatesTheOldLibrarySnapshot() async throws {
        let fixture = try makeFixture(name: "LibraryFolderIdentity")
        defer { fixture.cleanup() }
        let firstFolder = fixture.outputFolder.appendingPathComponent("first", isDirectory: true)
        let secondFolder = fixture.outputFolder.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try fixture.settings.setSaveFolder(firstFolder)
        let resolvedFirstFolder = fixture.settings.saveFolderURL

        let scanner = ControllableAudioLibraryScanner()
        let model = AppModel(
            settings: fixture.settings,
            conversionEngine: FakeNativeEngine(),
            articleExtractor: FakeArticleExtractor(article: fixture.article),
            libraryScanner: scanner,
            playbackCoordinator: makePlaybackCoordinator(rate: fixture.settings.playbackRate),
            voicePreviewDirectory: fixture.outputFolder.appendingPathComponent("previews")
        )
        let oldItem = AudioLibraryItem(
            url: resolvedFirstFolder.appendingPathComponent("old.m4a"),
            modifiedAt: .distantPast
        )

        let firstRefresh = Task { await model.refreshLibrary() }
        await scanner.waitUntilRequested(resolvedFirstFolder)
        await scanner.complete(folderURL: resolvedFirstFolder, with: [oldItem])
        await firstRefresh.value
        #expect(model.libraryItems == [oldItem])

        try fixture.settings.setSaveFolder(secondFolder)
        let resolvedSecondFolder = fixture.settings.saveFolderURL

        #expect(model.libraryItems.isEmpty)
        model.toggleLibraryPlayback(oldItem)
        #expect(model.activeLibraryItemID == nil)

        let secondRefresh = Task { await model.refreshLibrary() }
        await scanner.waitUntilRequested(resolvedSecondFolder)
        #expect(model.libraryItems.isEmpty)
        await scanner.complete(folderURL: resolvedSecondFolder, with: [])
        await secondRefresh.value
    }

    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let outputFolder: URL
        let settings: AppSettings
        let article: ReadableArticle

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: outputFolder)
        }
    }

    private func makeFixture(name: String) throws -> Fixture {
        let suiteName = "AudioMonster\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults) { nil }
        try settings.setSaveFolder(outputFolder)
        settings.autoPlay = false
        let sourceURL = try #require(URL(string: "https://example.com/native"))
        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            outputFolder: outputFolder,
            settings: settings,
            article: ReadableArticle(
                sourceURL: sourceURL,
                resolvedURL: sourceURL,
                title: "Native Article",
                text: "A complete readable article body that is synthesized entirely in Swift."
            )
        )
    }

    private func waitUntil(
        attempts: Int = 300,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeFlowTestError.timedOut
    }
}
