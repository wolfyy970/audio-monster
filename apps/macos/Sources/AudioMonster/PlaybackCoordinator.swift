import Foundation

@MainActor
protocol PlaybackRatePlayer: AnyObject {
    var rate: Float { get set }
    var defaultRate: Float { get set }
    func playImmediately(atRate rate: Float)
}

@MainActor
enum PlaybackRateController {
    static func start(_ player: any PlaybackRatePlayer, at rate: Double) {
        let playerRate = Float(AppSettings.normalizedPlaybackRate(rate))
        player.defaultRate = playerRate
        player.playImmediately(atRate: playerRate)
    }

    static func update(
        _ player: any PlaybackRatePlayer,
        to rate: Double,
        whilePlaying: Bool
    ) {
        let playerRate = Float(AppSettings.normalizedPlaybackRate(rate))
        player.defaultRate = playerRate
        if whilePlaying { player.rate = playerRate }
    }
}

@MainActor
protocol PlaybackItemReference: AnyObject {
    var notificationObject: AnyObject { get }
}

@MainActor
protocol ManagedPlaybackPlayer: PlaybackRatePlayer {
    var durationSeconds: Double? { get }
    var hasPlayableItem: Bool { get }

    func pause()
    func seek(to seconds: Double)
    func addPeriodicTimeObserver(
        interval: Double,
        using handler: @escaping @MainActor (Double) -> Void
    ) -> Any
    func removeTimeObserver(_ observer: Any)
    func loadDurationSeconds() async -> Double?
}

@MainActor
protocol ManagedPlaybackQueuePlayer: ManagedPlaybackPlayer {
    func enqueue(url: URL) -> any PlaybackItemReference
    func removeAllItems()
}

@MainActor
struct PlaybackPlayerSession {
    let player: any ManagedPlaybackPlayer
    let item: any PlaybackItemReference
}

@MainActor
protocol PlaybackPlayerCreating {
    func makePlayer(
        url: URL,
        automaticallyWaitsToMinimizeStalling: Bool
    ) -> PlaybackPlayerSession
    func makeQueuePlayer() -> any ManagedPlaybackQueuePlayer
}

@MainActor
protocol PlaybackObservation: AnyObject {
    func cancel()
}

