import Foundation
import Testing
@testable import HermesMobile

@Suite("Stock native provider authentication", .serialized)
@MainActor
struct NativeProviderAuthTests {
    private let baseURL = URL(string: "https://provider.gateway.test")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeAuthStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func bundle(
        access: String = "access-old",
        refresh: String = "refresh-old",
        expiresAt: Int = Int(Date().timeIntervalSince1970) + 3_600
    ) -> ProviderCredentialBundle {
        ProviderCredentialBundle(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresAt,
            provider: "hermes-mobile",
            userId: "user-1",
            clientId: "client-1"
        )
    }

    private func refreshedJSON(
        access: String = "access-new",
        refresh: String = "refresh-new"
    ) -> Data {
        Data("""
        {"access_token":"\(access)","refresh_token":"\(refresh)",
         "expires_at":\(Int(Date().timeIntervalSince1970) + 3_600),
         "provider":"hermes-mobile","user_id":"user-1","client_id":"client-1"}
        """.utf8)
    }

    @Test("provider pairing payload is additive and does not expose a shared token")
    func providerPairPayload() throws {
        let raw = "hermesapp://pair?kind=provider&url=https%3A%2F%2Fgateway.example&bootstrap=once-123"
        let parsed = try #require(HermesURLRouter.parsePairPayload(raw))
        #expect(parsed.url == "https://gateway.example")
        #expect(parsed.token.isEmpty)
        #expect(parsed.providerBootstrap == "once-123")
        #expect(parsed.isProviderPair)

        #expect(HermesURLRouter.parsePairPayload(
            "hermesapp://pair?kind=provider&url=https%3A%2F%2Fgateway.example"
        ) == nil)
        #expect(HermesURLRouter.parsePairPayload(
            "hermesapp://pair?kind=provider&manual_token=true&url=https%3A%2F%2Fgateway.example&bootstrap=once"
        ) == nil)
    }

    @Test("legacy pair payload remains unchanged")
    func legacyPairPayload() throws {
        let raw = "hermesapp://pair?url=https%3A%2F%2Fgateway.example&token=shared"
        let parsed = try #require(HermesURLRouter.parsePairPayload(raw))
        #expect(parsed.token == "shared")
        #expect(!parsed.isProviderPair)
    }

    @Test("WebSocket tickets use the stock ticket query and never the token query")
    func ticketURL() throws {
        let request = WSURLBuilder.wsRequest(
            baseURL: baseURL,
            ticket: "ticket secret+value",
            mode: .remoteURL
        )
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "wss")
        #expect(components.queryItems == [URLQueryItem(name: "ticket", value: "ticket secret+value")])
        #expect(request.value(forHTTPHeaderField: "Host") == nil)
    }

    @Test("provider REST uses Bearer while legacy REST keeps the shared-token header")
    func authorizationHeaders() async throws {
        NativeAuthStubProtocol.reset(paths: [
            "/provider": [.init(status: 200, data: Data())],
            "/legacy": [.init(status: 200, data: Data())],
        ])
        let transport = session()
        let current = bundle()
        let controller = NativeCredentialController(
            baseURL: baseURL,
            credentialStoreKey: "header-test",
            bundle: current,
            session: transport,
            credentialSaver: { _, _ in }
        )
        let provider = RestClient(
            baseURL: baseURL,
            providerCredential: current,
            controller: controller,
            session: transport
        )
        _ = try await provider.get(path: "/provider")

        let legacy = RestClient(baseURL: baseURL, token: "shared", session: transport)
        _ = try await legacy.get(path: "/legacy")

        let requests = NativeAuthStubProtocol.recordedRequests()
        let providerRequest = try #require(requests.first { $0.url?.path == "/provider" })
        #expect(providerRequest.value(forHTTPHeaderField: "Authorization") == "Bearer access-old")
        #expect(providerRequest.value(forHTTPHeaderField: WSURLBuilder.sessionTokenHeader) == nil)
        #expect(providerRequest.value(forHTTPHeaderField: "Host") == nil)
        let legacyRequest = try #require(requests.first { $0.url?.path == "/legacy" })
        #expect(legacyRequest.value(forHTTPHeaderField: WSURLBuilder.sessionTokenHeader) == "shared")
        #expect(legacyRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(legacyRequest.value(forHTTPHeaderField: "Host") == WSURLBuilder.loopbackHost)
    }

    @Test("concurrent expired requests share one rotating refresh flight")
    func singleFlightRefresh() async throws {
        NativeAuthStubProtocol.reset(paths: [
            "/auth/native/refresh": [
                .init(status: 200, data: refreshedJSON(), delay: 0.05),
            ],
            "/probe": [
                .init(status: 200, data: Data()),
                .init(status: 200, data: Data()),
            ],
        ])
        let transport = session()
        let current = bundle(expiresAt: 0)
        let saved = SavedCredentialBox()
        let controller = NativeCredentialController(
            baseURL: baseURL,
            credentialStoreKey: "single-flight",
            bundle: current,
            session: transport,
            credentialSaver: { credential, key in saved.append(credential, key: key) }
        )
        let client = RestClient(
            baseURL: baseURL,
            providerCredential: current,
            controller: controller,
            session: transport
        )

        async let first = client.get(path: "/probe")
        async let second = client.get(path: "/probe")
        _ = try await (first, second)

        #expect(NativeAuthStubProtocol.requestCount(path: "/auth/native/refresh") == 1)
        #expect(saved.values().count == 1)
        #expect(saved.values().first?.0.accessToken == "access-new")
        #expect(saved.values().first?.1 == "single-flight")
        #expect(NativeAuthStubProtocol.recordedRequests(path: "/probe").allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-new"
        })
    }

    @Test("a failed rotated-token commit poisons the controller without replaying refresh")
    func persistenceFailureIsTerminal() async {
        NativeAuthStubProtocol.reset(paths: [
            "/auth/native/refresh": [.init(status: 200, data: refreshedJSON())],
        ])
        let transport = session()
        let current = bundle(expiresAt: 0)
        let controller = NativeCredentialController(
            baseURL: baseURL,
            credentialStoreKey: "persistence-failure",
            bundle: current,
            session: transport,
            credentialSaver: { _, _ in throw TestFailure.expected }
        )

        do {
            _ = try await controller.accessToken()
            Issue.record("Expected secure persistence failure")
        } catch {
            #expect(error as? NativeCredentialError == .persistenceFailed)
        }
        do {
            _ = try await controller.accessToken()
            Issue.record("Expected controller to remain terminal")
        } catch {
            #expect(error as? NativeCredentialError == .persistenceFailed)
        }
        #expect(NativeAuthStubProtocol.requestCount(path: "/auth/native/refresh") == 1)
    }

    @Test("retiring a controller fences an in-flight rotation from resurrecting provider storage")
    func retirementFencesRotationPersistence() async {
        NativeAuthStubProtocol.reset(paths: [
            "/auth/native/refresh": [
                .init(status: 200, data: refreshedJSON(), delay: 0.05),
            ],
        ])
        let transport = session()
        let saved = SavedCredentialBox()
        let controller = NativeCredentialController(
            baseURL: baseURL,
            credentialStoreKey: "retired",
            bundle: bundle(expiresAt: 0),
            session: transport,
            credentialSaver: { credential, key in saved.append(credential, key: key) }
        )
        let refresh = Task { try await controller.accessToken() }
        try? await Task.sleep(for: .milliseconds(10))
        await controller.retire()

        do {
            _ = try await refresh.value
            Issue.record("Expected the retired controller to discard the rotation")
        } catch {
            #expect(error as? NativeCredentialError == .retired)
        }
        #expect(saved.values().isEmpty)
    }

    @Test("ticket rejection refreshes once and every ticket request mints a fresh value")
    func ticketRefreshAndFreshness() async throws {
        NativeAuthStubProtocol.reset(paths: [
            "/api/auth/ws-ticket": [
                .init(status: 401, data: Data()),
                .init(status: 200, data: Data(#"{"ticket":"ticket-1","ttl_seconds":30}"#.utf8)),
                .init(status: 200, data: Data(#"{"ticket":"ticket-2","ttl_seconds":30}"#.utf8)),
            ],
            "/auth/native/refresh": [.init(status: 200, data: refreshedJSON())],
        ])
        let transport = session()
        let current = bundle()
        let controller = NativeCredentialController(
            baseURL: baseURL,
            credentialStoreKey: "tickets",
            bundle: current,
            session: transport,
            credentialSaver: { _, _ in }
        )

        #expect(try await controller.webSocketTicket() == "ticket-1")
        #expect(try await controller.webSocketTicket() == "ticket-2")
        #expect(NativeAuthStubProtocol.requestCount(path: "/auth/native/refresh") == 1)
        #expect(NativeAuthStubProtocol.requestCount(path: "/api/auth/ws-ticket") == 3)
    }

    @Test("provider Keychain bundle round-trips atomically and wins over a legacy token")
    func keychainRoundTripAndDelete() throws {
        let server = "native-provider-test-\(UUID().uuidString)"
        defer { KeychainService.deleteCredentials(server: server) }
        try KeychainService.saveToken("legacy", server: server)
        let current = bundle()
        try KeychainService.saveProviderCredential(current, server: server)

        #expect(KeychainService.loadProviderCredential(server: server) == current)
        #expect(KeychainService.loadCredential(server: server) == .provider(current))
        #expect(KeychainService.loadToken(server: server) == nil)

        try KeychainService.saveSharedCredentialReplacingProvider("legacy-new", server: server)
        #expect(KeychainService.loadProviderCredential(server: server) == nil)
        #expect(KeychainService.loadCredential(server: server) == .sharedToken("legacy-new"))

        KeychainService.deleteCredentials(server: server)
        #expect(KeychainService.loadCredential(server: server) == nil)
    }
}

private enum TestFailure: Error { case expected }

private final class SavedCredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(ProviderCredentialBundle, String)] = []
    func append(_ credential: ProviderCredentialBundle, key: String) {
        lock.withLock { stored.append((credential, key)) }
    }
    func values() -> [(ProviderCredentialBundle, String)] {
        lock.withLock { stored }
    }
}

private final class NativeAuthStubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let status: Int
        let data: Data
        let delay: TimeInterval
        init(status: Int, data: Data, delay: TimeInterval = 0) {
            self.status = status
            self.data = data
            self.delay = delay
        }
    }

    private static let state = State()

    static func reset(paths: [String: [Stub]]) { state.reset(paths: paths) }
    static func recordedRequests() -> [URLRequest] { state.requests() }
    static func recordedRequests(path: String) -> [URLRequest] {
        state.requests().filter { $0.url?.path == path }
    }
    static func requestCount(path: String) -> Int { recordedRequests(path: path).count }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.state.next(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if stub.delay > 0 { Thread.sleep(forTimeInterval: stub.delay) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String: [Stub]] = [:]
        private var observed: [URLRequest] = []

        func reset(paths: [String: [Stub]]) {
            lock.withLock {
                self.paths = paths
                observed = []
            }
        }

        func next(for request: URLRequest) -> Stub? {
            lock.withLock {
                observed.append(request)
                let path = request.url?.path ?? ""
                guard var queue = paths[path], !queue.isEmpty else { return nil }
                let next = queue.removeFirst()
                paths[path] = queue
                return next
            }
        }

        func requests() -> [URLRequest] { lock.withLock { observed } }
    }
}
