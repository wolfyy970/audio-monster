import Foundation
import Testing

@testable import AudioMonster

struct DocumentFileParserTests {
    @Test
    func readsPlainTextAndUsesTheFilenameAsTitle() async throws {
        let fileURL = try temporaryFile(named: "Notes.txt", contents: "  First line\r\nSecond line  ")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let document = try await DocumentFileParserRegistry().parse(
            fileURL: fileURL,
            displayName: fileURL.lastPathComponent
        )

        #expect(
            document.origin
                == .file(displayName: fileURL.lastPathComponent, fileType: "txt")
        )
        #expect(document.title == fileURL.deletingPathExtension().lastPathComponent)
        #expect(document.text == "First line\nSecond line")
    }

    @Test
    func projectsCommonMarkdownSyntaxIntoReadableText() async throws {
        let markdown = """
        # A heading

        - First item
        - [Second item](https://example.com)

        > A quotation
        """
        let fileURL = try temporaryFile(named: "Guide.md", contents: markdown)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let document = try await DocumentFileParserRegistry().parse(
            fileURL: fileURL,
            displayName: fileURL.lastPathComponent
        )

        #expect(document.title == fileURL.deletingPathExtension().lastPathComponent)
        #expect(document.text == "A heading\n\nFirst item\nSecond item\n\nA quotation")
    }

    @Test
    func readsRichTextWithoutExposingMarkup() async throws {
        let rtf = #"{\rtf1\ansi This is readable text.}"#
        let fileURL = try temporaryFile(named: "Letter.rtf", contents: rtf)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let document = try await DocumentFileParserRegistry().parse(
            fileURL: fileURL,
            displayName: fileURL.lastPathComponent
        )

        #expect(document.title == fileURL.deletingPathExtension().lastPathComponent)
        #expect(document.text == "This is readable text.")
    }

    @Test
    func rejectsUnsupportedExtensionsAtTheRegistryBoundary() async throws {
        let fileURL = try temporaryFile(named: "Archive.doc", contents: "not a doc")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try await DocumentFileParserRegistry().parse(
                fileURL: fileURL,
                displayName: fileURL.lastPathComponent
            )
            Issue.record("Legacy DOC should remain unsupported until a safe importer exists.")
        } catch DocumentFileParsingError.unsupportedFormat("doc") {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func rejectsAnOversizedSparseFileBeforeReadingItsContents() async throws {
        let fileURL = try temporaryFile(named: "Too-large.txt", contents: "")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(10 * 1024 * 1024 + 1))
        try handle.close()

        do {
            _ = try await DocumentFileParserRegistry().parse(
                fileURL: fileURL,
                displayName: fileURL.lastPathComponent
            )
            Issue.record("Files over the input limit must be rejected before reading.")
        } catch DocumentFileParsingError.fileTooLarge {
            // Expected. The sparse file proves the guard uses metadata before allocating.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func rejectsWhitespaceOnlyTextAsEmpty() async throws {
        let fileURL = try temporaryFile(named: "Blank.txt", contents: " \n\t\r\n ")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try await DocumentFileParserRegistry().parse(
                fileURL: fileURL,
                displayName: fileURL.lastPathComponent
            )
            Issue.record("Whitespace-only documents must not become narration jobs.")
        } catch DocumentFileParsingError.emptyText {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func temporaryFile(named name: String, contents: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
