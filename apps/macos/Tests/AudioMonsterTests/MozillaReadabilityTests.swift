import CryptoKit
import Foundation
import Testing

@testable import AudioMonster

@MainActor
struct MozillaReadabilityTests {
    @Test
    func bundlesThePinnedAuditedMozillaSourceAndLicense() throws {
        let source = try MozillaReadabilityAsset.source()
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(MozillaReadabilityAsset.version == "0.6.0")
        #expect(digest == MozillaReadabilityAsset.sourceSHA256)
        #expect(source.contains("function Readability(doc, options)"))
        #expect(try MozillaReadabilityAsset.license().contains("Apache License"))
        #expect(try MozillaReadabilityAsset.upstreamMetadata().contains(digest))
    }

    @Test
    func extractsAnArticleAndRejectsPageFurniture() async throws {
        let extractor = BrowserPageRenderer()
        let article = try await extractor.extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html>
                      <head>
                        <title>Wrong browser-tab title | Example</title>
                        <meta property="og:title" content="A Better Article Title">
                      </head>
                      <body>
                        <nav>Navigation noise that must never be narrated.</nav>
                        <main>
                          <article class="story-body">
                            <h1>A Better Article Title</h1>
                            <p>Article extraction is difficult because real publishing sites contain navigation, advertising, recommendations, and interactive furniture around the prose.</p>
                            <p>A mature reader algorithm scores paragraphs and their ancestors, penalises link-heavy regions, and preserves the coherent body instead of choosing a tag by name.</p>
                            <p>This final paragraph makes the intended story unmistakable and gives a listener a clean, continuous narration without unrelated interface copy.</p>
                          </article>
                        </main>
                        <aside>Sponsored sidebar noise that must never be narrated.</aside>
                        <footer>Footer noise that must never be narrated.</footer>
                      </body>
                    </html>
                    """))

        #expect(article.title == "A Better Article Title")
        #expect(article.text.contains("Article extraction is difficult"))
        #expect(article.text.contains("This final paragraph"))
        #expect(!article.text.contains("Navigation noise"))
        #expect(!article.text.contains("Sponsored sidebar"))
        #expect(!article.text.contains("Footer noise"))
        #expect(extractor.lastExtractionMethod == .mozillaReadability)
    }

    @Test
    func findsDivHeavyProseWithoutSemanticArticleMarkup() async throws {
        let extractor = BrowserPageRenderer()
        let article = try await extractor.extract(
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
        #expect(extractor.lastExtractionMethod == .mozillaReadability)
    }

    @Test
    func preservesShortParagraphsListsAndUnicodeInsideLongContent() async throws {
        let extractor = BrowserPageRenderer()
        let article = try await extractor.extract(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html lang="en"><head><title>Small Lines Matter</title></head><body>
                      <article>
                        <h1>Small Lines Matter</h1>
                        <p>A readable article can contain intentionally short dramatic paragraphs, compact list entries, multilingual quotations, and other text that should not disappear merely because a block has fewer than twenty characters.</p>
                        <p>Listen.</p>
                        <blockquote>静かな声も物語の一部です。</blockquote>
                        <ul><li>First.</li><li>Second.</li><li>Third.</li></ul>
                        <p>The surrounding long-form prose supplies enough evidence that all of those short blocks belong to the article and should survive extraction for narration.</p>
                      </article>
                    </body></html>
                    """))

        #expect(article.text.contains("Listen."))
        #expect(article.text.contains("静かな声も物語の一部です。"))
        #expect(article.text.contains("First."))
        #expect(article.text.contains("Second."))
        #expect(article.text.contains("Third."))
        #expect(article.text.components(separatedBy: "\n\n").count >= 5)
    }

    @Test
    func waitsForClientRenderedArticleContent() async throws {
        let extractor = BrowserPageRenderer()
        let article = try await extractor.extract(
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
                        }, 150);
                      </script>
                    </body></html>
                    """))

        #expect(article.title == "The Hydrated Article")
        #expect(article.text.contains("client-rendered publishing application"))
        #expect(article.text.contains("completed dynamic article"))
        #expect(!article.text.contains("Loading…"))
        #expect(extractor.lastExtractionMethod == .mozillaReadability)
    }

    private func dataURL(for html: String) throws -> URL {
        let encoded = Data(html.utf8).base64EncodedString()
        return try #require(URL(string: "data:text/html;charset=utf-8;base64,\(encoded)"))
    }
}
