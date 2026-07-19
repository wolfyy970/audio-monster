import AudioMonsterCore
import Foundation

/// The application-facing boundary for turning a URL into narration-ready prose.
@MainActor
protocol ArticleExtracting: AnyObject {
    func extract(url: URL) async throws -> ReadableArticle
}

/// Composes browser hydration with native article selection and narration projection.
///
/// WebKit is responsible only for loading the submitted page and serializing its
/// rendered DOM. `ArticleParsing` owns all content selection and speech-oriented
/// projection, so another Apple client or a hosted service can supply HTML without
/// inheriting the desktop browser adapter.
@MainActor
final class NativeArticleExtractor: ArticleExtracting {
    static let shared = NativeArticleExtractor(
        renderer: BrowserPageRenderer.shared,
        parser: SwiftReadabilityArticleParser()
    )

    private let renderer: any RenderedPageRendering
    private let parser: any ArticleParsing

    init(
        renderer: any RenderedPageRendering,
        parser: any ArticleParsing
    ) {
        self.renderer = renderer
        self.parser = parser
    }

    func extract(url: URL) async throws -> ReadableArticle {
        let snapshot = try await renderer.render(url: url)
        try Task.checkCancellation()

        guard !snapshot.challenged else {
            throw ArticleExtractionError.accessChallenge
        }
        guard
            let extracted = try await parser.parse(
                html: snapshot.html,
                sourceURL: snapshot.sourceURL,
                resolvedURL: snapshot.resolvedURL
            )
        else {
            throw ArticleExtractionError.noReadableContent
        }
        try Task.checkCancellation()

        return ReadableArticle(
            sourceURL: extracted.sourceURL,
            resolvedURL: extracted.resolvedURL,
            title: extracted.title,
            text: extracted.narrationText
        )
    }
}
