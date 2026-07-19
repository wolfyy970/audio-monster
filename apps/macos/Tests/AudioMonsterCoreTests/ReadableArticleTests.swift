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
}
