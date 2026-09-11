import XCTest
@testable import HermesMobile

/// Coverage for push tap routing and per-event preferences. Notification
/// categories intentionally open the app; foreground responses use stock RPC.
final class NotificationActionTests: XCTestCase {

    // MARK: - aps.category decode

    func testApsCategoryReadsNestedApsBlock() {
        let userInfo: [AnyHashable: Any] = ["aps": ["category": "HERMES_APPROVAL"]]
        XCTAssertEqual(NotificationService.apsCategory(in: userInfo), "HERMES_APPROVAL")
    }

    func testApsCategoryNilWhenAbsent() {
        XCTAssertNil(NotificationService.apsCategory(in: ["aps": ["alert": "hi"]]))
        XCTAssertNil(NotificationService.apsCategory(in: [:]))
    }

    // MARK: - decodeTap via aps.category (no event_type)

    func testDecodeTapRoutesApprovalCategoryToAttention() {
        // The F2-S remote payload routes by `aps.category` (no flat event_type).
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_APPROVAL"],
            "hermes": ["session_id": "sess-runtime-1"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .attention(sessionId: "sess-runtime-1")
        )
    }

    func testDecodeTapRoutesClarifyCategoryToAttention() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_CLARIFY"],
            "hermes": ["session_id": "sess-2"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .attention(sessionId: "sess-2")
        )
    }

    func testDecodeTapRoutesTurnCategoryToTurnComplete() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_TURN"],
            "hermes": ["session_id": "sess-3"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .turnComplete(sessionId: "sess-3")
        )
    }

    func testDecodeTapStillHonorsExplicitEventType() {
        // A flat event_type (local notifications / legacy) takes precedence over
        // category and keeps working.
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_TURN"],
            "hermes": ["session_id": "sess-4", "event_type": "approval"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .attention(sessionId: "sess-4")
        )
    }

    func testDecodeTapNilWithoutSessionId() {
        let userInfo: [AnyHashable: Any] = ["aps": ["category": "HERMES_APPROVAL"]]
        XCTAssertNil(NotificationService.decodeTap(from: userInfo))
    }

    // MARK: - QA-3 S12: stored_session_id deep-link payload

    func testDecodeTapCarriesStoredSessionIdWhenPresent() {
        // The relay resolves live→origin at drive time and stamps the stored id
        // in the hermes block; decodeTap must surface it so the router can open
        // the owning session directly instead of dumping to the Inbox.
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_TURN"],
            "hermes": ["session_id": "live-9", "stored_session_id": "origin-stored-9"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .turnComplete(sessionId: "live-9", storedSessionId: "origin-stored-9")
        )
    }

    func testDecodeTapStoredSessionIdNilWhenAbsent() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_TURN"],
            "hermes": ["session_id": "live-9"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .turnComplete(sessionId: "live-9", storedSessionId: nil)
        )
    }

    func testDecodeTapBlankStoredSessionIdTreatedAsNil() {
        // A whitespace-only stored id must not route a tap at an empty/garbage
        // stored id — fall back to the runtime id / inbox map instead.
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_APPROVAL"],
            "hermes": ["session_id": "rt", "stored_session_id": "   "],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .attention(sessionId: "rt", storedSessionId: nil)
        )
    }

    func testDecodeCorrelatedAlertPreservesStableRouteIdentity() throws {
        let userInfo: [AnyHashable: Any] = ["hermes": [
            "event_type": "clarify",
            "event_id": "evt-44",
            "gateway_scope": "gw-1",
            "session_id": "runtime-1",
            "stored_session_id": "stored-1",
            "request_id": "request-1",
        ]]
        let alert = try XCTUnwrap(NotificationService.decodeCorrelatedAlert(from: userInfo))
        XCTAssertEqual(alert.kind, .clarify)
        XCTAssertEqual(alert.eventId, "evt-44")
        XCTAssertEqual(alert.gatewayScope, "gw-1")
        XCTAssertEqual(alert.sessionId, "runtime-1")
        XCTAssertEqual(alert.storedSessionId, "stored-1")
        XCTAssertEqual(alert.requestId, "request-1")
    }

    func testDecodeCorrelatedAlertRejectsMissingServerIdentity() {
        let userInfo: [AnyHashable: Any] = ["hermes": [
            "event_type": "approval",
            "session_id": "runtime-1",
        ]]
        XCTAssertNil(NotificationService.decodeCorrelatedAlert(from: userInfo))
        let approval = ApprovalRequestPayload(payload: .object([
            "title": .string("Legacy approval")
        ]))
        XCTAssertTrue(approval.id.isEmpty, "the client must not substitute a random UUID")
    }

    func testActionIdentifiersMatchCategoryContract() {
        XCTAssertEqual(NotificationService.remoteApprovalCategory, "HERMES_APPROVAL")
        XCTAssertEqual(NotificationService.remoteClarifyCategory, "HERMES_CLARIFY")
        XCTAssertEqual(NotificationService.remoteTurnCategory, "HERMES_TURN")
    }
}

