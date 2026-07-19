import Foundation

struct AudioLibraryItem: Identifiable, Hashable, Sendable {
    let url: URL
    let modifiedAt: Date

    var id: URL { url }
    var filename: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

enum AudioLibrary {
    typealias ResourceValuesProvider = (URL, Set<URLResourceKey>) throws -> URLResourceValues

    static let supportedExtensions: Set<String> = [
        "aac", "flac", "m4a", "mp3", "ogg", "opus", "wav",
    ]

    static func scan(
        folderURL: URL,
        fileManager: FileManager = .default,
        resourceValuesProvider: ResourceValuesProvider = { url, keys in
            try url.resourceValues(forKeys: keys)
        }
    ) throws -> [AudioLibraryItem] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return []
        }

        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                return nil
            }
            guard let values = try? resourceValuesProvider(url, keys) else {
                return nil
            }
            guard values.isRegularFile == true else { return nil }
            return AudioLibraryItem(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { left, right in
            if left.modifiedAt != right.modifiedAt {
                return left.modifiedAt > right.modifiedAt
            }
            return left.filename.localizedStandardCompare(right.filename) == .orderedAscending
        }
    }
}
