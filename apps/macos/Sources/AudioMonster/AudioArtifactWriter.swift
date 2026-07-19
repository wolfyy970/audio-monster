@preconcurrency import AVFoundation
import AudioMonsterCore
import Foundation

enum AudioArtifactError: LocalizedError {
    case cannotCreateExporter
    case exportFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .cannotCreateExporter: "The native AAC encoder is unavailable."
        case .exportFailed(let message): "The audio file could not be encoded: \(message)"
        case .emptyAudio: "Kokoro produced no audio."
        }
    }
}

enum AudioArtifactWriter {
    static func exportM4A(
        from waveURL: URL,
        to outputURL: URL,
        title: String,
        sourceURL: URL,
        resolvedURL: URL
    ) async throws {
        let asset = AVURLAsset(url: waveURL)
        guard
            let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            )
        else { throw AudioArtifactError.cannotCreateExporter }

        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false
        exporter.metadata = metadataItems(
            title: title,
            sourceURL: sourceURL,
            resolvedURL: resolvedURL
        )

        await exporter.export()
        switch exporter.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw AudioArtifactError.exportFailed(
                exporter.error?.localizedDescription ?? "Unknown encoder error"
            )
        }
    }

    private static func metadataItems(
        title: String,
        sourceURL: URL,
        resolvedURL: URL
    ) -> [AVMetadataItem] {
        let safeSourceURL = ArticleURL(sourceURL.absoluteString)?.value
        let safeResolvedURL = ArticleURL(resolvedURL.absoluteString)?.value
        var items = [item(identifier: .iTunesMetadataSongName, value: title)]

        if let safeSourceURL {
            items.append(
                item(
                    identifier: .iTunesMetadataDescription,
                    value: "Generated from \(safeSourceURL.absoluteString)"
                ))
            items.append(
                item(
                    identifier: .iTunesMetadataUserComment,
                    value: safeSourceURL.absoluteString
                ))
            items.append(
                item(
                    identifier: .quickTimeUserDataURLLink,
                    value: safeSourceURL.absoluteString
                ))
        }
        if let safeResolvedURL, safeResolvedURL != safeSourceURL {
            items.append(
                item(
                    identifier: .quickTimeMetadataInformation,
                    value: "Resolved URL: \(safeResolvedURL.absoluteString)"
                ))
        }
        return items
    }

    private static func item(
        identifier: AVMetadataIdentifier,
        value: String
    ) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item.copy() as? AVMetadataItem ?? item
    }
}
