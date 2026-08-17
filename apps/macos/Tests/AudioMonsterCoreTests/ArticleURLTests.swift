import AudioMonsterCore
import Foundation
import Testing

struct ArticleURLTests {
    @Test(arguments: [
        "https://example.com/article",
        "http://example.com/article?edition=morning#chapter-2",
        "  https://example.com/trimmed  ",
        "HTTP://EXAMPLE.COM/Article",
        "http://example.com:8080/article",
        "http://127.0.0.1/local-essay",
        "http://192.0.2.1/documented-address",
        "http://[2001:db8::1]/ipv6-essay",
        "http://www.incompleteideas.net/IncIdeas/BitterLesson.html",
    ])
    func acceptsCompleteWebURLs(_ input: String) throws {
        let articleURL = try #require(ArticleURL(input))
        #expect(["http", "https"].contains(articleURL.value.scheme?.lowercased() ?? ""))
        #expect(articleURL.value.host != nil)
    }

    @Test
    func keepsSubmittedHTTPSchemeInsteadOfUpgradingToHTTPS() throws {
        let articleURL = try #require(
            ArticleURL("http://www.incompleteideas.net/IncIdeas/BitterLesson.html")
        )

        #expect(articleURL.value.scheme == "http")
        #expect(articleURL.value.host == "www.incompleteideas.net")
        #expect(articleURL.value.path == "/IncIdeas/BitterLesson.html")
        #expect(articleURL.value.absoluteString.hasPrefix("https://") == false)
    }

    @Test(arguments: [
        "",
        "example.com/article",
        "/relative/article",
        "ftp://example.com/article",
        "file:///tmp/article.html",
        "https://",
        "https://reader@example.com/private",
        "https://reader:secret@example.com/private",
        "https://:secret@example.com/private",
    ])
    func rejectsIncompleteUnsupportedOrCredentialBearingURLs(_ input: String) {
        #expect(ArticleURL(input) == nil)
    }

    @Test
    func equalityUsesTheNormalizedURLValue() throws {
        let plain = try #require(ArticleURL("https://example.com/article"))
        let padded = try #require(ArticleURL("\n https://example.com/article\t"))
        #expect(plain == padded)
        #expect(plain.hashValue == padded.hashValue)
    }
}
