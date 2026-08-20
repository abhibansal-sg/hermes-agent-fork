import XCTest
@testable import HermesMobile

/// ABH-46: gateway/iOS protocol-parity follow-ons. Every fixture below mirrors
/// a REAL gateway emission (file:line citations inline) — never a fictional
/// shape (the ABH-45 lesson).
@MainActor
final class ProtocolParityTests: XCTestCase {

    private let activeRuntime = "rt-active"
    private let storedId = "stored-abc"

    // MARK: - Item 1: gateway `error` event

    func testErrorEventDecodes() throws {
        // server.py:813 — _emit("error", sid, {"message": "agent init failed: …"})
        let event = try XCTUnwrap(GatewayEvent(params: .object([
            "type": .string("error"),
            "session_id": .string(activeRuntime),
            "payload": .object(["message": .string("agent init failed: boom")]),
        ])))
        XCTAssertEqual(event.type, .error)
        XCTAssertEqual(event.payload["message"]?.stringValue, "agent init failed: boom")
    }

    func testGatewayErrorClearsLocalStreamingAndSurfaces() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("partial…")])))
        await waitUntil { chat.isStreaming }  // wait for the flush, don't race it
        XCTAssertTrue(chat.isStreaming)

        chat.handle(event: localFrame(
            type: "error", payload: .object(["message": .string("turn exploded")])))
        XCTAssertFalse(chat.isStreaming, "error must clear streaming")
        XCTAssertEqual(chat.lastError, "turn exploded")
        XCTAssertNil(chat.activeToolName)
        let last = try XCTUnwrap(chat.messages.last)
        XCTAssertFalse(last.isStreaming)
        XCTAssertEqual(last.warning, "turn exploded")
    }

    // MARK: - Item 2: clarify request_id round-trip

    func testClarifyRequestIdDecodes() {
        // _block injects request_id into every clarify frame (server.py:1117).
        let payload: JSONValue = .object([
            "question": .string("Which file?"),
            "choices": .array([.string("a.txt"), .string("b.txt")]),
            "request_id": .string("ab12cd34"),
        ])
        let request = ClarifyRequestPayload(payload: payload)
        XCTAssertEqual(request.requestId, "ab12cd34")
        XCTAssertEqual(request.question, "Which file?")
        XCTAssertEqual(request.choices, ["a.txt", "b.txt"])
    }

    func testClarifyMissingRequestIdNormalizesToNil() {
        let request = ClarifyRequestPayload(payload: .object([
            "question": .string("q"), "request_id": .string("")]))
        XCTAssertNil(request.requestId)
    }

    // MARK: - Item 5: message.complete status + final reasoning

    func testMessageCompleteAppliesFinalReasoningAndErrorStatus() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "reasoning.delta", payload: .object(["text": .string("partial think")])))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "text": .string("answer"),
            "status": .string("interrupted"),
            "reasoning": .string("the full settled reasoning"),
        ])))
        await waitUntil { chat.messages.last?.thinking == "the full settled reasoning" }
        let last = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(last.thinking, "the full settled reasoning",
                       "final reasoning replaces streamed deltas")
        XCTAssertNotNil(last.reasoningElapsed,
                        "reasoning duration is captured from the active turn before turnStartedAt is cleared")
        XCTAssertEqual(last.warning, "Turn interrupted")
        XCTAssertFalse(chat.isStreaming)
        XCTAssertNil(chat.turnStartedAt, "completion clears the active turn source after stamping the message")
    }

    func testMessageCompleteUsesStructuredProviderError() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "status": .string("error"),
            "error": .string("HTTP 503: all accounts at capacity"),
            "recoverable": .bool(true),
        ])))

        await waitUntil { chat.isStreaming == false }
        let last = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(last.warning, "HTTP 503: all accounts at capacity")
        XCTAssertNotEqual(last.warning, "Turn error")
    }

    func testInflightTurnDecodesTerminalFailureFields() throws {
        let payload: JSONValue = .object([
            "user": .string("draft the follow-up"),
            "assistant": .string(""),
            "streaming": .bool(false),
            "turn_id": .string("turn-provider-failure"),
            "started_at": .number(123.5),
            "status": .string("failed"),
            "error": .string("HTTP 503: all accounts at capacity"),
            "recoverable": .bool(true),
        ])

        let inflight = try XCTUnwrap(payload.decoded(as: SessionInflightTurn.self))
        XCTAssertEqual(inflight.status, "failed")
        XCTAssertEqual(inflight.turnId, "turn-provider-failure")
        XCTAssertEqual(inflight.startedAt, 123.5)
        XCTAssertEqual(inflight.error, "HTTP 503: all accounts at capacity")
        XCTAssertEqual(inflight.recoverable, true)
    }

    func testCanonicalUserRowDecodesHermesTurnIdentity() throws {
        let message = try XCTUnwrap(StoredMessage(json: .object([
            "role": .string("user"),
            "content": .string("draft the follow-up"),
            "display_metadata": .object([
                "hermes_turn_id": .string("turn-provider-failure"),
            ]),
        ])))

        XCTAssertEqual(message.turnID, "turn-provider-failure")
    }

    // MARK: - Item 6: approval payload surfaces the real command

    func testApprovalPayloadSurfacesCommandAndDerivesTitle() {
        // tools/approval.py request dict: {command, pattern_key, description} —
        // there is NO `title` key on the live wire.
        let payload: JSONValue = .object([
            "command": .string("rm -rf build/"),
            "pattern_key": .string("recursive delete"),
            "description": .string("Delete the build directory"),
            "request_id": .string("ff00aa11"),
        ])
        let request = ApprovalRequestPayload(payload: payload)
        XCTAssertEqual(request.command, "rm -rf build/")
        XCTAssertEqual(request.patternKey, "recursive delete")
        XCTAssertEqual(request.title, "rm -rf build/",
                       "title falls back to the real command, not a generic label")
        XCTAssertEqual(request.descriptionText, "Delete the build directory")
    }

    func testApprovalExplicitTitleStillWins() {
        let request = ApprovalRequestPayload(payload: .object([
            "title": .string("Custom title"), "command": .string("ls")]))
        XCTAssertEqual(request.title, "Custom title")
    }

    func testApprovalNoFieldsFallsBackToGeneric() {
        let request = ApprovalRequestPayload(payload: .object([:]))
        XCTAssertEqual(request.title, "Approval required")
        XCTAssertNil(request.command)
    }

    // MARK: - Item 7: resume `resumed` fallback as stored session id

    func testSessionOpenResultFallsBackToResumed() throws {
        // session.resume returns the stored/target id under `resumed`
        // (server.py:3241), NOT `stored_session_id`.
        let json: JSONValue = .object([
            "session_id": .string("rt1"),
            "resumed": .string("20260606_010203_abcdef"),
            "message_count": .number(4),
        ])
        let result = try XCTUnwrap(json.decoded(as: SessionOpenResult.self))
        XCTAssertEqual(result.sessionId, "rt1")
        XCTAssertEqual(result.storedSessionId, "20260606_010203_abcdef")
        XCTAssertEqual(result.messageCount, 4)
    }

    func testSessionOpenResultPrefersExplicitStoredId() throws {
        let json: JSONValue = .object([
            "session_id": .string("rt1"),
            "stored_session_id": .string("stored-explicit"),
            "resumed": .string("stored-fallback"),
        ])
        let result = try XCTUnwrap(json.decoded(as: SessionOpenResult.self))
        XCTAssertEqual(result.storedSessionId, "stored-explicit")
    }

    func testSessionOpenResultDecodesStockHistoryAndSessionKey() throws {
        let json: JSONValue = .object([
            "session_id": .string("runtime-stock"),
            "session_key": .string("stored-stock"),
            "messages": .array([
                .object(["role": .string("user"), "content": .string("hello")]),
                .object(["role": .string("assistant"), "content": .string("hi")]),
            ]),
            "queued": .array([.object(["text": .string("later")])]),
        ])
        let result = try XCTUnwrap(json.decoded(as: SessionOpenResult.self))
        XCTAssertEqual(result.storedSessionId, "stored-stock")
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.messages.first?.role, "user")
        XCTAssertEqual(result.queued.count, 1)
    }

    func testSessionActiveListDecodesStructuredStockShape() throws {
        let json: JSONValue = .object([
            "sessions": .array([
                .object([
                    "id": .string("runtime-watch"),
                    "session_key": .string("stored-watch"),
                    "status": .string("working"),
                    "model": .string("review-model"),
                ]),
            ]),
        ])
        let result = try XCTUnwrap(json.decoded(as: SessionActiveListResult.self))
        XCTAssertEqual(result.sessions, [
            SessionActiveItem(
                id: "runtime-watch", sessionKey: "stored-watch", status: .working,
                model: "review-model"
            )
        ])
    }

    func testGatewayReadyAdvertisesStockWatchCapability() {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)

        XCTAssertEqual(connection.botModeCapability, .unknown)

        connection.applyGatewayReadyCapabilities(.object([
            "capabilities": .array([
                .string("session_watch_v1"),
                .string("session_action_authority_v1"),
                .string("future_contract_v2"),
            ]),
        ]))

        XCTAssertTrue(connection.supportsGatewayCapability("session_watch_v1"))
        XCTAssertTrue(connection.supportsGatewayCapability("session_action_authority_v1"))
        XCTAssertFalse(connection.supportsGatewayCapability("missing_contract_v1"))
        XCTAssertEqual(connection.botModeCapability, .unavailable)

        connection.applyGatewayReadyCapabilities(.object([:]))
        XCTAssertFalse(connection.supportsGatewayCapability("session_watch_v1"))
        XCTAssertEqual(connection.gatewayCapabilityState("session_watch_v1"), .unavailable)

        connection.applyGatewayReadyCapabilities(.object([
            "capabilities": .array([.string("profiles_bot_chat_v1")]),
        ]))
        XCTAssertEqual(connection.botModeCapability, .available)
    }

    func testWatchedPromptExplicitlyTakesOverBeforeDriving() async throws {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        connection.applyGatewayReadyCapabilities(.object([
            "capabilities": .array([.string("session_action_authority_v1")]),
        ]))
        sessions.transcriptFetch = { _ in [] }
        sessions.watchRPC = { _ in
            JSONValue.object([
                "session_id": .string("runtime-desktop"),
                "session_key": .string("stored-desktop"),
                "messages": .array([]),
                "action_revision": .number(4),
            ]).decoded(as: SessionOpenResult.self)!
        }
        sessions.resumeRPC = { _, _ in
            XCTFail("watch snapshot must not resume the runtime")
            throw GatewayError.notConnected
        }
        var takeoverRuntime: String?
        sessions.takeoverRPC = { runtimeID in takeoverRuntime = runtimeID }
        sessions.open(SessionSummary(
            id: "stored-desktop", title: "Desktop", preview: nil,
            startedAt: 1, messageCount: 1, source: nil, lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()

        _ = try await sessions.beginPromptSubmission(runtimeID: "runtime-desktop")

        XCTAssertEqual(takeoverRuntime, "runtime-desktop")
        XCTAssertEqual(sessions.sessionBinding?.mode, .drive)
    }

    func testTakeoverLandingAfterNavigationCannotRebindOldSession() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        connection.applyGatewayReadyCapabilities(.object([
            "capabilities": .array([.string("session_action_authority_v1")]),
        ]))
        sessions.transcriptFetch = { _ in [] }
        sessions.watchRPC = { _ in
            JSONValue.object([
                "session_id": .string("runtime-desktop"),
                "session_key": .string("stored-desktop"),
                "messages": .array([]),
                "action_revision": .number(4),
            ]).decoded(as: SessionOpenResult.self)!
        }
        sessions.resumeRPC = { _, _ in
            XCTFail("watch snapshot must not resume the runtime")
            throw GatewayError.notConnected
        }
        let takeoverStarted = expectation(description: "takeover started")
        sessions.takeoverRPC = { _ in
            takeoverStarted.fulfill()
            try await Task.sleep(for: .milliseconds(50))
        }
        sessions.open(SessionSummary(
            id: "stored-desktop", title: "Desktop", preview: nil,
            startedAt: 1, messageCount: 1, source: nil, lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()

        let takeover = Task {
            try await sessions.beginPromptSubmission(runtimeID: "runtime-desktop")
        }
        await fulfillment(of: [takeoverStarted], timeout: 1)
        sessions.startDraft()

        do {
            _ = try await takeover.value
            XCTFail("stale takeover must be cancelled after navigation")
        } catch is CancellationError {
            XCTAssertTrue(sessions.isDraft)
            XCTAssertNil(sessions.activeRuntimeId)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPassiveOpenWatchesLiveSessionWithoutResume() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        sessions.activeListRPC = {
            SessionActiveListResult(sessions: [
                SessionActiveItem(
                    id: "runtime-desktop", sessionKey: "stored-desktop", status: .working,
                    model: "watch-model"
                )
            ])
        }
        var resumeCalls = 0
        sessions.resumeRPC = { _, _ in
            resumeCalls += 1
            return JSONValue.object([
                "session_id": .string("must-not-resume"),
                "resumed": .string("stored-desktop"),
            ]).decoded(as: SessionOpenResult.self)!
        }

        sessions.open(SessionSummary(
            id: "stored-desktop", title: "Desktop", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(resumeCalls, 0)
        XCTAssertEqual(sessions.sessionBinding?.storedID, "stored-desktop")
        XCTAssertEqual(sessions.sessionBinding?.runtimeID, "runtime-desktop")
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)
        XCTAssertEqual(connection.sessionModelRaw, "watch-model")
        XCTAssertTrue(chat.isStreaming, "a stock active-list working status must restore the live Stop state immediately")
        XCTAssertFalse(chat.localTurnInFlight)
        XCTAssertEqual(chat.interruptTarget, "runtime-desktop")

        chat.handle(event: GatewayEvent(params: .object([
            "type": .string("message.start"),
            "session_id": .string("runtime-desktop"),
            "stored_session_id": .string("stored-desktop"),
            "payload": .object([:]),
        ]))!)
        XCTAssertTrue(chat.isStreaming, "a repeated live start must preserve the adopted watch")
        XCTAssertEqual(chat.interruptTarget, "runtime-desktop")
        XCTAssertFalse(chat.localTurnInFlight)
    }

    func testStoredSessionListPreservesItsActualModelIdentity() throws {
        let json = JSONValue.object([
            "id": .string("stored-model"),
            "title": .string("Model truth"),
            "model": .string("qwen3.8-max"),
            "billing_provider": .string("openrouter"),
        ])

        let summary = try XCTUnwrap(json.decoded(as: SessionSummary.self))
        XCTAssertEqual(summary.model, "qwen3.8-max")
        XCTAssertEqual(summary.billingProvider, "openrouter")
    }

    func testStockActiveStatusesMapToRunningWithoutNewVocabulary() {
        XCTAssertFalse(SessionActiveItem.Status.idle.isRunning)
        XCTAssertTrue(SessionActiveItem.Status.starting.isRunning)
        XCTAssertTrue(SessionActiveItem.Status.waiting.isRunning)
        XCTAssertTrue(SessionActiveItem.Status.working.isRunning)
    }

    func testStockActiveStatusesMapToDrawerPresentation() {
        XCTAssertEqual(DrawerSessionStatus(stockStatus: .idle), .idle)
        XCTAssertEqual(DrawerSessionStatus(stockStatus: .starting), .starting)
        XCTAssertEqual(DrawerSessionStatus(stockStatus: .working), .working)
        XCTAssertEqual(DrawerSessionStatus(stockStatus: .waiting), .needsAttention)
        XCTAssertEqual(DrawerSessionStatus.needsAttention.accessibilityLabel, "Needs attention")
    }

    func testDrawerStatusRefreshUsesNativeActiveListInventory() async {
        let sessions = SessionStore()
        let working = SessionSummary(
            id: "stored-working", title: "Working", preview: nil,
            startedAt: 1, messageCount: 2, source: "desktop",
            lastActive: 1, cwd: nil
        )
        let waiting = SessionSummary(
            id: "stored-waiting", title: "Waiting", preview: nil,
            startedAt: 1, messageCount: 2, source: "desktop",
            lastActive: 1, cwd: nil
        )
        sessions.sessions = [working, waiting]
        sessions.activeListRPC = {
            SessionActiveListResult(sessions: [
                SessionActiveItem(
                    id: "runtime-working", sessionKey: "stored-working",
                    status: .working, model: nil
                ),
                SessionActiveItem(
                    id: "runtime-waiting", sessionKey: "stored-waiting",
                    status: .waiting, model: nil
                ),
            ])
        }

        await sessions.refreshDrawerLiveStatuses()

        XCTAssertEqual(sessions.drawerStatus(for: working), .working)
        XCTAssertEqual(sessions.drawerStatus(for: waiting), .needsAttention)
    }

    func testRepeatedStockWatchSnapshotGrowsSameAssistantRow() async {
        let (chat, _) = makeStore()
        let first = SessionInflightTurn(
            user: "build the feature", assistant: "working", streaming: true
        )
        let second = SessionInflightTurn(
            user: "build the feature", assistant: "working on it", streaming: true
        )

        await chat.reconcileLiveTurnStatus(
            runtimeId: activeRuntime,
            snapshotRunning: true,
            inflight: first,
            watchOnly: true
        )
        let assistantID = try? XCTUnwrap(chat.messages.last?.id)

        await chat.reconcileLiveTurnStatus(
            runtimeId: activeRuntime,
            snapshotRunning: true,
            inflight: second,
            watchOnly: true
        )

        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(chat.messages.last?.id, assistantID)
        XCTAssertEqual(chat.messages.last?.text, "working on it")
        XCTAssertTrue(chat.messages.last?.isStreaming == true)
        XCTAssertFalse(chat.localTurnInFlight)
    }

    func testPassiveOpenUsesStockWatchSnapshotWithoutResume() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        sessions.watchRPC = { storedID in
            XCTAssertEqual(storedID, "stored-desktop")
            return JSONValue.object([
                "session_id": .string("runtime-desktop"),
                "session_key": .string("stored-desktop"),
                "running": .bool(true),
                "status": .string("working"),
                "inflight": .object([
                    "user": .string("build the feature"),
                    "assistant": .string("working on it"),
                    "streaming": .bool(true),
                ]),
                "messages": .array([]),
                "info": .object(["model": .string("watch-model")]),
            ]).decoded(as: SessionOpenResult.self)!
        }
        sessions.activeListRPC = {
            XCTFail("versioned stock watch must avoid the legacy inventory probe")
            return SessionActiveListResult(sessions: [])
        }
        var resumeCalls = 0
        sessions.resumeRPC = { _, _ in
            resumeCalls += 1
            return JSONValue.object([
                "session_id": .string("must-not-resume"),
                "resumed": .string("stored-desktop"),
            ]).decoded(as: SessionOpenResult.self)!
        }

        sessions.open(SessionSummary(
            id: "stored-desktop", title: "Desktop", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(resumeCalls, 0)
        XCTAssertEqual(sessions.sessionBinding?.runtimeID, "runtime-desktop")
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)
        XCTAssertEqual(connection.sessionModelRaw, "watch-model")
        XCTAssertTrue(chat.isStreaming)
        XCTAssertFalse(chat.localTurnInFlight)
        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.messages.first?.text, "build the feature")
        XCTAssertEqual(chat.messages.last?.text, "working on it")
    }

    func testStockWatchRefreshSettlesFromCanonicalTranscriptWithoutTakeover() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        chat.backfillFetch = { _ in [
            StoredMessage(role: "user", content: .string("build the feature")),
            StoredMessage(role: "assistant", content: .string("finished")),
        ] }
        var watchCalls = 0
        sessions.watchRPC = { _ in
            watchCalls += 1
            let running = watchCalls == 1
            return JSONValue.object([
                "session_id": .string("runtime-desktop"),
                "session_key": .string("stored-desktop"),
                "running": .bool(running),
                "status": .string(running ? "working" : "idle"),
                "inflight": running ? .object([
                    "user": .string("build the feature"),
                    "assistant": .string("working on it"),
                    "streaming": .bool(true),
                ]) : .null,
                "messages": .array([]),
            ]).decoded(as: SessionOpenResult.self)!
        }
        sessions.resumeRPC = { _, _ in
            XCTFail("watch refresh must not resume or rebind the session")
            throw GatewayError.notConnected
        }

        sessions.open(SessionSummary(
            id: "stored-desktop", title: "Desktop", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()
        XCTAssertTrue(chat.isStreaming)

        let continued = await sessions.refreshWatchedSessionOnce(
            storedID: "stored-desktop", runtimeID: "runtime-desktop"
        )

        XCTAssertTrue(continued)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertFalse(chat.localTurnInFlight)
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)
        XCTAssertEqual(chat.messages.last?.text, "finished")
        await sessions.closeActive()
    }

    func testStockWatchRefreshRestoresRetainedTerminalFailureWhenIdle() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        var watchCalls = 0
        sessions.watchRPC = { _ in
            watchCalls += 1
            let running = watchCalls == 1
            return JSONValue.object([
                "session_id": .string("runtime-desktop"),
                "session_key": .string("stored-desktop"),
                "running": .bool(running),
                "status": .string(running ? "working" : "error"),
                "inflight": .object([
                    "user": .string("build the feature"),
                    "assistant": .string(""),
                    "streaming": .bool(running),
                    "status": .string(running ? "working" : "failed"),
                    "error": running
                        ? .null
                        : .string("HTTP 503: all accounts at capacity"),
                    "recoverable": .bool(!running),
                ]),
                "messages": .array([]),
            ]).decoded(as: SessionOpenResult.self)!
        }
        sessions.resumeRPC = { _, _ in
            XCTFail("watch refresh must not resume or rebind the session")
            throw GatewayError.notConnected
        }

        sessions.open(SessionSummary(
            id: "stored-desktop", title: "Desktop", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()
        XCTAssertTrue(chat.isStreaming)

        let continued = await sessions.refreshWatchedSessionOnce(
            storedID: "stored-desktop", runtimeID: "runtime-desktop"
        )

        XCTAssertTrue(continued)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.messages.last?.warning, "HTTP 503: all accounts at capacity")
        XCTAssertEqual(chat.lastError, "HTTP 503: all accounts at capacity")
        await sessions.closeActive()
    }

    func testAbsentStockWatchSettlesAndRefreshesCanonicalRail() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        let selected = SessionSummary(
            id: "stored-desktop", title: "Desktop", preview: "working",
            startedAt: 1, messageCount: 2, source: "desktop",
            lastActive: 1, cwd: nil
        )
        sessions.sessions = [selected]
        sessions.transcriptFetch = { _ in [] }
        chat.backfillFetch = { _ in [
            StoredMessage(role: "user", content: .string("build the feature")),
            StoredMessage(role: "assistant", content: .string("finished")),
        ] }
        var watchCalls = 0
        sessions.watchRPC = { _ in
            watchCalls += 1
            if watchCalls > 1 {
                throw GatewayError.rpc(code: 4001, message: "session not found")
            }
            return JSONValue.object([
                "session_id": .string("runtime-desktop"),
                "session_key": .string("stored-desktop"),
                "running": .bool(true),
                "status": .string("working"),
                "inflight": .object([
                    "user": .string("build the feature"),
                    "assistant": .string("working"),
                    "streaming": .bool(true),
                ]),
                "messages": .array([]),
            ]).decoded(as: SessionOpenResult.self)!
        }
        sessions.resumeRPC = { _, _ in
            XCTFail("watch snapshot must not resume the runtime")
            throw GatewayError.notConnected
        }
        var railRefreshes = 0
        sessions.sessionsFetch = {
            railRefreshes += 1
            return ([SessionSummary(
                id: "stored-desktop", title: "Desktop", preview: "finished",
                startedAt: 1, messageCount: 3, source: "desktop",
                lastActive: 2, cwd: nil
            )], 1)
        }

        sessions.open(selected)
        await sessions.waitForPendingOpenForTesting()
        XCTAssertTrue(chat.isStreaming)

        _ = await sessions.refreshWatchedSessionOnce(
            storedID: "stored-desktop", runtimeID: "runtime-desktop"
        )

        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.messages.last?.text, "finished")
        XCTAssertEqual(railRefreshes, 1)
        XCTAssertEqual(sessions.sessions.first?.preview, "finished")
        await sessions.closeActive()
    }

    func testPassiveOpenOfIdleSessionDoesNotResume() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        sessions.activeListRPC = { SessionActiveListResult(sessions: []) }
        var resumeCalls = 0
        sessions.resumeRPC = { _, _ in
            resumeCalls += 1
            return JSONValue.object([
                "session_id": .string("runtime-phone"),
                "session_key": .string("stored-idle"),
                "messages": .array([]),
            ]).decoded(as: SessionOpenResult.self)!
        }

        sessions.open(SessionSummary(
            id: "stored-idle", title: "Idle", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil,
            model: "stored-model", billingProvider: "openrouter"
        ))
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(resumeCalls, 0)
        XCTAssertEqual(sessions.sessionBinding?.storedID, "stored-idle")
        XCTAssertNil(sessions.sessionBinding?.runtimeID)
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)
        XCTAssertNil(sessions.sessionBinding?.generation)
        XCTAssertEqual(connection.sessionModelRaw, "stored-model")
        XCTAssertNil(
            connection.sessionProvider,
            "billing_provider is accounting metadata, not runtime provider truth"
        )
        XCTAssertFalse(chat.isStreaming)

        let runtime = await sessions.ensureActiveRuntime()
        XCTAssertEqual(resumeCalls, 1, "the first drive action owns the resume edge")
        XCTAssertEqual(runtime, "runtime-phone")
        XCTAssertEqual(sessions.sessionBinding?.mode, .drive)
    }

    func testReconnectToWorkingStockSessionRestoresWatchState() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        sessions.resumeRPC = { _, _ in
            XCTFail("an already-live session must stay on the read-only watch path")
            throw GatewayError.notConnected
        }
        sessions.activeListRPC = {
            SessionActiveListResult(sessions: [
                SessionActiveItem(
                    id: "runtime-working",
                    sessionKey: "stored-working",
                    status: .working,
                    model: "gpt-5.6-sol"
                ),
            ])
        }

        sessions.open(SessionSummary(
            id: "stored-working", title: "Working", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil,
            model: "gpt-5.6-sol", billingProvider: "openai-codex"
        ))
        await sessions.waitForPendingOpenForTesting()
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)

        chat.handleConnectionDrop()
        sessions.transportDidBecomeUnavailable()
        XCTAssertFalse(chat.isStreaming)
        XCTAssertNil(sessions.activeRuntimeId)

        let runtime = await sessions.resumeActiveAfterReconnect()

        XCTAssertEqual(runtime, "runtime-working")
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(chat.interruptTarget, "runtime-working")
    }

    func testVisibleIdleSessionObservesWorkingStateFromActiveList() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        var isWorking = false
        sessions.activeListRPC = {
            SessionActiveListResult(sessions: isWorking ? [
                SessionActiveItem(
                    id: "runtime-foreign",
                    sessionKey: "stored-visible",
                    status: .working,
                    model: "gpt-5.6-sol"
                ),
            ] : [])
        }
        sessions.resumeRPC = { _, _ in
            XCTFail("foreground observation must never resume or steal an idle session")
            throw GatewayError.notConnected
        }
        sessions.open(SessionSummary(
            id: "stored-visible", title: "Visible", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil,
            model: "gpt-5.6-sol", billingProvider: nil
        ))
        await sessions.waitForPendingOpenForTesting()
        XCTAssertFalse(chat.isStreaming)

        isWorking = true
        await sessions.reconcileVisibleLiveStatus()

        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)
        XCTAssertEqual(chat.interruptTarget, "runtime-foreign")
    }

    func testWatchOnlyWorkingSettlesOnceWhenActiveListBecomesIdle() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        var status: SessionActiveItem.Status = .working
        var historyCalls = 0
        sessions.activeListRPC = {
            SessionActiveListResult(sessions: [
                SessionActiveItem(
                    id: self.activeRuntime,
                    sessionKey: self.storedId,
                    status: status,
                    model: nil
                )
            ])
        }
        sessions.resumeRPC = { _, _ in
            XCTFail("watch-only observation must never resume or steal the session")
            throw GatewayError.notConnected
        }
        chat.backfillFetch = { _ in
            historyCalls += 1
            return [
                StoredMessage(role: "user", content: .string("desktop prompt")),
                StoredMessage(role: "assistant", content: .string("desktop reply")),
            ]
        }

        sessions.open(SessionSummary(
            id: storedId, title: "Watched", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)

        status = .idle
        await sessions.reconcileVisibleLiveStatus()
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(historyCalls, 1)
        XCTAssertTrue(chat.messages.contains { $0.text == "desktop reply" })

        await sessions.reconcileVisibleLiveStatus()
        XCTAssertEqual(historyCalls, 1, "the running-to-idle edge refreshes exactly once")
    }

    func testLocalWorkingSettlesWhenActiveListBecomesIdle() async {
        let (chat, sessions) = makeStore()
        _ = try? await sessions.beginPromptSubmission(runtimeID: activeRuntime)
        var status: SessionActiveItem.Status = .working
        var historyCalls = 0
        sessions.activeListRPC = {
            SessionActiveListResult(sessions: [
                SessionActiveItem(
                    id: self.activeRuntime,
                    sessionKey: self.storedId,
                    status: status,
                    model: nil
                )
            ])
        }
        chat.backfillFetch = { _ in
            historyCalls += 1
            return [
                StoredMessage(role: "user", content: .string("phone prompt")),
                StoredMessage(role: "assistant", content: .string("phone reply")),
            ]
        }
        chat.handle(event: localFrame(type: "message.start"))
        XCTAssertTrue(chat.localTurnInFlight)
        XCTAssertTrue(chat.isStreaming)

        status = .idle
        await sessions.reconcileVisibleLiveStatus()

        XCTAssertFalse(chat.isStreaming)
        XCTAssertFalse(chat.localTurnInFlight)
        XCTAssertEqual(historyCalls, 1)
        XCTAssertTrue(chat.messages.contains { $0.text == "phone reply" })

        await sessions.reconcileVisibleLiveStatus()
        XCTAssertEqual(historyCalls, 1, "idle polling must settle once")
    }

    func testSilentLocalTurnPreservesWorkingStockSessionWithoutHistoryFetch() async {
        let (chat, sessions) = makeStore()
        var activeListCalls = 0
        var historyCalls = 0
        sessions.activeListRPC = {
            activeListCalls += 1
            return SessionActiveListResult(sessions: [
                SessionActiveItem(
                    id: self.activeRuntime,
                    sessionKey: self.storedId,
                    status: .working,
                    model: nil
                )
            ])
        }
        chat.backfillFetch = { _ in
            historyCalls += 1
            return []
        }
        chat.messages = [ChatMessage(role: .user, text: "keep working")]
        chat.handle(event: localFrame(type: "message.start"))

        XCTAssertTrue(chat._debugFireTurnLivenessResync())
        await waitUntil { activeListCalls == 1 }

        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(historyCalls, 0)
    }

    func testSilentIdleLocalTurnFetchesHistoryOnceAndSettlesReply() async {
        let (chat, sessions) = makeStore()
        var activeListCalls = 0
        var historyCalls = 0
        sessions.activeListRPC = {
            activeListCalls += 1
            return SessionActiveListResult(sessions: [
                SessionActiveItem(
                    id: self.activeRuntime,
                    sessionKey: self.storedId,
                    status: .idle,
                    model: nil
                )
            ])
        }
        chat.backfillFetch = { _ in
            historyCalls += 1
            return [
                StoredMessage(role: "user", content: .string("recover me")),
                StoredMessage(role: "assistant", content: .string("recovered reply")),
            ]
        }
        chat.messages = [ChatMessage(role: .user, text: "recover me")]
        chat.handle(event: localFrame(type: "message.start"))

        XCTAssertTrue(chat._debugFireTurnLivenessResync())
        XCTAssertFalse(chat._debugFireTurnLivenessResync(), "stage 1 is latched once per turn")
        await waitUntil { !chat.isStreaming }

        XCTAssertEqual(activeListCalls, 1)
        XCTAssertEqual(historyCalls, 1)
        XCTAssertEqual(chat.messages.last?.text, "recovered reply")
        XCTAssertFalse(chat.localTurnInFlight)
    }

    // MARK: - Item 9: subagent failed/interrupted → error

    func testSubagentTerminalStatusMapping() {
        XCTAssertEqual(SubagentNode.Status(completionStatus: "failed"), .error)
        XCTAssertEqual(SubagentNode.Status(completionStatus: "interrupted"), .error)
        XCTAssertEqual(SubagentNode.Status(completionStatus: "error"), .error)
        XCTAssertEqual(SubagentNode.Status(completionStatus: "timeout"), .timeout)
        XCTAssertEqual(SubagentNode.Status(completionStatus: "completed"), .completed)
        XCTAssertEqual(SubagentNode.Status(completionStatus: nil), .completed)
    }

    // MARK: - Desktop-style assistant parts

    func testAssistantPartsPreserveTextToolTextOrder() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta",
            payload: .object(["text": .string("Before tool. ")])))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t-order"),
            "name": .string("shell"),
        ])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t-order"),
            "name": .string("shell"),
            "result": .object(["output": .string("ok")]),
            "duration_s": .number(0.1),
        ])))
        chat.handle(event: localFrame(
            type: "message.delta",
            payload: .object(["text": .string("After tool.")])))

        await waitUntil { (chat.messages.last?.parts.count ?? 0) == 3 }

        let message = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(message.text, "Before tool. After tool.")
        XCTAssertEqual(message.tools.count, 1)
        let parts = message.parts
        XCTAssertEqual(parts.count, 3)
        guard parts.count == 3 else { return }
        guard case .text(_, let firstText) = parts[0] else {
            return XCTFail("expected leading text part")
        }
        XCTAssertEqual(firstText, "Before tool. ")
        guard case .tools(_, let tools, _, _) = parts[1] else {
            return XCTFail("expected middle tool part")
        }
        XCTAssertEqual(tools.first?.id, "t-order")
        guard case .text(_, let secondText) = parts[2] else {
            return XCTFail("expected trailing text part")
        }
        XCTAssertEqual(secondText, "After tool.")
    }

    // MARK: - Parts adoption review fixes (#1–#5, #7)

    /// Review #7(c): `message.complete` carrying authoritative
    /// text/reasoning/warning/usage must keep the LEGACY fields and the ordered
    /// PARTS in sync — the whole point of the dual-representation model.
    func testMessageCompleteKeepsLegacyFieldsAndPartsInSync() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("partial ")])))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "text": .string("partial answer"),
            "reasoning": .string("settled reasoning"),
            "warning": .string("heads up"),
            "usage": .object(["input_tokens": .number(10), "output_tokens": .number(5)]),
        ])))
        await waitUntil { chat.messages.last?.text == "partial answer" }

        let message = try XCTUnwrap(chat.messages.last)
        // Legacy fields.
        XCTAssertEqual(message.text, "partial answer")
        XCTAssertEqual(message.thinking, "settled reasoning")
        XCTAssertEqual(message.warning, "heads up")
        XCTAssertNotNil(message.usage)
        // Ordered parts mirror them — and exactly once each (no double-emit).
        let parts = message.parts
        XCTAssertEqual(parts.filter { if case .warning = $0 { return true }; return false }.count, 1,
                       "exactly one warning part")
        XCTAssertEqual(parts.filter { if case .usage = $0 { return true }; return false }.count, 1,
                       "exactly one usage part")
        let textParts = parts.compactMap { part -> String? in
            if case .text(_, let t) = part { return t }; return nil
        }
        XCTAssertEqual(textParts.joined(), "partial answer", "settled text reflected in parts")
        let reasoningParts = parts.compactMap { part -> String? in
            if case .reasoning(_, let t) = part { return t }; return nil
        }
        XCTAssertEqual(reasoningParts.joined(), "settled reasoning", "settled reasoning reflected in parts")
    }

    /// Review #1 + #7(d): a connection drop mid-stream on a turn that already
    /// accumulated ordered parts must land "Connection lost" as an in-order
    /// `.warning` PART (via `setWarningPart`), not just the legacy field.
    func testConnectionDropWarningRendersAsOrderedPart() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("half a reply")])))
        await waitUntil { chat.isStreaming }
        XCTAssertTrue(chat.isStreaming)

        chat.handleConnectionDrop()

        let message = try XCTUnwrap(chat.messages.last)
        XCTAssertFalse(message.isStreaming)
        XCTAssertEqual(message.warning, "Connection lost")
        // The warning is a real ordered part now — the part list is not silently
        // inconsistent with the legacy field (review fix #1).
        XCTAssertTrue(message.parts.contains { if case .warning(_, let t) = $0 { return t == "Connection lost" }; return false },
                      "Connection lost must be an ordered .warning part")
        // parts must not double-emit it.
        let warningCount = message.parts.filter {
            if case .warning = $0 { return true }; return false
        }.count
        XCTAssertEqual(warningCount, 1, "warning rendered exactly once")
    }

    /// ABH-87 Batch D / §3.2 (fixes D8): a turn with text-interleaved single-tool
    /// clusters (text→toolA→text→toolB) collapses PER-CLUSTER, not on the turn
    /// total. Each cluster has only ONE tool, so NEITHER collapses — the turn
    /// shows two lone tool rows, never two "1 tool call" capsules. The derived
    /// `toolsCollapsed` (true iff ANY cluster collapsed) is therefore FALSE here.
    ///
    /// (Supersedes the pre-Batch-D `testInterleavedToolClustersCollapseConsistently`,
    /// which asserted the turn-total collapse-all behavior the contract names as
    /// the D8 defect.)
    func testInterleavedSingleToolClustersDoNotCollapse() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("A ")])))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("c1"), "name": .string("shell")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("c1"), "name": .string("shell"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("B ")])))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("c2"), "name": .string("grep")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("c2"), "name": .string("grep"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "text": .string("A B done")])))
        await waitUntil { (chat.messages.last?.tools.count ?? 0) == 2 }

        let message = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(message.tools.count, 2, "two tools total across two clusters")
        let toolClusters = message.parts.compactMap { part -> Bool? in
            if case .tools(_, _, let collapsed, _) = part { return collapsed }; return nil
        }
        XCTAssertEqual(toolClusters.count, 2, "interleaving yields two single-tool clusters")
        XCTAssertTrue(toolClusters.allSatisfy { $0 == false },
                      "neither single-tool cluster collapses (per-cluster decision, §3.2)")
        XCTAssertFalse(message.toolsCollapsed,
                       "derived flag is false: no cluster collapsed")
    }

    /// ABH-87 Batch D / §3.2: consecutive tools with NO prose between them form
    /// ONE cluster of ≥2 tools, which DOES collapse into a single summary. This is
    /// the other half of the per-cluster contract (§4.test item 4): one collapsed
    /// cluster here vs. two un-collapsed single-tool clusters above.
    func testConsecutiveToolsFormOneCollapsedCluster() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        // Two tools back-to-back, no intervening prose → ONE cluster.
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("d1"), "name": .string("shell")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("d1"), "name": .string("shell"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("d2"), "name": .string("grep")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("d2"), "name": .string("grep"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "text": .string("done")])))
        await waitUntil { (chat.messages.last?.tools.count ?? 0) == 2 }

        let message = try XCTUnwrap(chat.messages.last)
        let toolClusters = message.parts.compactMap { part -> (Int, Bool)? in
            if case .tools(_, let tools, let collapsed, _) = part { return (tools.count, collapsed) }
            return nil
        }
        XCTAssertEqual(toolClusters.count, 1, "consecutive tools form a single cluster")
        XCTAssertEqual(toolClusters.first?.0, 2, "the cluster carries both tools")
        XCTAssertEqual(toolClusters.first?.1, true, "a ≥2-tool cluster collapses")
        XCTAssertTrue(message.toolsCollapsed, "derived flag is true: the cluster collapsed")
    }

    /// ABH-87 §2.1: a SEEDED message materializes its scalar seed content into
    /// deterministic `parts` at construction (single source of truth, no parallel
    /// legacy fields, no salvage). Warning/usage appear EXACTLY ONCE and the
    /// derived accessors read back through `parts`.
    func testSeededMessageRendersWithoutDoubleWarningOrUsage() throws {
        // Decode UsageStats from the wire shape rather than coupling to its
        // memberwise init (it is Decodable-only with private storage names).
        let usage = try XCTUnwrap(JSONValue.object([
            "input": .number(3), "output": .number(4), "total": .number(7),
        ]).decoded(as: UsageStats.self))
        let seeded = ChatMessage(
            role: .assistant,
            text: "seeded body",
            usage: usage,
            warning: "seeded warning"
        )
        // Seed content is now materialized into parts at construction time.
        XCTAssertFalse(seeded.parts.isEmpty, "seed content materializes into ordered parts")

        let parts = seeded.parts
        XCTAssertEqual(parts.filter { if case .warning = $0 { return true }; return false }.count, 1,
                       "warning materialized exactly once")
        XCTAssertEqual(parts.filter { if case .usage = $0 { return true }; return false }.count, 1,
                       "usage materialized exactly once")
        // Derived accessors read back through parts.
        XCTAssertEqual(seeded.text, "seeded body")
        XCTAssertEqual(seeded.warning, "seeded warning")
        XCTAssertNotNil(seeded.usage)
    }

    /// Review #4: a reconciled turn that received text→tool but whose authoritative
    /// final text EXTENDS into post-tool prose must keep the new prose AFTER the
    /// tool, not float it above by merging into the pre-tool text part.
    func testApplyFinalTextKeepsPostToolProseAfterTool() {
        var message = ChatMessage(role: .assistant)
        message.appendAssistantTextDelta("Before. ")
        message.upsertToolActivity(ToolActivity(
            id: "t1", name: "shell", argsSummary: "", progressText: "",
            resultPreview: "", state: .done, durationMs: 100, todos: nil))
        // The settled completion carries the full text including the post-tool
        // tail the throttled client never received as a delta.
        message.applyFinalText("Before. After.")

        let order = message.parts.map { part -> String in
            switch part {
            case .text(_, let t): return "text(\(t))"
            case .tools: return "tool"
            default: return "other"
            }
        }
        // text(Before. ) → tool → text(After.) — the tail stays below the tool.
        XCTAssertEqual(order, ["text(Before. )", "tool", "text(After.)"],
                       "post-tool prose must render after the tool, not above it")
        XCTAssertEqual(message.text, "Before. After.")
    }

    // MARK: - Item 10: structured todos retained untruncated

    func testToolCompleteRetainsStructuredTodos() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t1"), "name": .string("todo")])))
        // A list long enough that the 300-char resultPreview truncates — the
        // structured field must survive verbatim regardless.
        let todos: [JSONValue] = (0..<20).map { i in
            .object([
                "id": .string("todo-\(i)"),
                "content": .string("A reasonably long todo item number \(i) with detail"),
                "status": .string(i % 2 == 0 ? "completed" : "pending"),
            ])
        }
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t1"),
            "name": .string("todo"),
            "result": .object(["todos": .array(todos), "summary": .object([:])]),
            "todos": .array(todos),
            "duration_s": .number(0.2),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.todos?.count == 20 }
        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        XCTAssertEqual(tool.todos?.count, 20, "structured todos retained")
        XCTAssertTrue(tool.resultPreview.count <= 300)
        let todosArray = try XCTUnwrap(tool.todos)
        let parsed = try XCTUnwrap(TodoList(todosArray: todosArray))
        XCTAssertEqual(parsed.items.count, 20)
    }

    // MARK: - STR-460: inline diff rendering for file-edit tools

    func testToolCompleteRetainsFullDiffForPatchTool() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t1"), "name": .string("patch")])))
        // Long enough that the 300-char resultPreview truncates the JSON blob —
        // the diff must survive untruncated on `fullDiff` regardless.
        let hunkLines = (0..<20).map { "+added context line number \($0) with enough text to pad" }
        let diff = "┊ review diff\n" + hunkLines.joined(separator: "\n")
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t1"),
            "name": .string("patch"),
            "result": .object(["inline_diff": .string(diff), "message": .string("applied")]),
            "duration_s": .number(0.2),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.state == .done }
        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        let fullDiff = try XCTUnwrap(tool.fullDiff)
        XCTAssertFalse(fullDiff.hasPrefix("┊"), "leading review-diff chrome must be stripped")
        XCTAssertTrue(fullDiff.contains("added context line number 19"), "diff kept untruncated")
        XCTAssertGreaterThan(fullDiff.count, 300)
        XCTAssertTrue(tool.resultPreview.count <= 300, "resultPreview stays truncated/normal")
    }

    func testToolCompleteRetainsFullDiffForWriteFileTool() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t2"), "name": .string("write_file")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t2"),
            "name": .string("write_file"),
            "result": .object(["diff": .string("+new line\n-old line")]),
            "duration_s": .number(0.1),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.state == .done }
        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        XCTAssertEqual(tool.fullDiff, "+new line\n-old line")
    }

    /// Negative: a non-file-edit tool whose result happens to carry a `diff`
    /// key must NOT be treated as a file-edit diff.
    func testToolCompleteIgnoresDiffKeyForNonFileEditTool() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t3"), "name": .string("web_search")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t3"),
            "name": .string("web_search"),
            "result": .object(["diff": .string("+not a real edit diff")]),
            "duration_s": .number(0.1),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.state == .done }
        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        XCTAssertNil(tool.fullDiff, "only patch/write_file/edit_file extract a diff")
    }

    /// STR-463: `resultSummary` must be derived from the FULL `payload.result`,
    /// not the already-truncated `resultPreview`. Here the meaningful
    /// `message` field sorts (alphabetically, per `compactDescription`) after
    /// a long `filler` field that alone exceeds the 300-char preview cutoff —
    /// so `resultPreview` never reaches "message" at all, while
    /// `resultSummary` (built from the untruncated result) must still surface it.
    func testToolCompleteSummaryDerivedFromFullResultBeyondPreviewTruncation() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t-summary"), "name": .string("extract")])))
        let filler = String(repeating: "x", count: 400)
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t-summary"),
            "name": .string("extract"),
            "result": .object([
                "filler": .string(filler),
                "message": .string("archive extracted to /tmp/output"),
            ]),
            "duration_s": .number(0.3),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.state == .done }

        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        XCTAssertTrue(tool.resultPreview.count <= 300, "resultPreview stays truncated")
        XCTAssertFalse(
            tool.resultPreview.contains("archive extracted"),
            "the truncated preview never reaches the message field"
        )
        let summary = try XCTUnwrap(tool.resultSummary, "resultSummary must be derived even when the preview truncates")
        XCTAssertTrue(
            summary.contains("archive extracted to /tmp/output"),
            "resultSummary reads the full untruncated result, not the truncated preview"
        )
    }

    // MARK: - Harness

    /// Poll a @MainActor condition until it holds or `timeout` elapses. Replaces
    /// fixed `Task.sleep(120ms)` waits that race the streaming debounce flush
    /// (~40ms) and flake under heavy parallel-build load: the fix is to wait for
    /// the actual end-state (e.g. "3 parts coalesced") rather than a guessed
    /// duration, so the test is correct by construction regardless of machine
    /// load. Returns as soon as the condition is satisfied; on timeout the
    /// caller's subsequent assertions report the real failure.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(5),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
        }
    }

    private func makeStore() -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = activeRuntime
        sessions.activeStoredId = storedId
        chat.backfillFetch = { _ in [] }
        return (chat, sessions)
    }

    private func localFrame(type: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(activeRuntime),
            "payload": payload,
        ]))!
    }

}
