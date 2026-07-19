import AudioMonsterCore
import Foundation
import MLXAudioCore
@preconcurrency import MLXAudioTTS

protocol AudioConversionEngine: VoicePreviewGenerating {
    func prepare() async throws
    func convert(
        article: ReadableArticle,
        voiceID: String,
        workspaceURL: URL,
        onEvent: @escaping @Sendable (SynthesisEvent) async -> Void
    ) async throws -> SynthesisResult
}

protocol KokoroSampleGenerating: Sendable {
    var sampleRate: Int { get }

    func generateSamples(
        text: String,
        voiceID: String,
        language: String?
    ) async throws -> [Float]
}

protocol KokoroModelLoading: Sendable {
    func loadModel() async throws -> any KokoroSampleGenerating
}

protocol AudioArtifactEncoding: Sendable {
    func exportM4A(
        from waveURL: URL,
        to outputURL: URL,
        title: String,
        sourceURL: URL,
        resolvedURL: URL
    ) async throws
}

enum NativeKokoroError: LocalizedError {
    case unsupportedVoice(String)
    case unexpectedModel

    var errorDescription: String? {
        switch self {
        case .unsupportedVoice(let voice): "Kokoro does not include the voice \(voice)."
        case .unexpectedModel: "The Swift audio SDK did not load a Kokoro model."
        }
    }
}

struct MLXKokoroSampleGenerator: KokoroSampleGenerating {
    let model: KokoroModel

    var sampleRate: Int { model.sampleRate }

    func generateSamples(
        text: String,
        voiceID: String,
        language: String?
    ) async throws -> [Float] {
        let audio = try await model.generate(
            text: text,
            voice: voiceID,
            refAudio: nil,
            refText: nil,
            language: language,
            generationParameters: model.defaultGenerationParameters
        )
        try Task.checkCancellation()
        return audio.asArray(Float.self)
    }
}

struct MLXKokoroModelLoader: KokoroModelLoading {
    private static let repository = "mlx-community/Kokoro-82M-bf16"
    private static let modelType = "kokoro"

    func loadModel() async throws -> any KokoroSampleGenerating {
        let loaded = try await TTS.loadModel(
            modelRepo: Self.repository,
            modelType: Self.modelType
        )
        guard let kokoro = loaded as? KokoroModel else {
            throw NativeKokoroError.unexpectedModel
        }
        return MLXKokoroSampleGenerator(model: kokoro)
    }
}

struct NativeAudioArtifactEncoder: AudioArtifactEncoding {
    func exportM4A(
        from waveURL: URL,
        to outputURL: URL,
        title: String,
        sourceURL: URL,
        resolvedURL: URL
    ) async throws {
        try await AudioArtifactWriter.exportM4A(
            from: waveURL,
            to: outputURL,
            title: title,
            sourceURL: sourceURL,
            resolvedURL: resolvedURL
        )
    }
}

