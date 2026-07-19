@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import AudioMonster

struct AudioArtifactWriterTests {
    @Test
    func exportsPlayableM4AWithTitleAndSourceURLMetadata() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let waveURL = folder.appendingPathComponent("input.wav")
        let outputURL = folder.appendingPathComponent("output.m4a")
        try writeWave(to: waveURL)
        let sourceURL = try #require(URL(string: "https://example.com/original-article"))

        try await AudioArtifactWriter.exportM4A(
            from: waveURL,
            to: outputURL,
            title: "Original Article",
            sourceURL: sourceURL,
            resolvedURL: sourceURL
        )

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0.9)
        let metadata = try await asset.load(.metadata)
        let titleItem = metadata.first { $0.identifier == .iTunesMetadataSongName }
        let sourceItem = metadata.first { $0.identifier == .iTunesMetadataUserComment }
        #expect(try await titleItem?.load(.stringValue) == "Original Article")
        #expect(try await sourceItem?.load(.stringValue) == sourceURL.absoluteString)
    }

    @Test
    func exportsSafeSourceAndResolvedURLs() async throws {
        let sourceURL = try #require(URL(string: "https://example.com/original-article"))
        let resolvedURL = try #require(URL(string: "https://www.example.com/articles/canonical"))
        let metadata = try await exportedMetadataStrings(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL
        )

        #expect(metadata.contains { $0 == sourceURL.absoluteString })
        #expect(metadata.contains { $0 == "Resolved URL: \(resolvedURL.absoluteString)" })
    }

    @Test
    func omitsCredentialBearingResolvedURLFromExportedMetadata() async throws {
        let sourceURL = try #require(URL(string: "https://example.com/original-article"))
        let resolvedURL = try #require(
            URL(
                string: "https://private-reader:super-secret@example.com/articles/canonical"
            ))
        let metadata = try await exportedMetadataStrings(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL
        )

        #expect(metadata.contains { $0 == sourceURL.absoluteString })
        #expect(!metadata.joined(separator: "\n").contains("private-reader"))
        #expect(!metadata.joined(separator: "\n").contains("super-secret"))
        #expect(!metadata.contains { $0.contains(resolvedURL.absoluteString) })
    }

    @Test
    func omitsCredentialBearingSourceURLFromExportedMetadata() async throws {
        let sourceURL = try #require(
            URL(
                string: "https://private-reader:super-secret@example.com/original-article"
            ))
        let resolvedURL = try #require(URL(string: "https://example.com/articles/canonical"))
        let metadata = try await exportedMetadataStrings(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL
        )

        let allMetadata = metadata.joined(separator: "\n")
        #expect(!allMetadata.contains("private-reader"))
        #expect(!allMetadata.contains("super-secret"))
        #expect(!metadata.contains { $0.contains(sourceURL.absoluteString) })
        #expect(metadata.contains { $0 == "Resolved URL: \(resolvedURL.absoluteString)" })
    }

    private func exportedMetadataStrings(
        sourceURL: URL,
        resolvedURL: URL
    ) async throws -> [String] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let waveURL = folder.appendingPathComponent("input.wav")
        let outputURL = folder.appendingPathComponent("output.m4a")
        try writeWave(to: waveURL)

        try await AudioArtifactWriter.exportM4A(
            from: waveURL,
            to: outputURL,
            title: "Metadata Test",
            sourceURL: sourceURL,
            resolvedURL: resolvedURL
        )

        let items = try await AVURLAsset(url: outputURL).load(.metadata)
        var strings: [String] = []
        for item in items {
            if let value = try await item.load(.stringValue) {
                strings.append(value)
            }
        }
        return strings
    }

    private func writeWave(to url: URL) throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 24_000,
                channels: 1,
                interleaved: false
            ))
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 24_000
            ))
        buffer.frameLength = 24_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<24_000 {
            samples[index] = 0.15 * sin(2 * .pi * 440 * Float(index) / 24_000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
