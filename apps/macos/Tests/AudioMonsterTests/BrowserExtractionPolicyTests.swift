import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

@MainActor
struct BrowserPageRendererLifecycleTests {
    private var fastPolicy: BrowserExtractionPolicy {
        BrowserExtractionPolicy(inspectionInterval: .milliseconds(5))
    }

    @Test
    func describesHTTPFailuresWithoutWaitingForExtractionTimeout() {
        let error = ArticleExtractionError.httpStatus(429)

        #expect(
            error.errorDescription
                == "The page could not be opened because the web server returned HTTP 429."
        )
    }

    @Test
    func usesSemanticFallbackWhenReadabilityDeclinesTheDocument() async throws {
        let bundledScripts = try BrowserExtractionScripts.bundled()
        let scripts = BrowserExtractionScripts(
            readabilitySource: """
                function Readability() {
                  this.parse = function() { return null; };
                }
                """,
            snapshotSource: bundledScripts.snapshotSource
        )
        let extractor = BrowserPageRenderer(policy: fastPolicy) { scripts }
        let article = try await extractor.extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html><head><title>Semantic Fallback Article</title></head><body>
                      <nav>Navigation that should be removed from narration.</nav>
                      <main>
                        <h1>Semantic Fallback Article</h1>
                        <p>A semantic fallback remains useful when the primary reader declines a document even though its main region contains coherent article prose for narration.</p>
                        <p>The fallback must preserve paragraph boundaries, discard navigation furniture, and return enough clean text for the ordinary stability policy to accept it.</p>
                        <p>This final paragraph makes the deterministic fixture comfortably longer than the minimum readable content threshold used by Audio Monster.</p>
                      </main>
                    </body></html>
                    """))

        #expect(article.title == "Semantic Fallback Article")
        #expect(article.text.contains("semantic fallback remains useful"))
        #expect(!article.text.contains("Navigation that should be removed"))
        #expect(extractor.lastExtractionMethod == .semanticFallback)
    }

    @Test
    func rejectsAConcurrentExtractionAndCancelsTheActiveRequestPromptly() async throws {
        let extractor = BrowserPageRenderer(policy: fastPolicy)
        let waitingURL = try dataURL(
            for: """
                <!doctype html><html><head><title>Waiting</title></head>
                <body><main>Not enough content yet.</main></body></html>
                """)
        let firstRequest = Task { @MainActor in
            try await extractor.extract(url: waitingURL)
        }
        try await Task.sleep(for: .milliseconds(25))

        do {
            _ = try await extractor.extract(url: waitingURL)
            Issue.record("A concurrent extraction should be rejected.")
        } catch ArticleExtractionError.alreadyLoading {
            // Expected.
        } catch {
            Issue.record("Expected alreadyLoading, received \(error).")
        }

        firstRequest.cancel()
        do {
            _ = try await firstRequest.value
            Issue.record("The active extraction should finish with cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected cancellation, received \(error).")
        }
    }

    @Test
    func handlesCancellationBeforeContinuationSetupAndAllowsTheNextRequest() async throws {
        let extractor = BrowserPageRenderer(policy: fastPolicy)
        let waitingURL = try dataURL(
            for: """
                <!doctype html><html><head><title>Waiting</title></head>
                <body><main>Not enough content yet.</main></body></html>
                """)
        let cancelledRequest = Task { @MainActor in
            try await extractor.extract(url: waitingURL)
        }
        cancelledRequest.cancel()

        do {
            _ = try await cancelledRequest.value
            Issue.record("A pre-cancelled extraction should not wait for its timeout.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected cancellation, received \(error).")
        }

        let nextArticle = try await extractor.extract(
            url: dataURL(
                for: """
                    <!doctype html><html><head><title>The Next Article</title></head><body>
                      <article>
                        <h1>The Next Article</h1>
                        <p>The request after a pre-cancelled extraction must own an independent continuation that cannot be completed by the earlier cancellation handler.</p>
                        <p>A request-scoped identifier ensures delayed WebKit callbacks and cancellation delivery are ignored once their original extraction has finished.</p>
                        <p>This fixture contains enough stable prose to complete immediately under the same readability rules used by the application.</p>
                      </article>
                    </body></html>
                    """))
        #expect(nextArticle.title == "The Next Article")
    }

    private func dataURL(for html: String) throws -> URL {
        let encoded = Data(html.utf8).base64EncodedString()
        return try #require(URL(string: "data:text/html;charset=utf-8;base64,\(encoded)"))
    }
}
