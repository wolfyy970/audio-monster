import Foundation

/// Deterministic text preparation shared by audio-producing clients and services.
public enum ArticleChunker {
    public static let defaultMaximumCharacters = 280

    private static let sentenceBoundaryRegex = try? NSRegularExpression(
        pattern: #"(?<=[.!?。！？])(?:[\"'”’»)]*)\s+"#
    )

    public static func chunks(
        from text: String,
        maximumCharacters: Int = defaultMaximumCharacters
    ) -> [String] {
        precondition(maximumCharacters >= 100)
        let paragraphs =
            text
            .components(separatedBy: .newlines)
            .map { normalized($0) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        for paragraph in paragraphs {
            result.append(contentsOf: split(paragraph, maximumCharacters: maximumCharacters))
        }
        return result
    }

    public static func suggestedFilename(title: String, pathExtension: String = "m4a") -> String {
        let normalizedTitle = title.precomposedStringWithCompatibilityMapping
        let safe = normalizedTitle.map { character in
            character.isLetter || character.isNumber ? String(character) : " "
        }.joined()
        let stem =
            safe
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: "-")
            .lowercased()
            .prefix(96)
        return "\(stem.isEmpty ? "article" : String(stem)).\(pathExtension)"
    }

    private static func split(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let boundaries = sentenceBoundaryRegex?.matches(in: text, range: range).map(\.range) ?? []
        var sentences: [String] = []
        var start = text.startIndex
        for boundary in boundaries {
            guard let boundaryRange = Range(boundary, in: text) else { continue }
            let sentence = normalized(String(text[start..<boundaryRange.lowerBound]))
            if !sentence.isEmpty { sentences.append(sentence) }
            start = boundaryRange.upperBound
        }
        let tail = normalized(String(text[start...]))
        if !tail.isEmpty { sentences.append(tail) }
        if sentences.isEmpty { sentences = [text] }

        var result: [String] = []
        var current = ""
        for sentence in sentences {
            for piece in hardWrap(sentence, maximumCharacters: maximumCharacters) {
                let candidate = current.isEmpty ? piece : "\(current) \(piece)"
                if candidate.count > maximumCharacters, !current.isEmpty {
                    result.append(current)
                    current = piece
                } else {
                    current = candidate
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func hardWrap(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var result: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.count > maximumCharacters {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                var remainder = word[...]
                while !remainder.isEmpty {
                    let end = remainder.index(
                        remainder.startIndex,
                        offsetBy: min(maximumCharacters, remainder.count)
                    )
                    result.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                continue
            }
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count > maximumCharacters {
                result.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
