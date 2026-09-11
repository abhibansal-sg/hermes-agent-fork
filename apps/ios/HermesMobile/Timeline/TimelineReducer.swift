import Foundation

/// Pure, value-type fold for persisted timeline events.
///
/// Record-id dedupe is intentionally in the reduction state rather than in
/// `TimelineProjection`: snapshots remain small, while `TimelineStore` keeps a
/// bounded durable dedupe table across record compaction.
struct TimelineReductionState: Sendable, Equatable {
    private(set) var projection: TimelineProjection
    private var appliedRecordIDs: Set<String>

    init(
        projection: TimelineProjection = .empty,
        appliedRecordIDs: Set<String> = []
    ) {
        self.projection = projection
        self.appliedRecordIDs = appliedRecordIDs
    }

    @discardableResult
    mutating func apply(_ event: TimelineEvent) -> TimelineApplyResult {
        guard !appliedRecordIDs.contains(event.id) else {
            return .ignoredDuplicateEvent
        }

        // An event identity is consumed even when its target is stale or
        // already final. Otherwise replaying that same immutable input after
        // later state changes could produce a different projection.
        appliedRecordIDs.insert(event.id)
        return reduce(event)
    }

    private mutating func reduce(_ event: TimelineEvent) -> TimelineApplyResult {
        switch event.payload {
        case .turnStarted:
            if projection.latestTurnID == event.turnID {
                return projection.runState.isTerminal
                    ? .ignoredFinishedTarget
                    : .ignoredDuplicateTarget
            }

            projection = TimelineProjection(
                latestTurnID: event.turnID,
                activeTurnID: event.turnID,
                runState: .submitting,
                segments: [],
                tools: [],
                failureSummary: nil
            )
            return .applied

        case let .segmentSnapshot(segmentID, role, revision, text):
            guard mayMutateActiveTurn(event.turnID) else {
                return rejectionForInactiveTurn(event.turnID)
            }

            if let index = projection.segments.firstIndex(where: { $0.id == segmentID }) {
                let existing = projection.segments[index]
                guard !existing.isFinal else { return .ignoredFinishedTarget }
                guard revision > existing.revision else {
                    return revision == existing.revision && text == existing.text
                        ? .ignoredDuplicateTarget
                        : .ignoredStaleRevision
                }
                projection.segments[index].revision = revision
                projection.segments[index].text = text
            } else {
                projection.segments.append(TimelineSegment(
                    id: segmentID,
                    turnID: event.turnID,
                    role: role,
                    revision: revision,
                    text: text,
                    isFinal: false,
                    wireID: nil,
                    order: nextOrder()
                ))
            }
            projection.runState = .streaming
            return .applied

        case let .toolSnapshot(toolID, name, state, revision, summary):
            guard mayMutateActiveTurn(event.turnID) else {
                return rejectionForInactiveTurn(event.turnID)
            }

            if let index = projection.tools.firstIndex(where: { $0.id == toolID }) {
                let existing = projection.tools[index]
                guard !existing.state.isTerminal else { return .ignoredFinishedTarget }
                guard revision > existing.revision else {
                    let isSame = revision == existing.revision
                        && name == existing.name
                        && state == existing.state
                        && summary == existing.summary
                    return isSame ? .ignoredDuplicateTarget : .ignoredStaleRevision
                }
                guard TimelineToolState.isMonotonic(from: existing.state, to: state) else {
                    return .ignoredStaleRevision
                }
                projection.tools[index].name = name
                projection.tools[index].state = state
                projection.tools[index].revision = revision
                projection.tools[index].summary = summary
            } else {
                projection.tools.append(TimelineTool(
                    id: toolID,
                    turnID: event.turnID,
                    name: name,
                    state: state,
                    revision: revision,
                    summary: summary,
                    order: nextOrder()
                ))
            }
            projection.runState = .streaming
            return .applied

        case .streamState(let streamState):
            guard mayMutateActiveTurn(event.turnID) else {
                return rejectionForInactiveTurn(event.turnID)
            }
            let next: TimelineRunState = switch streamState {
            case .streaming: .streaming
            case .suspended: .suspended
            case .reconnecting: .reconnecting
            }
            guard projection.runState != next else { return .ignoredDuplicateTarget }
            projection.runState = next
            return .applied

        case let .canonicalMessageCommitted(segmentID, role, text, wireID):
            guard projection.latestTurnID == event.turnID else {
                return .ignoredStaleTurn
            }

            if let index = projection.segments.firstIndex(where: { $0.id == segmentID }) {
                let existing = projection.segments[index]
                if existing.isFinal, existing.text == text, existing.wireID == wireID {
                    return .ignoredDuplicateTarget
                }
                projection.segments[index].revision = existing.revision + 1
                projection.segments[index].text = text
                projection.segments[index].isFinal = true
                projection.segments[index].wireID = wireID
            } else {
                projection.segments.append(TimelineSegment(
                    id: segmentID,
                    turnID: event.turnID,
                    role: role,
                    revision: 0,
                    text: text,
                    isFinal: true,
                    wireID: wireID,
                    order: nextOrder()
                ))
            }
            return .applied

        case let .turnFinished(outcome, summary):
            guard projection.latestTurnID == event.turnID else {
                return .ignoredStaleTurn
            }
            guard projection.activeTurnID == event.turnID else {
                return .ignoredFinishedTarget
            }

            for index in projection.segments.indices {
                projection.segments[index].isFinal = true
            }
            projection.activeTurnID = nil
            projection.failureSummary = summary
            projection.runState = switch outcome {
            case .completed: .completed
            case .interrupted: .interrupted
            case .failed: .failed
            }
            return .applied
        }
    }

    private mutating func mayMutateActiveTurn(_ turnID: String) -> Bool {
        if projection.activeTurnID == nil, projection.latestTurnID == nil {
            projection.latestTurnID = turnID
            projection.activeTurnID = turnID
            projection.runState = .streaming
        }
        return projection.activeTurnID == turnID
    }

    private func rejectionForInactiveTurn(_ turnID: String) -> TimelineApplyResult {
        if projection.latestTurnID == turnID, projection.runState.isTerminal {
            return .ignoredFinishedTarget
        }
        return .ignoredStaleTurn
    }

    private func nextOrder() -> Int {
        let segmentMax = projection.segments.map(\.order).max() ?? -1
        let toolMax = projection.tools.map(\.order).max() ?? -1
        return max(segmentMax, toolMax) + 1
    }
}
