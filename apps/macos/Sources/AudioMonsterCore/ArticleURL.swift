import Foundation

/// A validated public HTTP or HTTPS article location without embedded credentials.
public struct ArticleURL: Equatable, Hashable, Sendable {
    public let value: URL

    public init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil
        else { return nil }
        value = url
    }
}
