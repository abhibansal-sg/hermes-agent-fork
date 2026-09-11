import XCTest
import GRDB
@testable import HermesMobile

@MainActor
final class InboxPersistenceTests: XCTestCase {
    private let scope = CacheScope(serverId: "https://persist.example", profileId: "all")

    private func record(kind: String = "clarify") -> PersistedAttentionItem {
        PersistedAttentionItem(
            id: "attention-1", requestId: "request-1", sessionId: "runtime-1",
            storedSessionId: "stored-1", kind: kind,
            safeTitle: kind == "clarify" ? "Which option?" : "Approve?",
            detail: .init(question: "Which option?", choices: ["A", "B"]),
            createdAt: 100
        )
    }

    func testRelaunchExpiresActionabilityWithoutLiveWaiter() async throws {
        let queue = try DatabaseQueue()
        let firstCache = try CacheStore(testDB: queue)
        _ = try await firstCache.upsertLiveAttention(record(), scope: scope)

        let relaunched = InboxStore()
        relaunched.attachCache(try CacheStore(testDB: queue))
        var widgetCount: Int?
        relaunched.onCommittedSnapshot = { widgetCount = $0.pendingCount }
        await relaunched.hydrate(scope: scope)

        XCTAssertTrue(relaunched.pendingItems.isEmpty)
        XCTAssertEqual(relaunched.storedSessionId(forRuntime: "runtime-1"), "stored-1")
        XCTAssertEqual(widgetCount, relaunched.pendingCount)
    }

    func testLiveReplayCannotResurrectTerminalCommittedItem() async throws {
        let cache = try CacheStore(testDB: DatabaseQueue())
        _ = try await cache.upsertLiveAttention(record(kind: "approval"), scope: scope)
        _ = try await cache.markAttentionState(id: "attention-1", state: .resolvedElsewhere, scope: scope)

        let inbox = InboxStore()
        inbox.attachCache(cache)
        await inbox.hydrate(scope: scope)
        let replay = GatewayEvent(params: .object([
            "type": .string("approval.request"), "session_id": .string("runtime-1"),
            "stored_session_id": .string("stored-1"),
            "payload": .object(["id": .string("attention-1"), "title": .string("Old replay")]),
        ]))!
        inbox.handle(event: replay)
        await inbox.flushPersistence()

        XCTAssertEqual(inbox.pendingCount, 0)
        let persisted = try await cache.loadAttentionSnapshot(scope: scope)
        XCTAssertEqual(persisted.items.first?.state, .resolvedElsewhere)
    }

    func testActiveChatAckDrainsQueuedInsertBeforeResolvingMirror() async throws {
        let cache = try CacheStore(testDB: DatabaseQueue())
        let inbox = InboxStore()
        inbox.attachCache(cache)
        await inbox.hydrate(scope: scope)
        let event = try XCTUnwrap(GatewayEvent(params: .object([
            "type": .string("clarify.request"),
            "session_id": .string("runtime-1"),
            "stored_session_id": .string("stored-1"),
            "payload": .object([
                "question": .string("Which option?"),
                "choices": .array([.string("A"), .string("B")]),
                "request_id": .string("request-1"),
            ]),
        ])))

        inbox.handle(event: event)
        await inbox.resolveMirroredClarification(
            sessionID: "runtime-1",
            requestID: "request-1"
        )
        await inbox.flushPersistence()

        XCTAssertEqual(inbox.pendingCount, 0)
        let persisted = try await cache.loadAttentionSnapshot(scope: scope)
        XCTAssertEqual(persisted.items.first?.state, .resolvedElsewhere)
    }

    func testActiveChatAckTombstoneSuppressesLaterLiveReceipt() async throws {
        let cache = try CacheStore(testDB: DatabaseQueue())
        let inbox = InboxStore()
        inbox.attachCache(cache)
        await inbox.hydrate(scope: scope)

        await inbox.resolveMirroredClarification(
            sessionID: "runtime-1",
            requestID: "request-1"
        )
        inbox.handle(event: try XCTUnwrap(GatewayEvent(params: .object([
            "type": .string("clarify.request"),
            "session_id": .string("runtime-1"),
            "stored_session_id": .string("stored-1"),
            "payload": .object([
                "question": .string("Which option?"),
                "request_id": .string("request-1"),
            ]),
        ]))))
        await inbox.flushPersistence()

        XCTAssertEqual(inbox.pendingCount, 0)
        let persisted = try await cache.loadAttentionSnapshot(scope: scope)
        XCTAssertTrue(persisted.items.isEmpty)
    }
}
