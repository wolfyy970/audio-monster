import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

@MainActor
struct DocumentResolverTests {
    @Test
    func normalizesPastedTextAndUsesFallbackTitle() async throws {
        let resolver = NativeDocumentResolver(
            articleExtractor: StubArticleExtractor()
        )

        let document = try await resolver.resolve(
            .pasted(title: "  ", text: "  First line\r\nSecond line  ")
        )

        #expect(document.origin == .pasted)
        #expect(document.title == "Pasted text")
        #expect(document.text == "First line\nSecond line")
    }

    @Test
    func rejectsEmptyPastedTextBeforeCreatingDocument() async {
        let resolver = NativeDocumentResolver(
            articleExtractor: StubArticleExtractor()
        )

        do {
            _ = try await resolver.resolve(.pasted(title: nil, text: " \n\t "))
            Issue.record("Whitespace-only pasted text should be rejected.")
        } catch DocumentResolutionError.emptyPastedText {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func webInputStillDelegatesToExistingArticleExtractor() async throws {
        let sourceURL = try #require(URL(string: "https://example.com/story"))
        let expected = ReadableDocument(
            origin: .web(sourceURL: sourceURL, resolvedURL: sourceURL),
            title: "Story",
            text: "Readable story."
        )
        let extractor = StubArticleExtractor(document: expected)
        let resolver = NativeDocumentResolver(articleExtractor: extractor)

        let document = try await resolver.resolve(.web(sourceURL))

        #expect(document == expected)
        #expect(extractor.requestedURL == sourceURL)
    }
}

@MainActor
private final class StubArticleExtractor: ArticleExtracting {
    let document: ReadableDocument
    private(set) var requestedURL: URL?

    init(
        document: ReadableDocument = ReadableDocument(
            origin: .web(
                sourceURL: URL(string: "https://example.com/default")!,
                resolvedURL: URL(string: "https://example.com/default")!
            ),
            title: "Default",
            text: "Default text."
        )
    ) {
        self.document = document
    }

    func extract(url: URL) async throws -> ReadableDocument {
        requestedURL = url
        return document
    }
}
