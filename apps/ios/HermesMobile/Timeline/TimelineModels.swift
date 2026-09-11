import Foundation

/// Presentation-only lifecycle state for the most recent turn in a session.
///
/// The gateway transcript remains authoritative. These values exist so an
/// interrupted iOS process can paint a coherent partial turn before the next
/// authoritative reconcile completes.
enum TimelineRunState: String, Codable, Sendable, Equatable {
    case idle
    case submitting
    case streaming
    case suspended
    case reconnecting
    case completed
    case interrupted
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .interrupted, .failed:
            true
        case .idle, .submitting, .streaming, .suspended, .reconnecting:
            false
        }
    }
}

enum TimelineSegmentRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case reasoning
    case status
}

struct TimelineSegment: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let turnID: String
    let role: TimelineSegmentRole
    var revision: Int
    var text: String
    var isFinal: Bool
    var wireID: Int?
    let order: Int
}

enum TimelineToolState: String, Codable, Sendable, Equatable {
    case preparing
    case awaitingApproval
    case running
    case completed
    case failed
    case denied

    fileprivate var rank: Int {
        switch self {
        case .preparing: 0
        case .awaitingApproval: 1
        case .running: 2
        case .completed, .failed, .denied: 3
        }
    }

    var isTerminal: Bool { rank == 3 }
}

struct TimelineTool: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let turnID: String
    var name: String
    var state: TimelineToolState
    var revision: Int
    /// Display-safe summary only. Raw arguments, secrets, and full tool output
    /// are deliberately outside this database's contract.
    var summary: String?
    let order: Int
}

struct TimelineProjection: Codable, Sendable, Equatable {
    var latestTurnID: String?
    var activeTurnID: String?
    var runState: TimelineRunState
    var segments: [TimelineSegment]
    var tools: [TimelineTool]
    var failureSummary: String?

    static let empty = TimelineProjection(
        latestTurnID: nil,
        activeTurnID: nil,
        runState: .idle,
        segments: [],
        tools: [],
        failureSummary: nil
    )
}

enum TimelineTurnOutcome: String, Codable, Sendable, Equatable {
    case completed
    case interrupted
    case failed
}

enum TimelineStreamState: String, Codable, Sendable, Equatable {
    case streaming
    case suspended
    case reconnecting
}

/// One immutable input to the timeline reducer.
///
/// Text events carry full segment snapshots, not raw tokens. A caller may keep
/// rendering at a 40 ms cadence while persisting these less frequently.
enum TimelineEventPayload: Codable, Sendable, Equatable {
    case turnStarted
    case segmentSnapshot(
        segmentID: String,
        role: TimelineSegmentRole,
        revision: Int,
        text: String
    )
    case toolSnapshot(
        toolID: String,
        name: String,
        state: TimelineToolState,
        revision: Int,
        summary: String?
    )
    case streamState(TimelineStreamState)
    case canonicalMessageCommitted(
        segmentID: String,
        role: TimelineSegmentRole,
        text: String,
        wireID: Int?
    )
    case turnFinished(outcome: TimelineTurnOutcome, summary: String?)

    var kind: String {
        switch self {
        case .turnStarted: "turn.started"
        case .segmentSnapshot: "segment.snapshot"
        case .toolSnapshot: "tool.snapshot"
        case .streamState(let state): "stream.\(state.rawValue)"
        case .canonicalMessageCommitted: "canonical.message.committed"
        case .turnFinished: "turn.finished"
        }
    }

    var isTerminal: Bool {
        if case .turnFinished = self { return true }
        return false
    }
}

struct TimelineEvent: Codable, Sendable, Equatable, Identifiable {
    let id: String
    /// Stable upstream event/cursor identity when the transport supplies one.
    /// Nil is valid for today's gateway frames.
    let sourceEventID: String?
    let turnID: String
    let occurredAt: Double
    let payload: TimelineEventPayload

    init(
        id: String = UUID().uuidString,
        sourceEventID: String? = nil,
        turnID: String,
        occurredAt: Double = Date().timeIntervalSince1970,
        payload: TimelineEventPayload
    ) {
        self.id = id
        self.sourceEventID = sourceEventID
        self.turnID = turnID
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

enum TimelineApplyResult: Sendable, Equatable {
    case applied
    case ignoredDuplicateEvent
    case ignoredDuplicateTarget
    case ignoredFinishedTarget
    case ignoredStaleRevision
    case ignoredStaleTurn
}

struct TimelineCommitResult: Sendable, Equatable {
    let projection: TimelineProjection
    let applications: [TimelineApplyResult]
    let lastSequence: Int
    let wroteSnapshot: Bool
}

struct TimelineStoreStats: Sendable, Equatable {
    let heads: Int
    let records: Int
    let snapshots: Int
    let dedupeKeys: Int
    let payloadBytes: Int
}

struct TimelineRetentionPolicy: Sendable, Equatable {
    let snapshotRecordThreshold: Int
    let snapshotByteThreshold: Int
    let maxSessions: Int
    let maxTotalBytes: Int
    let maxDedupeKeysPerSession: Int

    static let standard = TimelineRetentionPolicy(
        snapshotRecordThreshold: 64,
        snapshotByteThreshold: 256 * 1_024,
        maxSessions: 50,
        maxTotalBytes: 50 * 1_024 * 1_024,
        maxDedupeKeysPerSession: 512
    )
}

extension TimelineToolState {
    static func isMonotonic(from old: TimelineToolState, to new: TimelineToolState) -> Bool {
        new.rank >= old.rank
    }
}
