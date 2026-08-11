import XCTest
@testable import HermesMobile

@MainActor
final class InboxStoreTests: XCTestCase {
    private func event(_ type: String, session: String, id: String = "approval-1") -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type), "session_id": .string(session),
            "payload": .object(["id": .string(id), "title": .string("Approve")]),
        ]))!
    }

    func testMessageCompletionExpiresVisibleFailedOrPendingRows() {
        let inbox = InboxStore()
        inbox.handle(event: event("approval.request", session: "runtime"))
        XCTAssertEqual(inbox.pendingCount, 1)
        inbox.handle(event: event("message.complete", session: "runtime"))
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertEqual(inbox.items.first?.state, .expired)
    }

    func testExplicitDismissRemainsAnIntentionalLocalAction() {
        let inbox = InboxStore()
        inbox.handle(event: event("approval.request", session: "runtime"))
        inbox.dismiss(inbox.items[0])
        XCTAssertTrue(inbox.items.isEmpty)
    }

    func testActiveClarificationMatchesRuntimeOrStoredIdentity() throws {
        let inbox = InboxStore()
        let event = try XCTUnwrap(GatewayEvent(params: .object([
            "type": .string("clarify.request"),
            "session_id": .string("runtime-clarify"),
            "stored_session_id": .string("stored-clarify"),
            "payload": .object([
                "question": .string("Which path should I use?"),
                "choices": .array([.string("A"), .string("B")]),
                "request_id": .string("request-clarify"),
            ]),
        ])))
        inbox.handle(event: event)

        XCTAssertEqual(
            inbox.pendingClarification(runtimeID: "runtime-clarify", storedID: nil)?.id,
            "clarify:runtime-clarify"
        )
        XCTAssertEqual(
            inbox.pendingClarification(runtimeID: nil, storedID: "stored-clarify")?.id,
            "clarify:runtime-clarify"
        )
        XCTAssertNil(inbox.pendingClarification(runtimeID: "other", storedID: "other"))
    }
}