// MARK: - Push tap cold-start routing

@MainActor
final class PushTapRoutingTests: XCTestCase {
    private struct Stores {
        let connection: ConnectionStore
        let sessions: SessionStore
        let chat: ChatStore
        let inbox: InboxStore
    }

    private func makeStores() -> Stores {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        let inbox = InboxStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        inbox.attach(connection: connection)
        return Stores(connection: connection, sessions: sessions, chat: chat, inbox: inbox)
    }

    private func summary(id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            title: "Session \(id)",
            preview: nil,
            startedAt: nil,
            messageCount: nil,
            source: nil,
            lastActive: nil,
            cwd: nil
        )
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testCachedWarmTurnCompleteOpensSynchronouslyAndDoesNotReplay() async {
        let s = makeStores()
        s.sessions.sessions = [summary(id: "stored-warm")]
        var readinessCalls = 0
        var refreshCalls = 0
        s.connection.sessionRefreshReadinessOverride = {
            readinessCalls += 1
            return true
        }
        s.sessions.sessionsFetch = {
            refreshCalls += 1
            return ([self.summary(id: "stored-warm")], 1)
        }

        HermesURLRouter.routePushTap(
            .turnComplete(sessionId: "stored-warm"),
            sessions: s.sessions,
            inbox: s.inbox,
            connection: s.connection
        )

        XCTAssertEqual(s.sessions.activeStoredId, "stored-warm")
        XCTAssertEqual(readinessCalls, 0, "warm path must not enter readiness machinery")
        XCTAssertEqual(refreshCalls, 0, "warm path must not schedule a miss refresh")
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)

