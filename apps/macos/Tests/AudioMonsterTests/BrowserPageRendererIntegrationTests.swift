import Foundation
import Testing

@testable import AudioMonster

@MainActor
extension WebKitBackedExtractionTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["AUDIO_MONSTER_LIVE_WEB_TEST"] == "1",
            "Set AUDIO_MONSTER_LIVE_WEB_TEST=1 to exercise a real browser-protected article."
        )
    )
    func extractsTheAeonArticlePastItsBrowserCheckpoint() async throws {
        let url = try #require(
            URL(string: "https://aeon.co/essays/silicon-valley-has-a-science-fiction-problem")
        )

        let article = try await NativeArticleExtractor.shared.extract(url: url)

        #expect(article.title.contains("Silicon Valley has a science fiction problem"))
        #expect(article.text.contains("The looting of science fiction"))
        #expect(article.text.contains("Tech titans claim the genre inspired them"))
        #expect(!article.text.contains("Vercel Security Checkpoint"))
    }
}
