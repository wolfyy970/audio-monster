import Foundation

enum ApplicationDirectories {
    static func applicationSupport(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
    }

    static func localAudioLibrary(fileManager: FileManager = .default) -> URL {
        applicationSupport(fileManager: fileManager)
            .appendingPathComponent("Audio Monster", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    static func voicePreviewCache(fileManager: FileManager = .default) -> URL {
        applicationSupport(fileManager: fileManager)
            .appendingPathComponent("Audio Monster", isDirectory: true)
            .appendingPathComponent("Voice Previews", isDirectory: true)
            .appendingPathComponent(FileVoicePreviewCache.version, isDirectory: true)
    }
}