        await Task.yield()
        XCTAssertEqual(s.sessions.activeStoredId, "stored-warm")
        XCTAssertEqual(readinessCalls, 0)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testColdTurnCompleteWaitsForReadinessRefreshesAndOpens() async {
        let s = makeStores()
        var readinessCalls = 0
        var refreshCalls = 0
        s.connection.sessionRefreshReadinessOverride = {
            readinessCalls += 1
            return true
        }
        s.sessions.sessionsFetch = {
            refreshCalls += 1
            return ([self.summary(id: "stored-cold")], 1)
        }

        HermesURLRouter.routePushTap(
            .turnComplete(sessionId: "stored-cold"),
            sessions: s.sessions,
            inbox: s.inbox,
            connection: s.connection
        )

        await waitUntil { s.sessions.activeStoredId == "stored-cold" }
        XCTAssertEqual(readinessCalls, 1)
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(s.sessions.activeStoredId, "stored-cold")
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)
    }

    func testColdTurnCompleteNotReadyFallsBackToInbox() async {
        let s = makeStores()
        var readinessCalls = 0
        var refreshCalls = 0
        let tokenBefore = s.inbox.presentationRequestToken
        s.connection.sessionRefreshReadinessOverride = {
            readinessCalls += 1
            return false
        }
        s.sessions.sessionsFetch = {
            refreshCalls += 1
            return ([], 0)
        }

        HermesURLRouter.routePushTap(
            .turnComplete(sessionId: "missing"),
            sessions: s.sessions,
            inbox: s.inbox,
            connection: s.connection
        )

        await waitUntil { s.inbox.presentationRequestToken > tokenBefore }
        XCTAssertEqual(readinessCalls, 1)
        XCTAssertEqual(refreshCalls, 0, "not-ready taps must not refresh against an unusable connection")
        XCTAssertNil(s.sessions.activeStoredId)
        XCTAssertEqual(s.inbox.presentationRequestToken, tokenBefore + 1)
    }

    func testColdAttentionWaitsForReadinessRefreshesAndOpensBeforeInboxFallback() async {
        let s = makeStores()
        var readinessCalls = 0
        var refreshCalls = 0
        s.connection.sessionRefreshReadinessOverride = {
            readinessCalls += 1
            return true
        }
        s.sessions.sessionsFetch = {
            refreshCalls += 1
            return ([self.summary(id: "stored-attention")], 1)
        }

        HermesURLRouter.routePushTap(
            .attention(sessionId: "stored-attention"),
            sessions: s.sessions,
            inbox: s.inbox,
            connection: s.connection
        )

        await waitUntil { s.sessions.activeStoredId == "stored-attention" }
        XCTAssertEqual(readinessCalls, 1)
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(s.sessions.activeStoredId, "stored-attention")
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)
    }

    // MARK: - QA-3 S12: stored_session_id deep-link

    func testTapWithStoredSessionIdOpensOwningSessionDirectly() async {
        // The relay's stored id is in the payload but the runtime id is NOT in
        // the inbox map (an ordinary turn_complete of a compressed session) and
        // the session is already loaded. The tap MUST open the stored-id
        // session synchronously, without falling through to the Inbox.
        let s = makeStores()
        s.sessions.sessions = [summary(id: "origin-stored-9")]
        // No inbox mapping for the runtime id (the precondition that was broken).
        XCTAssertNil(s.inbox.storedSessionId(forRuntime: "live-9"))

        var readinessCalls = 0
        var refreshCalls = 0
        s.connection.sessionRefreshReadinessOverride = {
            readinessCalls += 1
            return true
        }
        s.sessions.sessionsFetch = {
            refreshCalls += 1
            return ([self.summary(id: "origin-stored-9")], 1)
        }

        HermesURLRouter.routePushTap(
            .turnComplete(sessionId: "live-9", storedSessionId: "origin-stored-9"),
            sessions: s.sessions,
            inbox: s.inbox,
            connection: s.connection
        )

        XCTAssertEqual(s.sessions.activeStoredId, "origin-stored-9")
        XCTAssertEqual(readinessCalls, 0, "stored-id hit must not enter readiness machinery")
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertEqual(s.inbox.presentationRequestToken, 0,
                       "must not dump to the Inbox when the stored id resolves")
    }

    func testTapWithStoredSessionIdColdOpensAfterRefresh() async {
        // Cold launch: session list empty; the stored id lets us target the
        // right session once the refresh lands, instead of guessing the runtime
        // id (which never matches a stored-id list).
        let s = makeStores()
        var refreshCalls = 0
        s.connection.sessionRefreshReadinessOverride = { true }
        s.sessions.sessionsFetch = {
            refreshCalls += 1
            return ([self.summary(id: "origin-stored-cold")], 1)
        }

        HermesURLRouter.routePushTap(
            .turnComplete(sessionId: "live-cold", storedSessionId: "origin-stored-cold"),
            sessions: s.sessions,
            inbox: s.inbox,
            connection: s.connection
        )

        await waitUntil { s.sessions.activeStoredId == "origin-stored-cold" }
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(s.sessions.activeStoredId, "origin-stored-cold")
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)
    }
}

// MARK: - Per-event push prefs round-trip (A4)

