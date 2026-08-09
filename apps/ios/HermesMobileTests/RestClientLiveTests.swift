import XCTest
@testable import HermesMobile

/// Live integration coverage for stock `RestClient` endpoints against a running
/// Hermes gateway.
///
/// Requires the shared dashboard to be reachable, with credentials supplied via
/// the test-runner environment:
///   TEST_RUNNER_HERMES_URL / TEST_RUNNER_HERMES_TOKEN on the xcodebuild
///   invocation (surfaced to the process here as HERMES_URL / HERMES_TOKEN).
/// Skips (rather than fails) when credentials are absent so the unit suite stays
/// green in CI without a backend — mirroring the env-skip pattern in
/// `HermesMobileUITests/ChatFlowUITests.swift`.
final class RestClientLiveTests: XCTestCase {

    func testTranscriptPageFetchUsesStockLatestWindow() async {
        TranscriptPageStubProtocol.nextResponse = (
            #"{"messages":[{"id":41,"role":"user","content":"older"}],"pagination":{"limit":50,"offset":0,"order":"latest","returned":1}}"#.data(using: .utf8)!,
            200
        )
        TranscriptPageStubProtocol.requestedPath = nil
        TranscriptPageStubProtocol.requestedQuery = nil
        let rest = transcriptPageStubClient()

        let page = await fetchTranscriptPage(rest: rest, sessionId: "s 1", limit: 50, before: 42)

        XCTAssertEqual(TranscriptPageStubProtocol.requestedPath, "/api/sessions/s%201/messages")
        XCTAssertEqual(TranscriptPageStubProtocol.requestedQuery, "limit=50&offset=0&order=latest")
        XCTAssertEqual(page?.messages.map(\.wireId), [41])
        XCTAssertEqual(page?.oldestId, 41)
        XCTAssertEqual(page?.hasMoreBefore, false)
    }

    func testTranscriptPageFetchDoesNotRequirePluginPathStyle() async {
        TranscriptPageStubProtocol.nextResponse = (
            #"{"messages":[],"pagination":{"limit":50,"offset":0,"order":"latest","returned":0}}"#.data(using: .utf8)!,
            200
        )
        TranscriptPageStubProtocol.requestedPath = nil
        let rest = transcriptPageStubClient()

        let page = await fetchTranscriptPage(rest: rest, sessionId: "s1", limit: 50)

        XCTAssertNotNil(page)
        XCTAssertEqual(TranscriptPageStubProtocol.requestedPath, "/api/sessions/s1/messages")
    }

    func testStockTranscriptPageUsesOffsetAndProfile() async {
        TranscriptPageStubProtocol.nextResponse = (
            #"{"session_id":"s 1","messages":[{"id":11,"role":"user","content":"older"}],"pagination":{"limit":10,"offset":10,"returned":1}}"#.data(using: .utf8)!,
            200
        )
        TranscriptPageStubProtocol.requestedPath = nil
        TranscriptPageStubProtocol.requestedQuery = nil
        let rest = transcriptPageStubClient()

        let page = await fetchStockTranscriptPage(
            rest: rest,
            sessionId: "s 1",
            profile: "work profile",
            limit: 10,
            offset: 10
        )

        XCTAssertEqual(
            TranscriptPageStubProtocol.requestedPath,
            "/api/sessions/s%201/messages"
        )
        XCTAssertEqual(
            TranscriptPageStubProtocol.requestedQuery,
            "limit=10&offset=10&profile=work%20profile"
        )
        XCTAssertEqual(page?.messages.map(\.wireId), [11])
        XCTAssertEqual(page?.hasMoreBefore, true)
    }

    /// `GET /api/sessions?order=recent` must round-trip with its query string
    /// intact (regression: appendingPathComponent percent-encoded the "?" and
    /// the server 404'd, silently degrading the app to creation-ordered
    /// listings) and decode into recency-ordered summaries with lastActive.
    func testLiveSessionsAreRecencyOrdered() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !urlString.isEmpty, !token.isEmpty,
              let url = URL(string: urlString) else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live sessions test")
        }

        let client = RestClient(baseURL: url, token: token)
        let sessions = try await client.sessions(limit: 50)

        XCTAssertFalse(sessions.isEmpty, "Live gateway should report sessions")
        let actives = sessions.compactMap(\.lastActive)
        XCTAssertFalse(actives.isEmpty, "REST rows should carry last_active")
        XCTAssertEqual(
            actives, actives.sorted(by: >),
            "Sessions must be ordered most-recently-active first"
        )
    }

    /// `GET /api/cron/delivery-targets` keeps snake_case target metadata intact
    /// and exposes both configured and needs-home-channel states to the cron
    /// editor. This is stubbed (not live) so CI pins the decoder without a
    /// configured gateway channel.
    func testCronDeliveryTargetsDecodeHomeTargetState() async throws {
        CronDeliveryTargetsStubProtocol.nextResponse = (
            data: #"{"targets":[{"id":"local","name":"Local (save only)","home_target_set":true,"home_env_var":null},{"id":"telegram","name":"Telegram","home_target_set":true,"home_env_var":"TELEGRAM_HOME_CHAT_ID"},{"id":"discord","name":"Discord","home_target_set":false,"home_env_var":"DISCORD_HOME_CHANNEL_ID"}]}"#.data(using: .utf8)!,
            status: 200
        )
        CronDeliveryTargetsStubProtocol.requestedPath = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CronDeliveryTargetsStubProtocol.self]
        let client = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )

        let targets = try await client.cronDeliveryTargets()

        XCTAssertEqual(CronDeliveryTargetsStubProtocol.requestedPath, "/api/cron/delivery-targets")
        XCTAssertEqual(targets.map(\.id), ["local", "telegram", "discord"])
        XCTAssertEqual(targets[0].name, "Local (save only)")
        XCTAssertTrue(targets[0].homeTargetSet)
        XCTAssertNil(targets[0].homeEnvVar)
        XCTAssertTrue(targets[1].homeTargetSet)
        XCTAssertEqual(targets[1].homeEnvVar, "TELEGRAM_HOME_CHAT_ID")
        XCTAssertFalse(targets[2].homeTargetSet)
        XCTAssertEqual(targets[2].homeEnvVar, "DISCORD_HOME_CHANNEL_ID")
    }

    // MARK: - Test fixtures

    private func transcriptPageStubClient() -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptPageStubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )
    }
}

private final class TranscriptPageStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (data: Data, status: Int)?
    nonisolated(unsafe) static var requestedPath: String?
    nonisolated(unsafe) static var requestedQuery: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Record the WIRE path (percent-encoded). iOS 17+ Foundation's
        // `URL.path`/`URL.query` return the percent-DECODED form (`s 1`),
        // which masks the exact property this gate protects: session ids
        // percent-encode onto the wire (`s%201` — a raw space is an invalid
        // request line; the sibling recency test pins the `?`-encoding twin
        // of this regression). `URLComponents` exposes the encoded form.
        let components = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        Self.requestedPath = components?.percentEncodedPath ?? request.url?.path
        Self.requestedQuery = components?.percentEncodedQuery ?? request.url?.query
        guard let (data, status) = Self.nextResponse else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CronDeliveryTargetsStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (data: Data, status: Int)?
    nonisolated(unsafe) static var requestedPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedPath = request.url?.path
        guard let (data, status) = Self.nextResponse else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
