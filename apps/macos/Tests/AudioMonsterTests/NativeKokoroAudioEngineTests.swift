@preconcurrency import AVFoundation
import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

private struct GenerationRequest: Equatable, Sendable {
    let text: String
    let voiceID: String
    let language: String?
}

private actor RecordingKokoroModel: KokoroSampleGenerating {
    nonisolated let sampleRate: Int
    private let samples: [Float]
    private var requests: [GenerationRequest] = []

    init(sampleRate: Int = 24_000, samples: [Float]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    func generateSamples(
        text: String,
        voiceID: String,
        language: String?
    ) async throws -> [Float] {
        requests.append(GenerationRequest(text: text, voiceID: voiceID, language: language))
        return samples
    }

    func recordedRequests() -> [GenerationRequest] {
        requests
    }
}

private actor BlockingKokoroModel: KokoroSampleGenerating {
    nonisolated let sampleRate = 24_000
    private var requests: [GenerationRequest] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func generateSamples(
        text: String,
        voiceID: String,
        language: String?
    ) async throws -> [Float] {
        requests.append(GenerationRequest(text: text, voiceID: voiceID, language: language))
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        return [0.1, -0.1]
    }

    func requestCount() -> Int {
        requests.count
    }

    func releaseFirstRequest() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor FakeKokoroModelLoader: KokoroModelLoading {
    private let model: any KokoroSampleGenerating
    private let delay: Duration
    private var loads = 0

    init(
        model: any KokoroSampleGenerating,
        delay: Duration = .zero
    ) {
        self.model = model
        self.delay = delay
    }

    func loadModel() async throws -> any KokoroSampleGenerating {
        loads += 1
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return model
    }

    func loadCount() -> Int {
        loads
    }
}

private enum FakeEncodingError: Error {
    case failed
}

private actor FakeArtifactEncoder: AudioArtifactEncoding {
    private let error: FakeEncodingError?
    private var calls = 0

    init(error: FakeEncodingError? = nil) {
        self.error = error
    }

    func exportM4A(
        from waveURL: URL,
        to outputURL: URL,
        title: String,
        sourceURL: URL,
        resolvedURL: URL
    ) async throws {
        calls += 1
        if let error { throw error }
        try Data("encoded audio".utf8).write(to: outputURL)
    }

    func callCount() -> Int {
        calls
    }
}

private enum RecordedSynthesisEvent: Equatable, Sendable {
    case started(sectionCount: Int)
    case segment(index: Int, completed: Int, total: Int)
    case encoding
}

private actor SynthesisEventRecorder {
    private var events: [RecordedSynthesisEvent] = []

    func record(_ event: SynthesisEvent) {
        switch event {
        case .started(let sectionCount):
            events.append(.started(sectionCount: sectionCount))
        case .segment(let segment, let completed, let total):
            events.append(.segment(index: segment.index, completed: completed, total: total))
        case .encoding:
            events.append(.encoding)
        }
    }

    func recordedEvents() -> [RecordedSynthesisEvent] {
        events
    }
}

struct NativeKokoroAudioEngineTests {
    @Test
    func prepareCoalescesConcurrentModelLoadsAndKeepsTheModelWarm() async throws {
        let model = RecordingKokoroModel(samples: [0.1, -0.1])
        let loader = FakeKokoroModelLoader(model: model, delay: .milliseconds(50))
        let engine = NativeKokoroAudioEngine(
            modelLoader: loader,
            artifactEncoder: FakeArtifactEncoder()
        )

        async let firstPrepare: Void = engine.prepare()
        async let secondPrepare: Void = engine.prepare()
        _ = try await (firstPrepare, secondPrepare)
        try await engine.prepare()

        #expect(await loader.loadCount() == 1)
    }

    @Test
    func rejectsAnUnsupportedVoiceBeforeLoadingTheModel() async throws {
        let model = RecordingKokoroModel(samples: [0.1])
        let loader = FakeKokoroModelLoader(model: model)
        let engine = NativeKokoroAudioEngine(
            modelLoader: loader,
            artifactEncoder: FakeArtifactEncoder()
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsupported-\(UUID().uuidString).wav")

        do {
            _ = try await engine.generatePreview(
                voiceID: "not_a_kokoro_voice",
                destinationURL: destination
            )
            Issue.record("An unsupported voice should fail validation.")
        } catch let NativeKokoroError.unsupportedVoice(voiceID) {
            #expect(voiceID == "not_a_kokoro_voice")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await loader.loadCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func convertsSectionsInOrderAndEmitsAStableEventSequence() async throws {
        let workspace = try makeTemporaryDirectory(named: "ordered-conversion")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = RecordingKokoroModel(samples: [0.1, -0.1, 0.05, -0.05])
        let loader = FakeKokoroModelLoader(model: model)
        let encoder = FakeArtifactEncoder()
        let recorder = SynthesisEventRecorder()
        let engine = NativeKokoroAudioEngine(modelLoader: loader, artifactEncoder: encoder)
        let article = try makeArticle(
            title: "Ordered Article",
            text: "First section.\nSecond section.\nThird section."
        )

        let result = try await engine.convert(
            article: article,
            voiceID: "af_heart",
            workspaceURL: workspace
        ) { event in
            await recorder.record(event)
        }

        #expect(
            await model.recordedRequests() == [
                GenerationRequest(text: "First section.", voiceID: "af_heart", language: "en-us"),
                GenerationRequest(text: "Second section.", voiceID: "af_heart", language: "en-us"),
                GenerationRequest(text: "Third section.", voiceID: "af_heart", language: "en-us"),
            ])
        #expect(
            await recorder.recordedEvents() == [
                .started(sectionCount: 3),
                .segment(index: 0, completed: 1, total: 3),
                .segment(index: 1, completed: 2, total: 3),
                .segment(index: 2, completed: 3, total: 3),
                .encoding,
            ])
        #expect(await encoder.callCount() == 1)
        #expect(result.recommendedFilename == "ordered-article.m4a")
        #expect(try Data(contentsOf: result.audioURL) == Data("encoded audio".utf8))
    }

    @Test
    func rejectsEmptyGeneratedSamplesBeforeEncoding() async throws {
        let workspace = try makeTemporaryDirectory(named: "empty-samples")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = RecordingKokoroModel(samples: [])
        let encoder = FakeArtifactEncoder()
        let engine = NativeKokoroAudioEngine(
            modelLoader: FakeKokoroModelLoader(model: model),
            artifactEncoder: encoder
        )

        do {
            _ = try await engine.convert(
                article: makeArticle(title: "Empty", text: "This section produces no audio."),
                voiceID: "af_heart",
                workspaceURL: workspace
            ) { _ in }
            Issue.record("Empty samples should stop conversion.")
        } catch AudioArtifactError.emptyAudio {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await encoder.callCount() == 0)
    }

    @Test
    func clipsVoicePreviewsToTenSeconds() async throws {
        let folder = try makeTemporaryDirectory(named: "preview-clipping")
        defer { try? FileManager.default.removeItem(at: folder) }
        let sampleRate = 24_000
        let model = RecordingKokoroModel(
            sampleRate: sampleRate,
            samples: Array(repeating: Float(0.1), count: sampleRate * 11)
        )
        let engine = NativeKokoroAudioEngine(
            modelLoader: FakeKokoroModelLoader(model: model),
            artifactEncoder: FakeArtifactEncoder()
        )
        let destination = folder.appendingPathComponent("af_heart.wav")

        let preview = try await engine.generatePreview(
            voiceID: "af_heart",
            destinationURL: destination
        )
        let audioFile = try AVAudioFile(forReading: destination)

        #expect(preview.status == .ready)
        #expect(preview.durationSeconds == 10)
        #expect(audioFile.length == AVAudioFramePosition(sampleRate * 10))
        #expect(audioFile.fileFormat.sampleRate == Double(sampleRate))
    }

    @Test
    func propagatesEncodingFailureAfterEmittingEncodingEvent() async throws {
        let workspace = try makeTemporaryDirectory(named: "encoding-failure")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let recorder = SynthesisEventRecorder()
        let encoder = FakeArtifactEncoder(error: .failed)
        let engine = NativeKokoroAudioEngine(
            modelLoader: FakeKokoroModelLoader(
                model: RecordingKokoroModel(samples: [0.1, -0.1])
            ),
            artifactEncoder: encoder
        )

        do {
            _ = try await engine.convert(
                article: makeArticle(title: "Encoding", text: "One complete section."),
                voiceID: "af_heart",
                workspaceURL: workspace
            ) { event in
                await recorder.record(event)
            }
            Issue.record("The encoder failure should be propagated.")
        } catch FakeEncodingError.failed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await encoder.callCount() == 1)
        #expect(
            await recorder.recordedEvents() == [
                .started(sectionCount: 1),
                .segment(index: 0, completed: 1, total: 1),
                .encoding,
            ])
    }

    @Test
    func serializesGenerationAndCancelsAWaiterBeforeItReachesTheModel() async throws {
        let folder = try makeTemporaryDirectory(named: "serialized-generation")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BlockingKokoroModel()
        let engine = NativeKokoroAudioEngine(
            modelLoader: FakeKokoroModelLoader(model: model),
            artifactEncoder: FakeArtifactEncoder()
        )
        let firstDestination = folder.appendingPathComponent("first.wav")
        let secondDestination = folder.appendingPathComponent("second.wav")

        let first = Task {
            try await engine.generatePreview(
                voiceID: "af_heart",
                destinationURL: firstDestination
            )
        }
        for _ in 0..<100 where await model.requestCount() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await model.requestCount() == 1)

        let second = Task {
            try await engine.generatePreview(
                voiceID: "af_bella",
                destinationURL: secondDestination
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await model.requestCount() == 1)

        second.cancel()
        do {
            _ = try await second.value
            Issue.record("A cancelled generation waiter should throw CancellationError.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await model.requestCount() == 1)

        await model.releaseFirstRequest()
        _ = try await first.value
        #expect(FileManager.default.fileExists(atPath: firstDestination.path))
        #expect(!FileManager.default.fileExists(atPath: secondDestination.path))
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeArticle(title: String, text: String) throws -> ReadableArticle {
        let sourceURL = try #require(URL(string: "https://example.com/article"))
        return ReadableArticle(
            sourceURL: sourceURL,
            resolvedURL: sourceURL,
            title: title,
            text: text
        )
    }
}
