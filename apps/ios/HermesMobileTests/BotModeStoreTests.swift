import XCTest
@testable import HermesMobile

@MainActor
final class BotModeStoreTests: XCTestCase {
    private func decodeSnake<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    func testEnsureBotChatResultUsesDurableAndOptionalRuntimeIDs() throws {
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
