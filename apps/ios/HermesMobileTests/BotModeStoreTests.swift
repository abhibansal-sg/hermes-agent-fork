import XCTest
@testable import HermesMobile

@MainActor
final class BotModeStoreTests: XCTestCase {
    private final class BotTransport: GatewayWebSocketTask, @unchecked Sendable {
        private let lock = NSLock()
        private var inbox: [URLSessionWebSocketTask.Message] = [
            .string(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        ]
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var requests: [[String: Any]] = []
        let conflict: Bool
        init(conflict: Bool) { self.conflict = conflict }
        func resume() {}
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            lock.lock()
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume(throwing: CancellationError())
        }
        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if inbox.isEmpty {
                    waiter = continuation
                    lock.unlock()
                } else {
                    let message = inbox.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: message)
                }
            }
        }
        func snapshot() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
        private func respond(_ request: [String: Any]) throws {
            lock.lock()
            requests.append(request)
            let method = request["method"] as! String
            let lists = requests.filter { $0["method"] as? String == "profiles.list" }.count
            lock.unlock()
            var response: [String: Any] = ["jsonrpc": "2.0", "id": request["id"]!]
            switch method {
            case "profiles.list":
                let canonical: Any = lists > 1 ? ["id": "winner", "resolved_id": "winner-tip"] : NSNull()
                response["result"] = ["bot_mode_protocol": true, "profiles": [
                    ["name": "research", "is_default": false, "canonical_session": canonical]
                ]]
            case "session.create":
                response["result"] = ["session_id": "runtime", "stored_session_id": "stored"]
            case "session.title":
                if conflict {
                    response["error"] = ["code": 4022, "message": "Title already in use"]
                } else {
                    response["result"] = ["pending": false, "title": "Bot Chat"]
                }
            default:
                response["error"] = ["code": -32601, "message": "Unexpected method"]
            }
            let data = try JSONSerialization.data(withJSONObject: response)
            let message = URLSessionWebSocketTask.Message.string(String(decoding: data, as: UTF8.self))
            lock.lock()
            if let pending = waiter {
                waiter = nil
                lock.unlock()
                pending.resume(returning: message)
            } else {
                inbox.append(message)
                lock.unlock()
            }
        }
        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case .string(let text) = message else { return }
            let request = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            try respond(request)
        }
    }

    func testStockCreateMaterializesBeforeReturningAndConflictAdoptsWinner() async throws {
        for conflict in [false, true] {
            let transport = BotTransport(conflict: conflict)
            let client = HermesGatewayClient(transportFactory: { _ in transport })
            try await client.connect(baseURL: URL(string: "http://127.0.0.1:9119")!, token: "test")
            do {
                let result = try await client.ensureBotChat(profile: "research")
                XCTAssertEqual(result.sessionId, conflict ? "winner-tip" : "stored")
                XCTAssertEqual(result.created, !conflict)
                let requests = transport.snapshot()
                XCTAssertEqual(requests.compactMap { $0["method"] as? String },
                               conflict ? ["profiles.list", "session.create", "session.title", "profiles.list"]
                                        : ["profiles.list", "session.create", "session.title"])
                let create = requests[1]["params"] as! [String: Any]
                XCTAssertEqual(create["profile"] as? String, "research")
                XCTAssertEqual(create["title"] as? String, "Bot Chat")
                XCTAssertEqual(create["hidden"] as? Bool, true)
                XCTAssertEqual(create["follow_profile_config"] as? Bool, true)
                XCTAssertEqual((requests[0]["params"] as? [String: Any])?["include_sessions"] as? Bool, true)
                XCTAssertEqual((requests[2]["params"] as? [String: Any])?["session_id"] as? String, "runtime")
                await client.disconnect()
            } catch {
                await client.disconnect()
                throw error
            }
        }
    }

    private func decodeSnake<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    // ABH-520: resolution result is local, not a fork RPC wire contract.
    func testLocalBotChatResultUsesDurableAndOptionalRuntimeIDs() throws {
        let result = try decodeSnake(BotChatEnsureResult.self, """
        {
          "session_id": "stored-bot-chat",
          "profile": "research",
          "created": true,
          "runtime_session_id": "live-runtime"
        }
        """)

        XCTAssertEqual(result.sessionId, "stored-bot-chat")
        XCTAssertEqual(result.profile, "research")
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.runtimeSessionId, "live-runtime")
    }

    func testStockCanonicalResolutionAndConflictAdoption() throws {
        let result = try decodeSnake(BotProfilesResult.self, """
        {"bot_mode_protocol":true,"profiles":[
          {"name":"research","is_default":false,"canonical_session":{
            "id":"root","resolved_id":"tip","root_title":"Bot Chat",
            "title":"Compressed","preview":"hello","started_at":1,
            "last_active":2,"message_count":3}},
          {"name":"default","is_default":true,"canonical_session":null}
        ]}
        """)
        XCTAssertTrue(result.supportsBotMode)
        XCTAssertEqual(try BotChatResolution.resolve(result, profile: "research"), .open("tip"))
        XCTAssertEqual(try BotChatResolution.adoptWinner(result, profile: "research"), "tip")
        XCTAssertEqual(try BotChatResolution.resolve(result, profile: "default"), .create)
        XCTAssertThrowsError(try BotChatResolution.adoptWinner(result, profile: "default"))
        XCTAssertThrowsError(try BotChatResolution.resolve(result, profile: "deleted"))
        XCTAssertTrue(BotChatResolution.shouldAdoptWinner(message: "Title ALREADY IN USE"))
        XCTAssertFalse(BotChatResolution.shouldAdoptWinner(message: "Connection lost"))
        XCTAssertEqual(result.profiles.first?.canonicalSession?.messageCount, 3)
    }

    func testCanonicalIdentityFallsBackToRootAndLegacyPayloadsStayDormant() throws {
        let root = try decodeSnake(BotProfilesResult.self, """
        {"bot_mode_protocol":true,"profiles":[{"name":"default","is_default":true,
        "canonical_session":{"id":"root"}}]}
        """)
        XCTAssertEqual(try BotChatResolution.resolve(root, profile: "default"), .open("root"))
        for json in [
            #"{"profiles":[{"name":"default","is_default":true}]}"#,
            #"{"bot_mode_protocol":true,"profiles":[{"name":"default","is_default":true}]}"#,
            #"{"bot_mode_protocol":false,"profiles":[{"name":"default","is_default":true,"canonical_session":null}]}"#
        ] {
            let result = try decodeSnake(BotProfilesResult.self, json)
            XCTAssertFalse(result.supportsBotMode)
            XCTAssertThrowsError(try BotChatResolution.resolve(result, profile: "default"))
        }
    }

    func testRefreshUsesTheExistingProfileSurfaceWithoutPersistingRosterState() async {
        let expected = [
            ProfileSummary(name: "default", isDefault: true, description: "Primary"),
            ProfileSummary(name: "research", isDefault: false, description: "Research bot"),
        ]
        let store = BotModeStore(profileLoader: { expected })

        await store.refresh()

        XCTAssertEqual(store.rosterPhase, .loaded)
        XCTAssertEqual(store.profiles, expected)
        XCTAssertEqual(store.profiles.map(\.id), ["default", "research"])
    }

    func testOpenRoutesTheDurableSessionThroughSessionStore() async {
        let result = BotChatEnsureResult(
            sessionId: "durable-bot-chat",
            profile: "research",
            created: true,
            runtimeSessionId: "ephemeral-runtime"
        )
        let store = BotModeStore(botChatEnsurer: { requestedProfile in
            XCTAssertEqual(requestedProfile, "research")
            return result
        })
        let sessions = SessionStore()
        let profile = ProfileSummary(name: "research", isDefault: false, description: nil)

        let destination = await store.open(profile, in: sessions)

        XCTAssertEqual(destination, BotChatDestination(sessionID: "durable-bot-chat", profile: "research"))
        XCTAssertEqual(sessions.activeStoredId, "durable-bot-chat")
        XCTAssertEqual(sessions.activeSummary?.profile, "research")
        XCTAssertNil(sessions.activeRuntimeId, "The durable id must not be replaced by a fresh runtime id")
    }

    func testOpenFailureDoesNotChangeTheCurrentSession() async {
        enum TestError: LocalizedError {
            case unavailable

            var errorDescription: String? { "Hermes is unavailable." }
        }

        let store = BotModeStore(botChatEnsurer: { _ in throw TestError.unavailable })
        let sessions = SessionStore()
        let profile = ProfileSummary(name: "research", isDefault: false, description: nil)

        let destination = await store.open(profile, in: sessions)

        XCTAssertNil(destination)
        XCTAssertNil(sessions.activeStoredId)
        XCTAssertEqual(store.openError, "Hermes is unavailable.")
    }

    func testOpenRejectsAnEnsureResultForADifferentProfile() async {
        let store = BotModeStore(botChatEnsurer: { _ in
            BotChatEnsureResult(
                sessionId: "durable-bot-chat",
                profile: "other",
                created: false,
                runtimeSessionId: nil
            )
        })
        let sessions = SessionStore()
        let profile = ProfileSummary(name: "research", isDefault: false, description: nil)

        let destination = await store.open(profile, in: sessions)

        XCTAssertNil(destination)
        XCTAssertEqual(store.openError, "Hermes returned a bot chat for a different profile.")
        XCTAssertNil(sessions.activeStoredId)
    }

    func testAuthoritativeProfileIsBoundBeforeCapabilityProbeSettles() async {
        let sessions = SessionStore()
        let summary = SessionSummary(
            id: "durable-bot-chat",
            title: "Bot Chat",
            preview: nil,
            startedAt: nil,
            messageCount: 0,
            source: nil,
            lastActive: nil,
            cwd: nil,
            profile: nil
        )

        sessions.open(summary, authoritativeProfile: "research", bindRuntime: false)

        XCTAssertEqual(sessions.activeStoredId, "durable-bot-chat")
        XCTAssertEqual(sessions.activeStoredProfile, "research")
        XCTAssertEqual(sessions.activeSummary?.profile, "research")
    }

    func testUnsupportedGatewayDoesNotLoadOrOpenBotMode() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        connection.applyGatewayReadyCapabilities(.object([:]))
        let store = BotModeStore(profileLoader: {
            XCTFail("unsupported gateways must not load the Bot roster")
            return []
        }, botChatEnsurer: { _ in
            XCTFail("unsupported gateways must not ensure a Bot Chat")
            throw GatewayError.notConnected
        })
        let profile = ProfileSummary(name: "research", isDefault: false, description: nil)

        await store.refresh(using: connection)
        let destination = await store.open(profile, in: sessions, using: connection)

        XCTAssertNil(destination)
        XCTAssertEqual(store.rosterPhase, .idle)
        XCTAssertEqual(store.openError, "Bot Mode is unavailable on this Hermes gateway. Choose Session Mode in Settings.")
    }
}
