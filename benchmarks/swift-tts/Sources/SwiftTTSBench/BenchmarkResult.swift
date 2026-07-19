import Foundation

struct AudioChecks: Codable, Sendable {
    let sampleCount: Int
    let durationSeconds: Double
    let rms: Double
    let peak: Double
    let clippedSampleRatio: Double
    let nonFiniteSampleCount: Int
}

struct GenerationMeasurement: Codable, Sendable {
    let name: String
    let elapsedSeconds: Double
    let timeToFirstAudioSeconds: Double?
    let realtimeFactor: Double
    let realtimeMultiple: Double
    let reportedTokensPerSecond: Double?
    let reportedPeakMemoryGB: Double?
    let audio: AudioChecks
    let outputFile: String
}

struct BenchmarkSummary: Codable, Sendable {
    let warmRunCount: Int
    let medianWarmElapsedSeconds: Double
    let medianWarmRealtimeMultiple: Double
    let medianWarmTimeToFirstAudioSeconds: Double?
    let outputDurationSpreadSeconds: Double
}

struct BenchmarkResult: Codable, Sendable {
    let schemaVersion: Int
    let recordedAt: Date
    let sdkRevision: String
    let machine: String
    let operatingSystem: String
    let model: BenchmarkModel
    let text: String
    let sampleRate: Int
    let modelLoadSeconds: Double
    let processPeakResidentBytes: Int64
    let generations: [GenerationMeasurement]
    let summary: BenchmarkSummary
}

enum ResultAnalysis {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    static func summary(generations: [GenerationMeasurement]) -> BenchmarkSummary {
        let warm = Array(generations.dropFirst())
        let durations = generations.map(\.audio.durationSeconds)
        return BenchmarkSummary(
            warmRunCount: warm.count,
            medianWarmElapsedSeconds: median(warm.map(\.elapsedSeconds)) ?? 0,
            medianWarmRealtimeMultiple: median(warm.map(\.realtimeMultiple)) ?? 0,
            medianWarmTimeToFirstAudioSeconds: median(warm.compactMap(\.timeToFirstAudioSeconds)),
            outputDurationSpreadSeconds: (durations.max() ?? 0) - (durations.min() ?? 0)
        )
    }

    static func checks(samples: [Float], sampleRate: Int) -> AudioChecks {
        guard !samples.isEmpty, sampleRate > 0 else {
            return AudioChecks(
                sampleCount: samples.count,
                durationSeconds: 0,
                rms: 0,
                peak: 0,
                clippedSampleRatio: 0,
                nonFiniteSampleCount: samples.filter { !$0.isFinite }.count
            )
        }

        var squareSum = 0.0
        var peak = 0.0
        var clipped = 0
        var nonFinite = 0
        for sample in samples {
            guard sample.isFinite else {
                nonFinite += 1
                continue
            }
            let magnitude = abs(Double(sample))
            squareSum += magnitude * magnitude
            peak = max(peak, magnitude)
            if magnitude >= 0.999 {
                clipped += 1
            }
        }

        let finiteCount = max(samples.count - nonFinite, 1)
        return AudioChecks(
            sampleCount: samples.count,
            durationSeconds: Double(samples.count) / Double(sampleRate),
            rms: sqrt(squareSum / Double(finiteCount)),
            peak: peak,
            clippedSampleRatio: Double(clipped) / Double(finiteCount),
            nonFiniteSampleCount: nonFinite
        )
    }
}
