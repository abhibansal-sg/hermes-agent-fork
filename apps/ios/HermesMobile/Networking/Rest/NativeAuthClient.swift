import Foundation

/// Standard native-session credential bundle returned by Hermes dashboard auth.
/// Access and refresh tokens are persisted together as one Keychain value so a
/// rotated refresh token can never be committed independently of its access token.
struct ProviderCredentialBundle: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int
    let provider: String
    let userId: String
    let clientId: String

    var isUsable: Bool {
        !accessToken.isEmpty && !refreshToken.isEmpty && !provider.isEmpty && !clientId.isEmpty
    }
}

enum StoredGatewayCredential: Equatable, Sendable {
    case sharedToken(String)
    case provider(ProviderCredentialBundle)
}

/// Minimal client for the stock Hermes native-auth endpoints plus the thin,
/// one-time mobile bootstrap exchange. It owns no session/workflow state.
struct NativeAuthClient: Sendable {
    struct Ticket: Decodable, Equatable, Sendable {
        let ticket: String
        let ttlSeconds: Int
    }

    private struct PairExchangeBody: Encodable { let deviceName: String }
    private struct RefreshBody: Encodable {
        let refreshToken: String
        let provider: String
    }
    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int
        let provider: String
        let userId: String
        let clientId: String?
    }

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func exchange(bootstrap: String, deviceName: String) async throws -> ProviderCredentialBundle {
        let response: TokenResponse = try await post(
            path: "/api/plugins/hermes-mobile/pair/exchange",
            bearer: bootstrap,
            body: PairExchangeBody(deviceName: deviceName)
        )
        guard let clientId = response.clientId, !clientId.isEmpty else {
            throw RestError.decoding("pair exchange: missing client_id")
        }
        let bundle = ProviderCredentialBundle(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresAt,
            provider: response.provider,
            userId: response.userId,
            clientId: clientId
        )
        guard bundle.isUsable else {
            throw RestError.decoding("pair exchange: incomplete credential bundle")
        }
        return bundle
    }

    func refresh(_ current: ProviderCredentialBundle) async throws -> ProviderCredentialBundle {
        let response: TokenResponse = try await post(
            path: "/auth/native/refresh",
            bearer: nil,
            body: RefreshBody(
                refreshToken: current.refreshToken,
                provider: current.provider
            )
        )
        let bundle = ProviderCredentialBundle(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresAt,
            provider: response.provider,
            userId: response.userId.isEmpty ? current.userId : response.userId,
            // Stock refresh responses predate Session.client_id. Identity is
            // provider-verified and stable, so retain the exchange-time value.
            clientId: response.clientId.flatMap { $0.isEmpty ? nil : $0 } ?? current.clientId
        )
        guard bundle.isUsable else {
            throw RestError.decoding("native refresh: incomplete credential bundle")
        }
        return bundle
    }

    func wsTicket(accessToken: String) async throws -> Ticket {
        struct EmptyBody: Encodable {}
        let ticket: Ticket = try await post(
            path: "/api/auth/ws-ticket",
            bearer: accessToken,
            body: EmptyBody()
        )
        guard !ticket.ticket.isEmpty, ticket.ttlSeconds > 0 else {
            throw RestError.decoding("ws ticket: incomplete response")
        }
        return ticket
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        bearer: String?,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(
            url: endpoint(path: path),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw RestError.network("Could not encode native-auth request")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RestError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RestError.network("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw RestError.badStatus(http.statusCode, body: String(text.prefix(512)))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw RestError.decoding("native auth: \(error.localizedDescription)")
        }
    }

    private func endpoint(path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        let base = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = base + (path.hasPrefix("/") ? path : "/\(path)")
        components.query = nil
        components.fragment = nil
        return components.url ?? baseURL
    }
}

enum NativeCredentialError: Error, LocalizedError, Equatable, Sendable {
    case persistenceFailed
    case retired

    var errorDescription: String? {
        switch self {
        case .persistenceFailed:
            return "The rotated Hermes credential could not be saved securely. Pair again."
        case .retired:
            return "This Hermes credential is no longer active."
        }
    }
}

