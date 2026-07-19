import Foundation

enum SaveLocationKind: Equatable, Sendable {
    case iCloudDrive
    case localFallback
    case custom

    var label: String {
        switch self {
        case .iCloudDrive: "iCloud Drive"
        case .localFallback: "On This Mac (iCloud unavailable)"
        case .custom: "Custom folder"
        }
    }
}

enum AppSettingsError: LocalizedError, Equatable {
    case saveDestinationLocked

    var errorDescription: String? {
        switch self {
        case .saveDestinationLocked:
            "The save location can’t be changed while an audio file is being saved."
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    struct SaveDestinationReservation: Sendable {
        fileprivate let id: UUID
        let folderURL: URL
        let locationKind: SaveLocationKind
    }

    private enum Key {
        static let voiceID = "voiceID"
        static let playbackRate = "playbackRate"
        static let legacySynthesisSpeed = "speed"
        static let autoPlay = "autoPlay"
        static let folderBookmark = "folderBookmark"
    }

    nonisolated static let playbackRateRange = 0.2...3.0

    private let defaults: UserDefaults
    private let ubiquityContainerProvider: @Sendable () -> URL?
    private let localFallbackFolderProvider: () -> URL
    private var hasCustomSaveFolder: Bool
    private var saveLocationResolutionGeneration = 0
    private var activeSaveDestinationReservationID: UUID?
    private var hasPendingRecommendedResolution = false
    private var hasPendingRecommendedReset = false

    @Published var voiceID: String {
        didSet { defaults.set(voiceID, forKey: Key.voiceID) }
    }

    @Published var playbackRate: Double {
        didSet {
            let normalized = Self.normalizedPlaybackRate(playbackRate)
            guard normalized == playbackRate else {
                playbackRate = normalized
                return
            }
            defaults.set(playbackRate, forKey: Key.playbackRate)
        }
    }

    @Published var autoPlay: Bool {
        didSet { defaults.set(autoPlay, forKey: Key.autoPlay) }
    }

    @Published private(set) var saveFolderURL: URL
    @Published private(set) var saveLocationKind: SaveLocationKind

    init(
        defaults: UserDefaults = .standard,
        ubiquityContainerProvider: @escaping @Sendable () -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        },
        localFallbackFolderProvider: @escaping () -> URL = {
            ApplicationDirectories.localAudioLibrary()
        }
    ) {
        self.defaults = defaults
        self.ubiquityContainerProvider = ubiquityContainerProvider
        self.localFallbackFolderProvider = localFallbackFolderProvider
        voiceID = defaults.string(forKey: Key.voiceID) ?? "af_heart"

        let storedPlaybackRate = defaults.object(forKey: Key.playbackRate) as? NSNumber
        let legacySynthesisSpeed = defaults.object(forKey: Key.legacySynthesisSpeed) as? NSNumber
        playbackRate = Self.normalizedPlaybackRate(
            storedPlaybackRate?.doubleValue ?? legacySynthesisSpeed?.doubleValue ?? 1.0
        )
        autoPlay = defaults.object(forKey: Key.autoPlay) as? Bool ?? true
        if let restoredFolder = Self.restoreFolder(from: defaults) {
            saveFolderURL = restoredFolder
            saveLocationKind = .custom
            hasCustomSaveFolder = true
        } else {
            saveFolderURL = localFallbackFolderProvider()
            saveLocationKind = .localFallback
            hasCustomSaveFolder = false
        }
        defaults.set(playbackRate, forKey: Key.playbackRate)
    }

    nonisolated static func normalizedPlaybackRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, playbackRateRange.lowerBound), playbackRateRange.upperBound)
    }

    func setSaveFolder(_ url: URL) throws {
        guard activeSaveDestinationReservationID == nil else {
            throw AppSettingsError.saveDestinationLocked
        }
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        // Resolve the bookmark immediately instead of retaining the transient
        // URL supplied by NSOpenPanel. This gives the current session the same
        // durable security-scoped URL that a later launch would restore and
        // prevents access from disappearing after the picker grant is released.
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let storedBookmark: Data
        if isStale {
            storedBookmark = try resolvedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            storedBookmark = bookmark
        }
        defaults.set(storedBookmark, forKey: Key.folderBookmark)
        saveLocationResolutionGeneration &+= 1
        saveFolderURL = resolvedURL
        saveLocationKind = .custom
        hasCustomSaveFolder = true
    }

    func reserveSaveDestination() throws -> SaveDestinationReservation {
        guard activeSaveDestinationReservationID == nil else {
            throw AppSettingsError.saveDestinationLocked
        }
        let reservation = SaveDestinationReservation(
            id: UUID(),
            folderURL: saveFolderURL,
            locationKind: saveLocationKind
        )
        activeSaveDestinationReservationID = reservation.id
        return reservation
    }

    /// Releases a persistence snapshot and applies any iCloud identity change
    /// that arrived while the snapshot was in use. Returns whether the active
    /// library folder changed and therefore needs to be scanned again.
    func releaseSaveDestination(_ reservation: SaveDestinationReservation) async -> Bool {
        guard activeSaveDestinationReservationID == reservation.id else { return false }

        activeSaveDestinationReservationID = nil
        let previousFolder = saveFolderURL
        let previousLocationKind = saveLocationKind
        if hasPendingRecommendedReset {
            hasPendingRecommendedReset = false
            hasPendingRecommendedResolution = false
            await resetToRecommendedSaveFolder()
        } else if hasPendingRecommendedResolution {
            hasPendingRecommendedResolution = false
            await resolveRecommendedSaveFolder()
        }
        return saveFolderURL != previousFolder || saveLocationKind != previousLocationKind
    }

    func resolveRecommendedSaveFolder() async {
        guard activeSaveDestinationReservationID == nil else {
            hasPendingRecommendedResolution = true
            return
        }
        guard !hasCustomSaveFolder else { return }
        saveLocationResolutionGeneration &+= 1
        let generation = saveLocationResolutionGeneration

        // Apple warns that establishing access to a ubiquity container may take
        // nontrivial time, so never perform this lookup on the main thread.
        let provider = ubiquityContainerProvider
        let containerURL = await Task.detached(priority: .utility) {
            provider()
        }.value

        // A folder selected while iCloud resolution was suspended always wins.
        guard activeSaveDestinationReservationID == nil else {
            hasPendingRecommendedResolution = true
            return
        }
        guard !hasCustomSaveFolder,
            generation == saveLocationResolutionGeneration
        else { return }

        guard let containerURL else {
            saveFolderURL = localFallbackFolderProvider()
            saveLocationKind = .localFallback
            return
        }

        saveFolderURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
        saveLocationKind = .iCloudDrive
    }

    func resetToRecommendedSaveFolder() async {
        guard activeSaveDestinationReservationID == nil else {
            hasPendingRecommendedReset = true
            return
        }
        defaults.removeObject(forKey: Key.folderBookmark)
        saveLocationResolutionGeneration &+= 1
        hasCustomSaveFolder = false
        saveFolderURL = localFallbackFolderProvider()
        saveLocationKind = .localFallback
        await resolveRecommendedSaveFolder()
    }

    private static func restoreFolder(from defaults: UserDefaults) -> URL? {
        guard let data = defaults.data(forKey: Key.folderBookmark) else {
            return nil
        }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        else {
            return nil
        }
        if isStale,
            let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        {
            defaults.set(refreshed, forKey: Key.folderBookmark)
        }
        return url
    }

}