actor NativeKokoroAudioEngine: AudioConversionEngine {
    static let shared = NativeKokoroAudioEngine()

    private static let previewMaximumSeconds = 10.0

    private let modelLoader: any KokoroModelLoading
    private let artifactEncoder: any AudioArtifactEncoding
    private var model: (any KokoroSampleGenerating)?
    private var modelLoadingTask: Task<any KokoroSampleGenerating, any Error>?
    private var generationInProgress = false

    init(
        modelLoader: any KokoroModelLoading = MLXKokoroModelLoader(),
        artifactEncoder: any AudioArtifactEncoding = NativeAudioArtifactEncoder()
    ) {
        self.modelLoader = modelLoader
        self.artifactEncoder = artifactEncoder
    }

    func prepare() async throws {
        _ = try await loadedModel()
    }

    func convert(
        article: ReadableArticle,
        voiceID: String,
        workspaceURL: URL,
        onEvent: @escaping @Sendable (SynthesisEvent) async -> Void
    ) async throws -> SynthesisResult {
        try validate(voiceID: voiceID)
        let sections = ArticleChunker.chunks(from: article.text)
        guard !sections.isEmpty else { throw ArticleExtractionError.noReadableContent }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let segmentDirectory = workspaceURL.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: segmentDirectory,
            withIntermediateDirectories: true
        )

        let speechModel = try await loadedModel()
        let sampleRate = speechModel.sampleRate
        let continuousWaveURL = workspaceURL.appendingPathComponent("complete.wav")
        let writer = try StreamingWAVWriter(
            url: continuousWaveURL,
            sampleRate: Double(sampleRate)
        )
        await onEvent(.started(sectionCount: sections.count))

        do {
            for (index, section) in sections.enumerated() {
                try Task.checkCancellation()
                let samples = try await generateSamples(
                    text: section,
                    voiceID: voiceID,
                    model: speechModel
                )
                guard !samples.isEmpty else { throw AudioArtifactError.emptyAudio }
                try writer.writeChunk(samples)
                let segmentURL =
                    segmentDirectory
                    .appendingPathComponent(String(format: "%05d.wav", index))
                try AudioUtils.writeWavFile(
                    samples: samples,
                    sampleRate: sampleRate,
                    fileURL: segmentURL
                )
                let segment = AudioSegment(
                    index: index,
                    url: segmentURL
                )
                await onEvent(.segment(segment, completed: index + 1, total: sections.count))
            }
            _ = writer.finalize()
        } catch {
            _ = writer.finalize()
            throw error
        }

        try Task.checkCancellation()
        await onEvent(.encoding)
        let outputURL = workspaceURL.appendingPathComponent("complete.m4a")
        try await artifactEncoder.exportM4A(
            from: continuousWaveURL,
            to: outputURL,
            title: article.title,
            sourceURL: article.sourceURL,
            resolvedURL: article.resolvedURL
        )
        try Task.checkCancellation()
        return SynthesisResult(
            audioURL: outputURL,
            recommendedFilename: ArticleChunker.suggestedFilename(title: article.title)
        )
    }

    func generatePreview(voiceID: String, destinationURL: URL) async throws -> VoicePreview {
        try validate(voiceID: voiceID)
        let speechModel = try await loadedModel()
        let samples = try await generateSamples(
            text: Self.previewText(for: voiceID),
            voiceID: voiceID,
            model: speechModel
        )
        let maximumFrames = Int(Double(speechModel.sampleRate) * Self.previewMaximumSeconds)
        let clipped = Array(samples.prefix(maximumFrames))
        guard !clipped.isEmpty else { throw AudioArtifactError.emptyAudio }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AudioUtils.writeWavFile(
            samples: clipped,
            sampleRate: speechModel.sampleRate,
            fileURL: destinationURL
        )
        return VoicePreview(
            voiceID: voiceID,
            status: .ready,
            audioURL: destinationURL,
            durationSeconds: Double(clipped.count) / Double(speechModel.sampleRate)
        )
    }

    private func loadedModel() async throws -> any KokoroSampleGenerating {
        if let model { return model }
        if let modelLoadingTask {
            return try await modelLoadingTask.value
        }

        let modelLoader = modelLoader
        let loadingTask = Task<any KokoroSampleGenerating, any Error> {
            try await modelLoader.loadModel()
        }
        modelLoadingTask = loadingTask
        defer { modelLoadingTask = nil }

        let loadedModel = try await loadingTask.value
        model = loadedModel
        return loadedModel
    }

    private func generateSamples(
        text: String,
        voiceID: String,
        model: any KokoroSampleGenerating
    ) async throws -> [Float] {
        try await acquireGenerationSlot()
        defer { generationInProgress = false }

        let samples = try await model.generateSamples(
            text: text,
            voiceID: voiceID,
            language: KokoroVoiceCatalog.language(for: voiceID)?.synthesisCode,
        )
        try Task.checkCancellation()
        return samples
    }

    /// MLX shares a single Metal command queue and unified-memory allocator. Keeping
    /// one generation in flight avoids re-entrant access to the warmed model while
    /// still letting extraction, file I/O, and encoding proceed asynchronously.
    private func acquireGenerationSlot() async throws {
        while generationInProgress {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        generationInProgress = true
    }

    private func validate(voiceID: String) throws {
        guard KokoroVoiceCatalog.voiceIDs.contains(voiceID) else {
            throw NativeKokoroError.unsupportedVoice(voiceID)
        }
    }

    private static func previewText(for voiceID: String) -> String {
        switch voiceID.first {
        case "e":
            "Audio Monster convierte tus artículos favoritos en una narración clara y natural para escuchar cuando quieras."
        case "f":
            "Audio Monster transforme vos articles préférés en une narration claire et naturelle, prête à être écoutée."
        case "h":
            "ऑडियो मॉन्स्टर आपके पसंदीदा लेखों को साफ़ और स्वाभाविक आवाज़ में बदल देता है, ताकि आप उन्हें कभी भी सुन सकें।"
        case "i":
            "Audio Monster trasforma i tuoi articoli preferiti in una narrazione chiara e naturale, pronta da ascoltare."
        case "j":
            "オーディオモンスターは、お気に入りの記事をいつでも聴ける自然で明瞭な音声に変換します。"
        case "p":
            "O Audio Monster transforma seus artigos favoritos em uma narração clara e natural, pronta para ouvir quando quiser."
        case "z":
            "音频怪兽会把你喜欢的文章转换成清晰自然的语音，让你随时都能轻松收听。"
        default:
            "Audio Monster turns your favourite articles into clear, natural listening, ready whenever you step away from the screen."
        }
    }
}
