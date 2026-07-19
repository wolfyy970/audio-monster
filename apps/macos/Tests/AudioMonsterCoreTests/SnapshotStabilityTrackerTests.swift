import AudioMonsterCore
import Foundation
import Testing

struct SnapshotStabilityTrackerTests {
    private let policy = SnapshotStabilityPolicy(
        minimumReadableCharacterCount: 200,
        requiredConsecutiveStableSnapshots: 2,
        maximumReadableSnapshotCount: 5
    )

    @Test
    func acceptsTheSecondMatchingReadableSnapshotWithoutResettingForTransientNoise() {
        var tracker = SnapshotStabilityTracker(policy: policy)
        let candidate = snapshot(text: String(repeating: "Readable prose. ", count: 20))
        let transientChallenge = snapshot(
            text: "Checking your browser",
            challenged: true
        )

        #expect(tracker.observe(candidate) == .waiting)
        #expect(tracker.observe(transientChallenge) == .waiting)
        #expect(tracker.observe(candidate) == .accept(candidate))
    }

    @Test
    func acceptsTheFifthReadableSnapshotWhenLiveContentNeverStabilizes() {
        var tracker = SnapshotStabilityTracker(policy: policy)
        let candidates = (1...5).map { index in
            snapshot(
                title: "Article revision \(index)",
                text: String(repeating: "Readable prose. ", count: 20) + "\(index)"
            )
        }

        for candidate in candidates.dropLast() {
            #expect(tracker.observe(candidate) == .waiting)
        }
        #expect(tracker.observe(candidates[4]) == .accept(candidates[4]))
    }

    @Test
    func rejectsIncompleteChallengedShortAndUntitledSnapshots() {
        let readableText = String(repeating: "Readable prose. ", count: 20)
        let invalidSnapshots = [
            snapshot(text: readableText, ready: false),
            snapshot(text: readableText, challenged: true),
            snapshot(text: "Too short"),
            snapshot(title: "", text: readableText),
        ]

        for invalid in invalidSnapshots {
            var tracker = SnapshotStabilityTracker(policy: policy)
            #expect(tracker.observe(invalid) == .waiting)
        }
    }

    private func snapshot(
        title: String = "Stable Article",
        text: String,
        ready: Bool = true,
        challenged: Bool = false
    ) -> BrowserExtractionSnapshot {
        BrowserExtractionSnapshot(
            title: title,
            text: text,
            resolvedURL: "https://example.com/article",
            ready: ready,
            challenged: challenged,
            method: .mozillaReadability
        )
    }
}
