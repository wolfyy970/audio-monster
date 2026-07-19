import Foundation

public enum BrowserExtractionMethod: String, Codable, Sendable {
    case mozillaReadability = "mozilla-readability"
    case semanticFallback = "semantic-fallback"
}

public enum BrowserNavigationResponseDisposition: Equatable, Sendable {
    case allow
    case rejectHTTPStatus(Int)
}

/// Platform-neutral response handling shared by WebKit-based clients.
///
/// Only a failing main-document response should abort article extraction. A
/// stylesheet or image failure must not discard an otherwise readable page,
/// and redirect responses must remain available to the browser to follow.
public enum BrowserNavigationResponsePolicy {
    public static func disposition(
        isForMainFrame: Bool,
        httpStatusCode: Int?
    ) -> BrowserNavigationResponseDisposition {
        guard isForMainFrame,
            let httpStatusCode,
            (400..<600).contains(httpStatusCode)
        else {
            return .allow
        }
        return .rejectHTTPStatus(httpStatusCode)
    }
}

/// A serializable observation produced by any browser-based extraction adapter.
public struct BrowserExtractionSnapshot: Decodable, Equatable, Sendable {
    public let title: String
    public let text: String
    public let resolvedURL: String
    public let ready: Bool
    public let challenged: Bool
    public let method: BrowserExtractionMethod

    public init(
        title: String,
        text: String,
        resolvedURL: String,
        ready: Bool,
        challenged: Bool,
        method: BrowserExtractionMethod
    ) {
        self.title = title
        self.text = text
        self.resolvedURL = resolvedURL
        self.ready = ready
        self.challenged = challenged
        self.method = method
    }
}

public struct SnapshotStabilityPolicy: Equatable, Sendable {
    public let minimumReadableCharacterCount: Int
    public let requiredConsecutiveStableSnapshots: Int
    public let maximumReadableSnapshotCount: Int

    public init(
        minimumReadableCharacterCount: Int,
        requiredConsecutiveStableSnapshots: Int,
        maximumReadableSnapshotCount: Int
    ) {
        self.minimumReadableCharacterCount = minimumReadableCharacterCount
        self.requiredConsecutiveStableSnapshots = requiredConsecutiveStableSnapshots
        self.maximumReadableSnapshotCount = maximumReadableSnapshotCount
    }

    public func isReadable(_ snapshot: BrowserExtractionSnapshot) -> Bool {
        snapshot.ready
            && !snapshot.challenged
            && snapshot.text.count >= minimumReadableCharacterCount
            && !snapshot.title.isEmpty
    }
}

public enum SnapshotStabilityDecision: Equatable, Sendable {
    case waiting
    case accept(BrowserExtractionSnapshot)
}

public struct SnapshotStabilityTracker: Sendable {
    public let policy: SnapshotStabilityPolicy

    private var previousCandidate: BrowserExtractionSnapshot?
    private var consecutiveStableSnapshots = 0
    private var readableSnapshotCount = 0

    public init(policy: SnapshotStabilityPolicy) {
        self.policy = policy
    }

    public mutating func observe(_ snapshot: BrowserExtractionSnapshot) -> SnapshotStabilityDecision {
        guard policy.isReadable(snapshot) else { return .waiting }

        readableSnapshotCount += 1
        if snapshot == previousCandidate {
            consecutiveStableSnapshots += 1
        } else {
            previousCandidate = snapshot
            consecutiveStableSnapshots = 1
        }

        if consecutiveStableSnapshots >= policy.requiredConsecutiveStableSnapshots
            || readableSnapshotCount >= policy.maximumReadableSnapshotCount
        {
            return .accept(snapshot)
        }
        return .waiting
    }
}

/// Platform-neutral tuning used by browser adapters without depending on WebKit.
public struct BrowserExtractionPolicy: Sendable {
    public static let standard = BrowserExtractionPolicy()

    public let stability: SnapshotStabilityPolicy
    public let maximumTextBytes: Int
    public let timeout: Duration
    public let requestTimeoutInterval: TimeInterval
    public let inspectionInterval: Duration
    public let readabilityMaximumElements: Int
    public let readabilityTopCandidates: Int
    public let webViewWidth: Double
    public let webViewHeight: Double
    public let applicationNameForUserAgent: String

    public init(
        minimumReadableCharacterCount: Int = 200,
        requiredConsecutiveStableSnapshots: Int = 2,
        maximumReadableSnapshotCount: Int = 5,
        maximumTextBytes: Int = 4 * 1024 * 1024,
        timeout: Duration = .seconds(30),
        requestTimeoutInterval: TimeInterval = 30,
        inspectionInterval: Duration = .milliseconds(400),
        readabilityMaximumElements: Int = 100_000,
        readabilityTopCandidates: Int = 5,
        webViewWidth: Double = 1_280,
        webViewHeight: Double = 900,
        applicationNameForUserAgent: String = "AudioMonster/0.3"
    ) {
        stability = SnapshotStabilityPolicy(
            minimumReadableCharacterCount: minimumReadableCharacterCount,
            requiredConsecutiveStableSnapshots: requiredConsecutiveStableSnapshots,
            maximumReadableSnapshotCount: maximumReadableSnapshotCount
        )
        self.maximumTextBytes = maximumTextBytes
        self.timeout = timeout
        self.requestTimeoutInterval = requestTimeoutInterval
        self.inspectionInterval = inspectionInterval
        self.readabilityMaximumElements = readabilityMaximumElements
        self.readabilityTopCandidates = readabilityTopCandidates
        self.webViewWidth = webViewWidth
        self.webViewHeight = webViewHeight
        self.applicationNameForUserAgent = applicationNameForUserAgent
    }
}
