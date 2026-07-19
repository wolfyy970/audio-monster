@preconcurrency import Combine
import Foundation

protocol VoicePreviewGenerating: Sendable {
    func generatePreview(voiceID: String, destinationURL: URL) async throws -> VoicePreview
}

@MainActor
protocol VoicePreviewPlaybackControlling: AnyObject {
    var playingPreviewVoiceID: String? { get }
    func playVoicePreview(voiceID: String, url: URL)
    func stopVoicePreview()
}

extension PlaybackCoordinator: VoicePreviewPlaybackControlling {}

private enum VoicePreviewCoordinatorError: LocalizedError {
    case unexpectedVoice(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedVoice(let voiceID):
            "The voice generator returned a sample for \(voiceID) unexpectedly."
        }
    }
}

@MainActor
final class VoicePreviewCoordinator: ObservableObject {
    @Published private(set) var previews: [String: VoicePreview]
    @Published private(set) var errorMessage: String?

    private struct AutoplayIntent: Equatable {
        let voiceID: String
    }

    private let voiceIDs: [String]
    private let supportedVoiceIDs: Set<String>
    private let generator: any VoicePreviewGenerating
    private let cache: any VoicePreviewCaching
    private weak var playback: (any VoicePreviewPlaybackControlling)?

    private var queue: [String] = []
    private var queuedVoiceIDs: Set<String> = []
    private var activeVoiceID: String?
    private var activeWorkerID: UUID?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var generationEpoch: UInt = 0
    private var isSuspended = true
    private var wantsFullBatch = false
    private var autoplayIntent: AutoplayIntent?

    init(
        voiceIDs: [String],
        generator: any VoicePreviewGenerating,
        cache: any VoicePreviewCaching,
        playback: any VoicePreviewPlaybackControlling
    ) {
        self.voiceIDs = voiceIDs
        supportedVoiceIDs = Set(voiceIDs)
        self.generator = generator
        self.cache = cache
        self.playback = playback
        previews = Self.previewSnapshot(
            voiceIDs: voiceIDs,
            cached: cache.load(voiceIDs: voiceIDs)
        )
    }

    isolated deinit {
        for worker in workers.values { worker.cancel() }
    }

    var readyCount: Int {
        previews.values.lazy.filter { $0.status == .ready }.count
    }

    var totalCount: Int { voiceIDs.count }

    func prepareAll() {
        wantsFullBatch = true
        errorMessage = nil
        enqueueAllMissingVoices()
        startWorkerIfPossible()
    }

    func resumePreparation() {
        guard isSuspended else {
            startWorkerIfPossible()
            return
        }
        isSuspended = false
        if wantsFullBatch { enqueueAllMissingVoices() }
        if let autoplayIntent { prioritize(autoplayIntent.voiceID) }
        startWorkerIfPossible()
    }

    func suspendPreparation(clearAutoplay: Bool) {
        invalidateWorkers()
        isSuspended = true
        if clearAutoplay {
            autoplayIntent = nil
            playback?.stopVoicePreview()
        }
    }

    func reloadCache() {
        let shouldRemainSuspended = isSuspended
        invalidateWorkers()
        isSuspended = true
        previews = Self.previewSnapshot(
            voiceIDs: voiceIDs,
            cached: cache.load(voiceIDs: voiceIDs)
        )
        errorMessage = nil

        if let intent = autoplayIntent,
            let preview = previews[intent.voiceID],
            preview.status == .ready,
            let url = preview.audioURL
        {
            autoplayIntent = nil
            playback?.playVoicePreview(voiceID: intent.voiceID, url: url)
        }

        guard !shouldRemainSuspended else { return }
        isSuspended = false
        if wantsFullBatch { enqueueAllMissingVoices() }
        if let autoplayIntent { prioritize(autoplayIntent.voiceID) }
        startWorkerIfPossible()
    }

    func requestPlayback(voiceID: String) {
        guard supportedVoiceIDs.contains(voiceID) else { return }
        if let preview = previews[voiceID],
            preview.status == .ready,
            let url = preview.audioURL
        {
            autoplayIntent = nil
            playback?.playVoicePreview(voiceID: voiceID, url: url)
            return
        }

        autoplayIntent = AutoplayIntent(voiceID: voiceID)
        errorMessage = nil
        prioritize(voiceID)
        startWorkerIfPossible()
    }

    func togglePlayback(voiceID: String) {
        guard supportedVoiceIDs.contains(voiceID) else { return }
        if playback?.playingPreviewVoiceID == voiceID {
            autoplayIntent = nil
            playback?.stopVoicePreview()
        } else {
            requestPlayback(voiceID: voiceID)
        }
    }

    private func enqueueAllMissingVoices() {
        for voiceID in voiceIDs {
            guard activeVoiceID != voiceID,
                !queuedVoiceIDs.contains(voiceID),
                previews[voiceID]?.status != .ready
            else { continue }
            queue.append(voiceID)
            queuedVoiceIDs.insert(voiceID)
        }
    }

