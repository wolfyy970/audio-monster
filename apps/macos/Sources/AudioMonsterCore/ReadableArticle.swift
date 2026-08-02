import Foundation

/// Identifies where narration-ready content came from without forcing every
/// source to pretend to be a web page.
public enum ReadableDocumentOrigin: Equatable, Sendable {
    case web(sourceURL: URL, resolvedURL: URL)
    case file(displayName: String, fileType: String)
    case pasted

    public var sourceURL: URL? {
        guard case .web(let sourceURL, _) = self else { return nil }
        return sourceURL
    }

    public var resolvedURL: URL? {
        guard case .web(_, let resolvedURL) = self else { return nil }
        return resolvedURL
    }

    public var displayName: String {
        switch self {
        case .web(let sourceURL, _):
            return sourceURL.host ?? "Web page"
        case .file(let displayName, _):
            return displayName
        case .pasted:
            return "Pasted text"
        }
    }
}

/// Normalized content ready for narration, regardless of its input format.
public struct ReadableDocument: Equatable, Sendable {
    public let origin: ReadableDocumentOrigin
    public let title: String
    public let text: String

    public init(origin: ReadableDocumentOrigin, title: String, text: String) {
        self.origin = origin
        self.title = title
        self.text = text
    }

    /// Compatibility initializer for existing web extraction clients.
    public init(sourceURL: URL, resolvedURL: URL, title: String, text: String) {
        self.init(
            origin: .web(sourceURL: sourceURL, resolvedURL: resolvedURL),
            title: title,
            text: text
        )
    }

    /// Compatibility accessors for the pre-document API. New code should use
    /// `origin` so non-web sources are never mistaken for URLs.
    public var sourceURL: URL {
        origin.sourceURL ?? Self.nonWebPlaceholderURL
    }

    public var resolvedURL: URL {
        origin.resolvedURL ?? Self.nonWebPlaceholderURL
    }

    private static let nonWebPlaceholderURL = URL(string: "about:blank")!
}

/// Temporary source-compatible name while clients migrate from article-only
/// terminology to the broader document model.
public typealias ReadableArticle = ReadableDocument