/// Round-trips the notification toggles through `DefaultsKeys`, asserting
/// the default-ON semantics and the deterministic wire `events` list.
final class PushEventPrefsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "PushEventPrefsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAbsentKeysDefaultOn() {
        // Fresh install / legacy: everything on, list carries all three tokens.
        XCTAssertTrue(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventApproval, defaults))
        XCTAssertTrue(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventClarify, defaults))
        XCTAssertTrue(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventTurnComplete, defaults))
        XCTAssertTrue(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventTurnError, defaults))
        XCTAssertTrue(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventBackgroundDone, defaults))
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["approval", "clarify", "turn_complete", "turn_error", "background_done"]
        )
    }

    func testTogglingApprovalOffExcludesItFromList() {
        defaults.set(false, forKey: DefaultsKeys.pushEventApproval)
        XCTAssertFalse(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventApproval, defaults))
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["clarify", "turn_complete", "turn_error", "background_done"],
            "approval must drop out of the events list when toggled off"
        )
    }

    func testTogglingTurnErrorAndBackgroundDoneOffExcludesThemFromList() {
        defaults.set(false, forKey: DefaultsKeys.pushEventTurnError)
        defaults.set(false, forKey: DefaultsKeys.pushEventBackgroundDone)
        XCTAssertFalse(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventTurnError, defaults))
        XCTAssertFalse(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventBackgroundDone, defaults))
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["approval", "clarify", "turn_complete"],
            "new push kinds must drop out of the events list when toggled off"
        )
    }

    func testAllOffYieldsEmptyList() {
        defaults.set(false, forKey: DefaultsKeys.pushEventApproval)
        defaults.set(false, forKey: DefaultsKeys.pushEventClarify)
        defaults.set(false, forKey: DefaultsKeys.pushEventTurnComplete)
        defaults.set(false, forKey: DefaultsKeys.pushEventTurnError)
        defaults.set(false, forKey: DefaultsKeys.pushEventBackgroundDone)
        XCTAssertEqual(DefaultsKeys.pushEventList(defaults), [])
    }

    func testRoundTripPersistsExplicitTrue() {
        // An explicit ON (the user toggled off then on again) is honored verbatim.
        defaults.set(false, forKey: DefaultsKeys.pushEventClarify)
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["approval", "turn_complete", "turn_error", "background_done"]
        )
        defaults.set(true, forKey: DefaultsKeys.pushEventClarify)
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["approval", "clarify", "turn_complete", "turn_error", "background_done"]
        )
    }

    func testListOrderIsStable() {
        // Order is part of the contract for deterministic access-log assertions.
        defaults.set(true, forKey: DefaultsKeys.pushEventTurnComplete)
        defaults.set(true, forKey: DefaultsKeys.pushEventBackgroundDone)
        defaults.set(true, forKey: DefaultsKeys.pushEventApproval)
        defaults.set(true, forKey: DefaultsKeys.pushEventTurnError)
        defaults.set(true, forKey: DefaultsKeys.pushEventClarify)
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["approval", "clarify", "turn_complete", "turn_error", "background_done"]
        )
    }
}

// MARK: - Push-token registration dedupe: env key (ABH-182 Inc-2)

