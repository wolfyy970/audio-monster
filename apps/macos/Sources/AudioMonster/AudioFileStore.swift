import AudioMonsterCore
import Darwin
import Foundation

enum AudioFileStore {
    static func persist(
        from downloadedURL: URL,
        in folder: URL,
        requestedName: String,
        sourceURL: URL,
        locationKind: SaveLocationKind
    ) throws -> URL {
        let safeName = safeFilename(requestedName)
        let safeSourceURL = ArticleURL(sourceURL.absoluteString)?.value
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMonster-\(UUID().uuidString)", isDirectory: true)
        let stagingURL = stagingDirectory.appendingPathComponent(safeName)

        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        try FileManager.default.copyItem(at: downloadedURL, to: stagingURL)
        // The native encoder embeds the URL in the audio container. This extended
        // attribute also exposes it as Finder's “Where from” value on macOS.
        if let safeSourceURL {
            try? setWhereFrom(safeSourceURL, on: stagingURL)
        }

        switch locationKind {
        case .iCloudDrive:
            return try moveIntoICloud(stagingURL, folder: folder, filename: safeName)
        case .localFallback:
            return try copyLocally(
                stagingURL,
                folder: folder,
                filename: safeName,
                sourceURL: safeSourceURL
            )
        case .custom:
            return try copyWithCoordination(
                stagingURL,
                folder: folder,
                filename: safeName,
                sourceURL: safeSourceURL
            )
        }
    }

    private static func copyLocally(
        _ stagingURL: URL,
        folder: URL,
        filename: String,
        sourceURL: URL?
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // Application Support is private app-owned storage. Apple explicitly
        // excludes it from the file-coordination requirement, so a normal copy
        // avoids manufacturing document-provider access for a private file.
        for attempt in 1...10_000 {
            let candidate = destination(in: folder, filename: filename, attempt: attempt)
            do {
                try fileManager.copyItem(at: stagingURL, to: candidate)
                if let sourceURL {
                    try? setWhereFrom(sourceURL, on: candidate)
                }
                return candidate
            } catch {
                if isFileExists(error) { continue }
                throw error
            }
        }

        throw CocoaError(.fileWriteFileExists)
    }

    private static func moveIntoICloud(
        _ stagingURL: URL,
        folder: URL,
        filename: String
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        for attempt in 1...10_000 {
            let destination = destination(in: folder, filename: filename, attempt: attempt)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }

            do {
                // Apple performs the necessary coordinated move internally.
                // This method must be invoked from the background executor used
                // by AppModel; wrapping it in NSFileCoordinator can deadlock.
                try fileManager.setUbiquitous(
                    true,
                    itemAt: stagingURL,
                    destinationURL: destination
                )
                return destination
            } catch {
                // Another device or presenter may have claimed the filename
                // after our check. The local staging file remains retryable.
                if fileManager.fileExists(atPath: destination.path),
                    fileManager.fileExists(atPath: stagingURL.path)
                {
                    continue
                }
                // A successful move followed by a late reporting error should
                // not cause us to duplicate the item under another name.
                if fileManager.fileExists(atPath: destination.path),
                    !fileManager.fileExists(atPath: stagingURL.path)
                {
                    return destination
                }
                throw error
            }
        }

        throw CocoaError(.fileWriteFileExists)
    }

    private static func copyWithCoordination(
        _ stagingURL: URL,
        folder: URL,
        filename: String,
        sourceURL: URL?
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        for attempt in 1...10_000 {
            let candidate = destination(in: folder, filename: filename, attempt: attempt)
            guard !fileManager.fileExists(atPath: candidate.path) else { continue }

            var coordinationError: NSError?
            var operationError: Error?
            var finalURL: URL?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                writingItemAt: candidate,
                options: .forReplacing,
                error: &coordinationError
            ) { coordinatedDestination in
                guard !fileManager.fileExists(atPath: coordinatedDestination.path) else {
                    operationError = CocoaError(.fileWriteFileExists)
                    return
                }
                do {
                    try fileManager.copyItem(at: stagingURL, to: coordinatedDestination)
                    if let sourceURL {
                        try? setWhereFrom(sourceURL, on: coordinatedDestination)
                    }
                    // The coordinator-provided URL is valid for the lifetime of
                    // this accessor. Keep the caller-owned destination URL as
                    // the durable reference returned after coordination ends.
                    finalURL = candidate
                } catch {
                    operationError = error
                    if !isFileExists(error) {
                        try? fileManager.removeItem(at: coordinatedDestination)
                    }
                }
            }

            if let coordinationError { throw coordinationError }
            if let operationError {
                if isFileExists(operationError) { continue }
                throw operationError
            }
            if let finalURL { return finalURL }
        }

        throw CocoaError(.fileWriteFileExists)
    }

    private static func isFileExists(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.fileWriteFileExists.rawValue
    }

    private static func setWhereFrom(_ sourceURL: URL, on fileURL: URL) throws {
        let propertyList = try PropertyListSerialization.data(
            fromPropertyList: [sourceURL.absoluteString],
            format: .binary,
            options: 0
        )
        let result: Int32 = fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return "com.apple.metadata:kMDItemWhereFroms".withCString { attributeName in
                propertyList.withUnsafeBytes { bytes in
                    setxattr(
                        path,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        0
                    )
                }
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func safeFilename(_ filename: String) -> String {
        var name = URL(fileURLWithPath: filename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            name = "Audio Monster.m4a"
        }
        if URL(fileURLWithPath: name).pathExtension.isEmpty {
            name += ".m4a"
        }
        return name
    }

    private static func destination(in folder: URL, filename: String, attempt: Int) -> URL {
        let original = folder.appendingPathComponent(filename)
        guard attempt > 1 else { return original }

        let extensionName = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        let suffix = extensionName.isEmpty ? "" : ".\(extensionName)"
        return folder.appendingPathComponent("\(stem) (\(attempt))\(suffix)")
    }
}
