import Foundation
import Testing

@testable import AudioMonster

struct AudioLibraryTests {
    @Test
    func scansSupportedFilesNewestFirstAndSkipsOtherEntries() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let oldest = folder.appendingPathComponent("First Article.mp3")
        let newest = folder.appendingPathComponent("Third Article.wav")
        let middle = folder.appendingPathComponent("Second Article.m4a")
        let ignored = folder.appendingPathComponent("notes.txt")
        for url in [oldest, newest, middle, ignored] {
            try Data([0, 1, 2]).write(to: url)
        }
        let now = Date()
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30)],
            ofItemAtPath: oldest.path
        )
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: newest.path)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10)],
            ofItemAtPath: middle.path
        )

        let items = try AudioLibrary.scan(folderURL: folder)

        #expect(
            items.map(\.filename) == [
                "Third Article.wav",
                "Second Article.m4a",
                "First Article.mp3",
            ])
    }

    @Test
    func skipsAFileWhoseResourceValuesCannotBeReadWithoutFailingTheScan() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let readable = folder.appendingPathComponent("Readable Article.m4a")
        let inaccessible = folder.appendingPathComponent("Inaccessible Article.mp3")
        try Data([0, 1, 2]).write(to: readable)
        try Data([3, 4, 5]).write(to: inaccessible)

        let items = try AudioLibrary.scan(
            folderURL: folder,
            fileManager: fileManager
        ) { url, keys in
            // Directory enumeration may canonicalize /var to /private/var.
            if url.lastPathComponent == inaccessible.lastPathComponent {
                throw CocoaError(.fileReadNoPermission)
            }
            return try url.resourceValues(forKeys: keys)
        }

        #expect(items.map(\.filename) == ["Readable Article.m4a"])
    }
}