/// One actor owns provider-token refresh for a paired server. Every REST client
/// and WebSocket reconnect joins the same refresh flight, so a rotating refresh
/// token is never replayed by competing requests.
actor NativeCredentialController {
    typealias CredentialSaver = @Sendable (ProviderCredentialBundle, String) throws -> Void
    private struct RefreshFlight {
        let id: UUID
        let task: Task<ProviderCredentialBundle, Error>
    }

    private let credentialStoreKey: String
    private let client: NativeAuthClient
    private let credentialSaver: CredentialSaver
    private var bundle: ProviderCredentialBundle
    private var refreshFlight: RefreshFlight?
    private var persistenceFailed = false
    private var retired = false

    init(
        baseURL: URL,
        credentialStoreKey: String,
        bundle: ProviderCredentialBundle,
        session: URLSession? = nil,
        credentialSaver: @escaping CredentialSaver = { credential, server in
            try KeychainService.saveProviderCredential(credential, server: server)
        }
    ) {
        self.credentialStoreKey = credentialStoreKey
        self.bundle = bundle
        self.client = NativeAuthClient(baseURL: baseURL, session: session)
        self.credentialSaver = credentialSaver
    }

    func accessToken(minimumValidity: TimeInterval = 60) async throws -> String {
        guard !retired else { throw NativeCredentialError.retired }
        guard !persistenceFailed else { throw NativeCredentialError.persistenceFailed }
        if TimeInterval(bundle.expiresAt) - Date().timeIntervalSince1970 > minimumValidity {
            return bundle.accessToken
        }
        return try await refresh(rejectedAccessToken: nil).accessToken
    }

    func authorize(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue(
            "Bearer \(try await accessToken())",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(nil, forHTTPHeaderField: WSURLBuilder.sessionTokenHeader)
        return request
    }

    func retryAuthorization(
        _ request: URLRequest,
        rejectedAccessToken: String
    ) async throws -> URLRequest {
        var request = request
        let refreshed = try await refresh(rejectedAccessToken: rejectedAccessToken)
        request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: WSURLBuilder.sessionTokenHeader)
        return request
    }

    func webSocketTicket() async throws -> String {
        let access = try await accessToken()
        do {
            return try await client.wsTicket(accessToken: access).ticket
        } catch let error as RestError where Self.isAuthFailure(error) {
            let refreshed = try await refresh(rejectedAccessToken: access)
            return try await client.wsTicket(accessToken: refreshed.accessToken).ticket
        }
    }

    func currentBundle() -> ProviderCredentialBundle { bundle }

    /// Fence this controller before another credential mode takes ownership.
    /// An already-issued network refresh is allowed to settle, but its rotated
    /// result is discarded instead of resurrecting a provider Keychain item
    /// after an explicit switch to a shared credential or another provider.
    func retire() { retired = true }

    private func refresh(
        rejectedAccessToken: String?
    ) async throws -> ProviderCredentialBundle {
        guard !retired else { throw NativeCredentialError.retired }
        guard !persistenceFailed else { throw NativeCredentialError.persistenceFailed }
        if let rejectedAccessToken, rejectedAccessToken != bundle.accessToken {
            return bundle
        }

        let flight: RefreshFlight
        if let existing = refreshFlight {
            flight = existing
        } else {
            let id = UUID()
            let snapshot = bundle
            let client = client
            let task = Task { try await client.refresh(snapshot) }
            flight = RefreshFlight(id: id, task: task)
            refreshFlight = flight
        }

        do {
            let rotated = try await flight.task.value
            return try completeRefresh(id: flight.id, rotated: rotated)
        } catch {
            failRefresh(id: flight.id)
            throw error
        }
    }

    private func completeRefresh(
        id: UUID,
        rotated: ProviderCredentialBundle
    ) throws -> ProviderCredentialBundle {
        guard !retired else { throw NativeCredentialError.retired }
        guard !persistenceFailed else { throw NativeCredentialError.persistenceFailed }
        guard refreshFlight?.id == id else {
            // Another waiter already committed this flight (or a later one).
            // The actor-owned bundle is always the only admissible result.
            return bundle
        }
        do {
            try credentialSaver(rotated, credentialStoreKey)
        } catch {
            persistenceFailed = true
            refreshFlight = nil
            throw NativeCredentialError.persistenceFailed
        }
        bundle = rotated
        refreshFlight = nil
        return rotated
    }

    private func failRefresh(id: UUID) {
        if refreshFlight?.id == id {
            refreshFlight = nil
        }
    }

    private static func isAuthFailure(_ error: RestError) -> Bool {
        if case .badStatus(let status, _) = error {
            return status == 401 || status == 403
        }
        return false
    }
}