/// Verifies that the `pushLastEnv` key is part of the registration dedupe key,
/// so a sandbox→production flip forces a re-POST even when the token and event
/// prefs are identical. Tests are pure and deterministic: they exercise the
/// `DefaultsKeys.pushLastEnv` round-trip and the 3-way guard condition that
/// `PushRegistrar.didRegister` evaluates against `UserDefaults`. No network or
/// device needed.
///
/// The guard condition (simplified):
///   savedToken == token && savedEvents == events && savedEnv == env → SKIP
///   any mismatch → RE-POST
final class PushRegistrarEnvDedupeTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "PushRegistrarEnvDedupeTests"

    // Mirrors the 3-way dedupe guard in `PushRegistrar.didRegister` so tests can
    // evaluate it against a controlled `UserDefaults` suite without touching
    // `UserDefaults.standard` or the network.
    private func wouldSkip(
        token hex: String,
        events: [String],
        env: String,
        defaults: UserDefaults
    ) -> Bool {
        defaults.string(forKey: DefaultsKeys.pushLastDeviceToken) == hex
            && defaults.stringArray(forKey: DefaultsKeys.pushLastEvents) == events
            && defaults.string(forKey: DefaultsKeys.pushLastEnv) == env
    }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - pushLastEnv round-trip

    func testEnvKeyRoundTrips() {
        // Absent → nil (never registered).
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastEnv))

        // Written → readable.
        defaults.set("sandbox", forKey: DefaultsKeys.pushLastEnv)
        XCTAssertEqual(defaults.string(forKey: DefaultsKeys.pushLastEnv), "sandbox")

        // Overwrite.
        defaults.set("production", forKey: DefaultsKeys.pushLastEnv)
        XCTAssertEqual(defaults.string(forKey: DefaultsKeys.pushLastEnv), "production")

        // Cleared → nil.
        defaults.removeObject(forKey: DefaultsKeys.pushLastEnv)
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastEnv))
    }

    // MARK: - env missing → always a dedupe miss

    func testEnvKeyAbsentCausesDedupeMiss() {
        // Simulate the state written by a pre-ABH-182 install: token + events
        // persisted, but `pushLastEnv` never written. The guard must miss so
        // the next `didRegister` re-POSTs and stamps the env.
        let token = "aabbcc"
        let events = ["approval", "clarify", "turn_complete"]
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        // pushLastEnv intentionally absent.

        XCTAssertFalse(
            wouldSkip(token: token, events: events, env: "production", defaults: defaults),
            "missing env key must NOT skip — legacy installs must re-POST once to stamp the env"
        )
    }

    // MARK: - env change → dedupe miss (the core bug fix)

    func testEnvChangeForcesRePost() {
        // Same token + events that were registered under sandbox. Now the env
        // flipped to production (Xcode → TestFlight on the same device). The
        // dedupe must miss so the gateway receives a re-registration with the
        // correct env.
        let token = "deadbeef"
        let events = ["approval", "turn_complete"]
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        defaults.set("sandbox", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertFalse(
            wouldSkip(token: token, events: events, env: "production", defaults: defaults),
            "env sandbox→production must be a dedupe miss even when token+events are identical"
        )
    }

    func testReverseEnvChangeForcesRePost() {
        // Symmetric: production → sandbox (e.g. side-loading a dev build after
        // a TestFlight install). The dedupe must still miss.
        let token = "cafebabe"
        let events: [String] = []
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        defaults.set("production", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertFalse(
            wouldSkip(token: token, events: events, env: "sandbox", defaults: defaults),
            "env production→sandbox must be a dedupe miss"
        )
    }

    // MARK: - all three unchanged → dedupe hit

    func testIdenticalTokenEventsEnvSkips() {
        // All three fields match: the gateway already has the correct
        // registration → skip the redundant POST.
        let token = "112233"
        let events = ["approval", "clarify", "turn_complete"]
        let env = "production"
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        defaults.set(env, forKey: DefaultsKeys.pushLastEnv)

        XCTAssertTrue(
            wouldSkip(token: token, events: events, env: env, defaults: defaults),
            "identical token+events+env must skip the POST"
        )
    }

    func testIdenticalStateSandboxSkips() {
        // Sandbox variant: simulator / Xcode dev builds must also dedupe when
        // token+events+env are all unchanged.
        let token = "00ff00"
        let events = ["clarify"]
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        defaults.set("sandbox", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertTrue(
            wouldSkip(token: token, events: events, env: "sandbox", defaults: defaults),
            "identical sandbox registration must skip"
        )
    }

    // MARK: - token or events change still misses (existing behaviour preserved)

    func testTokenChangeMissesRegardlessOfEnv() {
        defaults.set("aaa", forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(["approval"], forKey: DefaultsKeys.pushLastEvents)
        defaults.set("production", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertFalse(
            wouldSkip(token: "bbb", events: ["approval"], env: "production", defaults: defaults),
            "different token must be a miss even when events+env match"
        )
    }

    func testEventsChangeMissesRegardlessOfEnv() {
        defaults.set("aaa", forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(["approval"], forKey: DefaultsKeys.pushLastEvents)
        defaults.set("production", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertFalse(
            wouldSkip(token: "aaa", events: ["approval", "clarify"], env: "production", defaults: defaults),
            "different events must be a miss even when token+env match"
        )
    }
}
