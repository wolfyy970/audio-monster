import AudioMonsterCore
import Foundation
import Testing

struct ReadableArticleTests {
    @Test
    func preservesSourceResolvedLocationAndReadableContent() throws {
        let sourceURL = try #require(URL(string: "https://example.com/short-link"))
        let resolvedURL = try #require(URL(string: "https://example.com/articles/final"))

        let article = ReadableArticle(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL,
            title: "A useful article",
            text: "Readable content."
        )

        #expect(article.sourceURL == sourceURL)
        #expect(article.resolvedURL == resolvedURL)
        #expect(article.title == "A useful article")
        #expect(article.text == "Readable content.")
    }

    @Test
    func decodesBrowserSnapshotWithoutAPlatformBrowserDependency() throws {
        let data = Data(
            #"{"title":"Article","text":"Readable content","resolvedURL":"https://example.com/final","ready":true,"challenged":false,"method":"mozilla-readability"}"#
                .utf8
        )

        let snapshot = try JSONDecoder().decode(BrowserExtractionSnapshot.self, from: data)

        #expect(snapshot.title == "Article")
        #expect(snapshot.resolvedURL == "https://example.com/final")
        #expect(snapshot.method == .mozillaReadability)
    }
}