    private func prioritize(_ voiceID: String) {
        guard supportedVoiceIDs.contains(voiceID), activeVoiceID != voiceID else { return }
        if queuedVoiceIDs.contains(voiceID) {
            queue.removeAll { $0 == voiceID }
        } else if previews[voiceID]?.status == .ready {
            return
        } else {
            queuedVoiceIDs.insert(voiceID)
        }
        queue.insert(voiceID, at: 0)
        previews[voiceID] = Self.pendingPreview(voiceID)
    }

    private func startWorkerIfPossible() {
        guard !isSuspended,
            activeWorkerID == nil,
            !queue.isEmpty
        else { return }
        let workerID = UUID()
        let epoch = generationEpoch
        activeWorkerID = workerID
        let worker = Task { @MainActor [weak self] in
            guard let self else { return }
            await runWorker(id: workerID, epoch: epoch)
        }
        workers[workerID] = worker
    }

    private func runWorker(id workerID: UUID, epoch: UInt) async {
        while isCurrentWorker(workerID, epoch: epoch),
            !Task.isCancelled,
            let voiceID = dequeueVoice()
        {
            activeVoiceID = voiceID
            previews[voiceID] = VoicePreview(
                voiceID: voiceID,
                status: .generating,
                audioURL: nil,
                durationSeconds: nil
            )
            var stagingURL: URL?
            do {
                let destination = try cache.makeStagingURL(voiceID: voiceID)
                stagingURL = destination
                let generated = try await generator.generatePreview(
                    voiceID: voiceID,
                    destinationURL: destination
                )
                guard isCurrentWorker(workerID, epoch: epoch), !Task.isCancelled else {
                    cache.discardStagingFile(at: destination)
                    workerFinished(id: workerID, epoch: epoch)
                    return
                }
                guard generated.voiceID == voiceID else {
                    throw VoicePreviewCoordinatorError.unexpectedVoice(generated.voiceID)
                }
                let artifact = try cache.commit(stagingURL: destination, voiceID: voiceID)
                previews[voiceID] = VoicePreview(
                    voiceID: voiceID,
                    status: .ready,
                    audioURL: artifact.url,
                    durationSeconds: artifact.durationSeconds
                )
                activeVoiceID = nil
                if let intent = autoplayIntent, intent.voiceID == voiceID {
                    autoplayIntent = nil
                    playback?.playVoicePreview(voiceID: voiceID, url: artifact.url)
                }
            } catch is CancellationError {
                if let stagingURL { cache.discardStagingFile(at: stagingURL) }
                guard isCurrentWorker(workerID, epoch: epoch) else {
                    workerFinished(id: workerID, epoch: epoch)
                    return
                }
                previews[voiceID] = Self.pendingPreview(voiceID)
                activeVoiceID = nil
                workerFinished(id: workerID, epoch: epoch)
                return
            } catch {
                if let stagingURL { cache.discardStagingFile(at: stagingURL) }
                guard isCurrentWorker(workerID, epoch: epoch) else {
                    workerFinished(id: workerID, epoch: epoch)
                    return
                }
                previews[voiceID] = VoicePreview(
                    voiceID: voiceID,
                    status: .failed,
                    audioURL: nil,
                    durationSeconds: nil
                )
                errorMessage = "\(voiceID): \(error.localizedDescription)"
                activeVoiceID = nil
            }
        }
        workerFinished(id: workerID, epoch: epoch)
    }

    private func dequeueVoice() -> String? {
        guard !queue.isEmpty else { return nil }
        let voiceID = queue.removeFirst()
        queuedVoiceIDs.remove(voiceID)
        return voiceID
    }

    private func invalidateWorkers() {
        generationEpoch &+= 1
        for worker in workers.values { worker.cancel() }
        activeWorkerID = nil
        if let activeVoiceID, previews[activeVoiceID]?.status == .generating {
            previews[activeVoiceID] = Self.pendingPreview(activeVoiceID)
        }
        activeVoiceID = nil
        queue.removeAll()
        queuedVoiceIDs.removeAll()
    }

    private func isCurrentWorker(_ workerID: UUID, epoch: UInt) -> Bool {
        activeWorkerID == workerID && generationEpoch == epoch
    }

    private func workerFinished(id workerID: UUID, epoch: UInt) {
        workers.removeValue(forKey: workerID)
        guard isCurrentWorker(workerID, epoch: epoch) else { return }
        activeWorkerID = nil
        activeVoiceID = nil
        startWorkerIfPossible()
    }

    private static func previewSnapshot(
        voiceIDs: [String],
        cached: [String: CachedVoicePreview]
    ) -> [String: VoicePreview] {
        Dictionary(
            uniqueKeysWithValues: voiceIDs.map { voiceID in
                if let artifact = cached[voiceID] {
                    return (
                        voiceID,
                        VoicePreview(
                            voiceID: voiceID,
                            status: .ready,
                            audioURL: artifact.url,
                            durationSeconds: artifact.durationSeconds
                        )
                    )
                }
                return (voiceID, pendingPreview(voiceID))
            })
    }

    private static func pendingPreview(_ voiceID: String) -> VoicePreview {
        VoicePreview(
            voiceID: voiceID,
            status: .pending,
            audioURL: nil,
            durationSeconds: nil
        )
    }
}
