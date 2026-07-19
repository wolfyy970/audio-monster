@preconcurrency import Combine
import Foundation
import Testing

@testable import AudioMonster

@MainActor
private final class PlaybackItemSpy: PlaybackItemReference {
    private let object = NSObject()

    var notificationObject: AnyObject { object }
}

@MainActor
private class PlaybackPlayerSpy: ManagedPlaybackPlayer {
    var rate: Float = 0
    var defaultRate: Float = 0
    var durationSeconds: Double? = 120
    var hasPlayableItem = true
    private(set) var playRates: [Float] = []
    private(set) var pauseCount = 0
    private(set) var seeks: [Double] = []
    private(set) var removedTimeObserverCount = 0
    private(set) var timeHandler: ((Double) -> Void)?
    var loadedDurationSeconds: Double? = 120

    func playImmediately(atRate rate: Float) {
        self.rate = rate
        playRates.append(rate)
    }

    func pause() {
        rate = 0
        pauseCount += 1
    }

    func seek(to seconds: Double) { seeks.append(seconds) }

    func addPeriodicTimeObserver(
        interval _: Double,
        using handler: @escaping @MainActor (Double) -> Void
    ) -> Any {
        timeHandler = handler
        return NSObject()
    }

    func removeTimeObserver(_: Any) {
        removedTimeObserverCount += 1
        timeHandler = nil
    }

    func loadDurationSeconds() async -> Double? { loadedDurationSeconds }
}

@MainActor
private final class PlaybackQueuePlayerSpy: PlaybackPlayerSpy, ManagedPlaybackQueuePlayer {
    private(set) var items: [PlaybackItemSpy] = []
    private(set) var enqueuedURLs: [URL] = []
    private(set) var removeAllItemsCount = 0

    func enqueue(url: URL) -> any PlaybackItemReference {
        let item = PlaybackItemSpy()
        items.append(item)
        enqueuedURLs.append(url)
        hasPlayableItem = true
        return item
    }

    func removeAllItems() {
        items.removeAll()
        hasPlayableItem = false
        removeAllItemsCount += 1
    }
}

@MainActor
private final class PlaybackPlayerFactorySpy: PlaybackPlayerCreating {
    private(set) var players: [PlaybackPlayerSpy] = []
    private(set) var playerItems: [PlaybackItemSpy] = []
    private(set) var queues: [PlaybackQueuePlayerSpy] = []

    func makePlayer(
        url _: URL,
        automaticallyWaitsToMinimizeStalling _: Bool
    ) -> PlaybackPlayerSession {
        let player = PlaybackPlayerSpy()
        let item = PlaybackItemSpy()
        players.append(player)
        playerItems.append(item)
        return PlaybackPlayerSession(player: player, item: item)
    }

    func makeQueuePlayer() -> any ManagedPlaybackQueuePlayer {
        let queue = PlaybackQueuePlayerSpy()
        queue.hasPlayableItem = false
        queues.append(queue)
        return queue
    }
}

@MainActor
private final class PlaybackObservationSpy: PlaybackObservation {
    private(set) var isCancelled = false

    func cancel() { isCancelled = true }
}

@MainActor
private final class PlaybackEventCenterSpy: PlaybackEventObserving {
    private struct Handlers {
        var end: [@MainActor () -> Void] = []
        var failure: [@MainActor () -> Void] = []
        var observations: [PlaybackObservationSpy] = []
    }

    private var handlers: [ObjectIdentifier: Handlers] = [:]
    private(set) var allObservations: [PlaybackObservationSpy] = []

