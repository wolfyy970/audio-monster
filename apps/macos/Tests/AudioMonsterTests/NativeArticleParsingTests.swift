import Foundation
import Testing

@testable import AudioMonster

@Suite("Native Swift Readability article parser")
struct NativeArticleParsingTests {
    private let sourceURL = URL(string: "https://short.example/story")!
    private let resolvedURL = URL(string: "https://publisher.example/features/native-reading")!

    @Test("Returns native title, narration, and URL provenance")
    func parsesArticleAndPreservesProvenance() async throws {
        let parser = SwiftReadabilityArticleParser(characterThreshold: 40)
        let article = try #require(
            await parser.parse(
                html: articleHTML,
                sourceURL: sourceURL,
                resolvedURL: resolvedURL
            ))

        #expect(article.sourceURL == sourceURL)
        #expect(article.resolvedURL == resolvedURL)
        #expect(article.sourceURL != article.resolvedURL)
        #expect(article.title == "A Native Reading Pipeline")
        #expect(article.narrationText.contains("Reader mode scoring"))
        #expect(article.narrationText.contains("A second substantive paragraph"))
        #expect(!article.narrationText.contains("Sections Search Subscribe"))
    }

    @Test("Uses an intelligible URL title when the document has no title metadata")
    func suppliesDeterministicFallbackTitle() async throws {
        let parser = SwiftReadabilityArticleParser(characterThreshold: 20)
        let resolvedURL = URL(string: "https://publisher.example/features/fallback-heading")!
        let article = try #require(
            await parser.parse(
                html: """
                    <html><body><article>
                      <p>This complete article paragraph contains enough connected prose for native extraction and a useful narration result.</p>
                      <p>A second paragraph makes the article candidate unambiguous without relying on browser title metadata.</p>
                    </article></body></html>
                    """,
                sourceURL: sourceURL,
                resolvedURL: resolvedURL
            ))

        #expect(article.title == "fallback heading")
    }

    @Test("Prefers the extracted article heading over a URL fallback")
    func usesArticleHeadingWhenDocumentMetadataIsMissing() async throws {
        let parser = SwiftReadabilityArticleParser(characterThreshold: 20)
        let article = try #require(
            await parser.parse(
                html: """
                    <html><body><article>
                      <h1>The Visible Heading Wins</h1>
                      <p>This complete paragraph contains enough connected prose for native extraction when ordinary browser title metadata is absent.</p>
                      <p>A second substantial paragraph makes the article candidate unambiguous and preserves its visible heading for the audio filename.</p>
                    </article></body></html>
                    """,
                sourceURL: sourceURL,
                resolvedURL: URL(string: "https://publisher.example/opaque/12345")!
            ))

        #expect(article.title == "The Visible Heading Wins")
    }

    @Test("Ignores branding headings outside the extracted article")
    func scopesFallbackHeadingToExtractedContent() async throws {
        let parser = SwiftReadabilityArticleParser(characterThreshold: 20)
        let resolvedURL = URL(string: "https://publisher.example/opaque/12345")!
        let article = try #require(
            await parser.parse(
                html: """
                    <html>
                      <head><title>publisher.example</title></head>
                      <body>
                        <header><h1>Publisher Brand</h1></header>
                        <article>
                          <h1>The Article Heading</h1>
                          <p>This complete paragraph contains enough connected prose for native extraction while the page header carries an unrelated branding heading.</p>
                          <p>A second substantial paragraph makes the article candidate unambiguous and keeps filename metadata scoped to the selected story.</p>
                        </article>
                      </body>
                    </html>
                    """,
                sourceURL: sourceURL,
                resolvedURL: resolvedURL
            ))

        #expect(article.title == "The Article Heading")
    }

    @Test("Empty documents do not fabricate content")
    func rejectsEmptyDocuments() async throws {
        let parser = SwiftReadabilityArticleParser(characterThreshold: 20)

        #expect(
            try await parser.parse(
                html: "",
                sourceURL: sourceURL,
                resolvedURL: resolvedURL
            ) == nil)
    }

    @Test("Rejects navigation-only output below the viable narration threshold")
    func rejectsNavigationOnlyDocuments() async throws {
        let parser = SwiftReadabilityArticleParser(characterThreshold: 20)

        #expect(
            try await parser.parse(
                html: "<html><body><nav>Home Account Search</nav></body></html>",
                sourceURL: sourceURL,
                resolvedURL: resolvedURL
            ) == nil)
    }

    @Test("Readability failures propagate instead of becoming empty articles")
    func propagatesParserFailure() async {
        let parser = SwiftReadabilityArticleParser(
            maximumElements: 1,
            characterThreshold: 0
        )

        do {
            _ = try await parser.parse(
                html: articleHTML,
                sourceURL: sourceURL,
                resolvedURL: resolvedURL
            )
            Issue.record("Expected the configured element limit to reject the document.")
        } catch {
            #expect(error.localizedDescription.contains("Aborting parsing document"))
        }
    }

    @Test("Cancellation is observed before an empty parse can succeed")
    func observesCallerCancellation() async {
        let parser = SwiftReadabilityArticleParser()
        let task = Task {
            try await parser.parse(
                html: "",
                sourceURL: sourceURL,
                resolvedURL: resolvedURL
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected a cancelled parse to throw CancellationError.")
        } catch is CancellationError {
            // Expected: cancellation is part of the parsing contract.
        } catch {
            Issue.record("Expected CancellationError, received \(error).")
        }
    }

    @Test("One parser safely produces deterministic results concurrently")
    func concurrentParsingIsDeterministic() async throws {
        let parser = SwiftReadabilityArticleParser(characterThreshold: 40)
        let results = try await withThrowingTaskGroup(
            of: ExtractedArticle?.self,
            returning: [ExtractedArticle].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await parser.parse(
                        html: articleHTML,
                        sourceURL: sourceURL,
                        resolvedURL: resolvedURL
                    )
                }
            }

            var results: [ExtractedArticle] = []
            for try await result in group {
                results.append(try #require(result))
            }
            return results
        }

        let first = try #require(results.first)
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == first })
    }

    private var articleHTML: String {
        """
        <!doctype html>
        <html lang="en">
          <head>
            <title>A Native Reading Pipeline</title>
            <meta name="description" content="A deterministic native extraction fixture.">
          </head>
          <body>
            <nav>Sections Search Subscribe</nav>
            <article>
              <h1>A Native Reading Pipeline</h1>
              <p>Reader mode scoring identifies the dense and connected prose that belongs to this article while leaving unrelated website controls behind.</p>
              <p>A second substantive paragraph preserves enough context for a listener to follow the author's complete argument away from the screen.</p>
              <blockquote>Native extraction keeps this short quotation in its proper position.</blockquote>
            </article>
            <footer>Privacy Careers Contact</footer>
          </body>
        </html>
        """
    }
}
