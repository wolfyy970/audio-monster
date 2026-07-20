import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

@MainActor
extension WebKitBackedExtractionTests {
    private var fastPolicy: BrowserExtractionPolicy {
        BrowserExtractionPolicy(
            timeout: .seconds(5),
            inspectionInterval: .milliseconds(5)
        )
    }

    private var unreadablePolicy: BrowserExtractionPolicy {
        BrowserExtractionPolicy(
            timeout: .milliseconds(150),
            inspectionInterval: .milliseconds(5)
        )
    }

    @Test
    func renderedDOMFlowsThroughNativeReadabilityAndRejectsPageFurniture() async throws {
        let article = try await extractor().extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html><head>
                      <title>Wrong browser-tab title | Example</title>
                      <meta property="og:title" content="A Better Article Title">
                    </head><body>
                      <nav>Navigation noise that must never be narrated.</nav>
                      <main><article class="story-body">
                        <h1>A Better Article Title</h1>
                        <p>Article extraction is difficult because real publishing sites contain navigation, advertising, recommendations, and interactive furniture around the prose.</p>
                        <p>A mature reader algorithm scores paragraphs and their ancestors, penalises link-heavy regions, and preserves the coherent body instead of choosing a tag by name.</p>
                        <p>This final paragraph makes the intended story unmistakable and gives a listener a clean, continuous narration without unrelated interface copy.</p>
                      </article></main>
                      <aside>Sponsored sidebar noise that must never be narrated.</aside>
                      <footer>Footer noise that must never be narrated.</footer>
                    </body></html>
                    """))

        #expect(article.title == "A Better Article Title")
        #expect(article.text.contains("Article extraction is difficult"))
        #expect(article.text.contains("This final paragraph"))
        #expect(!article.text.contains("Navigation noise"))
        #expect(!article.text.contains("Sponsored sidebar"))
        #expect(!article.text.contains("Footer noise"))
    }

    @Test
    func findsDivHeavyProseWithoutSemanticArticleMarkup() async throws {
        let article = try await extractor().extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html><head><title>The Div-Heavy Essay</title></head><body>
                      <div class="top-menu"><a href="#one">Home</a> <a href="#two">Topics</a></div>
                      <div id="entry-content" class="post story content">
                        <h1>The Div-Heavy Essay</h1>
                        <div><p>Many production websites still use generic containers even when the page is clearly a long-form article intended for careful reading.</p></div>
                        <div><p>The extractor therefore has to score textual density, punctuation, sibling paragraphs, class names, and link density rather than trust semantic HTML alone.</p></div>
                        <div><p>This is precisely the sort of messy but ordinary document structure that a hand-written article-or-main selector routinely mishandles.</p></div>
                      </div>
                      <div class="related"><a href="#elsewhere">A long unrelated promotional card full of distracting words and links.</a></div>
                    </body></html>
                    """))

        #expect(article.title == "The Div-Heavy Essay")
        #expect(article.text.contains("Many production websites"))
        #expect(article.text.contains("messy but ordinary document structure"))
        #expect(!article.text.contains("unrelated promotional card"))
    }

    @Test
    func preservesShortBlocksListsQuotationsAndUnicode() async throws {
        let article = try await extractor().extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html lang="es"><head><title>Voces en muchos idiomas</title></head><body>
                      <article>
                        <h1>Voces en muchos idiomas</h1>
                        <p>Una narración útil debe conservar la estructura de una explicación, incluso cuando combina una lista ordenada, citas breves y varios sistemas de escritura.</p>
                        <p>Listen.</p>
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

        #expect(article.text.contains("Listen."))
        #expect(article.text.contains("«الصوت الواضح يحمل المعنى بأمانة»"))
        #expect(article.text.contains("「短い引用も消してはいけません」"))
        let first = try #require(article.text.range(of: "Primero, identificar"))
        let second = try #require(article.text.range(of: "Después, mantener"))
        let third = try #require(article.text.range(of: "Por último, escuchar"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < third.lowerBound)
        #expect(article.text.components(separatedBy: "\n\n").count >= 7)
    }

    @Test
    func waitsForClientRenderedArticleBeforeNativeParsing() async throws {
        let article = try await extractor().extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html><head><title>Loading article</title></head><body>
                      <main id="app">Loading…</main>
                      <script>
                        setTimeout(() => {
                          document.title = "The Hydrated Article";
                          document.getElementById("app").innerHTML = `
                            <article>
                              <h1>The Hydrated Article</h1>
                              <p>This article arrived after the initial document load, exactly as content does in a client-rendered publishing application.</p>
                              <p>The browser renderer must wait for useful prose and then observe a stable result rather than narrating a loading label or a half-built page.</p>
                              <p>A final substantial paragraph verifies that the completed dynamic article is what reaches the audio conversion pipeline.</p>
                            </article>`;
                        }, 75);
                      </script>
                    </body></html>
                    """))

        #expect(article.title == "The Hydrated Article")
        #expect(article.text.contains("client-rendered publishing application"))
        #expect(article.text.contains("completed dynamic article"))
        #expect(!article.text.contains("Loading…"))
    }

    @Test
    func ignoresStablePageFurnitureWhileWaitingForDelayedArticleHydration() async throws {
        let renderer = BrowserPageRenderer(policy: fastPolicy)
        _ = try await renderer.render(
            url: dataURL(
                for: """
                    <!doctype html><html><head><title>Warm Browser</title></head><body><article>
                      <p>This warm-up document gives WebKit a ready content process before the timing-sensitive delayed-hydration regression begins.</p>
                      <p>Its only purpose is to ensure the first readiness probes run well before the following one-second client-rendering timer fires.</p>
                    </article></body></html>
                    """))
        let extractor = NativeArticleExtractor(
            renderer: renderer,
            parser: SwiftReadabilityArticleParser()
        )

        let article = try await extractor.extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html><head><title>Publisher</title></head><body>
                      <header>
                        <nav>
                          Home World Science Culture Technology Newsletters Podcasts Events About Contact Careers Privacy Terms Help Accessibility
                        </nav>
                      </header>
                      <div role="dialog" aria-modal="true" id="consent-layer">
                        We value your privacy. You can accept all cookies, reject optional cookies, review every category, manage advertising choices,
                        read our privacy policy, change your preferences, learn about our partners, or continue with essential storage only.
                      </div>
                      <main id="app"></main>
                      <script>
                        setTimeout(() => {
                          document.title = "The Patiently Hydrated Article";
                          document.getElementById("app").innerHTML = `
                            <article>
                              <h1>The Patiently Hydrated Article</h1>
                              <p>The real story arrived well after a stable publisher shell, so navigation and consent copy must never trigger an early browser snapshot.</p>
                              <p>A readiness probe may measure ordinary prose structure, but native Readability alone remains responsible for selecting the article.</p>
                              <p>Waiting for this final paragraph protects client-rendered publishers without moving extraction policy into JavaScript.</p>
                            </article>`;
                        }, 1000);
                      </script>
                    </body></html>
                    """))

        #expect(article.title == "The Patiently Hydrated Article")
        #expect(article.text.contains("real story arrived well after"))
        #expect(article.text.contains("Waiting for this final paragraph"))
        #expect(!article.text.contains("We value your privacy"))
        #expect(!article.text.contains("Home World Science"))
    }

    @Test
    func untitledRenderedArticleUsesItsVisibleHeading() async throws {
        let article = try await extractor().extract(
            url: dataURL(
                for: """
                    <!doctype html><html><body>
                      <article>
                        <h1>The Visible Heading Wins</h1>
                        <p>An otherwise valid article does not always provide a document title, especially when a client-rendered publisher only inserts a visible heading.</p>
                        <p>The browser boundary must pass that stable prose to native Readability instead of waiting until the request times out.</p>
                        <p>Native title fallback can then preserve the heading readers actually see without weakening article selection.</p>
                      </article>
                    </body></html>
                    """))

        #expect(article.title == "The Visible Heading Wins")
        #expect(article.text.contains("The browser boundary must pass"))
    }

    @Test
    func boundedDOMTransportPreservesJSONLDMetadataForNativeParsing() async throws {
        let policy = BrowserExtractionPolicy(
            minimumReadableCharacterCount: 200,
            requiredConsecutiveStableSnapshots: 1,
            maximumReadableSnapshotCount: 1,
            maximumHTMLBytes: 2_048,
            timeout: .seconds(3),
            inspectionInterval: .milliseconds(5)
        )
        let article = try await extractor(policy: policy).extract(
            url: dataURL(
                for: """
                    <!doctype html><html><head>
                      <title>Browser Shell Title</title>
                      <script type="application/ld+json">
                        {"@context":"https://schema.org","@type":"Article","headline":"The Structured Headline","author":{"@type":"Person","name":"Example Author"}}
                      </script>
                    </head><body>
                      <article>
                        <h1>Visible Heading</h1>
                        <p>The meaningful article remains compact even when the hydrated page contains a large executable state payload that native Readability would discard.</p>
                        <p>The transport clone must keep structured article metadata while removing inert script bytes before applying its strict size ceiling.</p>
                        <p>This proves the boundary optimization preserves Mozilla metadata semantics rather than merely retaining visible prose.</p>
                      </article>
                      <script>
                        const inert = document.createElement("script");
                        inert.textContent = "native-parser-bloat" + "x".repeat(8192);
                        document.body.appendChild(inert);
                      </script>
                    </body></html>
                    """))

        #expect(article.title == "The Structured Headline")
        #expect(article.text.contains("preserves Mozilla metadata semantics"))
        #expect(!article.text.contains("native-parser-bloat"))
    }

    @Test
    func emptyAndNonArticleDocumentsNeverBecomePageFurnitureNarration() async throws {
        let fixtures = [
            "<!doctype html><html><head><title>Empty</title></head><body></body></html>",
            """
            <!doctype html><html><head><title>Account portal</title></head><body>
              <nav><a href="/">Home</a> <a href="/sign-in">Sign in</a></nav>
              <main><form><label>Email <input type="email"></label><button>Continue</button></form></main>
              <footer>Privacy Terms Help</footer>
            </body></html>
            """,
        ]

        for fixture in fixtures {
            do {
                _ = try await extractor(policy: unreadablePolicy).extract(url: dataURL(for: fixture))
                Issue.record("A document without article prose must not become narration.")
            } catch ArticleExtractionError.timedOut {
                // Expected: the rendered document never reaches the prose threshold.
            } catch ArticleExtractionError.noReadableContent {
                // Also valid if a future rendering policy hands the document to Readability sooner.
            } catch {
                Issue.record("Expected a fail-closed unreadable result, received \(error).")
            }
        }
    }

    @Test
    func aStableBrowserChallengeFailsImmediatelyAsAChallenge() async throws {
        let policy = BrowserExtractionPolicy(
            minimumReadableCharacterCount: 1,
            requiredConsecutiveStableSnapshots: 1,
            maximumReadableSnapshotCount: 1,
            timeout: .seconds(2),
            inspectionInterval: .milliseconds(5)
        )

        do {
            _ = try await extractor(policy: policy).extract(
                url: dataURL(
                    for: """
                        <!doctype html><html><head><title>Just a moment...</title></head><body>
                          <form id="challenge-form">Checking your browser before accessing the publisher.</form>
                        </body></html>
                        """))
            Issue.record("A browser challenge must never become article narration.")
        } catch ArticleExtractionError.accessChallenge {
            // Expected.
        } catch {
            Issue.record("Expected accessChallenge, received \(error).")
        }
    }

    private func extractor(
        policy: BrowserExtractionPolicy? = nil
    ) -> NativeArticleExtractor {
        NativeArticleExtractor(
            renderer: BrowserPageRenderer(policy: policy ?? fastPolicy),
            parser: SwiftReadabilityArticleParser()
        )
    }

    private func dataURL(for html: String) throws -> URL {
        let encoded = Data(html.utf8).base64EncodedString()
        return try #require(URL(string: "data:text/html;charset=utf-8;base64,\(encoded)"))
    }
}
