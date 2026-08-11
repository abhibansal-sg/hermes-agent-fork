import XCTest
@testable import HermesMobile

/// Capability-matrix coverage: filesystem and profiles are stock probes;
/// broad mobile-plugin capabilities stay unavailable without a probe.
@MainActor
final class ServerCapabilitiesFSTests: XCTestCase {

    func testNewFieldsDefaultUnknown() {
        let caps = ServerCapabilities()
        XCTAssertEqual(caps.fs, .unknown)
        XCTAssertEqual(caps.subagentEvents, .unknown)
    }

    func testSubagentObservedTransitionsToAvailableOnce() {
        let caps = ServerCapabilities()
        XCTAssertEqual(caps.subagentEvents, .unknown)
        caps.noteSubagentObserved()
        XCTAssertEqual(caps.subagentEvents, .available)
        // Idempotent — a second call is a no-op (no crash, stays available).
        caps.noteSubagentObserved()
        XCTAssertEqual(caps.subagentEvents, .available)
    }

    func testResetClearsNewFields() {
        let caps = ServerCapabilities()
        caps.noteSubagentObserved()
        caps.reset()
        XCTAssertEqual(caps.fs, .unknown)
        XCTAssertEqual(caps.subagentEvents, .unknown)
    }

    func testStockFSIsIndependentFromPluginMount() async {
        defer { UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverCapabilities) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapabilityMatrixProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let rest = RestClient(
            baseURL: URL(string: "http://gateway.test")!,
            token: "t",
            session: session
        )
        let caps = ServerCapabilities()

        await caps.probe(serverURL: "http://gateway.test", rest: rest, force: true)

        XCTAssertEqual(caps.fs, .available)
        XCTAssertEqual(caps.profiles, .unavailable)
        XCTAssertEqual(
            Set(CapabilityMatrixProtocol.paths),
            [
                "/api/fs/default-cwd",
                "/api/profiles/sessions",
            ]
        )
    }

    func testCachedUnknownProfilesForcesFreshProbe() async {
        let key = DefaultsKeys.serverCapabilities
        let url = "http://gateway-cache.test"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let cached = """
        {"contractVersion":\(ServerCapabilities.capabilityContractVersion),
         "serverURL":"\(url)","appVersion":"\(ServerCapabilities.currentAppVersion)",
         "broadcast":"unknown","fs":"available","subagentEvents":"unknown",
         "profiles":"unknown"}
        """
        UserDefaults.standard.set(Data(cached.utf8), forKey: key)

        CachedUnknownProfilesProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CachedUnknownProfilesProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let rest = RestClient(
            baseURL: URL(string: url)!,
            token: "t",
            session: session
        )

        let caps = ServerCapabilities()
        await caps.probe(serverURL: url, rest: rest)

        XCTAssertEqual(caps.fs, .available)
        XCTAssertEqual(caps.profiles, .available)
        XCTAssertEqual(
            Set(CachedUnknownProfilesProtocol.paths),
            ["/api/profiles/sessions"],
            "a partial cache must probe only its missing capability"
        )
    }
}

private final class CapabilityMatrixProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedPaths: [String] = []

    static var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.recordedPaths.append(path)
        Self.lock.unlock()

        let status: Int
        let body: String
        if path == "/api/fs/default-cwd" {
            status = 200
            body = #"{"cwd":"/workspace","branch":"main"}"#
        } else {
            status = 404
            body = #"{"detail":"not found"}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CachedUnknownProfilesProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedPaths: [String] = []

    static var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    static func reset() {
        lock.lock()
        recordedPaths = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.recordedPaths.append(path)
        Self.lock.unlock()

        let body = path == "/api/profiles/sessions"
            ? #"{"sessions":[],"total":0,"profile_totals":{},"limit":20,"offset":0,"errors":[]}"#
            : #"{"cwd":"/workspace","branch":"main"}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
