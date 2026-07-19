@preconcurrency import AVFoundation
import Foundation

struct CachedVoicePreview: Equatable, Sendable {
    let url: URL
    let durationSeconds: Double
}

@MainActor
protocol VoicePreviewCaching: AnyObject {
    func load(voiceIDs: [String]) -> [String: CachedVoicePreview]
    func makeStagingURL(voiceID: String) throws -> URL
    func commit(stagingURL: URL, voiceID: String) throws -> CachedVoicePreview
    func discardStagingFile(at url: URL)
}

enum VoicePreviewCacheError: LocalizedError {
    case invalidVoiceID(String)
    case invalidAudio
    case unexpectedStagingLocation

    var errorDescription: String? {
        switch self {
        case .invalidVoiceID(let voiceID): "Invalid voice identifier: \(voiceID)."
        case .invalidAudio: "The generated voice sample is not a playable WAV file."
        case .unexpectedStagingLocation: "The generated voice sample used an invalid cache path."
        }
    }
}

@MainActor
final class FileVoicePreviewCache: VoicePreviewCaching {
    /// Bump this namespace whenever the model revision or preview script changes.
    nonisolated static let version = "kokoro-82m-bf16-preview-v1"

    private static let maximumPreviewDuration = 10.5
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
        discardAbandonedStagingFiles()
    }

    func load(voiceIDs: [String]) -> [String: CachedVoicePreview] {
        var result: [String: CachedVoicePreview] = [:]
        for voiceID in voiceIDs where Self.isSafeVoiceID(voiceID) {
            let url = finalURL(for: voiceID)
            if let artifact = validatedArtifact(at: url) { result[voiceID] = artifact }
        }
        return result
    }

    func makeStagingURL(voiceID: String) throws -> URL {
        guard Self.isSafeVoiceID(voiceID) else {
            throw VoicePreviewCacheError.invalidVoiceID(voiceID)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(
            ".\(voiceID)-\(UUID().uuidString).partial.wav"
        )
    }

    func commit(stagingURL: URL, voiceID: String) throws -> CachedVoicePreview {
        guard Self.isSafeVoiceID(voiceID) else {
            throw VoicePreviewCacheError.invalidVoiceID(voiceID)
        }
        let standardizedStagingURL = stagingURL.standardizedFileURL
        guard standardizedStagingURL.deletingLastPathComponent() == directory,
            standardizedStagingURL.lastPathComponent.hasSuffix(".partial.wav")
        else { throw VoicePreviewCacheError.unexpectedStagingLocation }
        guard validatedArtifact(at: standardizedStagingURL) != nil else {
            throw VoicePreviewCacheError.invalidAudio
        }

        let destination = finalURL(for: voiceID)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: standardizedStagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: standardizedStagingURL, to: destination)
        }
        guard let artifact = validatedArtifact(at: destination) else {
            throw VoicePreviewCacheError.invalidAudio
        }
        return artifact
    }

    func discardStagingFile(at url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.deletingLastPathComponent() == directory,
            standardizedURL.lastPathComponent.hasSuffix(".partial.wav")
        else { return }
        try? fileManager.removeItem(at: standardizedURL)
    }

    private func finalURL(for voiceID: String) -> URL {
        directory.appendingPathComponent("\(voiceID).wav")
    }

    private func validatedArtifact(at url: URL) -> CachedVoicePreview? {
        guard fileManager.fileExists(atPath: url.path),
            Self.hasWAVHeader(at: url),
            let audioFile = try? AVAudioFile(forReading: url)
        else { return nil }
        let format = audioFile.processingFormat
        let frameLength = audioFile.length
        let sampleRate = format.sampleRate
        guard format.channelCount > 0,
            frameLength > 0,
            sampleRate.isFinite,
            sampleRate > 0
        else { return nil }
        let duration = Double(frameLength) / sampleRate
        guard duration.isFinite,
            duration > 0,
            duration <= Self.maximumPreviewDuration
        else { return nil }
        return CachedVoicePreview(url: url, durationSeconds: duration)
    }

    private func discardAbandonedStagingFiles() {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return }
        for url in contents
        where url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.hasSuffix(".partial.wav") {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func hasWAVHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else {
            return false
        }
        return String(decoding: header.prefix(4), as: UTF8.self) == "RIFF"
            && String(decoding: header.suffix(4), as: UTF8.self) == "WAVE"
    }

    private static func isSafeVoiceID(_ voiceID: String) -> Bool {
        !voiceID.isEmpty
            && voiceID.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
            }
    }
}
