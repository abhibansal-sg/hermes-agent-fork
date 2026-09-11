import GRDB
import XCTest
@testable import HermesMobile

final class TimelineReducerTests: XCTestCase {
    func testDuplicateEventIsIdempotent() {
        var state = TimelineReductionState()
        let event = TimelineEvent(
            id: "event-1",
            turnID: "turn-1",
            payload: .turnStarted
        )

        XCTAssertEqual(state.apply(event), .applied)
        XCTAssertEqual(state.apply(event), .ignoredDuplicateEvent)
        XCTAssertEqual(state.projection.latestTurnID, "turn-1")
    }

    func testRejectedEventIdentityIsStillConsumed() {
        var state = TimelineReductionState()
        let initiallyStale = TimelineEvent(
            id: "event-1",
            turnID: "turn-1",
            payload: .turnFinished(outcome: .completed, summary: nil)
        )

        XCTAssertEqual(state.apply(initiallyStale), .ignoredStaleTurn)
        _ = state.apply(.init(id: "start", turnID: "turn-1", payload: .turnStarted))
        XCTAssertEqual(state.apply(initiallyStale), .ignoredDuplicateEvent)
        XCTAssertEqual(state.projection.runState, .submitting)
    }

    func testCanonicalCommitMayReplacePartialText() throws {
        var state = TimelineReductionState()
        XCTAssertEqual(state.apply(.init(
            id: "start",
            turnID: "turn-1",
            payload: .turnStarted
        )), .applied)
        XCTAssertEqual(state.apply(.init(
            id: "partial",
            turnID: "turn-1",
            payload: .segmentSnapshot(
                segmentID: "assistant-1",
                role: .assistant,
                revision: 1,
                text: "Alpha bravo duplicate tail"
            )
        )), .applied)
        XCTAssertEqual(state.apply(.init(
            id: "canonical",
            turnID: "turn-1",
            payload: .canonicalMessageCommitted(
                segmentID: "assistant-1",
                role: .assistant,
                text: "Alpha bravo.",
                wireID: 42
            )
        )), .applied)

        let segment = try XCTUnwrap(state.projection.segments.first)
        XCTAssertEqual(segment.text, "Alpha bravo.")
        XCTAssertEqual(segment.wireID, 42)
        XCTAssertTrue(segment.isFinal)
    }

    func testFinishedTurnRejectsLateDelta() {
        var state = TimelineReductionState()
        _ = state.apply(.init(id: "start", turnID: "turn-1", payload: .turnStarted))
        _ = state.apply(.init(
            id: "finish",
            turnID: "turn-1",
            payload: .turnFinished(outcome: .completed, summary: nil)
        ))

        XCTAssertEqual(state.apply(.init(
            id: "late",
            turnID: "turn-1",
            payload: .segmentSnapshot(
                segmentID: "assistant-1",
                role: .assistant,
                revision: 1,
                text: "late"
            )
        )), .ignoredFinishedTarget)
    }
}

final class TimelineStoreTests: XCTestCase {
    private let identity = CacheIdentity(
        serverId: "https://example.test",
        profileId: "default",
        sessionId: "session-1"
    )

    func testCommitDedupesRecordAndSourceIDs() async throws {
        let queue = try DatabaseQueue()
        let store = try TimelineStore(testDB: queue)
        let start = TimelineEvent(
            id: "start",
            sourceEventID: "stream:1",
            turnID: "turn-1",
            payload: .turnStarted
        )

        let first = try await store.commit(identity: identity, events: [start])
        let duplicateRecord = try await store.commit(identity: identity, events: [start])
        let duplicateSource = try await store.commit(identity: identity, events: [
            TimelineEvent(
                id: "different-record",
                sourceEventID: "stream:1",
                turnID: "turn-1",
                payload: .streamState(.streaming)
            )
        ])

        XCTAssertEqual(first.lastSequence, 1)
        XCTAssertEqual(duplicateRecord.applications, [.ignoredDuplicateEvent])
        XCTAssertEqual(duplicateRecord.lastSequence, 1)
        XCTAssertEqual(duplicateSource.applications, [.ignoredDuplicateEvent])
        XCTAssertEqual(duplicateSource.lastSequence, 1)
        let stats = try await store.stats()
        XCTAssertEqual(stats.records, 1)
    }

