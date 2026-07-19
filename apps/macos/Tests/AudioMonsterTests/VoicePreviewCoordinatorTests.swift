@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import AudioMonster

private enum PreviewTestError: LocalizedError {
    case intentional
    case rejectedArtifact
    case timedOut

    var errorDescription: String? {
        switch self {
        case .intentional: "Intentional preview failure"
        case .rejectedArtifact: "Rejected preview artifact"
        case .timedOut: "The preview test timed out"
        }
    }
}

private actor ControlledPreviewGenerator: VoicePreviewGenerating {
    enum Outcome: Sendable, Equatable {
        case success
        case failure
    }

    private let blockedVoiceIDs: Set<String>
    private let ignoresCancellation: Bool
    private var outcomes: [String: [Outcome]]
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var requests: [(voiceID: String, destination: URL)] = []

    init(
        blockedVoiceIDs: Set<String> = [],
        ignoresCancellation: Bool = false,
        outcomes: [String: [Outcome]] = [:]
    ) {
        self.blockedVoiceIDs = blockedVoiceIDs
        self.ignoresCancellation = ignoresCancellation
        self.outcomes = outcomes
    }

    func generatePreview(voiceID: String, destinationURL: URL) async throws -> VoicePreview {
        requests.append((voiceID, destinationURL))
        let outcome =
            outcomes[voiceID]?.isEmpty == false
            ? outcomes[voiceID]!.removeFirst()
            : .success

        if blockedVoiceIDs.contains(voiceID) {
            await withCheckedContinuation { continuation in
                continuations[voiceID, default: []].append(continuation)
            }
        }
        if !ignoresCancellation { try Task.checkCancellation() }
        if outcome == .failure { throw PreviewTestError.intentional }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("generated-\(voiceID)".utf8).write(to: destinationURL)
        return VoicePreview(
            voiceID: voiceID,
            status: .ready,
            audioURL: destinationURL,
            durationSeconds: 8
        )
    }

    func releaseFirst(_ voiceID: String) {
        guard var voiceContinuations = continuations[voiceID], !voiceContinuations.isEmpty else {
            return
        }
        let continuation = voiceContinuations.removeFirst()
        continuations[voiceID] = voiceContinuations
        continuation.resume()
    }

    func requestedVoiceIDs() -> [String] { requests.map(\.voiceID) }

    func destinations(for voiceID: String) -> [URL] {
        requests.filter { $0.voiceID == voiceID }.map(\.destination)
    }
}

@MainActor
private final class PreviewCacheSpy: VoicePreviewCaching {
    let directory: URL
    var artifacts: [String: CachedVoicePreview] = [:]
    var rejectedVoiceIDs: Set<String> = []
    private(set) var committedVoiceIDs: [String] = []
    private(set) var discardedURLs: [URL] = []
    private var stagingCounter = 0

    init(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-preview-cache-\(UUID().uuidString)")
    ) {
        self.directory = directory
    }

    func load(voiceIDs: [String]) -> [String: CachedVoicePreview] {
        artifacts.filter { voiceIDs.contains($0.key) }
    }

    func makeStagingURL(voiceID: String) throws -> URL {
        stagingCounter += 1
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(".\(voiceID)-\(stagingCounter).partial.wav")
    }

    func commit(stagingURL: URL, voiceID: String) throws -> CachedVoicePreview {
        if rejectedVoiceIDs.contains(voiceID) { throw PreviewTestError.rejectedArtifact }
        committedVoiceIDs.append(voiceID)
        let artifact = CachedVoicePreview(
            url: directory.appendingPathComponent("\(voiceID).wav"),
            durationSeconds: 8
        )
        artifacts[voiceID] = artifact
        return artifact
    }

