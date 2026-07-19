import Foundation
import Testing

@testable import SwiftTTSBench

@Test func audioChecksMeasureDurationAndAmplitude() {
    let checks = ResultAnalysis.checks(samples: [0, 0.5, -0.5, 1], sampleRate: 2)

    #expect(checks.sampleCount == 4)
    #expect(checks.durationSeconds == 2)
    #expect(abs(checks.rms - sqrt(0.375)) < 0.000_001)
    #expect(checks.peak == 1)
    #expect(checks.clippedSampleRatio == 0.25)
    #expect(checks.nonFiniteSampleCount == 0)
}

@Test func audioChecksReportInvalidSamples() {
    let checks = ResultAnalysis.checks(
        samples: [Float.nan, Float.infinity, -Float.infinity, 0.25],
        sampleRate: 1
    )

    #expect(checks.nonFiniteSampleCount == 3)
    #expect(checks.rms == 0.25)
    #expect(checks.peak == 0.25)
}

@Test func catalogExcludesKittenAndKeepsSopranoAsBaselineOnly() {
    #expect(BenchmarkCatalog.model(for: "kitten") == nil)
    #expect(BenchmarkCatalog.model(for: "kokoro")?.voice == "am_michael")
    #expect(BenchmarkCatalog.model(for: "soprano-baseline")?.role.contains("baseline") == true)
}

@Test func medianHandlesOddEvenAndEmptyInputs() {
    #expect(ResultAnalysis.median([]) == nil)
    #expect(ResultAnalysis.median([9]) == 9)
    #expect(ResultAnalysis.median([9, 1, 5]) == 5)
    #expect(ResultAnalysis.median([8, 2, 6, 4]) == 5)
}

@Test func summaryUsesWarmRunsAndMeasuresDurationSpread() {
    func measurement(_ name: String, elapsed: Double, duration: Double, firstAudio: Double) -> GenerationMeasurement {
        GenerationMeasurement(
            name: name,
            elapsedSeconds: elapsed,
            timeToFirstAudioSeconds: firstAudio,
            realtimeFactor: elapsed / duration,
            realtimeMultiple: duration / elapsed,
            reportedTokensPerSecond: nil,
            reportedPeakMemoryGB: nil,
            audio: AudioChecks(
                sampleCount: Int(duration * 24_000),
                durationSeconds: duration,
                rms: 0.1,
                peak: 0.5,
                clippedSampleRatio: 0,
                nonFiniteSampleCount: 0
            ),
            outputFile: "\(name).wav"
        )
    }

    let summary = ResultAnalysis.summary(generations: [
        measurement("cold", elapsed: 8, duration: 12, firstAudio: 8),
        measurement("warm-1", elapsed: 3, duration: 12, firstAudio: 3),
        measurement("warm-2", elapsed: 2, duration: 11, firstAudio: 2),
        measurement("warm-3", elapsed: 4, duration: 13, firstAudio: 4),
    ])

    #expect(summary.warmRunCount == 3)
    #expect(summary.medianWarmElapsedSeconds == 3)
    #expect(summary.medianWarmTimeToFirstAudioSeconds == 3)
    #expect(summary.outputDurationSpreadSeconds == 2)
}
