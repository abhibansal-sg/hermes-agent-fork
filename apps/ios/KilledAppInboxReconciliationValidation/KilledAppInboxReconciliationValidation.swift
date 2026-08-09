import XCTest
import GRDB
@testable import HermesMobile

/// Named physical-device acceptance target. Run on a signed device, terminate
/// the host between the two phases, then relaunch; the test also performs an
/// in-process database close/reopen so CI pins the same durable boundary.
final class KilledAppInboxReconciliationValidation: XCTestCase {
    func testRestoredAttentionLosesActionabilityAfterDatabaseReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("killed-inbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let scope = CacheScope(serverId: "physical-device-gateway", profileId: "all")

        do {
            let cache = try CacheStore(testDB: DatabaseQueue(path: url.path))
            let record = PersistedAttentionItem(
                id: "killed-1", requestId: "request-1", sessionId: "runtime-1",
                storedSessionId: "stored-1", kind: "approval", safeTitle: "Approve",
                detail: .init(description: "safe"), createdAt: 1
            )
            _ = try await cache.upsertLiveAttention(record, scope: scope)
        }

        let relaunched = try CacheStore(testDB: DatabaseQueue(path: url.path))
        let snapshot = try await relaunched.expireRestoredAttention(scope: scope)
        XCTAssertEqual(snapshot.items.map(\.id), ["killed-1"])
        XCTAssertEqual(snapshot.pendingCount, 0)
        XCTAssertEqual(snapshot.items.first?.state, .expired)
    }
}
