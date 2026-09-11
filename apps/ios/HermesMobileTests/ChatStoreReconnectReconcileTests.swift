import XCTest
@testable import HermesMobile

/// ABH-276 + ABH-278 — reconnect reconcile ordering.
///
/// A mid-generation socket drop finalizes the visible assistant row with a
/// "Connection lost" warning. The reconnect path then has two races:
///  - REST backfill can return before the resumed server turn has persisted;
///  - resumed WS frames can arrive before/while that backfill is reconciling.
/// Both must treat the interrupted assistant row as the in-flight turn's
/// placeholder: do not evict it when REST is temporarily behind, and do not append
/// a second assistant bubble when the stream resumes.
@MainActor
final class ChatStoreReconnectReconcileTests: XCTestCase {

    private let activeRuntime = "rt-local-reconnect"
    private let storedId = "stored-session-reconnect"

    private func makeStore(
        backfill: @escaping (String) async throws -> [StoredMessage] = { _ in [] }
    ) -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = activeRuntime
        sessions.activeStoredId = storedId
        chat.backfillFetch = backfill
        return (chat, sessions)
    }

    private func localFrame(type: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(activeRuntime),
            "payload": payload,
        ]))!
    }

    private func storedMessage(
        role: String, text: String, wireId: Int? = nil, timestamp: Double? = nil
    ) -> StoredMessage {
        var json: [String: JSONValue] = [
            "role": .string(role),
            "content": .string(text),
        ]
        if let wireId { json["id"] = .number(Double(wireId)) }
        if let timestamp { json["timestamp"] = .number(timestamp) }
        return StoredMessage(json: .object(json))!
    }

    private func beginLocalPartialTurn(_ chat: ChatStore) -> ChatMessage {
        chat.messages = [ChatMessage(role: .user, text: "prompt before drop")]
        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        chat.handle(event: localFrame(type: "message.delta", payload: ["text": "partial reply"] ))
        #if DEBUG
        chat.drainFlushForTesting()
        #endif
        return chat.messages.last(where: { $0.role == .assistant })!
    }

    private func warningTexts(in message: ChatMessage?) -> [String] {
        message?.parts.compactMap { part in
            if case .warning(_, let text) = part { return text }
            return nil
        } ?? []
    }

    func testBackfillBeforeResumedPersistencePreservesConnectionLostRow() async {
        let (chat, _) = makeStore { _ in
            // The server has not persisted the resumed/final assistant row yet.
            [self.storedMessage(role: "user", text: "prompt before drop")]
        }

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()

        guard let warningRow = chat.messages.first(where: { $0.id == interrupted.id }) else {
            return XCTFail("connection drop must leave the interrupted assistant row visible")
        }
        XCTAssertTrue(warningRow.text.contains("partial reply"))
        XCTAssertEqual(warningRow.warning, "Connection lost")

        await chat.backfill()
        await Task.yield()

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1,
                       "REST history that is temporarily behind must not evict the interrupted in-flight assistant row")
        XCTAssertEqual(assistantRows.first?.id, interrupted.id,
                       "the interrupted row keeps identity across the stale reconnect backfill")
        XCTAssertEqual(assistantRows.first?.warning, "Connection lost",
                       "the user-visible connection-loss warning must not vanish before the resumed turn settles")
    }

    func testResumedStreamReusesInterruptedRowInsteadOfAppendingDuplicateBubble() async {
        let (chat, _) = makeStore()

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)

        // WS resumes before/around reconnect backfill. The resumed stream belongs
        // to the same interrupted server turn, so it must continue in the warning
        // row rather than append a fresh assistant bubble for one UI turn.
        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1,
                       "resumed WS start must reuse the interrupted assistant row, not spawn a duplicate bubble")
        XCTAssertEqual(chat.messages.last(where: { $0.role == .assistant })?.id, interrupted.id)
        XCTAssertTrue(chat.isStreaming)

        chat.handle(event: localFrame(type: "message.delta", payload: ["text": " resumed"] ))
        #if DEBUG
        chat.drainFlushForTesting()
        #endif
        chat.handle(event: localFrame(
            type: "message.complete",
            payload: ["text": "final reply after reconnect", "status": "completed"]
        ))

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows.first?.id, interrupted.id,
                       "the final resumed reply keeps the interrupted row's identity")
        XCTAssertTrue(assistantRows.first?.text.contains("final reply after reconnect") == true)
        XCTAssertFalse(assistantRows.first?.isStreaming ?? true)
    }

    func testCleanResumedCompletionClearsConnectionLostWarningPart() async {
        let (chat, _) = makeStore()

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()
        XCTAssertEqual(warningTexts(in: chat.messages.first(where: { $0.id == interrupted.id })), ["Connection lost"])

        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        chat.handle(event: localFrame(type: "message.complete", payload: [
            "text": "fully recovered reply",
            "status": "completed",
        ]))

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows.first?.id, interrupted.id)
        XCTAssertEqual(assistantRows.first?.text, "fully recovered reply")
        XCTAssertEqual(warningTexts(in: assistantRows.first), [],
                       "a clean completion for the reconciled resumed row must remove the stale connection-loss warning part")
    }

    func testLiveGatewayCompleteStatusClearsConnectionLostWarningPart() async {
        let (chat, _) = makeStore()

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()
        XCTAssertEqual(warningTexts(in: chat.messages.first(where: { $0.id == interrupted.id })), ["Connection lost"])

        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        chat.handle(event: localFrame(type: "message.complete", payload: [
            "text": "fully recovered reply",
            "status": "complete",
        ]))

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows.first?.id, interrupted.id)
        XCTAssertEqual(assistantRows.first?.text, "fully recovered reply")
        XCTAssertEqual(warningTexts(in: assistantRows.first), [],
                       "the live gateway's `complete` status must clear the stale connection-loss warning")
    }

    func testFailedResumedCompletionKeepsWarningPart() async {
        let (chat, _) = makeStore()

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()
        XCTAssertEqual(warningTexts(in: chat.messages.first(where: { $0.id == interrupted.id })), ["Connection lost"])

        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        chat.handle(event: localFrame(type: "message.complete", payload: [
            "text": "failed after reconnect",
            "status": "failed",
            "warning": "Agent failed after reconnect",
        ]))

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows.first?.id, interrupted.id)
        XCTAssertEqual(assistantRows.first?.text, "failed after reconnect")
        XCTAssertFalse(assistantRows.first?.isStreaming ?? true)
        XCTAssertEqual(warningTexts(in: assistantRows.first), ["Agent failed after reconnect"],
                       "a failed/warning-bearing resumed completion must keep its warning part instead of clearing it as stale")
    }

    func testAuthoritativeReconcilePersistsGapSnapshotWithoutReplacingLiveProjection() async {
        var fetches = 0
        let (chat, _) = makeStore { _ in
            fetches += 1
            return [
                self.storedMessage(
                    role: "user", text: "prompt before drop", wireId: 1
                ),
                self.storedMessage(
                    role: "assistant", text: "persisted partial", wireId: 2
                ),
            ]
        }
        _ = beginLocalPartialTurn(chat)

        await chat.reconcileAuthoritativeTranscript()

        XCTAssertEqual(fetches, 1, "an authoritative checkpoint must not no-op while streaming")
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(
            chat.messages.filter { $0.role == .assistant }.count,
            1,
            "the live projection stays in place while the authoritative snapshot is fetched"
        )
        XCTAssertTrue(
            chat.messages.last?.text.contains("partial reply") == true,
            "a gap reconcile must not replace a newer live bubble mid-turn"
        )
    }

    func testLocalCompletionReconcilesOntoExistingBubbleWithoutDuplicate() async {
        let fetched = expectation(description: "terminal authoritative transcript fetched")
        let (chat, _) = makeStore { _ in
            fetched.fulfill()
            return [
                self.storedMessage(
                    role: "user", text: "prompt before drop", wireId: 1
                ),
                self.storedMessage(
                    role: "assistant", text: "authoritative final", wireId: 2
                ),
            ]
        }
        let live = beginLocalPartialTurn(chat)

        chat.handle(event: localFrame(
            type: "message.complete",
            payload: ["text": "frame final", "status": "complete"]
        ))
        await fulfillment(of: [fetched], timeout: 1)
        for _ in 0..<5 { await Task.yield() }

        let assistants = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.id, live.id)
        XCTAssertEqual(assistants.first?.text, "authoritative final")
        XCTAssertFalse(chat.isStreaming)
    }

    func testRepeatedAuthoritativeReconcileKeepsAdoptedCompletionSingle() async {
        let firstFetch = expectation(description: "terminal authoritative transcript fetched")
        var fetchCount = 0
        let (chat, _) = makeStore { _ in
            fetchCount += 1
            if fetchCount == 1 { firstFetch.fulfill() }
            return [
                self.storedMessage(
                    role: "user", text: "prompt before drop", wireId: 1
                ),
                self.storedMessage(
                    role: "assistant", text: "authoritative final", wireId: 2
                ),
            ]
        }
        let live = beginLocalPartialTurn(chat)

        chat.handle(event: localFrame(
            type: "message.complete",
            payload: ["text": "frame final", "status": "complete"]
        ))
        await fulfillment(of: [firstFetch], timeout: 1)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(chat.messages.last?.id, live.id)

        await chat.reconcileAuthoritativeTranscript(surfaceFailure: false)

        let assistants = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(
            assistants.count,
            1,
            "a later refresh must recognize the canonical row already adopted by the live bubble"
        )
        XCTAssertEqual(assistants.first?.id, live.id)
        XCTAssertEqual(assistants.first?.text, "authoritative final")
    }

    func testLegacyWindowShiftKeepsAdoptedCompletionSingleWithoutWireIDs() async throws {
        let firstFetch = expectation(description: "first legacy transcript fetched")
        var fetchCount = 0
        let (chat, _) = makeStore { _ in
            fetchCount += 1
            if fetchCount == 1 {
                firstFetch.fulfill()
                return [
                    self.storedMessage(role: "system", text: "head row that will drop"),
                    self.storedMessage(
                        role: "user", text: "persistent context prompt", wireId: 100
                    ),
                    self.storedMessage(
                        role: "assistant", text: "persistent context answer", wireId: 101
                    ),
                    self.storedMessage(role: "user", text: "prompt before drop"),
                    self.storedMessage(role: "assistant", text: "authoritative final"),
                ]
            }
            // A real bounded-tail advance drops leading rows and appends a new
            // turn. The adopted answer remains in-window but shifts index and is
            // no longer trailing on either side.
            return [
                self.storedMessage(
                    role: "user", text: "persistent context prompt", wireId: 100
                ),
                self.storedMessage(
                    role: "assistant", text: "persistent context answer", wireId: 101
                ),
                self.storedMessage(role: "user", text: "prompt before drop"),
                self.storedMessage(role: "assistant", text: "authoritative final"),
                self.storedMessage(role: "user", text: "later prompt"),
                self.storedMessage(role: "assistant", text: "later answer"),
            ]
        }
        let live = beginLocalPartialTurn(chat)

        chat.handle(event: localFrame(
            type: "message.complete",
            payload: ["text": "frame final", "status": "complete"]
        ))
        await fulfillment(of: [firstFetch], timeout: 1)
        for _ in 0..<5 { await Task.yield() }

        let firstCanonicalID = try XCTUnwrap(
            chat.messages.first(where: { $0.id == live.id })?.canonicalID
        )
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 2)

        await chat.reconcileAuthoritativeTranscript(surfaceFailure: false)
        await chat.reconcileAuthoritativeTranscript(surfaceFailure: false)

        let assistants = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(
            assistants.count,
            3,
            "the shifted adopted final and the genuinely new answer must each appear once"
        )
        XCTAssertEqual(assistants[1].id, live.id)
        XCTAssertEqual(assistants[1].text, "authoritative final")
        XCTAssertEqual(assistants.last?.text, "later answer")
        XCTAssertNotEqual(
            assistants[1].canonicalID,
            firstCanonicalID,
            "the adopted row should advance to the shifted positional authority alias"
        )
    }

    func testLegacyFallbackDoesNotAdoptOlderIdenticalAssistantPayload() async {
        let fetched = expectation(description: "new turn transcript fetched")
        let (chat, _) = makeStore { _ in
            fetched.fulfill()
            return [
                self.storedMessage(role: "user", text: "new distinct prompt"),
                self.storedMessage(role: "assistant", text: "Done"),
            ]
        }
        let olderID = UUID()
        chat.messages = [
            ChatMessage(
                id: olderID,
                canonicalID: UUID(),
                usesPositionalSeedIdentity: true,
                role: .assistant,
                text: "Done"
            ),
            ChatMessage(role: .user, text: "new distinct prompt"),
        ]

        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        chat.handle(event: localFrame(type: "message.delta", payload: ["text": "Done"]))
        #if DEBUG
        chat.drainFlushForTesting()
        #endif
        let live = chat.messages.last(where: { $0.role == .assistant })!
        XCTAssertNotEqual(live.id, olderID)

        chat.handle(event: localFrame(
            type: "message.complete",
            payload: ["text": "Done", "status": "complete"]
        ))
        await fulfillment(of: [fetched], timeout: 1)
        for _ in 0..<5 { await Task.yield() }

        let assistants = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(
            assistants.count,
            2,
            "union retains the older settled answer while adding the distinct new turn"
        )
        XCTAssertTrue(assistants.contains(where: { $0.id == olderID }))
        XCTAssertEqual(
            assistants.last?.id,
            live.id,
            "a later identical answer must adopt its own live bubble, never an older positional alias"
        )
        XCTAssertNotEqual(assistants.last?.id, olderID)
    }

    func testLegacyFallbackRequiresMatchingUserTurnForPassiveIdenticalAnswer() {
        let (chat, _) = makeStore()
        let olderID = UUID()
        chat.messages = [
            ChatMessage(role: .user, text: "old prompt"),
            ChatMessage(
                id: olderID,
                canonicalID: UUID(),
                usesPositionalSeedIdentity: true,
                role: .assistant,
                text: "Done"
            ),
        ]

        chat.seed(from: [
            storedMessage(role: "user", text: "new distinct prompt"),
            storedMessage(role: "assistant", text: "Done"),
        ], policy: .union)

        XCTAssertEqual(
            chat.messages.filter { $0.role == .user }.map(\.text),
            ["old prompt", "new distinct prompt"]
        )
        let assistants = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(
            assistants.count,
            2,
            "equal assistant text from a different offline turn must remain a distinct answer"
        )
        XCTAssertTrue(assistants.contains(where: { $0.id == olderID }))
        XCTAssertTrue(assistants.contains(where: { $0.id != olderID && $0.text == "Done" }))
    }

    func testLegacyFallbackDoesNotAliasRepeatedUserWithoutMatchingAnswer() {
        let (chat, _) = makeStore()
        let olderUserID = UUID()
        chat.messages = [
            ChatMessage(
                id: olderUserID,
                canonicalID: UUID(),
                usesPositionalSeedIdentity: true,
                role: .user,
                text: "continue"
            ),
            ChatMessage(role: .assistant, text: "old answer"),
        ]

        chat.seed(from: [
            storedMessage(role: "user", text: "continue"),
            storedMessage(role: "assistant", text: "different new answer"),
        ], policy: .union)

        let users = chat.messages.filter { $0.role == .user }
        XCTAssertEqual(users.count, 2)
        XCTAssertTrue(users.contains(where: { $0.id == olderUserID }))
        XCTAssertTrue(users.contains(where: { $0.id != olderUserID && $0.text == "continue" }))
        XCTAssertEqual(
            chat.messages.filter { $0.role == .assistant }.map(\.text),
            ["old answer", "different new answer"]
        )
    }

    func testLegacyFallbackUsesAuthorityTimestampsForIdenticalTurns() {
        let (chat, _) = makeStore()
        let olderUserID = UUID()
        let olderAssistantID = UUID()
        chat.messages = [
            ChatMessage(
                id: olderUserID,
                canonicalID: UUID(),
                usesPositionalSeedIdentity: true,
                authoritativeSeedTimestamp: 100,
                role: .user,
                text: "continue"
            ),
            ChatMessage(
                id: olderAssistantID,
                canonicalID: UUID(),
                usesPositionalSeedIdentity: true,
                authoritativeSeedTimestamp: 101,
                role: .assistant,
                text: "Done"
            ),
        ]

        chat.seed(from: [
            storedMessage(role: "user", text: "continue", timestamp: 200),
            storedMessage(role: "assistant", text: "Done", timestamp: 201),
        ], policy: .union)

        let users = chat.messages.filter { $0.role == .user }
        let assistants = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(assistants.count, 2)
        XCTAssertTrue(users.contains(where: { $0.id == olderUserID }))
        XCTAssertTrue(assistants.contains(where: { $0.id == olderAssistantID }))
        XCTAssertTrue(users.contains(where: { $0.id != olderUserID && $0.text == "continue" }))
        XCTAssertTrue(assistants.contains(where: { $0.id != olderAssistantID && $0.text == "Done" }))
    }

    func testLegacyToolOnlySyntheticRowKeepsAdoptedIdentityAcrossTailShift() throws {
        let toolRow = StoredMessage(
            role: "assistant",
            content: .string(""),
            timestamp: 11,
            toolCalls: [WireToolCall(callId: "legacy-tool", name: "shell")],
            finishReason: "tool_calls"
        )
        let first = ChatStore.toChatMessages([
            StoredMessage(role: "system", content: .string("head row that will drop")),
            StoredMessage(role: "user", content: .string("context prompt"), timestamp: 1),
            StoredMessage(role: "assistant", content: .string("context answer"), timestamp: 2),
            StoredMessage(role: "user", content: .string("run the tool"), timestamp: 10),
            toolRow,
        ])
        let canonical = try XCTUnwrap(first.last(where: { !$0.tools.isEmpty }))
        XCTAssertTrue(canonical.usesPositionalSeedIdentity)
        XCTAssertEqual(canonical.authoritativeSeedTimestamp, 11)

        let runtimeID = UUID()
        let adopted = ChatMessage(
            id: runtimeID,
            canonicalID: canonical.id,
            usesPositionalSeedIdentity: canonical.usesPositionalSeedIdentity,
            authoritativeSeedTimestamp: canonical.authoritativeSeedTimestamp,
            role: .assistant,
            parts: canonical.parts,
            timestamp: canonical.timestamp
        )
        let (chat, _) = makeStore()
        chat.messages = first.map { $0.id == canonical.id ? adopted : $0 }

        let shifted = ChatStore.toChatMessages([
            StoredMessage(role: "user", content: .string("context prompt"), timestamp: 1),
            StoredMessage(role: "assistant", content: .string("context answer"), timestamp: 2),
            StoredMessage(role: "user", content: .string("run the tool"), timestamp: 10),
            toolRow,
            StoredMessage(role: "user", content: .string("later prompt"), timestamp: 20),
            StoredMessage(role: "assistant", content: .string("later answer"), timestamp: 21),
        ])
        chat.seed(normalized: shifted, policy: .union)
        chat.seed(normalized: shifted, policy: .union)

        let toolRows = chat.messages.filter { !$0.tools.isEmpty }
        XCTAssertEqual(toolRows.count, 1)
        XCTAssertEqual(toolRows.first?.id, runtimeID)
        XCTAssertEqual(toolRows.first?.tools.first?.id, "legacy-tool")
    }

    func testRepeatedUnionReconcileKeepsAdoptedUserEchoSingle() {
        let (chat, _) = makeStore()
        let echo = ChatMessage(
            role: .user,
            clientMessageID: "client-prompt-1",
            text: "prompt before drop"
        )
        let authoritative = [
            storedMessage(role: "user", text: "prompt before drop", wireId: 1)
        ]
        chat.messages = [echo]

        chat.seed(from: authoritative, policy: .union)
        chat.seed(from: authoritative, policy: .union)

        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(chat.messages.first?.id, echo.id)
        XCTAssertEqual(chat.messages.first?.clientMessageID, echo.clientMessageID)
    }

    func testColdWatchCompletionRetiresLiveTwinOfAlreadyPaintedAuthority() async {
        let authoritative = [
            storedMessage(role: "user", text: "cold-open prompt", wireId: 1),
            storedMessage(role: "assistant", text: "cold-open answer", wireId: 2),
        ]
        let fetched = expectation(description: "watch terminal reconciled")
        let (chat, _) = makeStore { _ in
            fetched.fulfill()
            return authoritative
        }

        // Cold-open race: the bounded REST seed completes just before the
        // reattached live turn projects its own temporary assistant row.
        chat.seed(from: authoritative)
        await chat.reconcileLiveTurnStatus(
            runtimeId: activeRuntime,
            snapshotRunning: true,
            watchOnly: true
        )
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 2)

        chat.handle(event: localFrame(
            type: "message.complete",
            payload: ["text": "cold-open answer", "status": "complete"]
        ))
        await fulfillment(of: [fetched], timeout: 1)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(
            chat.messages.filter { $0.role == .assistant && $0.text == "cold-open answer" }.count,
            1,
            "the authoritative row and its reattached live placeholder are one logical reply"
        )
        XCTAssertFalse(chat.messages.contains(where: \.isStreaming))

        // A real terminal also releases watch ownership. Otherwise the next
        // authoritative seed is silently ignored by seed(normalized:policy:).
        chat.seed(from: authoritative + [
            storedMessage(role: "user", text: "later prompt", wireId: 3),
            storedMessage(role: "assistant", text: "later answer", wireId: 4),
        ], policy: .union)
        XCTAssertEqual(chat.messages.filter { $0.text == "later answer" }.count, 1)
    }
}
