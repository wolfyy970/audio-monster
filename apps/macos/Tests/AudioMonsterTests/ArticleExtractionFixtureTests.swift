import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

@MainActor
struct ArticleExtractionFixtureTests {
    private var fastPolicy: BrowserExtractionPolicy {
        BrowserExtractionPolicy(
            timeout: .seconds(5),
            inspectionInterval: .milliseconds(5)
        )
    }

    private var unreadableDocumentPolicy: BrowserExtractionPolicy {
        BrowserExtractionPolicy(
            timeout: .milliseconds(120),
            inspectionInterval: .milliseconds(5)
        )
    }

    @Test
    func emptyAndNonArticleDocumentsFailWithoutReturningPageFurniture() async throws {
        let fixtures = [
            """
            <!doctype html>
            <html><head><title>Empty document</title></head><body></body></html>
            """,
            """
            <!doctype html>
            <html><head><title>Account portal</title></head><body>
              <nav><a href="/">Home</a> <a href="/sign-in">Sign in</a></nav>
              <main><form><label>Email <input type="email"></label><button>Continue</button></form></main>
              <footer>Privacy Terms Help</footer>
            </body></html>
            """,
        ]

        for fixture in fixtures {
            let extractor = BrowserPageRenderer(policy: unreadableDocumentPolicy)
            do {
                _ = try await extractor.extract(url: dataURL(for: fixture))
                Issue.record("A document without article prose must not be returned as an article.")
            } catch ArticleExtractionError.timedOut {
                // An unreadable document remains below the acceptance threshold until
                // the request's deliberately short fixture timeout expires.
            } catch {
                Issue.record("Expected an unreadable-content timeout, received \(error).")
            }
        }
    }

    @Test
    func keepsTheSubmittedSourceURLSeparateFromTheBrowserResolvedURL() async throws {
        let resolvedURL = try #require(URL(string: "https://publisher.example/final-article"))
        let scripts = BrowserExtractionScripts(
            readabilitySource: "",
            snapshotSource: """
                return JSON.stringify({
                  title: "A Redirected Article",
                  text: "This deterministic browser snapshot represents a readable article after navigation has reached its final publisher URL. The original URL supplied by the user must remain separately available for file provenance and metadata, while the resolved URL records the browser destination. Repeating the same complete snapshot allows the normal stability policy to accept this fixture without any live network dependency.",
                  resolvedURL: "https://publisher.example/final-article",
                  ready: true,
                  challenged: false,
                  method: "mozilla-readability"
                });
                """
        )
        let extractor = BrowserPageRenderer(policy: fastPolicy) { scripts }
        let sourceURL = try dataURL(
            for: """
                <!doctype html><html><head><title>Redirecting</title></head><body></body></html>
                """)

        let article = try await extractor.extract(url: sourceURL)

        #expect(article.sourceURL == sourceURL)
        #expect(article.resolvedURL == resolvedURL)
        #expect(article.sourceURL != article.resolvedURL)
    }

    @Test
    func fallsBackToTheArticleHeadingWhenMetadataAndDocumentTitleAreMissing() async throws {
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
                    <!doctype html><html><head></head><body>
                      <main>
                        <article>
                          <h1>The Heading Becomes the Title</h1>
                          <p>Some publishers omit both Open Graph title metadata and the ordinary browser document title, even though the visible story begins with an unambiguous heading for readers.</p>
                          <p>The semantic extraction path should retain that heading as the narration title rather than rejecting otherwise coherent prose or producing a nameless audio file.</p>
                          <p>This final paragraph gives the frozen fixture enough useful text to satisfy the same readability threshold as a normal article.</p>
                        </article>
                      </main>
                    </body></html>
                    """))

        #expect(article.title == "The Heading Becomes the Title")
        #expect(article.text.contains("semantic extraction path"))
        #expect(extractor.lastExtractionMethod == .semanticFallback)
    }

    @Test
    func excludesConsentNavigationAndRelatedStoryPollution() async throws {
        let extractor = BrowserPageRenderer(policy: fastPolicy)
        let article = try await extractor.extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html><head><title>Listening Without the Clutter</title></head><body>
                      <div class="cookie-consent" role="dialog">
                        We value your privacy. Accept all cookies or manage consent preferences.
                      </div>
                      <nav>Sections Search Subscribe Account</nav>
                      <article>
                        <h1>Listening Without the Clutter</h1>
                        <p>Turning an essay into audio only works well when the extracted narration follows the author's argument instead of reading the surrounding website interface aloud.</p>
                        <p>Reader-mode scoring identifies the dense, connected paragraphs that make up this story and rejects controls, promotional cards, and other unrelated fragments.</p>
                        <p>The result should sound like one continuous article, with enough context for a listener to understand every transition while away from the screen.</p>
                        <section class="related-stories">
                          <h2>Related stories</h2>
                          <a href="/advertorial">Ten products every listener must buy today</a>
                        </section>
                      </article>
                      <footer>Newsletter Careers Advertising Contact us</footer>
                    </body></html>
                    """))

        #expect(article.text.contains("Turning an essay into audio"))
        #expect(article.text.contains("one continuous article"))
        #expect(!article.text.contains("Accept all cookies"))
        #expect(!article.text.contains("Sections Search Subscribe"))
        #expect(!article.text.contains("Related stories"))
        #expect(!article.text.contains("products every listener"))
        #expect(!article.text.contains("Newsletter Careers"))
    }

    @Test
    func preservesOrderedListOrderQuotationsAndNonEnglishText() async throws {
        let extractor = BrowserPageRenderer(policy: fastPolicy)
        let article = try await extractor.extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html lang="es"><head><title>Voces en muchos idiomas</title></head><body>
                      <article>
                        <h1>Voces en muchos idiomas</h1>
                        <p>Una narración útil debe conservar la estructura de una explicación, incluso cuando combina una lista ordenada, citas breves y varios sistemas de escritura.</p>
                        <blockquote lang="ar">قالت الباحثة: «الصوت الواضح يحمل المعنى بأمانة».</blockquote>
                        <ol>
                          <li>Primero, identificar el argumento principal.</li>
                          <li>Después, mantener el orden de cada paso.</li>
                          <li>Por último, escuchar la conclusión completa.</li>
                        </ol>
                        <blockquote lang="ja">「短い引用も消してはいけません」と著者は書いた。</blockquote>
                        <p>El texto final aporta suficiente contexto para que las frases cortas pertenezcan claramente al artículo y lleguen intactas a la síntesis de voz.</p>
                      </article>
                    </body></html>
                    """))

        #expect(article.text.contains("«الصوت الواضح يحمل المعنى بأمانة»"))
        #expect(article.text.contains("「短い引用も消してはいけません」"))

        let first = try #require(article.text.range(of: "Primero, identificar"))
        let second = try #require(article.text.range(of: "Después, mantener"))
        let third = try #require(article.text.range(of: "Por último, escuchar"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < third.lowerBound)
        #expect(article.text.components(separatedBy: "\n\n").count >= 7)
    }

    private func dataURL(for html: String) throws -> URL {
        let encoded = Data(html.utf8).base64EncodedString()
        return try #require(URL(string: "data:text/html;charset=utf-8;base64,\(encoded)"))
    }
}
