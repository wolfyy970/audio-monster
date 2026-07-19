import Foundation
import SwiftSoup

/// Converts extracted article HTML into stable, speech-oriented plain text.
///
/// Mozilla Readability deliberately exposes DOM `textContent`, whose block
/// boundaries disappear when serialized as plain text. Narration needs those
/// boundaries so the speech engine pauses between paragraphs, headings, list
/// items, and quotations. This projector preserves them without inventing
/// punctuation or changing the article's words.
struct NarrationTextProjector: Sendable {
    private static let boundaryTags: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt",
        "figcaption", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
        "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    /// Elements that do not contribute spoken article prose.
    ///
    /// Generic `header` elements are intentionally absent: an article header
    /// often contains its headline and standfirst. Publisher cleanup belongs in
    /// Readability's explicit Audio Monster extension profile, while this list is
    /// limited to semantic chrome, controls, executable content, and ruby hints.
    private static let excludedTags: Set<String> = [
        "audio", "button", "canvas", "embed", "form", "iframe", "input",
        "noscript", "object", "option", "rp", "rt", "script",
        "select", "style", "svg", "template", "textarea", "video",
    ]

    private static let excludedRoles: Set<String> = [
        "alertdialog", "dialog",
    ]

    /// Projects a detached article fragment into paragraphs separated by one
    /// blank line. Inline whitespace is normalized, while CJK text and punctuation
    /// remain untouched.
    func project(html: String) throws -> String {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        let document = try SwiftSoup.parseBodyFragment(html)
        guard let root = document.body() else { return "" }

        var paragraphs: [String] = []
        var fragments: [String] = []
        var traversal: [TraversalEvent] = [.enter(root)]

        func flush() {
            let paragraph = Self.normalizeInline(fragments.joined())
            if !paragraph.isEmpty {
                paragraphs.append(paragraph)
            }
            fragments.removeAll(keepingCapacity: true)
        }

        while let event = traversal.popLast() {
            switch event {
            case .exit(let element):
                if Self.boundaryTags.contains(element.tagName().lowercased()) {
                    flush()
                }

            case .enter(let node):
                if let textNode = node as? TextNode {
                    fragments.append(textNode.getWholeText())
                    continue
                }

                guard let element = node as? Element else { continue }
                let tag = element.tagName().lowercased()
                guard try !Self.isExcluded(element, tag: tag) else { continue }

                if tag == "br" {
                    flush()
                    continue
                }

                if Self.boundaryTags.contains(tag) {
                    flush()
                }

                traversal.append(.exit(element))
                for child in element.getChildNodes().reversed() {
                    traversal.append(.enter(child))
                }
            }
        }

        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func isExcluded(_ element: Element, tag: String) throws -> Bool {
        if excludedTags.contains(tag) || element.hasAttr("hidden") {
            return true
        }

        if try element.attr("aria-hidden")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("true") == .orderedSame
        {
            return true
        }

        let roles = try element.attr("role")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        if roles.contains(where: excludedRoles.contains) {
            return true
        }
        return try hasHiddenInlineStyle(element)
    }

    private static func hasHiddenInlineStyle(_ element: Element) throws -> Bool {
        for declaration in try element.attr("style").split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }

            let property = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(separator: "!", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if (property == "display" && value == "none")
                || (property == "visibility" && value == "hidden")
                || (property == "content-visibility" && value == "hidden")
            {
                return true
            }
        }
        return false
    }

    private static func normalizeInline(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private enum TraversalEvent {
        case enter(Node)
        case exit(Element)
    }
}
