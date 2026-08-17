import AudioMonsterCore
import Foundation

enum NarrationInput: Sendable {
    case web(URL)
    case file(URL)
    case pasted(title: String?, text: String)

    var origin: ReadableDocumentOrigin {
        switch self {
        case .web(let url):
            return .web(sourceURL: url, resolvedURL: url)
        case .file(let url):
            return .file(
                displayName: url.lastPathComponent,
                fileType: url.pathExtension.lowercased()
            )
        case .pasted:
            return .pasted
        }
    }
}

enum DocumentResolutionError: LocalizedError {
    case emptyPastedText
    case unsupportedFileInput

    var errorDescription: String? {
        switch self {
        case .emptyPastedText:
            return "Paste some text before creating audio."
        case .unsupportedFileInput:
            return "This document format is not supported yet."
        }
    }
}

/// The single boundary between user-facing input sources and narration-ready
/// content. Format-specific readers will be added behind this protocol.
@MainActor
protocol DocumentResolving: AnyObject {
    func resolve(_ input: NarrationInput) async throws -> ReadableDocument
}

@MainActor
final class NativeDocumentResolver: DocumentResolving {
    private let articleExtractor: any ArticleExtracting
    private let fileParsers: DocumentFileParserRegistry

    init(
        articleExtractor: any ArticleExtracting,
        fileParsers: DocumentFileParserRegistry = DocumentFileParserRegistry()
    ) {
        self.articleExtractor = articleExtractor
        self.fileParsers = fileParsers
    }

    func resolve(_ input: NarrationInput) async throws -> ReadableDocument {
        switch input {
        case .web(let url):
            return try await articleExtractor.extract(url: url)
        case .file(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            return try await fileParsers.parse(
                fileURL: url,
                displayName: url.lastPathComponent
            )
        case .pasted(let title, let text):
            let normalizedText =
                text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                throw DocumentResolutionError.emptyPastedText
            }
            let normalizedTitle = title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ReadableDocument(
                origin: .pasted,
                title: normalizedTitle?.isEmpty == false ? normalizedTitle! : "Pasted text",
                text: normalizedText
            )
        }
    }
}
