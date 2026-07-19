import AppKit
import AudioMonsterCore
@preconcurrency import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum EngineState: Equatable {
        case preparing
        case ready
        case unavailable
    }

    @Published var inputURL = ""
    @Published private(set) var engineState: EngineState = .preparing
    @Published private(set) var voices: [Voice] = KokoroVoiceCatalog.voices
    @Published private(set) var currentJob: ConversionJob?
    @Published private(set) var savedFileURL: URL?
    @Published private(set) var isSavingFile = false
    @Published private(set) var isRenderingWebPage = false
    @Published var playbackRate: Double {
        didSet {
            let normalized = AppSettings.normalizedPlaybackRate(playbackRate)
            guard normalized == playbackRate else {
                playbackRate = normalized
                return
            }
            if settings.playbackRate != playbackRate { settings.playbackRate = playbackRate }
            playbackCoordinator.setPlaybackRate(playbackRate)
        }
    }
    @Published private(set) var libraryItems: [AudioLibraryItem] = []
    @Published private(set) var libraryErrorMessage: String?
    @Published var errorMessage: String?

    let settings: AppSettings

    private let conversionEngine: any AudioConversionEngine
    private let articleExtractor: any ArticleExtracting
    private let filePersister: any AudioFilePersisting
    private let libraryScanner: any AudioLibraryScanning
    private let playbackCoordinator: PlaybackCoordinator
    private let voicePreviewCoordinator: VoicePreviewCoordinator
    private var didStart = false
    private var conversionTask: Task<Void, Never>?
    private var iCloudIdentityTask: Task<Void, Never>?
    private var libraryRefreshGeneration = 0
    private var libraryItemsFolderURL: URL?
    private var activeWorkspaceURL: URL?
    private var playbackObservation: AnyCancellable?
    private var saveFolderObservation: AnyCancellable?
    private var voicePreviewObservation: AnyCancellable?

    init(
        settings: AppSettings,
        conversionEngine: any AudioConversionEngine = NativeKokoroAudioEngine.shared,
        articleExtractor: any ArticleExtracting = NativeArticleExtractor.shared,
        filePersister: any AudioFilePersisting = NativeAudioFilePersister(),
        libraryScanner: any AudioLibraryScanning = NativeAudioLibraryScanner(),
        playbackCoordinator: PlaybackCoordinator? = nil,
        voicePreviewDirectory: URL? = nil,
        voicePreviewCoordinator: VoicePreviewCoordinator? = nil
    ) {
        self.settings = settings
        self.conversionEngine = conversionEngine
        self.articleExtractor = articleExtractor
        self.filePersister = filePersister
        self.libraryScanner = libraryScanner
        let resolvedPlaybackCoordinator =
            playbackCoordinator
            ?? PlaybackCoordinator(
                playbackRate: settings.playbackRate
            )
        self.playbackCoordinator = resolvedPlaybackCoordinator
        self.voicePreviewCoordinator =
            voicePreviewCoordinator
            ?? VoicePreviewCoordinator(
                voiceIDs: KokoroVoiceCatalog.voiceIDs,
                generator: conversionEngine,
                cache: FileVoicePreviewCache(
                    directory: voicePreviewDirectory ?? ApplicationDirectories.voicePreviewCache()
                ),
                playback: resolvedPlaybackCoordinator
            )
        playbackRate = settings.playbackRate
        normalizeSelectedVoice()
        playbackObservation = self.playbackCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        saveFolderObservation = settings.$saveFolderURL
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.invalidateLibrarySnapshot()
            }
        voicePreviewObservation = self.voicePreviewCoordinator.objectWillChange.sink {
            [weak self] _ in self?.objectWillChange.send()
        }
        iCloudIdentityTask = Task { @MainActor [weak self, weak settings] in
            for await _ in NotificationCenter.default.notifications(
                named: .NSUbiquityIdentityDidChange
            ) {
                guard !Task.isCancelled else { return }
                await settings?.resolveRecommendedSaveFolder()
                await self?.refreshLibrary()
            }
        }
    }

    deinit {
        conversionTask?.cancel()
        iCloudIdentityTask?.cancel()
    }

    var menuBarSymbol: String {
        if currentJob?.status == .synthesizing { return "waveform.badge.magnifyingglass" }
        return switch engineState {
        case .preparing: "waveform"
        case .ready: "waveform.circle.fill"
        case .unavailable: "waveform.slash"
        }
    }

    var isWorking: Bool {
        isSavingFile || isRenderingWebPage || (currentJob.map { !$0.status.isTerminal } ?? false)
    }

    var isPlaying: Bool { playbackCoordinator.isArticlePlaying }

    var activeLibraryItemID: URL? { playbackCoordinator.activeLibraryItemID }

    var isLibraryPlaying: Bool { playbackCoordinator.isLibraryPlaying }

    var libraryElapsedSeconds: Double { playbackCoordinator.libraryElapsedSeconds }

    var libraryDurationSeconds: Double { playbackCoordinator.libraryDurationSeconds }

    var playingPreviewVoiceID: String? { playbackCoordinator.playingPreviewVoiceID }

    var voicePreviews: [String: VoicePreview] { voicePreviewCoordinator.previews }

    var voicePreviewsReady: Int { voicePreviewCoordinator.readyCount }

    var voicePreviewsTotal: Int { voicePreviewCoordinator.totalCount }

    var voicePreviewErrorMessage: String? { voicePreviewCoordinator.errorMessage }

    var activeLibraryItem: AudioLibraryItem? {
        libraryItems.first { $0.id == activeLibraryItemID }
    }

    var libraryPlaybackProgress: Double {
        playbackCoordinator.libraryPlaybackProgress
    }

    var hasPreviousLibraryItem: Bool {
        guard let activeLibraryItemID,
            let index = libraryItems.firstIndex(where: { $0.id == activeLibraryItemID })
        else { return false }
        return index > 0
    }

    var hasNextLibraryItem: Bool {
        guard let activeLibraryItemID,
            let index = libraryItems.firstIndex(where: { $0.id == activeLibraryItemID })
        else { return false }
        return index + 1 < libraryItems.count
    }

    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        async let resolveStorage: Void = settings.resolveRecommendedSaveFolder()
        async let prepareEngine: Void = refreshEngine()
        _ = await (resolveStorage, prepareEngine)
        await refreshLibrary()
    }

    func refreshEngine() async {
        voicePreviewCoordinator.suspendPreparation(clearAutoplay: false)
        engineState = .preparing
        do {
            try await conversionEngine.prepare()
            engineState = .ready
            normalizeSelectedVoice()
            if !isWorking {
                voicePreviewCoordinator.prepareAll()
                voicePreviewCoordinator.resumePreparation()
            }
        } catch {
            engineState = .unavailable
        }
    }

    func submit() {
        errorMessage = nil
        savedFileURL = nil
        guard let articleURL = ArticleURL(inputURL) else {
            errorMessage = "Enter a complete http:// or https:// URL."
            return
        }
        let url = articleURL.value
        guard !isWorking else {
            errorMessage = "Finish or cancel the current conversion first."
            return
        }

        voicePreviewCoordinator.suspendPreparation(clearAutoplay: true)
        playbackCoordinator.resetArticlePlayback()
        cleanPreviousWorkspace()
        let jobID = UUID()
        currentJob = ConversionJob(
            id: jobID,
            url: url,
            status: .extracting,
            title: url.host(),
            recommendedFilename: nil,
            progress: 0.02,
            message: "Reading the page in WebKit",
            audioURL: nil,
            segments: []
        )
        inputURL = ""
        isRenderingWebPage = true

        conversionTask?.cancel()
        conversionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isRenderingWebPage = false
                if currentJob?.status.isTerminal == true, engineState == .ready {
                    voicePreviewCoordinator.prepareAll()
                    voicePreviewCoordinator.resumePreparation()
                }
            }
            do {
                let article = try await articleExtractor.extract(url: url)
                try Task.checkCancellation()
                isRenderingWebPage = false
                updateCurrentJob(id: jobID) { job in
                    job.title = article.title
                    job.status = .synthesizing
                    job.progress = 0.08
                    job.message = "Preparing article sections"
                }
                let workspace = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AudioMonster-\(jobID)", isDirectory: true)
                activeWorkspaceURL = workspace
                let result = try await conversionEngine.convert(
                    article: article,
                    voiceID: settings.voiceID,
                    workspaceURL: workspace
                ) { [weak self] event in
                    await self?.apply(event: event, jobID: jobID)
                }
                try Task.checkCancellation()
                updateCurrentJob(id: jobID) { job in
                    job.status = .completed
                    job.progress = 1
                    job.message = "Audio is ready"
                    job.audioURL = result.audioURL
                    job.recommendedFilename = result.recommendedFilename
                }
                do {
                    try await finishCompletedJob(allowAutoPlay: true)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    errorMessage = error.localizedDescription
                }
            } catch is CancellationError {
                markJobCancelled(id: jobID)
            } catch {
                if Task.isCancelled {
                    markJobCancelled(id: jobID)
                } else {
                    playbackCoordinator.resetArticlePlayback()
                    updateCurrentJob(id: jobID) { job in
                        job.status = .failed
                        job.message = error.localizedDescription
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelCurrentJob() {
        guard isWorking else { return }
        playbackCoordinator.resetArticlePlayback()
        conversionTask?.cancel()
    }

    func togglePlayback() {
        playbackCoordinator.toggleArticle(
            fallbackURL: savedFileURL ?? currentJob?.audioURL
        )
    }

    func revealSavedFile() {
        guard let savedFileURL else { return }
        let folder = settings.saveFolderURL
        let didAccess =
            settings.saveLocationKind == .custom
            && folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([savedFileURL])
    }

    func retrySavingCompletedJob() {
        guard currentJob?.status == .completed, !isSavingFile else { return }
        // Reserve the save before creating the task so two UI actions in the same
        // main-actor turn cannot both enter persistence.
        let reservation: AppSettings.SaveDestinationReservation
        do {
            reservation = try settings.reserveSaveDestination()
            isSavingFile = true
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await finishCompletedJob(
                    allowAutoPlay: false,
                    destinationReservation: reservation
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshLibrary() async {
        let folder = settings.saveFolderURL
        let locationKind = settings.saveLocationKind
        if libraryItemsFolderURL != nil, libraryItemsFolderURL != folder {
            invalidateLibrarySnapshot()
        }
        libraryRefreshGeneration &+= 1
        let generation = libraryRefreshGeneration
        let didAccess =
            locationKind == .custom
            && folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
        do {
            let items = try await libraryScanner.scan(folderURL: folder)
            guard !Task.isCancelled,
                generation == libraryRefreshGeneration,
                folder == settings.saveFolderURL,
                locationKind == settings.saveLocationKind
            else { return }
            libraryItems = items
            libraryItemsFolderURL = folder
            libraryErrorMessage = nil
            if let activeLibraryItemID,
                !items.contains(where: { $0.id == activeLibraryItemID })
            {
                playbackCoordinator.stopLibraryPlayback(clearSelection: true)
            }
        } catch {
            guard !Task.isCancelled,
                generation == libraryRefreshGeneration,
                folder == settings.saveFolderURL,
                locationKind == settings.saveLocationKind
            else { return }
            libraryErrorMessage = "Couldn’t read the audio folder: \(error.localizedDescription)"
        }
    }

    func toggleLibraryPlayback(_ item: AudioLibraryItem) {
        guard librarySnapshotContains(item), let libraryItemsFolderURL else { return }
        playbackCoordinator.toggleLibrary(
            item: item,
            scopedFolder: settings.saveLocationKind == .custom ? libraryItemsFolderURL : nil
        ) { [weak self] in
            self?.playNextLibraryItem()
        }
    }

    func toggleActiveLibraryPlayback() {
        if let activeLibraryItem {
            toggleLibraryPlayback(activeLibraryItem)
        } else if let first = libraryItems.first {
            playLibraryItem(first)
        }
    }

    func playPreviousLibraryItem() {
        guard let activeLibraryItemID,
            let index = libraryItems.firstIndex(where: { $0.id == activeLibraryItemID }),
            index > 0
        else { return }
        playLibraryItem(libraryItems[index - 1])
    }

    func playNextLibraryItem() {
        guard let activeLibraryItemID,
            let index = libraryItems.firstIndex(where: { $0.id == activeLibraryItemID }),
            index + 1 < libraryItems.count
        else {
            playbackCoordinator.stopLibraryPlayback(clearSelection: false)
            return
        }
        playLibraryItem(libraryItems[index + 1])
    }

    func seekLibrary(to progress: Double) {
        playbackCoordinator.seekLibrary(to: progress)
    }

    func revealLibraryItem(_ item: AudioLibraryItem) {
        guard librarySnapshotContains(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func refreshVoicePreviews() async {
        voicePreviewCoordinator.reloadCache()
        if engineState == .ready, !isWorking {
            voicePreviewCoordinator.prepareAll()
            voicePreviewCoordinator.resumePreparation()
        }
    }

    func toggleVoicePreview(voiceID: String) {
        voicePreviewCoordinator.togglePlayback(voiceID: voiceID)
    }

    func startVoicePreview(voiceID: String) {
        voicePreviewCoordinator.requestPlayback(voiceID: voiceID)
    }

    private func apply(event: SynthesisEvent, jobID: UUID) {
        guard let job = currentJob, job.id == jobID, !job.status.isTerminal else { return }
        updateCurrentJob(id: jobID) { job in
            switch event {
            case .started(let sectionCount):
                let safeSectionCount = max(sectionCount, 0)
                job.status = .synthesizing
                job.progress = Self.synthesisProgress(current: job.progress, candidate: 0.1)
                job.message = "Creating audio (0/\(safeSectionCount) sections)"
            case .segment(let segment, let completed, let total):
                let safeTotal = max(total, 1)
                let safeCompleted = min(max(completed, 0), safeTotal)
                if !job.segments.contains(where: { $0.index == segment.index }) {
                    job.segments.append(segment)
                }
                let candidate = 0.1 + 0.84 * Double(safeCompleted) / Double(safeTotal)
                job.progress = Self.synthesisProgress(
                    current: job.progress,
                    candidate: candidate
                )
                job.message = "Creating audio (\(safeCompleted)/\(safeTotal) sections)"
                playbackCoordinator.enqueue(
                    segment: segment,
                    expectedCount: safeTotal,
                    autoPlay: settings.autoPlay
                )
            case .encoding:
                job.progress = Self.synthesisProgress(current: job.progress, candidate: 0.96)
                job.message = "Encoding high-quality audio"
            }
        }
    }

    private static func synthesisProgress(current: Double, candidate: Double) -> Double {
        let safeCurrent = current.isFinite ? min(max(current, 0), 0.96) : 0
        let safeCandidate = candidate.isFinite ? min(max(candidate, 0), 0.96) : safeCurrent
        return max(safeCurrent, safeCandidate)
    }

    private func updateCurrentJob(id: UUID, change: (inout ConversionJob) -> Void) {
        guard var job = currentJob, job.id == id else { return }
        change(&job)
        currentJob = job
    }

    private func markJobCancelled(id: UUID) {
        playbackCoordinator.resetArticlePlayback()
        updateCurrentJob(id: id) { job in
            job.status = .cancelled
            job.message = "Conversion cancelled"
        }
        errorMessage = nil
    }

    private func finishCompletedJob(
        allowAutoPlay: Bool,
        destinationReservation: AppSettings.SaveDestinationReservation? = nil
    ) async throws {
        guard let job = currentJob,
            job.status == .completed,
            let audioURL = job.audioURL
        else {
            if let destinationReservation {
                _ = await settings.releaseSaveDestination(destinationReservation)
                isSavingFile = false
            }
            throw AudioArtifactError.emptyAudio
        }

        let reservation: AppSettings.SaveDestinationReservation
        if let destinationReservation {
            reservation = destinationReservation
        } else {
            reservation = try settings.reserveSaveDestination()
            isSavingFile = true
        }

        do {
            if allowAutoPlay && settings.autoPlay && !playbackCoordinator.hasProgressiveQueue {
                playbackCoordinator.playArticle(url: audioURL)
            }
            let folder = reservation.folderURL
            let didAccess =
                reservation.locationKind == .custom
                && folder.startAccessingSecurityScopedResource()
            defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
            savedFileURL = try await filePersister.persist(
                AudioPersistenceRequest(
                    sourceFileURL: audioURL,
                    destinationFolderURL: folder,
                    requestedFilename: job.recommendedFilename ?? "Audio Monster.m4a",
                    sourceURL: job.url,
                    locationKind: reservation.locationKind
                ))
            await refreshLibrary()
        } catch {
            let folderChanged = await settings.releaseSaveDestination(reservation)
            isSavingFile = false
            if folderChanged { await refreshLibrary() }
            throw error
        }

        let folderChanged = await settings.releaseSaveDestination(reservation)
        isSavingFile = false
        if folderChanged { await refreshLibrary() }
    }

    private func playLibraryItem(_ item: AudioLibraryItem) {
        guard librarySnapshotContains(item), let libraryItemsFolderURL else { return }
        playbackCoordinator.playLibrary(
            item: item,
            scopedFolder: settings.saveLocationKind == .custom ? libraryItemsFolderURL : nil
        ) { [weak self] in
            self?.playNextLibraryItem()
        }
    }

    private func librarySnapshotContains(_ item: AudioLibraryItem) -> Bool {
        guard let libraryItemsFolderURL,
            libraryItemsFolderURL == settings.saveFolderURL
        else { return false }
        return libraryItems.contains { $0.id == item.id }
    }

    private func invalidateLibrarySnapshot() {
        libraryRefreshGeneration &+= 1
        libraryItemsFolderURL = nil
        libraryItems = []
        libraryErrorMessage = nil
        playbackCoordinator.stopLibraryPlayback(clearSelection: true)
    }

    private func normalizeSelectedVoice() {
        if !voices.contains(where: { $0.id == settings.voiceID }) {
            settings.voiceID = KokoroVoiceCatalog.defaultVoiceID
        }
    }

    private func cleanPreviousWorkspace() {
        guard let activeWorkspaceURL else { return }
        try? FileManager.default.removeItem(at: activeWorkspaceURL)
        self.activeWorkspaceURL = nil
    }
}