    func observeEnd(
        of item: any PlaybackItemReference,
        using handler: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation {
        let observation = PlaybackObservationSpy()
        let key = ObjectIdentifier(item.notificationObject)
        handlers[key, default: Handlers()].end.append(handler)
        handlers[key, default: Handlers()].observations.append(observation)
        allObservations.append(observation)
        return observation
    }

    func observeFailure(
        of item: any PlaybackItemReference,
        using handler: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation {
        let observation = PlaybackObservationSpy()
        let key = ObjectIdentifier(item.notificationObject)
        handlers[key, default: Handlers()].failure.append(handler)
        handlers[key, default: Handlers()].observations.append(observation)
        allObservations.append(observation)
        return observation
    }

    func sendEnd(for item: any PlaybackItemReference) {
        let stored = handlers[ObjectIdentifier(item.notificationObject)]
        for handler in stored?.end ?? [] { handler() }
    }

    func sendFailure(for item: any PlaybackItemReference) {
        let stored = handlers[ObjectIdentifier(item.notificationObject)]
        for handler in stored?.failure ?? [] { handler() }
    }
}

private final class SecurityScopeAccessorSpy: SecurityScopedResourceAccessing {
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []

    func startAccessing(_ url: URL) -> Bool {
        startedURLs.append(url)
        return true
    }

    func stopAccessing(_ url: URL) { stoppedURLs.append(url) }
}

@MainActor
struct PlaybackCoordinatorTests {
    @MainActor
    private struct Fixture {
        let factory = PlaybackPlayerFactorySpy()
        let events = PlaybackEventCenterSpy()
        let scopes = SecurityScopeAccessorSpy()
        let coordinator: PlaybackCoordinator

        init(rate: Double = 1) {
            coordinator = PlaybackCoordinator(
                playbackRate: rate,
                playerFactory: factory,
                eventCenter: events,
                securityScopes: scopes,
                prepareUbiquitousFile: { _ in }
            )
        }
    }

    @Test
    func progressivePlaybackStopsOnResetAndReleasesEveryObserver() {
        let fixture = Fixture(rate: 0.2)
        let first = AudioSegment(index: 0, url: URL(fileURLWithPath: "/tmp/0.wav"))
        let second = AudioSegment(index: 1, url: URL(fileURLWithPath: "/tmp/1.wav"))

        fixture.coordinator.enqueue(segment: first, expectedCount: 2, autoPlay: true)
        fixture.coordinator.enqueue(segment: second, expectedCount: 2, autoPlay: true)

        let queue = fixture.factory.queues[0]
        #expect(fixture.coordinator.isArticlePlaying)
        #expect(queue.playRates.last == 0.2)
        #expect(fixture.events.allObservations.count == 4)

        fixture.coordinator.resetArticlePlayback()

        #expect(!fixture.coordinator.isArticlePlaying)
        #expect(queue.pauseCount == 1)
        #expect(queue.removeAllItemsCount == 1)
        let allObserversCancelled = fixture.events.allObservations.allSatisfy { $0.isCancelled }
        #expect(allObserversCancelled)
    }

    @Test
    func exhaustedProgressiveQueueReplaysTheCompletedArtifact() {
        let fixture = Fixture()
        let segment = AudioSegment(index: 0, url: URL(fileURLWithPath: "/tmp/0.wav"))
        let completed = URL(fileURLWithPath: "/tmp/article.m4a")
        fixture.coordinator.enqueue(segment: segment, expectedCount: 1, autoPlay: true)
        let queue = fixture.factory.queues[0]

        fixture.events.sendEnd(for: queue.items[0])
        #expect(!fixture.coordinator.isArticlePlaying)

        fixture.coordinator.toggleArticle(fallbackURL: completed)

        #expect(fixture.factory.players.count == 1)
        #expect(fixture.coordinator.isArticlePlaying)
        #expect(queue.removeAllItemsCount == 1)
    }

    @Test
    func articleEndAndFailureBothClearPlayingState() {
        let fixture = Fixture()
        let url = URL(fileURLWithPath: "/tmp/article.m4a")
        fixture.coordinator.playArticle(url: url)
        let firstItem = fixture.factory.playerItems[0]

        fixture.events.sendEnd(for: firstItem)
        #expect(!fixture.coordinator.isArticlePlaying)

        fixture.coordinator.playArticle(url: url)
        fixture.events.sendFailure(for: fixture.factory.playerItems[1])
        #expect(!fixture.coordinator.isArticlePlaying)
    }

    @Test
    func delayedDirectArticleCallbackCannotStopReplacementSession() {
        let fixture = Fixture()
        fixture.coordinator.playArticle(url: URL(fileURLWithPath: "/tmp/first.m4a"))
        let replacedItem = fixture.factory.playerItems[0]

        fixture.coordinator.playArticle(url: URL(fileURLWithPath: "/tmp/replacement.m4a"))
        let replacementPlayer = fixture.factory.players[1]
        let replacementItem = fixture.factory.playerItems[1]
        let replacementObservations = Array(fixture.events.allObservations.suffix(2))

        fixture.events.sendFailure(for: replacedItem)

        #expect(fixture.coordinator.isArticlePlaying)
        #expect(replacementPlayer.pauseCount == 0)
        #expect(replacementObservations.allSatisfy { !$0.isCancelled })

        fixture.events.sendEnd(for: replacementItem)
        #expect(!fixture.coordinator.isArticlePlaying)
        #expect(replacementObservations.allSatisfy { $0.isCancelled })
    }

    @Test
    func delayedProgressiveCallbackCannotMutateResetSessionWithReusedIndex() {
        let fixture = Fixture()
        fixture.coordinator.enqueue(
            segment: AudioSegment(index: 0, url: URL(fileURLWithPath: "/tmp/old-0.wav")),
            expectedCount: 1,
            autoPlay: true
        )
        let replacedItem = fixture.factory.queues[0].items[0]
        fixture.coordinator.resetArticlePlayback()

        fixture.coordinator.enqueue(
            segment: AudioSegment(index: 0, url: URL(fileURLWithPath: "/tmp/new-0.wav")),
            expectedCount: 1,
            autoPlay: true
        )
        let replacementQueue = fixture.factory.queues[1]
        let replacementItem = replacementQueue.items[0]
        let replacementObservations = Array(fixture.events.allObservations.suffix(2))

        fixture.events.sendFailure(for: replacedItem)

        #expect(fixture.coordinator.isArticlePlaying)
        #expect(replacementQueue.pauseCount == 0)
        #expect(replacementObservations.allSatisfy { !$0.isCancelled })

        fixture.events.sendEnd(for: replacementItem)
        #expect(!fixture.coordinator.isArticlePlaying)
        #expect(replacementObservations.allSatisfy { $0.isCancelled })
    }

    @Test
    func startingEachSourcePausesThePreviouslyPlayingSource() {
        let fixture = Fixture()
        let segment = AudioSegment(index: 0, url: URL(fileURLWithPath: "/tmp/0.wav"))
        let folder = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        let libraryItem = AudioLibraryItem(
            url: folder.appendingPathComponent("saved.m4a"),
            modifiedAt: .now
        )
        fixture.coordinator.enqueue(segment: segment, expectedCount: 1, autoPlay: true)
        let articleQueue = fixture.factory.queues[0]

        fixture.coordinator.playLibrary(item: libraryItem, scopedFolder: folder) {}
        let libraryPlayer = fixture.factory.players[0]
        #expect(articleQueue.pauseCount == 1)
        #expect(!fixture.coordinator.isArticlePlaying)
        #expect(fixture.coordinator.isLibraryPlaying)

        fixture.coordinator.playVoicePreview(
            voiceID: "am_adam",
            url: URL(fileURLWithPath: "/tmp/preview.wav")
        )
        let previewPlayer = fixture.factory.players[1]
        #expect(libraryPlayer.pauseCount == 1)
        #expect(!fixture.coordinator.isLibraryPlaying)
        #expect(fixture.coordinator.playingPreviewVoiceID == "am_adam")

        fixture.coordinator.toggleArticle(fallbackURL: URL(fileURLWithPath: "/tmp/article.m4a"))
        #expect(previewPlayer.pauseCount == 1)
        #expect(fixture.coordinator.playingPreviewVoiceID == nil)
        #expect(fixture.coordinator.isArticlePlaying)
    }

    @Test
    func playbackRateUpdatesGeneratedAndLibraryPlayersAcrossTheFullRange() {
        let fixture = Fixture(rate: 0.2)
        let articleURL = URL(fileURLWithPath: "/tmp/article.m4a")
        fixture.coordinator.playArticle(url: articleURL)
        let generated = fixture.factory.players[0]
        #expect(generated.playRates.last == 0.2)

        fixture.coordinator.setPlaybackRate(3)
        #expect(generated.defaultRate == 3)
        #expect(generated.rate == 3)

        let folder = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        let item = AudioLibraryItem(
            url: folder.appendingPathComponent("saved.m4a"),
            modifiedAt: .now
        )
        fixture.coordinator.playLibrary(item: item, scopedFolder: folder) {}
        let library = fixture.factory.players[1]
        #expect(library.playRates.last == 3)

        fixture.coordinator.setPlaybackRate(0.2)
        #expect(library.defaultRate == 0.2)
        #expect(library.rate == 0.2)
    }

    @Test
    func libraryTimeSeekCompletionAndScopeLifecycleStayBalanced() async {
        let fixture = Fixture()
        let folder = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        let item = AudioLibraryItem(
            url: folder.appendingPathComponent("saved.m4a"),
            modifiedAt: .now
        )
        var completionCount = 0
        fixture.coordinator.playLibrary(item: item, scopedFolder: folder) {
            completionCount += 1
        }
        let player = fixture.factory.players[0]
        player.timeHandler?(30)
        await Task.yield()

        #expect(fixture.coordinator.libraryElapsedSeconds == 30)
        #expect(fixture.coordinator.libraryDurationSeconds == 120)
        #expect(fixture.coordinator.libraryPlaybackProgress == 0.25)
        fixture.coordinator.seekLibrary(to: 0.5)
        #expect(player.seeks == [60])

        fixture.events.sendEnd(for: fixture.factory.playerItems[0])
        #expect(completionCount == 1)
        #expect(!fixture.coordinator.isLibraryPlaying)
        #expect(player.removedTimeObserverCount == 1)
        #expect(fixture.scopes.startedURLs == [folder])
        #expect(fixture.scopes.stoppedURLs == [folder])
        let allObserversCancelled = fixture.events.allObservations.allSatisfy { $0.isCancelled }
        #expect(allObserversCancelled)

        fixture.coordinator.toggleLibrary(item: item, scopedFolder: folder) {}
        #expect(fixture.factory.players.count == 2)
        #expect(fixture.coordinator.isLibraryPlaying)

        fixture.coordinator.stopLibraryPlayback(clearSelection: true)
        #expect(fixture.scopes.stoppedURLs == [folder, folder])
        #expect(fixture.coordinator.activeLibraryItemID == nil)
    }

    @Test
    func libraryFailureImmediatelyReleasesResourcesAndAllowsReplay() {
        let fixture = Fixture()
        let folder = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        let item = AudioLibraryItem(
            url: folder.appendingPathComponent("failed.m4a"),
            modifiedAt: .now
        )
        fixture.coordinator.playLibrary(item: item, scopedFolder: folder) {}
        let failedPlayer = fixture.factory.players[0]
        let failedObservations = Array(fixture.events.allObservations)

        fixture.events.sendFailure(for: fixture.factory.playerItems[0])

        #expect(!fixture.coordinator.isLibraryPlaying)
        #expect(failedPlayer.removedTimeObserverCount == 1)
        #expect(failedObservations.allSatisfy { $0.isCancelled })
        #expect(fixture.scopes.stoppedURLs == [folder])

        fixture.coordinator.toggleLibrary(item: item, scopedFolder: folder) {}
        #expect(fixture.factory.players.count == 2)
        #expect(fixture.coordinator.isLibraryPlaying)
        fixture.coordinator.stopLibraryPlayback(clearSelection: true)
    }

    @Test
    func replacingLibraryPlaybackBalancesObserversAndSecurityScopes() {
        let fixture = Fixture()
        let firstFolder = URL(fileURLWithPath: "/tmp/first", isDirectory: true)
        let secondFolder = URL(fileURLWithPath: "/tmp/second", isDirectory: true)
        let first = AudioLibraryItem(
            url: firstFolder.appendingPathComponent("first.m4a"),
            modifiedAt: .now
        )
        let second = AudioLibraryItem(
            url: secondFolder.appendingPathComponent("second.m4a"),
            modifiedAt: .now
        )

        fixture.coordinator.playLibrary(item: first, scopedFolder: firstFolder) {}
        let firstPlayer = fixture.factory.players[0]
        let staleFirstTimeHandler = firstPlayer.timeHandler
        let firstObservations = Array(fixture.events.allObservations)
        fixture.coordinator.playLibrary(item: second, scopedFolder: secondFolder) {}
        staleFirstTimeHandler?(45)

        #expect(firstPlayer.removedTimeObserverCount == 1)
        #expect(fixture.coordinator.libraryElapsedSeconds == 0)
        #expect(fixture.coordinator.libraryDurationSeconds == 0)
        let firstObserversCancelled = firstObservations.allSatisfy { $0.isCancelled }
        #expect(firstObserversCancelled)
        #expect(fixture.scopes.startedURLs == [firstFolder, secondFolder])
        #expect(fixture.scopes.stoppedURLs == [firstFolder])

        fixture.coordinator.stopLibraryPlayback(clearSelection: false)
        #expect(fixture.scopes.stoppedURLs == [firstFolder, secondFolder])
    }

    @Test
    func voicePreviewPlaybackAndCompletionReleaseObservers() {
        let fixture = Fixture()
        let url = URL(fileURLWithPath: "/tmp/preview.wav")
        fixture.coordinator.playVoicePreview(voiceID: "am_adam", url: url)
        let player = fixture.factory.players[0]
        let item = fixture.factory.playerItems[0]
        #expect(fixture.coordinator.playingPreviewVoiceID == "am_adam")

        fixture.events.sendEnd(for: item)
        #expect(fixture.coordinator.playingPreviewVoiceID == nil)
        #expect(player.pauseCount == 1)
        let allObserversCancelled = fixture.events.allObservations.allSatisfy { $0.isCancelled }
        #expect(allObserversCancelled)

        fixture.coordinator.playVoicePreview(voiceID: "am_adam", url: url)
        fixture.coordinator.stopVoicePreview()
        #expect(fixture.coordinator.playingPreviewVoiceID == nil)
    }

    @Test
    func delayedVoicePreviewCallbackCannotStopReplacementSession() {
        let fixture = Fixture()
        fixture.coordinator.playVoicePreview(
            voiceID: "am_adam",
            url: URL(fileURLWithPath: "/tmp/adam.wav")
        )
        let replacedItem = fixture.factory.playerItems[0]

        fixture.coordinator.playVoicePreview(
            voiceID: "bf_emma",
            url: URL(fileURLWithPath: "/tmp/emma.wav")
        )
        let replacementPlayer = fixture.factory.players[1]
        let replacementItem = fixture.factory.playerItems[1]
        let replacementObservations = Array(fixture.events.allObservations.suffix(2))

        fixture.events.sendEnd(for: replacedItem)

        #expect(fixture.coordinator.playingPreviewVoiceID == "bf_emma")
        #expect(replacementPlayer.pauseCount == 0)
        #expect(replacementObservations.allSatisfy { !$0.isCancelled })

        fixture.events.sendFailure(for: replacementItem)
        #expect(fixture.coordinator.playingPreviewVoiceID == nil)
        #expect(replacementObservations.allSatisfy { $0.isCancelled })
    }

    @Test
    func shutdownIsIdempotentAndReleasesEveryPlaybackResource() {
        let fixture = Fixture()
        let segment = AudioSegment(
            index: 0,
            url: URL(fileURLWithPath: "/tmp/segment.wav")
        )
        fixture.coordinator.enqueue(segment: segment, expectedCount: 1, autoPlay: true)
        let folder = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        let item = AudioLibraryItem(
            url: folder.appendingPathComponent("saved.m4a"),
            modifiedAt: .now
        )
        fixture.coordinator.playLibrary(item: item, scopedFolder: folder) {}
        let libraryPlayer = fixture.factory.players[0]

        fixture.coordinator.shutdown()
        fixture.coordinator.shutdown()

        #expect(!fixture.coordinator.isArticlePlaying)
        #expect(!fixture.coordinator.isLibraryPlaying)
        #expect(fixture.coordinator.activeLibraryItemID == nil)
        #expect(libraryPlayer.removedTimeObserverCount == 1)
        #expect(fixture.scopes.stoppedURLs == [folder])
        let allObserversCancelled = fixture.events.allObservations.allSatisfy { $0.isCancelled }
        #expect(allObserversCancelled)
    }

    @Test
    func deinitializationPerformsTheSameBalancedCleanup() async {
        let factory = PlaybackPlayerFactorySpy()
        let events = PlaybackEventCenterSpy()
        let scopes = SecurityScopeAccessorSpy()
        var coordinator: PlaybackCoordinator? = PlaybackCoordinator(
            playbackRate: 1,
            playerFactory: factory,
            eventCenter: events,
            securityScopes: scopes,
            prepareUbiquitousFile: { _ in }
        )
        weak let weakCoordinator = coordinator
        let folder = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        let item = AudioLibraryItem(
            url: folder.appendingPathComponent("saved.m4a"),
            modifiedAt: .now
        )
        coordinator?.playLibrary(item: item, scopedFolder: folder) {}
        let player = factory.players[0]

        coordinator = nil
        await Task.yield()

        #expect(weakCoordinator == nil)
        #expect(player.removedTimeObserverCount == 1)
        #expect(scopes.stoppedURLs == [folder])
        let allObserversCancelled = events.allObservations.allSatisfy { $0.isCancelled }
        #expect(allObserversCancelled)
    }

    @Test
    func appModelFacadeForwardsCoordinatorStateChanges() throws {
        let suiteName = "AudioMonsterPlaybackFacade.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let factory = PlaybackPlayerFactorySpy()
        let coordinator = PlaybackCoordinator(
            playbackRate: 1,
            playerFactory: factory,
            eventCenter: PlaybackEventCenterSpy(),
            securityScopes: SecurityScopeAccessorSpy(),
            prepareUbiquitousFile: { _ in }
        )
        let model = AppModel(
            settings: AppSettings(defaults: defaults) { nil },
            playbackCoordinator: coordinator
        )
        var forwardedChangeCount = 0
        let observation = model.objectWillChange.sink {
            forwardedChangeCount += 1
        }
        defer { observation.cancel() }

        coordinator.playArticle(url: URL(fileURLWithPath: "/tmp/article.m4a"))

        #expect(model.isPlaying)
        #expect(forwardedChangeCount > 0)
        coordinator.shutdown()
    }
}
