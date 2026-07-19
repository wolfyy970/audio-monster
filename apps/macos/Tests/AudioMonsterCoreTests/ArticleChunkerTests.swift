import AudioMonsterCore
import Foundation
import Testing

struct ArticleChunkerTests {
    @Test
    func chunksAtSentenceBoundariesWithinKokorosSafeInputSize() {
        let sentence = "This is a sentence with enough words to sound natural when narrated. "
        let text = String(repeating: sentence, count: 30)

        let chunks = ArticleChunker.chunks(from: text, maximumCharacters: 180)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 180 })
        #expect(chunks.dropLast().allSatisfy { $0.hasSuffix(".") })
    }

    @Test
    func hardWrapsLongTokensWithoutLosingText() {
        let token = String(repeating: "x", count: 425)
        let chunks = ArticleChunker.chunks(from: token, maximumCharacters: 120)

        #expect(chunks.map(\.count) == [120, 120, 120, 65])
        #expect(chunks.joined() == token)
    }

    @Test
    func createsPortableTitleBasedM4AFilenames() {
        #expect(
            ArticleChunker.suggestedFilename(title: "The Challenges of Animal Translation!")
                == "the-challenges-of-animal-translation.m4a"
        )
        #expect(ArticleChunker.suggestedFilename(title: "***") == "article.m4a")
    }
}
