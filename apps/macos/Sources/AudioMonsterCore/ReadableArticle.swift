import Foundation

/// Extracted article content with both provenance and the final resolved location.
public struct ReadableArticle: Equatable, Sendable {
    public let sourceURL: URL
    public let resolvedURL: URL
    public let title: String
    public let text: String

    public init(sourceURL: URL, resolvedURL: URL, title: String, text: String) {
        self.sourceURL = sourceURL
        self.resolvedURL = resolvedURL
        self.title = title
        self.text = text
    }
}