    func discardStagingFile(at url: URL) {
        discardedURLs.append(url)
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
private final class PreviewPlaybackSpy: VoicePreviewPlaybackControlling {
    private(set) var playingPreviewVoiceID: String?
    private(set) var played: [(voiceID: String, url: URL)] = []
    private(set) var stopCount = 0

    func playVoicePreview(voiceID: String, url: URL) {
        playingPreviewVoiceID = voiceID
        played.append((voiceID, url))
    }

    func stopVoicePreview() {
        playingPreviewVoiceID = nil
        stopCount += 1
    }
}

@MainActor
struct VoicePreviewCoordinatorTests {
    @Test
    func loadsCachedPreviewsAndPublishesDerivedCounts() {
        let cache = PreviewCacheSpy()
        cache.artifacts["voice-b"] = CachedVoicePreview(
            url: cache.directory.appendingPathComponent("voice-b.wav"),
            durationSeconds: 4
        )
        let coordinator = makeCoordinator(
            voiceIDs: ["voice-a", "voice-b"],
            generator: ControlledPreviewGenerator(),
            cache: cache
        ).coordinator

        #expect(coordinator.previews["voice-a"]?.status == .pending)
        #expect(coordinator.previews["voice-b"]?.status == .ready)
        #expect(coordinator.readyCount == 1)
        #expect(coordinator.totalCount == 2)
    }

    @Test
    func preparesEveryMissingVoiceInCatalogOrderAndSkipsCacheHits() async throws {
        let generator = ControlledPreviewGenerator()
        let cache = PreviewCacheSpy()
        cache.artifacts["voice-b"] = CachedVoicePreview(
            url: cache.directory.appendingPathComponent("voice-b.wav"),
            durationSeconds: 4
        )
        let fixture = makeCoordinator(
            voiceIDs: ["voice-a", "voice-b", "voice-c"],
            generator: generator,
            cache: cache
        )

        fixture.coordinator.prepareAll()
        fixture.coordinator.resumePreparation()
        try await waitUntil { fixture.coordinator.readyCount == 3 }

        #expect(await generator.requestedVoiceIDs() == ["voice-a", "voice-c"])
        #expect(cache.committedVoiceIDs == ["voice-a", "voice-c"])
    }

    @Test
    func anExplicitRequestIsPrioritizedAndAutoplaysExactlyOnce() async throws {
        let generator = ControlledPreviewGenerator()
        let fixture = makeCoordinator(
            voiceIDs: ["voice-a", "voice-b", "voice-c"],
            generator: generator
        )

        fixture.coordinator.prepareAll()
        fixture.coordinator.requestPlayback(voiceID: "voice-c")
        fixture.coordinator.resumePreparation()
        try await waitUntil { fixture.coordinator.readyCount == 3 }

        #expect(await generator.requestedVoiceIDs() == ["voice-c", "voice-a", "voice-b"])
        #expect(fixture.playback.played.map(\.voiceID) == ["voice-c"])
    }

    @Test
    func cachedSelectionSupersedesAnOlderPendingAutoplay() async throws {
        let generator = ControlledPreviewGenerator(blockedVoiceIDs: ["voice-a"])
        let cache = PreviewCacheSpy()
        cache.artifacts["voice-b"] = CachedVoicePreview(
            url: cache.directory.appendingPathComponent("voice-b.wav"),
            durationSeconds: 4
        )
        let fixture = makeCoordinator(
            voiceIDs: ["voice-a", "voice-b"],
            generator: generator,
            cache: cache
        )
        fixture.coordinator.resumePreparation()

        fixture.coordinator.requestPlayback(voiceID: "voice-a")
        try await waitUntil { await generator.requestedVoiceIDs() == ["voice-a"] }
        fixture.coordinator.requestPlayback(voiceID: "voice-b")
        await generator.releaseFirst("voice-a")
        try await waitUntil { fixture.coordinator.previews["voice-a"]?.status == .ready }

        #expect(fixture.playback.played.map(\.voiceID) == ["voice-b"])
    }

    @Test
    func suspensionRejectsAStaleCancellationIgnoringCompletion() async throws {
        let generator = ControlledPreviewGenerator(
            blockedVoiceIDs: ["voice-a"],
            ignoresCancellation: true
        )
        let fixture = makeCoordinator(voiceIDs: ["voice-a"], generator: generator)
        fixture.coordinator.prepareAll()
        fixture.coordinator.resumePreparation()
        try await waitUntil { await generator.requestedVoiceIDs().count == 1 }

        fixture.coordinator.suspendPreparation(clearAutoplay: true)
        fixture.coordinator.resumePreparation()
        try await waitUntil { await generator.requestedVoiceIDs().count == 2 }
        let destinations = await generator.destinations(for: "voice-a")
        #expect(Set(destinations).count == 2)

        await generator.releaseFirst("voice-a")
        try await waitUntil { fixture.cache.discardedURLs.contains(destinations[0]) }
        #expect(fixture.cache.committedVoiceIDs.isEmpty)
        #expect(fixture.coordinator.previews["voice-a"]?.status == .generating)

        await generator.releaseFirst("voice-a")
        try await waitUntil { fixture.coordinator.previews["voice-a"]?.status == .ready }
        #expect(fixture.cache.committedVoiceIDs == ["voice-a"])
    }

    @Test
    func reloadInvalidatesAnActiveWorkerAndKeepsTheCacheSnapshotAuthoritative() async throws {
        let generator = ControlledPreviewGenerator(
            blockedVoiceIDs: ["voice-a"],
            ignoresCancellation: true
        )
        let cache = PreviewCacheSpy()
        let fixture = makeCoordinator(
            voiceIDs: ["voice-a"],
            generator: generator,
            cache: cache
        )
        fixture.coordinator.prepareAll()
        fixture.coordinator.resumePreparation()
        try await waitUntil { await generator.requestedVoiceIDs().count == 1 }

        let cachedURL = cache.directory.appendingPathComponent("external-voice-a.wav")
        cache.artifacts["voice-a"] = CachedVoicePreview(url: cachedURL, durationSeconds: 3)
        fixture.coordinator.reloadCache()
        await generator.releaseFirst("voice-a")
        try await waitUntil { !fixture.cache.discardedURLs.isEmpty }

        #expect(fixture.coordinator.previews["voice-a"]?.audioURL == cachedURL)
        #expect(fixture.cache.committedVoiceIDs.isEmpty)
    }

    @Test
    func failureDoesNotStopTheBatchAndAnExplicitRetryCanAutoplay() async throws {
        let generator = ControlledPreviewGenerator(outcomes: [
            "voice-a": [.failure, .success]
        ])
        let fixture = makeCoordinator(
            voiceIDs: ["voice-a", "voice-b"],
            generator: generator
        )
        fixture.coordinator.prepareAll()
        fixture.coordinator.resumePreparation()
        try await waitUntil {
            fixture.coordinator.previews["voice-a"]?.status == .failed
                && fixture.coordinator.previews["voice-b"]?.status == .ready
        }

        #expect(fixture.coordinator.errorMessage?.contains("voice-a") == true)
        fixture.coordinator.requestPlayback(voiceID: "voice-a")
        try await waitUntil { fixture.coordinator.previews["voice-a"]?.status == .ready }

        #expect(await generator.requestedVoiceIDs() == ["voice-a", "voice-b", "voice-a"])
        #expect(fixture.playback.played.map(\.voiceID) == ["voice-a"])
    }

    @Test
    func rejectedGeneratedArtifactBecomesAFailureAndNeverAutoplays() async throws {
        let cache = PreviewCacheSpy()
        cache.rejectedVoiceIDs = ["voice-a"]
        let fixture = makeCoordinator(
            voiceIDs: ["voice-a"],
            generator: ControlledPreviewGenerator(),
            cache: cache
        )
        fixture.coordinator.resumePreparation()
        fixture.coordinator.requestPlayback(voiceID: "voice-a")
        try await waitUntil { fixture.coordinator.previews["voice-a"]?.status == .failed }

        #expect(fixture.playback.played.isEmpty)
        #expect(fixture.coordinator.readyCount == 0)
    }

    @Test
    func repeatedPrepareAllCallsDoNotDuplicateInFlightGeneration() async throws {
        let generator = ControlledPreviewGenerator(blockedVoiceIDs: ["voice-a"])
        let fixture = makeCoordinator(voiceIDs: ["voice-a"], generator: generator)
        fixture.coordinator.resumePreparation()
        fixture.coordinator.prepareAll()
        fixture.coordinator.prepareAll()
        fixture.coordinator.prepareAll()
        try await waitUntil { await generator.requestedVoiceIDs().count == 1 }

        #expect(await generator.requestedVoiceIDs() == ["voice-a"])
        await generator.releaseFirst("voice-a")
        try await waitUntil { fixture.coordinator.readyCount == 1 }
        #expect(await generator.requestedVoiceIDs() == ["voice-a"])
    }

    @Test
    func togglingThePlayingVoiceStopsItWithoutGenerating() {
        let cache = PreviewCacheSpy()
        cache.artifacts["voice-a"] = CachedVoicePreview(
            url: cache.directory.appendingPathComponent("voice-a.wav"),
            durationSeconds: 4
        )
        let generator = ControlledPreviewGenerator()
        let fixture = makeCoordinator(
            voiceIDs: ["voice-a"],
            generator: generator,
            cache: cache
        )

        fixture.coordinator.requestPlayback(voiceID: "voice-a")
        fixture.coordinator.togglePlayback(voiceID: "voice-a")

        #expect(fixture.playback.played.map(\.voiceID) == ["voice-a"])
        #expect(fixture.playback.stopCount == 1)
    }

    @Test
    func fulfilledAutoplayIntentIsNotReplayedByRefreshOrPrepare() async throws {
        let fixture = makeCoordinator(
            voiceIDs: ["voice-a"],
            generator: ControlledPreviewGenerator()
        )
        fixture.coordinator.resumePreparation()
        fixture.coordinator.requestPlayback(voiceID: "voice-a")
        try await waitUntil { fixture.coordinator.readyCount == 1 }
        fixture.playback.stopVoicePreview()

        fixture.coordinator.reloadCache()
        fixture.coordinator.prepareAll()
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.playback.played.map(\.voiceID) == ["voice-a"])
    }

    @Test
    func fileCacheRejectsTruncatedWAVAndAcceptsPlayableWAV() throws {
        let directory = temporaryDirectory(named: "validation")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let truncated = directory.appendingPathComponent("voice-a.wav")
        try Data("RIFFxxxxxxxxWAVE".utf8).write(to: truncated)
        let cache = FileVoicePreviewCache(directory: directory)

        #expect(cache.load(voiceIDs: ["voice-a"]).isEmpty)

        let staging = try cache.makeStagingURL(voiceID: "voice-a")
        try writeWave(to: staging, frameCount: 2_400)
        let artifact = try cache.commit(stagingURL: staging, voiceID: "voice-a")

        #expect(artifact.durationSeconds > 0.09)
        #expect(artifact.durationSeconds < 0.11)
        #expect(cache.load(voiceIDs: ["voice-a"])["voice-a"] == artifact)
    }

    @Test
    func fileCacheUsesUniqueStagingAndAtomicallyReplacesTheFinalArtifact() throws {
        let directory = temporaryDirectory(named: "replacement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileVoicePreviewCache(directory: directory)
        let firstStage = try cache.makeStagingURL(voiceID: "voice-a")
        let secondStage = try cache.makeStagingURL(voiceID: "voice-a")
        #expect(firstStage != secondStage)

        try writeWave(to: firstStage, frameCount: 2_400)
        let first = try cache.commit(stagingURL: firstStage, voiceID: "voice-a")
        try writeWave(to: secondStage, frameCount: 4_800)
        let second = try cache.commit(stagingURL: secondStage, voiceID: "voice-a")

        #expect(first.url == second.url)
        #expect(second.durationSeconds > first.durationSeconds)
        #expect(!FileManager.default.fileExists(atPath: firstStage.path))
        #expect(!FileManager.default.fileExists(atPath: secondStage.path))
    }

    private struct Fixture {
        let coordinator: VoicePreviewCoordinator
        let cache: PreviewCacheSpy
        let playback: PreviewPlaybackSpy
    }

    private func makeCoordinator(
        voiceIDs: [String],
        generator: any VoicePreviewGenerating,
        cache: PreviewCacheSpy = PreviewCacheSpy()
    ) -> Fixture {
        let playback = PreviewPlaybackSpy()
        return Fixture(
            coordinator: VoicePreviewCoordinator(
                voiceIDs: voiceIDs,
                generator: generator,
                cache: cache,
                playback: playback
            ),
            cache: cache,
            playback: playback
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PreviewTestError.timedOut
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "AudioMonster-preview-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func writeWave(to url: URL, frameCount: AVAudioFrameCount) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: 24_000,
                channels: 1
            ))
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ))
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
