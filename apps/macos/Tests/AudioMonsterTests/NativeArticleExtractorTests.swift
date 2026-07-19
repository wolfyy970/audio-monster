import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

@MainActor
private final class FixedRenderedPageRenderer: RenderedPageRendering {
    let snapshot: RenderedPageSnapshot

    init(snapshot: RenderedPageSnapshot) {
        self.snapshot = snapshot
    }

    func render(url _: URL) async throws -> RenderedPageSnapshot {
        snapshot
    }
}

private actor RecordingArticleParser: ArticleParsing {
    private(set) var receivedHTML: String?
    private(set) var receivedSourceURL: URL?
    private(set) var receivedResolvedURL: URL?
    private var result: ExtractedArticle?

    init(result: ExtractedArticle?) {
        self.result = result
    }

    func parse(
        html: String,
        sourceURL: URL,
        resolvedURL: URL
    ) async throws -> ExtractedArticle? {
        receivedHTML = html
        receivedSourceURL = sourceURL
        receivedResolvedURL = resolvedURL
        return result
    }
}

@MainActor
struct NativeArticleExtractorTests {
    @Test
    func composesRenderedDOMAndNativeParserWithoutLosingURLProvenance() async throws {
        let sourceURL = try #require(URL(string: "https://example.com/short"))
        let resolvedURL = try #require(URL(string: "https://publisher.example/final"))
        let html = "<html><body><article><p>Rendered body</p></article></body></html>"
        let extracted = ExtractedArticle(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL,
            title: "Native Article",
            narrationText: "Rendered body"
        )
        let parser = RecordingArticleParser(result: extracted)
        let extractor = NativeArticleExtractor(
            renderer: FixedRenderedPageRenderer(
                snapshot: snapshot(
                    sourceURL: sourceURL,
                    resolvedURL: resolvedURL,
                    html: html
                )),
            parser: parser
        )

        let article = try await extractor.extract(url: sourceURL)

        #expect(article.sourceURL == sourceURL)
        #expect(article.resolvedURL == resolvedURL)
        #expect(article.title == "Native Article")
        #expect(article.text == "Rendered body")
        #expect(await parser.receivedHTML == html)
        #expect(await parser.receivedSourceURL == sourceURL)
        #expect(await parser.receivedResolvedURL == resolvedURL)
    }

    @Test
    func parserNilFailsClosedAsNoReadableContent() async throws {
        let url = try #require(URL(string: "https://example.com/page"))
        let extractor = NativeArticleExtractor(
            renderer: FixedRenderedPageRenderer(
                snapshot: snapshot(sourceURL: url, resolvedURL: url)
            ),
            parser: RecordingArticleParser(result: nil)
        )

        do {
            _ = try await extractor.extract(url: url)
            Issue.record("A nil native parse must not become an empty article.")
        } catch ArticleExtractionError.noReadableContent {
            // Expected.
        } catch {
            Issue.record("Expected noReadableContent, received \(error).")
        }
    }

    @Test
    func challengedSnapshotNeverReachesTheNativeParser() async throws {
        let url = try #require(URL(string: "https://example.com/page"))
        let parser = RecordingArticleParser(result: nil)
        let extractor = NativeArticleExtractor(
            renderer: FixedRenderedPageRenderer(
                snapshot: snapshot(
                    sourceURL: url,
                    resolvedURL: url,
                    challenged: true
                )),
            parser: parser
        )

        do {
            _ = try await extractor.extract(url: url)
            Issue.record("A browser challenge must stop before native parsing.")
        } catch ArticleExtractionError.accessChallenge {
            #expect(await parser.receivedHTML == nil)
        } catch {
            Issue.record("Expected accessChallenge, received \(error).")
        }
    }

    private func snapshot(
        sourceURL: URL,
        resolvedURL: URL,
        html: String = "<html><body>Article</body></html>",
        challenged: Bool = false
    ) -> RenderedPageSnapshot {
        RenderedPageSnapshot(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL,
            title: "Rendered Title",
            html: html,
            readyState: .complete,
            challenged: challenged,
            textCharacterCount: 320,
            substantiveProseCharacterCount: 320,
            stabilityFingerprint: "stable"
        )
    }
}