@MainActor
protocol PlaybackEventObserving {
    func observeEnd(
        of item: any PlaybackItemReference,
        using handler: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation
    func observeFailure(
        of item: any PlaybackItemReference,
        using handler: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation
}

protocol SecurityScopedResourceAccessing: AnyObject {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var isArticlePlaying = false
    @Published private(set) var activeLibraryItemID: URL?
    @Published private(set) var isLibraryPlaying = false
    @Published private(set) var libraryElapsedSeconds = 0.0
    @Published private(set) var libraryDurationSeconds = 0.0
    @Published private(set) var playingPreviewVoiceID: String?

    private var playbackRate: Double
    private let playerFactory: any PlaybackPlayerCreating
    private let eventCenter: any PlaybackEventObserving
    private let securityScopes: any SecurityScopedResourceAccessing
    private let prepareUbiquitousFile: @MainActor (URL) -> Void

    private var articlePlayer: (any ManagedPlaybackPlayer)?
    private var articleQueue: (any ManagedPlaybackQueuePlayer)?
    private var articleObservations: [any PlaybackObservation] = []
    private var progressiveObservations: [Int: [any PlaybackObservation]] = [:]
    private var directArticleSessionID: UUID?
    private var progressiveArticleSessionID: UUID?
    private var queuedSegmentIndexes: Set<Int> = []
    private var finishedSegmentIndexes: Set<Int> = []
    private var expectedSegmentCount = 0
    private var articlePlaybackFinished = false
    private var userPausedArticle = false

    private var libraryPlayer: (any ManagedPlaybackPlayer)?
    private var libraryTimeObserver: Any?
    private var libraryObservations: [any PlaybackObservation] = []
    private var libraryScopeLease: SecurityScopeLease?
    private var libraryDurationTask: Task<Void, Never>?
    private var librarySessionID: UUID?

    private var previewPlayer: (any ManagedPlaybackPlayer)?
    private var previewObservations: [any PlaybackObservation] = []
    private var previewSessionID: UUID?

    init(
        playbackRate: Double,
        playerFactory: (any PlaybackPlayerCreating)? = nil,
        eventCenter: (any PlaybackEventObserving)? = nil,
        securityScopes: (any SecurityScopedResourceAccessing)? = nil,
        prepareUbiquitousFile: (@MainActor (URL) -> Void)? = nil
    ) {
        self.playbackRate = AppSettings.normalizedPlaybackRate(playbackRate)
        self.playerFactory = playerFactory ?? NativePlaybackPlayerFactory()
        self.eventCenter = eventCenter ?? NativePlaybackEventCenter()
        self.securityScopes = securityScopes ?? NativeSecurityScopedResourceAccessor()
        self.prepareUbiquitousFile =
            prepareUbiquitousFile ?? { url in
                guard
                    (try? url.resourceValues(
                        forKeys: [.isUbiquitousItemKey]
                    ).isUbiquitousItem) == true
                else { return }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
    }

    isolated deinit { shutdown() }

    var hasProgressiveQueue: Bool { articleQueue != nil && !queuedSegmentIndexes.isEmpty }

    var libraryPlaybackProgress: Double {
        guard libraryDurationSeconds.isFinite, libraryDurationSeconds > 0 else { return 0 }
        return min(max(libraryElapsedSeconds / libraryDurationSeconds, 0), 1)
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = AppSettings.normalizedPlaybackRate(rate)
        if let articlePlayer {
            PlaybackRateController.update(
                articlePlayer,
                to: playbackRate,
                whilePlaying: isArticlePlaying
            )
        }
        if let libraryPlayer {
            PlaybackRateController.update(
                libraryPlayer,
                to: playbackRate,
                whilePlaying: isLibraryPlaying
            )
        }
    }

    func enqueue(segment: AudioSegment, expectedCount: Int, autoPlay: Bool) {
        guard !queuedSegmentIndexes.contains(segment.index) else { return }
        let queue: any ManagedPlaybackQueuePlayer
        let sessionID: UUID
        if let articleQueue {
            queue = articleQueue
            if let progressiveArticleSessionID {
                sessionID = progressiveArticleSessionID
            } else {
                let newSessionID = UUID()
                progressiveArticleSessionID = newSessionID
                sessionID = newSessionID
            }
        } else {
            let newQueue = playerFactory.makeQueuePlayer()
            let newSessionID = UUID()
            articleQueue = newQueue
            articlePlayer = newQueue
            directArticleSessionID = nil
            progressiveArticleSessionID = newSessionID
            queue = newQueue
            sessionID = newSessionID
        }

        expectedSegmentCount = max(expectedSegmentCount, expectedCount)
        articlePlaybackFinished = false
        queuedSegmentIndexes.insert(segment.index)
        let item = queue.enqueue(url: segment.url)
        progressiveObservations[segment.index] = observations(
            for: item,
            onEnd: { [weak self] in
                self?.progressiveItemEnded(index: segment.index, sessionID: sessionID)
            },
            onFailure: { [weak self] in
                self?.progressiveItemFailed(index: segment.index, sessionID: sessionID)
            }
        )

        if (autoPlay && !userPausedArticle) || isArticlePlaying {
            stopOtherSourcesForArticle()
            PlaybackRateController.start(queue, at: playbackRate)
            isArticlePlaying = true
        }
    }

    func toggleArticle(fallbackURL: URL?) {
        guard let articlePlayer else {
            if let fallbackURL { playArticle(url: fallbackURL) }
            return
        }
        if isArticlePlaying {
            articlePlayer.pause()
            isArticlePlaying = false
            userPausedArticle = true
            return
        }
        guard !articlePlaybackFinished, articlePlayer.hasPlayableItem else {
            if let fallbackURL { playArticle(url: fallbackURL) }
            return
        }
        stopOtherSourcesForArticle()
        PlaybackRateController.start(articlePlayer, at: playbackRate)
        isArticlePlaying = true
        userPausedArticle = false
    }

    func playArticle(url: URL) {
        resetArticlePlayback()
        stopOtherSourcesForArticle()
        let session = playerFactory.makePlayer(
            url: url,
            automaticallyWaitsToMinimizeStalling: true
        )
        let sessionID = UUID()
        directArticleSessionID = sessionID
        articlePlayer = session.player
        articlePlaybackFinished = false
        articleObservations = observations(
            for: session.item,
            onEnd: { [weak self] in self?.articleItemFinished(sessionID: sessionID) },
            onFailure: { [weak self] in self?.articleItemFinished(sessionID: sessionID) }
        )
        PlaybackRateController.start(session.player, at: playbackRate)
        isArticlePlaying = true
        userPausedArticle = false
    }

    func resetArticlePlayback() {
        directArticleSessionID = nil
        progressiveArticleSessionID = nil
        articlePlayer?.pause()
        articleQueue?.removeAllItems()
        cancel(&articleObservations)
        for key in progressiveObservations.keys {
            guard var observations = progressiveObservations[key] else { continue }
            cancel(&observations)
        }
        progressiveObservations.removeAll()
        articlePlayer = nil
        articleQueue = nil
        queuedSegmentIndexes.removeAll()
        finishedSegmentIndexes.removeAll()
        expectedSegmentCount = 0
        articlePlaybackFinished = false
        isArticlePlaying = false
        userPausedArticle = false
    }

    func toggleLibrary(
        item: AudioLibraryItem,
        scopedFolder: URL?,
        onEnd: @escaping @MainActor () -> Void
    ) {
        if activeLibraryItemID == item.id, let libraryPlayer {
            if isLibraryPlaying {
                libraryPlayer.pause()
                isLibraryPlaying = false
            } else {
                pauseArticleForAnotherSource()
                stopVoicePreview()
                PlaybackRateController.start(libraryPlayer, at: playbackRate)
                isLibraryPlaying = true
            }
            return
        }
        playLibrary(item: item, scopedFolder: scopedFolder, onEnd: onEnd)
    }

    func playLibrary(
        item: AudioLibraryItem,
        scopedFolder: URL?,
        onEnd: @escaping @MainActor () -> Void
    ) {
        pauseArticleForAnotherSource()
        stopVoicePreview()
        stopLibraryPlayback(clearSelection: false)

        if let scopedFolder {
            libraryScopeLease = SecurityScopeLease(url: scopedFolder, accessor: securityScopes)
        }
        prepareUbiquitousFile(item.url)
        let session = playerFactory.makePlayer(
            url: item.url,
            automaticallyWaitsToMinimizeStalling: true
        )
        let sessionID = UUID()
        librarySessionID = sessionID
        libraryPlayer = session.player
        activeLibraryItemID = item.id
        libraryElapsedSeconds = 0
        libraryDurationSeconds = 0
        libraryTimeObserver = session.player.addPeriodicTimeObserver(interval: 0.25) {
            [weak self, weak player = session.player] seconds in
            guard let self, librarySessionID == sessionID else { return }
            libraryElapsedSeconds = max(seconds, 0)
            if let duration = player?.durationSeconds {
                libraryDurationSeconds = duration
            }
        }
        libraryObservations = observations(
            for: session.item,
            onEnd: { [weak self] in
                guard let self, librarySessionID == sessionID else { return }
                stopLibraryPlayback(clearSelection: false)
                onEnd()
            },
            onFailure: { [weak self] in
                guard let self, librarySessionID == sessionID else { return }
                stopLibraryPlayback(clearSelection: false)
            }
        )
        PlaybackRateController.start(session.player, at: playbackRate)
        isLibraryPlaying = true

        libraryDurationTask = Task { @MainActor [weak self, weak player = session.player] in
            guard let duration = await player?.loadDurationSeconds(),
                !Task.isCancelled,
                self?.librarySessionID == sessionID
            else { return }
            self?.libraryDurationSeconds = duration
        }
    }

    func seekLibrary(to progress: Double) {
        guard libraryDurationSeconds.isFinite, libraryDurationSeconds > 0 else { return }
        let seconds = min(max(progress, 0), 1) * libraryDurationSeconds
        libraryPlayer?.seek(to: seconds)
        libraryElapsedSeconds = seconds
    }

    func stopLibraryPlayback(clearSelection: Bool) {
        librarySessionID = nil
        libraryDurationTask?.cancel()
        libraryDurationTask = nil
        libraryPlayer?.pause()
        if let libraryTimeObserver {
            libraryPlayer?.removeTimeObserver(libraryTimeObserver)
            self.libraryTimeObserver = nil
        }
        cancel(&libraryObservations)
        libraryPlayer = nil
        isLibraryPlaying = false
        libraryElapsedSeconds = 0
        libraryDurationSeconds = 0
        if clearSelection { activeLibraryItemID = nil }
        libraryScopeLease?.release()
        libraryScopeLease = nil
    }

    func playVoicePreview(voiceID: String, url: URL) {
        pauseArticleForAnotherSource()
        stopLibraryPlayback(clearSelection: false)
        stopVoicePreview()
        let session = playerFactory.makePlayer(
            url: url,
            automaticallyWaitsToMinimizeStalling: false
        )
        let sessionID = UUID()
        previewSessionID = sessionID
        previewPlayer = session.player
        playingPreviewVoiceID = voiceID
        previewObservations = observations(
            for: session.item,
            onEnd: { [weak self] in self?.previewItemFinished(sessionID: sessionID) },
            onFailure: { [weak self] in self?.previewItemFinished(sessionID: sessionID) }
        )
        PlaybackRateController.start(session.player, at: 1)
    }

    func stopVoicePreview() {
        previewSessionID = nil
        previewPlayer?.pause()
        previewPlayer = nil
        playingPreviewVoiceID = nil
        cancel(&previewObservations)
    }

    func shutdown() {
        resetArticlePlayback()
        stopLibraryPlayback(clearSelection: true)
        stopVoicePreview()
    }

    private func pauseArticleForAnotherSource() {
        articlePlayer?.pause()
        isArticlePlaying = false
        userPausedArticle = true
    }

    private func stopOtherSourcesForArticle() {
        stopLibraryPlayback(clearSelection: false)
        stopVoicePreview()
    }

    private func articleItemFinished(sessionID: UUID) {
        guard directArticleSessionID == sessionID else { return }
        directArticleSessionID = nil
        articlePlayer?.pause()
        isArticlePlaying = false
        articlePlaybackFinished = true
        cancel(&articleObservations)
    }

    private func progressiveItemEnded(index: Int, sessionID: UUID) {
        guard progressiveArticleSessionID == sessionID, progressiveObservations[index] != nil else {
            return
        }
        finishedSegmentIndexes.insert(index)
        cancelProgressiveObservations(index: index)
        if expectedSegmentCount > 0, finishedSegmentIndexes.count >= expectedSegmentCount {
            isArticlePlaying = false
            articlePlaybackFinished = true
        }
    }

    private func progressiveItemFailed(index: Int, sessionID: UUID) {
        guard progressiveArticleSessionID == sessionID, progressiveObservations[index] != nil else {
            return
        }
        finishedSegmentIndexes.insert(index)
        cancelProgressiveObservations(index: index)
        articlePlayer?.pause()
        isArticlePlaying = false
        articlePlaybackFinished = true
    }

    private func previewItemFinished(sessionID: UUID) {
        guard previewSessionID == sessionID else { return }
        stopVoicePreview()
    }

    private func cancelProgressiveObservations(index: Int) {
        guard var itemObservations = progressiveObservations.removeValue(forKey: index) else {
            return
        }
        cancel(&itemObservations)
    }

    private func observations(
        for item: any PlaybackItemReference,
        onEnd: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) -> [any PlaybackObservation] {
        [
            eventCenter.observeEnd(of: item, using: onEnd),
            eventCenter.observeFailure(of: item, using: onFailure),
        ]
    }

    private func cancel(_ observations: inout [any PlaybackObservation]) {
        for observation in observations { observation.cancel() }
        observations.removeAll()
    }
}
