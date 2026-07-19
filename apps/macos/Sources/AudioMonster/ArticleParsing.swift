import Foundation
import SwiftReadability
import SwiftSoup

/// An immutable native extraction result ready to become narrated audio.
struct ExtractedArticle: Equatable, Sendable {
    let sourceURL: URL
    let resolvedURL: URL
    let title: String
    let narrationText: String
}

/// The boundary between rendered-page acquisition and native article parsing.
///
/// A macOS client can supply hydrated HTML from WebKit, while a future service or
/// mobile client can supply HTML from its own transport without changing the
/// readability or narration pipeline.
protocol ArticleParsing: Sendable {
    func parse(
        html: String,
        sourceURL: URL,
        resolvedURL: URL
    ) async throws -> ExtractedArticle?
}

/// Parses rendered HTML with native Swift Readability and produces narration text.
///
/// Every parse constructs and consumes its mutable DOM inside a detached task.
/// No SwiftSoup or Readability reference crosses the concurrency boundary, so a
/// caller on the main actor never performs document parsing or article scoring.
struct SwiftReadabilityArticleParser: ArticleParsing, Sendable {
    /// Application-owned policy layered on top of SwiftReadability's empty,
    /// Mozilla-compatible default extension set.
    static let readabilityExtensions: ReadabilityExtensions = [
        .imageCarouselRecovery,
        .publisherChromeCleanup,
        .articleBodyPreservation,
        .significantMediaPreservation,
        .rubyNormalization,
    ]

    private let maximumElements: Int
    private let topCandidateCount: Int
    private let characterThreshold: Int

    init(
        maximumElements: Int = 100_000,
        topCandidateCount: Int = ReadabilityOptions.defaultNTopCandidates,
        characterThreshold: Int = 200
    ) {
        self.maximumElements = maximumElements
        self.topCandidateCount = topCandidateCount
        self.characterThreshold = characterThreshold
    }

    func parse(
        html: String,
        sourceURL: URL,
        resolvedURL: URL
    ) async throws -> ExtractedArticle? {
        try Task.checkCancellation()
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let maximumElements = maximumElements
        let topCandidateCount = topCandidateCount
        let characterThreshold = characterThreshold
        let minimumNarrationLength =
            characterThreshold == 0
            ? ReadabilityOptions.defaultCharThreshold
            : characterThreshold

        let parsingTask = Task.detached(priority: .userInitiated) { () throws -> ExtractedArticle? in
            try Task.checkCancellation()

            let options = ReadabilityOptions(
                maxElemsToParse: maximumElements,
                nbTopCandidates: topCandidateCount,
                charThreshold: characterThreshold,
                extensions: Self.readabilityExtensions
            )
            guard
                let result = try Readability(
                    html: html,
                    url: resolvedURL,
                    options: options
                ).parse()
            else {
                return nil
            }

            try Task.checkCancellation()
            let narrationText = try NarrationTextProjector().project(html: result.contentHTML)
            guard narrationText.utf16.count >= minimumNarrationLength else { return nil }

            let normalizedResultTitle = normalizedOptional(result.title)
            let articleHeading: String?
            if let normalizedResultTitle,
                !isURLDerivedTitle(normalizedResultTitle, resolvedURL: resolvedURL)
            {
                articleHeading = nil
            } else {
                articleHeading = try fallbackArticleHeading(
                    extractedHTML: result.contentHTML,
                    renderedHTML: html
                )
            }
            let title = normalizedTitle(
                normalizedResultTitle,
                articleHeading: articleHeading,
                resolvedURL: resolvedURL
            )
            return ExtractedArticle(
                sourceURL: sourceURL,
                resolvedURL: resolvedURL,
                title: title,
                narrationText: narrationText
            )
        }

        return try await withTaskCancellationHandler {
            try await parsingTask.value
        } onCancel: {
            parsingTask.cancel()
        }
    }
}

private func normalizedTitle(
    _ title: String?,
    articleHeading: String?,
    resolvedURL: URL
) -> String {
    let normalizedTitle = normalizedOptional(title)
    let normalizedHeading = normalizedOptional(articleHeading)
    if let normalizedTitle,
        !isURLDerivedTitle(normalizedTitle, resolvedURL: resolvedURL)
    {
        return normalizedTitle
    }
    if let normalizedHeading {
        return normalizedHeading
    }
    if let normalizedTitle {
        return normalizedTitle
    }

    let pathTitle = resolvedURL.deletingPathExtension().lastPathComponent
        .removingPercentEncoding?
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    if let pathTitle = normalizedOptional(pathTitle) {
        return pathTitle
    }

    return resolvedURL.host ?? "Untitled Article"
}

private func isURLDerivedTitle(_ title: String, resolvedURL: URL) -> Bool {
    let normalizedTitle = title.lowercased()
    let pathComponent = resolvedURL.deletingPathExtension().lastPathComponent
        .removingPercentEncoding?
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .lowercased()
    if normalizedOptional(pathComponent) == normalizedTitle {
        return true
    }
    return resolvedURL.host?.lowercased() == normalizedTitle
}

private func fallbackArticleHeading(
    extractedHTML: String,
    renderedHTML: String
) throws -> String? {
    let extractedDocument = try SwiftSoup.parseBodyFragment(extractedHTML)
    if let heading = try extractedDocument.select("h1").first()?.text() {
        return heading
    }

    let renderedDocument = try SwiftSoup.parse(renderedHTML)
    let articleContainers = try renderedDocument.select(
        "article, [role=article], [itemprop~=articleBody], main"
    )
    for container in articleContainers {
        if let heading = try container.select("h1").first()?.text() {
            return heading
        }
    }

    // On a non-semantic page, one unambiguous document heading is a useful
    // fallback. Multiple page-level headings are not safe to guess between.
    guard articleContainers.isEmpty() else { return nil }
    let documentHeadings = try renderedDocument.select("h1")
    guard documentHeadings.size() == 1 else { return nil }
    return try documentHeadings.first()?.text()
}

private func normalizedOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized =
        value
        .replacingOccurrences(of: "\u{00a0}", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return normalized.isEmpty ? nil : normalized
}
