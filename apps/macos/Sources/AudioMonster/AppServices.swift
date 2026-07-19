import Foundation

struct AudioPersistenceRequest: Sendable {
    let sourceFileURL: URL
    let destinationFolderURL: URL
    let requestedFilename: String
    let sourceURL: URL
    let locationKind: SaveLocationKind
}

protocol AudioFilePersisting: Sendable {
    func persist(_ request: AudioPersistenceRequest) async throws -> URL
}

struct NativeAudioFilePersister: AudioFilePersisting {
    func persist(_ request: AudioPersistenceRequest) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try AudioFileStore.persist(
                from: request.sourceFileURL,
                in: request.destinationFolderURL,
                requestedName: request.requestedFilename,
                sourceURL: request.sourceURL,
                locationKind: request.locationKind
            )
        }.value
    }
}

protocol AudioLibraryScanning: Sendable {
    func scan(folderURL: URL) async throws -> [AudioLibraryItem]
}

struct NativeAudioLibraryScanner: AudioLibraryScanning {
    func scan(folderURL: URL) async throws -> [AudioLibraryItem] {
        try await Task.detached(priority: .utility) {
            try AudioLibrary.scan(folderURL: folderURL)
        }.value
    }
}
