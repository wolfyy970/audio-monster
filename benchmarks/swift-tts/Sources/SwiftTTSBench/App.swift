import Darwin
import Foundation
import MLXAudioCore
import MLXAudioTTS

private let sdkRevision = "542fffacb3be8de47024b3b54888f71d72d46d30"
private let defaultText =
    "Audio Monster turns a carefully written article into clear, natural speech. This benchmark checks whether the narrator remains crisp, steady, and pleasant enough for focused listening, even when playback is slowed down."

enum BenchmarkError: Error, LocalizedError {
    case missingModel
    case unknownModel(String)
    case emptyAudio(String)

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Pass --model followed by one of: \(BenchmarkCatalog.models.map(\.key).joined(separator: ", "))"
        case .unknownModel(let key):
            return
                "Unknown model '\(key)'. Available models: \(BenchmarkCatalog.models.map(\.key).joined(separator: ", "))"
        case .emptyAudio(let generation):
            return "The \(generation) generation returned no audio"
        }
    }
}

struct Arguments {
    let modelKey: String
    let outputDirectory: URL
    let text: String

    static func parse() throws -> Arguments {
        let values = Array(CommandLine.arguments.dropFirst())
        if values.contains("--list") {
            for model in BenchmarkCatalog.models {
                print("\(model.key)\t\(model.repository)\t\(model.role)")
            }
            exit(0)
        }

        func value(after flag: String) -> String? {
            guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else {
                return nil
            }
            return values[index + 1]
        }

        guard let modelKey = value(after: "--model") else {
            throw BenchmarkError.missingModel
        }
        let outputPath = value(after: "--output") ?? "results/\(modelKey)"
        let text = value(after: "--text") ?? defaultText
        return Arguments(
            modelKey: modelKey,
            outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true),
            text: text
        )
    }
}

struct CapturedGeneration {
    let samples: [Float]
    let elapsedSeconds: Double
    let timeToFirstAudioSeconds: Double?
    let tokensPerSecond: Double?
    let reportedPeakMemoryGB: Double?
}

@main
enum SwiftTTSBench {
    static func main() async {
        do {
            let arguments = try Arguments.parse()
            guard let configuration = BenchmarkCatalog.model(for: arguments.modelKey) else {
                throw BenchmarkError.unknownModel(arguments.modelKey)
            }
            try await run(configuration: configuration, arguments: arguments)
        } catch {
            fputs("Benchmark failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(configuration: BenchmarkModel, arguments: Arguments) async throws {
        try FileManager.default.createDirectory(
            at: arguments.outputDirectory,
            withIntermediateDirectories: true
        )

        print("MODEL \(configuration.key): \(configuration.repository)")
        let loadStart = ContinuousClock.now
        let model = try await TTS.loadModel(
            modelRepo: configuration.repository,
            modelType: configuration.modelType
        )
        let modelLoadSeconds = elapsed(since: loadStart)
        print(String(format: "LOAD %.3f seconds", modelLoadSeconds))

        var measurements = [GenerationMeasurement]()
        for runIndex in 0..<4 {
            let name = runIndex == 0 ? "cold" : "warm-\(runIndex)"
            let capture = try await generate(
                model: model,
                configuration: configuration,
                text: arguments.text
            )
            guard !capture.samples.isEmpty else {
                throw BenchmarkError.emptyAudio(name)
            }

            let outputURL = arguments.outputDirectory.appendingPathComponent("\(configuration.key)-\(name).wav")
            try AudioUtils.writeWavFile(
                samples: capture.samples,
                sampleRate: Double(model.sampleRate),
                fileURL: outputURL
            )
            let checks = ResultAnalysis.checks(samples: capture.samples, sampleRate: model.sampleRate)
            let rtf = checks.durationSeconds > 0 ? capture.elapsedSeconds / checks.durationSeconds : 0
            let multiple = capture.elapsedSeconds > 0 ? checks.durationSeconds / capture.elapsedSeconds : 0
            measurements.append(
                GenerationMeasurement(
                    name: name,
                    elapsedSeconds: capture.elapsedSeconds,
                    timeToFirstAudioSeconds: capture.timeToFirstAudioSeconds,
                    realtimeFactor: rtf,
                    realtimeMultiple: multiple,
                    reportedTokensPerSecond: capture.tokensPerSecond,
                    reportedPeakMemoryGB: capture.reportedPeakMemoryGB,
                    audio: checks,
                    outputFile: outputURL.lastPathComponent
                )
            )
            print(
                String(
                    format: "%@ %.3fs for %.3fs audio = %.2fx realtime; first audio %@",
                    name.uppercased(),
                    capture.elapsedSeconds,
                    checks.durationSeconds,
                    multiple,
                    capture.timeToFirstAudioSeconds.map { String(format: "%.3fs", $0) } ?? "n/a"))
        }

        let result = BenchmarkResult(
            schemaVersion: 2,
            recordedAt: Date(),
            sdkRevision: sdkRevision,
            machine: machineDescription(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            model: configuration,
            text: arguments.text,
            sampleRate: model.sampleRate,
            modelLoadSeconds: modelLoadSeconds,
            processPeakResidentBytes: peakResidentBytes(),
            generations: measurements,
            summary: ResultAnalysis.summary(generations: measurements)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        let resultURL = arguments.outputDirectory.appendingPathComponent("result.json")
        try data.write(to: resultURL, options: .atomic)
        print(
            String(
                format: "MEDIAN WARM %.2fx realtime",
                result.summary.medianWarmRealtimeMultiple
            ))
        print("RESULT \(resultURL.path)")
    }

    private static func generate(
        model: SpeechGenerationModel,
        configuration: BenchmarkModel,
        text: String
    ) async throws -> CapturedGeneration {
        let started = ContinuousClock.now
        var samples = [Float]()
        var firstAudio: Double?
        var tokensPerSecond: Double?
        var reportedPeakMemoryGB: Double?

        let stream = model.generateStream(
            text: text,
            voice: configuration.voice,
            refAudio: nil,
            refText: nil,
            language: configuration.language,
            generationParameters: model.defaultGenerationParameters,
            streamingInterval: 0.32
        )
        for try await event in stream {
            switch event {
            case .token:
                break
            case .audio(let chunk):
                let chunkSamples = chunk.asArray(Float.self)
                if !chunkSamples.isEmpty, firstAudio == nil {
                    firstAudio = elapsed(since: started)
                }
                samples.append(contentsOf: chunkSamples)
            case .info(let info):
                tokensPerSecond = info.tokensPerSecond
                reportedPeakMemoryGB = info.peakMemoryUsage
            }
        }
        return CapturedGeneration(
            samples: samples,
            elapsedSeconds: elapsed(since: started),
            timeToFirstAudioSeconds: firstAudio,
            tokensPerSecond: tokensPerSecond,
            reportedPeakMemoryGB: reportedPeakMemoryGB
        )
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }

    private static func machineDescription() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
