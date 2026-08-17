import AudioMonsterCore
import Foundation
@preconcurrency import PDFKit

protocol DocumentFileParsing: Sendable {
    var supportedExtensions: Set<String> { get }

    func parse(fileURL: URL, displayName: String) async throws -> ReadableDocument
}

enum DocumentFileParsingError: LocalizedError {
    case unsupportedFormat(String)
    case fileTooLarge
    case unreadableText
    case emptyText
    case malformedDocument
    case pdfHasNoTextLayer

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let extensionName):
            return "Audio Monster does not support .\(extensionName) files yet."
        case .fileTooLarge:
            return "That document is too large to read safely."
        case .unreadableText:
            return "The document’s text could not be decoded."
        case .emptyText:
            return "The document does not contain readable text."
        case .malformedDocument:
            return "The document could not be opened."
        case .pdfHasNoTextLayer:
            return "This PDF has no selectable text. Scanned-document OCR is not supported yet."
        }
    }
}

struct DocumentFileParserRegistry: Sendable {
    private let parsers: [any DocumentFileParsing]

    init(
        parsers: [any DocumentFileParsing] = [
            PlainTextDocumentParser(),
            MarkdownDocumentParser(),
            RichTextDocumentParser(),
            PDFDocumentParser(),
        ]
    ) {
        self.parsers = parsers
    }

    func parse(fileURL: URL, displayName: String) async throws -> ReadableDocument {
        let extensionName = fileURL.pathExtension.lowercased()
        guard let parser = parsers.first(where: { $0.supportedExtensions.contains(extensionName) })
        else {
            throw DocumentFileParsingError.unsupportedFormat(extensionName.isEmpty ? "unknown" : extensionName)
        }
        return try await parser.parse(fileURL: fileURL, displayName: displayName)
    }
}

struct PlainTextDocumentParser: DocumentFileParsing {
    let supportedExtensions: Set<String> = ["txt", "text"]

    func parse(fileURL: URL, displayName: String) async throws -> ReadableDocument {
        let text = try await DocumentTextReading.read(fileURL: fileURL)
        return try DocumentTextReading.document(
            text: text,
            origin: .file(displayName: displayName, fileType: fileURL.pathExtension.lowercased()),
            title: DocumentTextReading.title(from: displayName)
        )
    }
}

struct MarkdownDocumentParser: DocumentFileParsing {
    let supportedExtensions: Set<String> = ["md", "markdown", "mdown", "mkdn"]

    func parse(fileURL: URL, displayName: String) async throws -> ReadableDocument {
        let source = try await DocumentTextReading.read(fileURL: fileURL)
        let text = MarkdownTextProjector.project(source)
        return try DocumentTextReading.document(
            text: text,
            origin: .file(displayName: displayName, fileType: fileURL.pathExtension.lowercased()),
            title: DocumentTextReading.title(from: displayName)
        )
    }
}

struct RichTextDocumentParser: DocumentFileParsing {
    let supportedExtensions: Set<String> = ["rtf", "rtfd"]

    func parse(fileURL: URL, displayName: String) async throws -> ReadableDocument {
        try DocumentTextReading.validateSize(of: fileURL)
        let attributedText: NSAttributedString
        do {
            attributedText = try NSAttributedString(
                url: fileURL,
                options: [:],
                documentAttributes: nil
            )
        } catch {
            throw DocumentFileParsingError.malformedDocument
        }
        guard attributedText.length <= DocumentTextReading.maximumCharacters else {
            throw DocumentFileParsingError.fileTooLarge
        }
        return try DocumentTextReading.document(
            text: attributedText.string,
            origin: .file(displayName: displayName, fileType: fileURL.pathExtension.lowercased()),
            title: DocumentTextReading.title(from: displayName)
        )
    }
}

struct PDFDocumentParser: DocumentFileParsing {
    let supportedExtensions: Set<String> = ["pdf"]

    func parse(fileURL: URL, displayName: String) async throws -> ReadableDocument {
        try DocumentTextReading.validateSize(of: fileURL)
        guard let pdf = PDFDocument(url: fileURL) else {
            throw DocumentFileParsingError.malformedDocument
        }

        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pdf.pageCount)
        var extractedCharacterCount = 0
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            if let pageText = pdf.page(at: index)?.string {
                extractedCharacterCount += pageText.utf16.count
                guard extractedCharacterCount <= DocumentTextReading.maximumCharacters else {
                    throw DocumentFileParsingError.fileTooLarge
                }
                pageTexts.append(pageText)
            }
        }
        let text = pageTexts.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentFileParsingError.pdfHasNoTextLayer
        }
        return try DocumentTextReading.document(
            text: text,
            origin: .file(displayName: displayName, fileType: "pdf"),
            title: DocumentTextReading.title(from: displayName)
        )
    }
}

private enum DocumentTextReading {
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumCharacters = 5 * 1024 * 1024

    static func read(fileURL: URL) async throws -> String {
        try Task.checkCancellation()
        let data: Data
        do {
            try validateSize(of: fileURL)
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as DocumentFileParsingError {
            throw error
        } catch {
            throw DocumentFileParsingError.malformedDocument
        }
        guard data.count <= maximumBytes else {
            throw DocumentFileParsingError.fileTooLarge
        }

        let text =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
        guard let text else { throw DocumentFileParsingError.unreadableText }
        guard text.utf16.count <= maximumCharacters else {
            throw DocumentFileParsingError.fileTooLarge
        }
        return text
    }

    static func validateSize(of fileURL: URL) throws {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        } catch {
            throw DocumentFileParsingError.malformedDocument
        }
        if values.isDirectory == true {
            var totalBytes = 0
            guard
                let enumerator = FileManager.default.enumerator(
                    at: fileURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                throw DocumentFileParsingError.malformedDocument
            }
            for case let childURL as URL in enumerator {
                try Task.checkCancellation()
                let childValues = try childURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                if childValues.isSymbolicLink == true {
                    throw DocumentFileParsingError.malformedDocument
                }
                if childValues.isDirectory != true {
                    totalBytes += childValues.fileSize ?? 0
                    if totalBytes > maximumBytes {
                        throw DocumentFileParsingError.fileTooLarge
                    }
                }
            }
            return
        }
        guard let fileSize = values.fileSize, fileSize <= maximumBytes else {
            throw DocumentFileParsingError.fileTooLarge
        }
    }

    static func document(
        text: String,
        origin: ReadableDocumentOrigin,
        title: String
    ) throws -> ReadableDocument {
        let normalized =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw DocumentFileParsingError.emptyText }
        guard normalized.utf16.count <= maximumCharacters else {
            throw DocumentFileParsingError.fileTooLarge
        }
        return ReadableDocument(origin: origin, title: title, text: normalized)
    }

    static func title(from displayName: String) -> String {
        let title = URL(fileURLWithPath: displayName)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled document" : title
    }
}

private enum MarkdownTextProjector {
    static func project(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { projectLine(String($0)) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
    }

    private static func projectLine(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") || line.hasPrefix("~~~") {
            return ""
        }
        line = line.replacingOccurrences(
            of: "^#{1,6}\\s+",
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: "^(?:[-+*]|\\d+[.)])\\s+",
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: "^>\\s?",
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: "!\\[([^]]*)\\]\\([^)]*\\)",
            with: "$1",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: "\\[([^]]+)\\]\\([^)]*\\)",
            with: "$1",
            options: .regularExpression
        )
        line = line.replacingOccurrences(of: "`", with: "")
        line = line.replacingOccurrences(of: "**", with: "")
        line = line.replacingOccurrences(of: "__", with: "")
        return line
    }
}
