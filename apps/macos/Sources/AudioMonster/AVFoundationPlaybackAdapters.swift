@preconcurrency import AVFoundation
import Foundation

final class NativeSecurityScopedResourceAccessor: SecurityScopedResourceAccessing {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

final class SecurityScopeLease {
    private let url: URL
    private let accessor: any SecurityScopedResourceAccessing
    private var isActive: Bool

    init(url: URL, accessor: any SecurityScopedResourceAccessing) {
        self.url = url
        self.accessor = accessor
        isActive = accessor.startAccessing(url)
    }

    func release() {
        guard isActive else { return }
        accessor.stopAccessing(url)
        isActive = false
    }

    deinit { release() }
}

@MainActor
private final class NativePlaybackItemReference: PlaybackItemReference {
    let item: AVPlayerItem

    init(item: AVPlayerItem) { self.item = item }

    var notificationObject: AnyObject { item }
}

@MainActor
private class NativeManagedPlaybackPlayer: ManagedPlaybackPlayer {
    let player: AVPlayer

    init(player: AVPlayer) { self.player = player }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    var defaultRate: Float {
        get { player.defaultRate }
        set { player.defaultRate = newValue }
    }

    var durationSeconds: Double? {
        guard let seconds = player.currentItem?.duration.seconds,
            seconds.isFinite,
            seconds > 0
        else { return nil }
        return seconds
    }

    var hasPlayableItem: Bool { player.currentItem != nil }

    func playImmediately(atRate rate: Float) {
        player.playImmediately(atRate: rate)
    }

    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func addPeriodicTimeObserver(
        interval: Double,
        using handler: @escaping @MainActor (Double) -> Void
    ) -> Any {
        let callback = MainActorDoubleCallback(handler)
        return player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                callback.action(time.seconds)
            }
        }
    }

    func removeTimeObserver(_ observer: Any) {
        player.removeTimeObserver(observer)
    }

    func loadDurationSeconds() async -> Double? {
        guard let asset = player.currentItem?.asset,
            let duration = try? await asset.load(.duration),
            duration.seconds.isFinite,
            duration.seconds > 0
        else { return nil }
        return duration.seconds
    }
}

@MainActor
private final class NativeManagedPlaybackQueuePlayer:
    NativeManagedPlaybackPlayer,
    ManagedPlaybackQueuePlayer
{
    private let queue: AVQueuePlayer

    init(queue: AVQueuePlayer) {
        self.queue = queue
        super.init(player: queue)
    }

    func enqueue(url: URL) -> any PlaybackItemReference {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        queue.insert(item, after: queue.items().last)
        return NativePlaybackItemReference(item: item)
    }

    func removeAllItems() { queue.removeAllItems() }
}

private final class MainActorDoubleCallback: @unchecked Sendable {
    let action: @MainActor (Double) -> Void

    init(_ action: @escaping @MainActor (Double) -> Void) { self.action = action }
}

private final class MainActorVoidCallback: @unchecked Sendable {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
}

@MainActor
final class NativePlaybackPlayerFactory: PlaybackPlayerCreating {
    func makePlayer(
        url: URL,
        automaticallyWaitsToMinimizeStalling: Bool
    ) -> PlaybackPlayerSession {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
        return PlaybackPlayerSession(
            player: NativeManagedPlaybackPlayer(player: player),
            item: NativePlaybackItemReference(item: item)
        )
    }

    func makeQueuePlayer() -> any ManagedPlaybackQueuePlayer {
        NativeManagedPlaybackQueuePlayer(queue: AVQueuePlayer())
    }
}

@MainActor
private final class NotificationPlaybackObservation: PlaybackObservation {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    func cancel() {
        guard let token else { return }
        center.removeObserver(token)
        self.token = nil
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}

@MainActor
final class NativePlaybackEventCenter: PlaybackEventObserving {
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) { self.center = center }

    func observeEnd(
        of item: any PlaybackItemReference,
        using handler: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation {
        observe(
            name: .AVPlayerItemDidPlayToEndTime,
            object: item.notificationObject,
            using: handler
        )
    }

    func observeFailure(
        of item: any PlaybackItemReference,
        using handler: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation {
        observe(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item.notificationObject,
            using: handler
        )
    }

    private func observe(
        name: Notification.Name,
        object: AnyObject,
        using handler: @escaping @MainActor () -> Void
    ) -> any PlaybackObservation {
        let callback = MainActorVoidCallback(handler)
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { callback.action() }
        }
        return NotificationPlaybackObservation(center: center, token: token)
    }
}
