import Foundation

/// Errors surfaced by ``RestClient``.
enum RestError: Error, LocalizedError, Sendable {
    /// The server returned a non-2xx status. `body` is the (possibly truncated) response text.
    case badStatus(Int, body: String)
    /// A transport-level failure (URLSession error, bad URL).
    case network(String)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Server returned HTTP \(code)"
                : "Server returned HTTP \(code): \(trimmed)"
        case .network(let message):
            return "Network error: \(message)"
        case .decoding(let message):
            return "Could not decode response: \(message)"
        }
    }
}

/// Stateless HTTP client for the hermes gateway's REST surface.
///
/// Token gateways receive `X-Hermes-Session-Token`; session gateways use the
/// system cookie jar. Remote requests keep their real Host, matching Desktop.
/// All requests use a 15-second timeout and throw ``RestError`` on failure.
///
/// The core endpoint groups live in `extension RestClient` files
/// (`RestClient+Sessions.swift`, `RestClient+Control.swift`, `RestClient+Audio.swift`).
/// They share the request plumbing below — `makeRequest`/`get`/`perform` and the
/// `decode`/`decodeJSONValue` helpers are `internal` (not `private`) precisely so
/// those same-module extensions reuse one implementation instead of cloning it.
struct RestClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession
    /// - Parameters:
    ///   - baseURL: The gateway base, e.g. `https://host[:port]`.
    ///   - token: The session token sent as `X-Hermes-Session-Token`.
    init(
        baseURL: URL,
        token: String
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.timeout
        config.waitsForConnectivity = false
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        self.baseURL = baseURL
        self.token = token
        self.session = URLSession(configuration: config)
    }

    /// Testing-only initialiser: accepts a pre-built ``URLSession`` so tests
    /// can inject a stub transport (``URLProtocol`` subclass) without hitting
    /// a live server. Not intended for production use.
    init(
        baseURL: URL,
        token: String,
        session: URLSession
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    private static let timeout: TimeInterval = 15

    // MARK: - Endpoints

    /// `GET /api/status` — server health and capability snapshot.
    func status() async throws -> ServerStatus {
        let data = try await get(path: "/api/status")
        return try decode(ServerStatus.self, from: data, context: "status")
    }

    func authProbe() async throws -> GatewayAuthProbe {
        let status = try await status()
        guard status.authRequired == true else {
            return GatewayAuthProbe(mode: .token, providers: [], version: status.version)
        }
        let data = try await get(path: "/api/auth/providers")
        struct Envelope: Decodable {
            let providers: [GatewayAuthProvider]
        }
        let providers = try decode(Envelope.self, from: data, context: "auth providers").providers
        return GatewayAuthProbe(mode: .session, providers: providers, version: status.version)
    }

    func webSocketTicket() async throws -> String {
        var request = makeRequest(path: "/api/auth/ws-ticket", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await perform(request)
        struct Ticket: Decodable { let ticket: String }
        let ticket = try decode(Ticket.self, from: data, context: "WebSocket ticket").ticket
        guard !ticket.isEmpty else {
            throw RestError.decoding("WebSocket ticket was empty")
        }
        return ticket
    }

    func logoutSession() async throws {
        _ = try await perform(makeRequest(path: "/auth/logout", method: "POST"))
    }

    /// `GET /api/sessions` — session list ordered by most recent activity.
    ///
    /// Unlike the WS `session.list` RPC (creation order), `order=recent` is
    /// compression-chain aware and bubbles an old session back to the top
    /// when it gets new activity — matching the desktop sidebar.
    func sessions(limit: Int = 100) async throws -> [SessionSummary] {
        let data = try await get(
            path: "/api/sessions?limit=\(limit)&order=recent&archived=exclude"
        )
        struct Wrapper: Decodable { let sessions: [SessionSummary] }
        return try decode(Wrapper.self, from: data, context: "sessions").sessions
    }

    /// `GET /api/sessions` — session list with the server-reported total count.
    ///
    /// The wire response is `{"sessions":[…], "total": N, "limit": N, "offset": N}`.
    /// Older gateways omit the pagination envelope and return only `{"sessions":[…]}`;
    /// in that case `total` is `nil` (the caller preserves the previously-known total).
    ///
    /// ABH-86 item 3: decoding the `total` field so the drawer's count affordance works.
    /// UX1: `minMessages=1` filters scaffold/empty sessions server-side (desktop parity:
    /// `listAllProfileSessions(limit, 1)` in desktop-controller.tsx:265).
    /// Pagination uses GROW-THE-LIMIT semantics (desktop-controller.tsx:290): pass
    /// `limit = loaded + PAGE_SIZE, offset=0` on every call — the window expands rather
    /// than walking with a fixed-limit+offset. The `offset` parameter is kept for the
    /// production-path default (offset=0) so older call sites compile unchanged.
    /// `excludeSource` / `source` filter by session origin (ABH drawer
    /// bifurcation): the human-chat Recents passes `excludeSource: ["cron", "subagent"]`
    /// so automation/agent-internal rows never enter the list (or its cache); the
    /// automation-runs feed passes `source: "cron"`. The server splits
    /// `exclude_sources` on commas.
    ///
    /// ABH-407: `cwdPrefix` scopes the list to sessions whose cwd starts with the
    /// given path (Project detail). Built via `URLQueryItem`/`URLComponents` so the
    /// raw path (spaces, slashes, etc.) is correctly percent-encoded — unlike the
    /// other params above, a project root is arbitrary user-filesystem text, not a
    /// fixed enum value. `+` is additionally escaped to `%2B` below, since
    /// `URLComponents` otherwise leaves it literal and FastAPI/Starlette decode a
    /// literal `+` as a space.
    /// `includeChildren` appends `include_children=true` so the dedicated
    /// automation slice can surface subagent child sessions the default
    /// parent-only listing hides. It remains `false` for existing callers.
    func sessionsWithTotal(
        limit: Int = 100,
        offset: Int = 0,
        order: String = "recent",
        minMessages: Int = 1,
        excludeSource: [String] = [],
        source: String? = nil,
        cwdPrefix: String? = nil,
        includeChildren: Bool = false
    ) async throws -> (sessions: [SessionSummary], total: Int?) {
        var queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "archived", value: "exclude"),
        ]
        if minMessages > 0 { queryItems.append(URLQueryItem(name: "min_messages", value: "\(minMessages)")) }
        if offset > 0       { queryItems.append(URLQueryItem(name: "offset", value: "\(offset)")) }
        if !excludeSource.isEmpty {
            // Gateway FastAPI param is `exclude_sources` (PLURAL) — see
            // web_server.py /api/sessions. iOS historically sent the singular
            // `exclude_source`, which FastAPI silently dropped, so autonomous rows
            // were never server-filtered and dominated the first page (only the
            // client-side `visibleSessions` filter hid them — wasting the loaded
            // window and making a freshly-active desktop session far less likely to
            // be in it). Backward-safe: a stock gateway ignores an unknown param,
            // and the client-side filter remains the guarantee.
            queryItems.append(URLQueryItem(name: "exclude_sources", value: excludeSource.joined(separator: ",")))
        }
        if let source, !source.isEmpty {
            queryItems.append(URLQueryItem(name: "source", value: source))
        }
        if let cwdPrefix, !cwdPrefix.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd_prefix", value: cwdPrefix))
        }
        if includeChildren {
            queryItems.append(URLQueryItem(name: "include_children", value: "true"))
        }
        var components = URLComponents()
        components.queryItems = queryItems
        // URLComponents leaves "+" unescaped in a query (RFC 3986 allows it there
        // unencoded), but FastAPI/Starlette's query parsing follows the
        // application/x-www-form-urlencoded convention and decodes a literal "+"
        // as a space. Escape it explicitly so a value containing "+" (e.g. a
        // cwd_prefix project root) round-trips exactly instead of becoming a space.
        let rawQuery = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let path = "/api/sessions?" + rawQuery
        let data = try await get(path: path)
        struct Wrapper: Decodable {
            let sessions: [SessionSummary]
            let total: Int?
        }
        let wrapper = try decode(Wrapper.self, from: data, context: "sessionsWithTotal")
        return (wrapper.sessions, wrapper.total)
    }

    /// `GET /api/sessions/{id}/messages` — stored transcript for a session.
    ///
    /// The response is either `{"messages": [...]}` or a bare `[...]` array;
    /// both shapes are handled. Entries that fail ``StoredMessage`` parsing
    /// are dropped.
    ///
    /// `shape` (WS-5.1): `"skeleton"` requests conversational text only (heavy
    /// `reasoning_content` + `tool_calls` nulled server-side) for a fast cold-open
    /// paint, then a follow-up full fetch hydrates them. Only the hermes-mobile
    /// PLUGIN mount honors `shape`; a stock gateway ignores the unknown query param
    /// and returns the full transcript unchanged, so this stays fully
    /// backward-safe. `nil` (default) is the shipped full fetch.
    func messages(sessionId: String, shape: String? = nil) async throws -> [StoredMessage] {
        var path = "/api/sessions/\(sessionId)/messages"
        if let shape, !shape.isEmpty { path += "?shape=\(shape)" }
        let data = try await get(path: path)

        let root = try decodeJSONValue(from: data, context: "messages")

        let array: [JSONValue]
        if let bare = root.arrayValue {
            array = bare
        } else if let wrapped = root["messages"]?.arrayValue {
            array = wrapped
        } else {
            throw RestError.decoding("messages: expected array or {messages:[…]}")
        }
        return array.compactMap(StoredMessage.init(json:))
    }

    /// Result of a side-effect-free stock-gateway capability probe.
    enum UploadProbeResult: Sendable, Equatable {
        case available
        case unavailable
        case inconclusive
    }

    // MARK: - Request plumbing
    //
    // `internal` (not `private`) so the `RestClient+*` extension files reuse this
    // single implementation rather than cloning Host derivation, authentication,
    // header, timeout, status check, and error mapping.

    /// JSON key-decoding strategy a caller needs for a given response shape.
    enum KeyStrategy: Sendable {
        /// Wire keys are snake_case; let `JSONDecoder` camel-case them. Use for
        /// fixed-shape responses whose models have no explicit `CodingKeys`.
        case convertFromSnakeCase
        /// No key conversion. Use when the model declares explicit snake_case
        /// `CodingKeys` (converting would double-transform and corrupt the match).
        case useDefaultKeys
    }

    /// Build a request with the mandatory Host override + auth headers.
    func makeRequest(path: String, method: String) -> URLRequest {
        // Split any query string off before joining — appendingPathComponent
        // percent-encodes "?" and the server would see a literal-path 404.
        let parts = path.split(separator: "?", maxSplits: 1)
        let purePath = String(parts[0])
        // Callers pass a PRE-ENCODED path (webhook names etc. run
        // addingPercentEncoding first). appendingPathComponent re-encoded the
        // "%" of those escapes ("a%20b" → "a%2520b"), so the gateway saw a
        // literal percent-20 in the path. Concatenate onto the base string so
        // the already-valid escapes survive verbatim; URL(string:) fails only
        // on a malformed URL, which the appendingPathComponent fallback still
        // handles (by re-encoding, as before).
        let baseString = baseURL.absoluteString
        let trimmedBase = baseString.hasSuffix("/") ? String(baseString.dropLast()) : baseString
        let pathWithSlash = purePath.hasPrefix("/") ? purePath : "/\(purePath)"
        var url = URL(string: trimmedBase + pathWithSlash)
            ?? baseURL.appendingPathComponent(
                purePath.hasPrefix("/") ? String(purePath.dropFirst()) : purePath
            )
        if parts.count == 2,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(parts[1])
            url = components.url ?? url
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.timeout
        )
        request.httpMethod = method
        if let host = WSURLBuilder.effectiveHost(for: baseURL) {
            request.setValue(host, forHTTPHeaderField: "Host")
        }
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func get(path: String) async throws -> Data {
        try await perform(makeRequest(path: path, method: "GET"))
    }

    /// JSON-encode a ``JSONValue`` request body, mapping failures to ``RestError``.
    func encodeBody(_ body: JSONValue, context: String) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw RestError.network("\(context): encode body: \(error.localizedDescription)")
        }
    }

    /// Execute a request and validate the HTTP status, mapping failures to ``RestError``.
    func perform(_ request: URLRequest) async throws -> Data {
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
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RestError.badStatus(http.statusCode, body: String(body.prefix(512)))
        }
        return data
    }

    /// Decode `data` into `T`, applying the requested key strategy.
    ///
    /// Defaults to `.convertFromSnakeCase` (the common fixed-shape case:
    /// status/sessions/upload/model.info/usage). Pass `.useDefaultKeys` for models
    /// with explicit snake_case `CodingKeys` (``SessionSearchResult``,
    /// ``AudioSpeakResult``) so the wire keys aren't double-converted.
    func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        context: String,
        strategy: KeyStrategy = .convertFromSnakeCase
    ) throws -> T {
        let decoder = JSONDecoder()
        if case .convertFromSnakeCase = strategy {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RestError.decoding("\(context): \(error.localizedDescription)")
        }
    }

    /// Decode `data` into a raw ``JSONValue`` with NO key conversion — dynamic
    /// keys (provider slugs, model ids, personality names) must survive verbatim,
    /// which `.convertFromSnakeCase` would rewrite. Used by the control surface's
    /// `/api/config`, `/api/cron/jobs`, `/api/skills` and by
    /// the bare-array message/export payloads.
    func decodeJSONValue(from data: Data, context: String) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw RestError.decoding("\(context): \(error.localizedDescription)")
        }
    }

}

// MARK: - Stock bounded transcript fetch

/// Compatibility name retained for callers while authority moves entirely to
/// stock session history. Hermes bounds the default response server-side; the
/// local cache is only a presentation accelerator.
func fetchTranscriptDeltaAware(
    rest: RestClient,
    cacheStore: CacheStore?,
    sessionId: String,
    identity: CacheIdentity?,
    shape: String? = nil
) async throws -> [StoredMessage] {
    _ = cacheStore
    _ = identity
    return try await rest.messages(sessionId: sessionId, shape: shape)
}