    func testKilledAppRestoreReplaysUncompactedPartialTurn() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-relaunch-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let events = [
            TimelineEvent(id: "start", turnID: "turn-1", payload: .turnStarted),
            TimelineEvent(
                id: "partial",
                turnID: "turn-1",
                payload: .segmentSnapshot(
                    segmentID: "assistant-1",
                    role: .assistant,
                    revision: 1,
                    text: "Partial response"
                )
            ),
            TimelineEvent(id: "suspend", turnID: "turn-1", payload: .streamState(.suspended)),
        ]
        do {
            let queue = try DatabaseQueue(path: url.path)
            let store = try TimelineStore(testDB: queue)
            _ = try await store.commit(identity: identity, events: events)
        }

        let reopenedQueue = try DatabaseQueue(path: url.path)
        let reopened = try TimelineStore(testDB: reopenedQueue)
        let restored = try await reopened.loadProjection(identity: identity)

        XCTAssertEqual(restored?.activeTurnID, "turn-1")
        XCTAssertEqual(restored?.runState, .suspended)
        XCTAssertEqual(restored?.segments.first?.text, "Partial response")
    }

    func testTerminalCommitSnapshotsAndCompactsRecords() async throws {
        let queue = try DatabaseQueue()
        let store = try TimelineStore(testDB: queue)
        let events = [
            TimelineEvent(id: "start", turnID: "turn-1", payload: .turnStarted),
            TimelineEvent(
                id: "partial",
                turnID: "turn-1",
                payload: .segmentSnapshot(
                    segmentID: "assistant-1",
                    role: .assistant,
                    revision: 1,
                    text: "Partial"
                )
            ),
            TimelineEvent(
                id: "canonical",
                turnID: "turn-1",
                payload: .canonicalMessageCommitted(
                    segmentID: "assistant-1",
                    role: .assistant,
                    text: "Final answer",
                    wireID: 99
                )
            ),
            TimelineEvent(
                id: "finish",
                turnID: "turn-1",
                payload: .turnFinished(outcome: .completed, summary: nil)
            ),
        ]

        let result = try await store.commit(identity: identity, events: events)
        let stats = try await store.stats()
        let restored = try await store.loadProjection(identity: identity)

        XCTAssertTrue(result.wroteSnapshot)
        XCTAssertEqual(stats.records, 0)
        XCTAssertEqual(stats.snapshots, 1)
        XCTAssertEqual(restored?.runState, .completed)
        XCTAssertNil(restored?.activeTurnID)
        XCTAssertEqual(restored?.segments.first?.text, "Final answer")
        XCTAssertEqual(restored?.segments.first?.wireID, 99)
    }

    func testDedupeSurvivesTerminalCompaction() async throws {
        let queue = try DatabaseQueue()
        let store = try TimelineStore(testDB: queue)
        let finish = TimelineEvent(
            id: "finish",
            sourceEventID: "stream:9",
            turnID: "turn-1",
            payload: .turnFinished(outcome: .completed, summary: nil)
        )
        _ = try await store.commit(identity: identity, events: [
            TimelineEvent(id: "start", turnID: "turn-1", payload: .turnStarted),
            finish,
        ])

        let duplicate = try await store.commit(identity: identity, events: [finish])

        XCTAssertEqual(duplicate.applications, [.ignoredDuplicateEvent])
        XCTAssertEqual(duplicate.lastSequence, 2)
        XCTAssertFalse(duplicate.wroteSnapshot)
        let stats = try await store.stats()
        XCTAssertEqual(stats.records, 0)
    }

    func testRecordThresholdCreatesSnapshotBeforeTurnFinishes() async throws {
        let queue = try DatabaseQueue()
        let policy = TimelineRetentionPolicy(
            snapshotRecordThreshold: 2,
            snapshotByteThreshold: .max,
            maxSessions: 50,
            maxTotalBytes: 50 * 1_024 * 1_024,
            maxDedupeKeysPerSession: 512
        )
        let store = try TimelineStore(testDB: queue, retention: policy)

        let result = try await store.commit(identity: identity, events: [
            TimelineEvent(id: "start", turnID: "turn-1", payload: .turnStarted),
            TimelineEvent(
                id: "partial",
                turnID: "turn-1",
                payload: .segmentSnapshot(
                    segmentID: "assistant-1",
                    role: .assistant,
                    revision: 1,
                    text: "Still streaming"
                )
            ),
        ])

        XCTAssertTrue(result.wroteSnapshot)
        let stats = try await store.stats()
        let restored = try await store.loadProjection(identity: identity)
        XCTAssertEqual(stats.records, 0)
        XCTAssertEqual(restored?.runState, .streaming)
    }
}
