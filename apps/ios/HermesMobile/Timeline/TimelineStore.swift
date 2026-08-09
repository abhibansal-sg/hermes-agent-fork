import Foundation
import GRDB

/// Bounded, non-authoritative persistence for active/recent turn presentation.
///
/// This database is intentionally separate from `hermes_cache.sqlite`: stream
/// snapshots have a much higher write cadence and a much shorter retention
/// contract than the finalized transcript/FTS cache.
actor TimelineStore {
    static let databaseName = "hermes_timeline.sqlite"

    private let db: DatabaseQueue
    private let retention: TimelineRetentionPolicy
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(retention: TimelineRetentionPolicy = .standard) throws {
        let url = try Self.databaseURL()
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.makeMigrator().migrate(queue)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var excludedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excludedURL.setResourceValues(values)
        self.db = queue
        self.retention = retention
    }

    init(
        testDB: DatabaseQueue,
        retention: TimelineRetentionPolicy = .standard
    ) throws {
        try testDB.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try Self.makeMigrator().migrate(testDB)
        self.db = testDB
        self.retention = retention
    }

    /// Append a batch and fold it into the latest projection atomically.
    /// Duplicate record/source ids return `.ignoredDuplicateEvent` and consume
    /// neither a sequence number nor additional storage.
    func commit(
        identity: CacheIdentity,
        events: [TimelineEvent]
    ) throws -> TimelineCommitResult {
        let encoder = self.encoder
        let decoder = self.decoder
        let retention = self.retention

        return try db.write { db in
            let existingHead = try TimelineHeadRow.fetch(identity, in: db)
            var head = existingHead ?? TimelineHeadRow(identity: identity)
            if existingHead == nil {
                try head.insert(db)
            }

            var reduction = try Self.loadReductionState(
                identity: identity,
                decoder: decoder,
                in: db
            )
            var applications: [TimelineApplyResult] = []
            var wroteSnapshot = false
            var appliedTerminalEvent = false

            for event in events {
                let keys = Self.dedupeKeys(for: event)
                if try keys.contains(where: {
                    try TimelineDedupeRow.exists(identity: identity, eventKey: $0, in: db)
                }) {
                    applications.append(.ignoredDuplicateEvent)
                    continue
                }

                let application = reduction.apply(event)
                applications.append(application)
                if application == .applied, event.payload.isTerminal {
                    appliedTerminalEvent = true
                }

                let payload = try encoder.encode(event)
                head.lastSequence += 1
                let row = TimelineRecordRow(
                    identity: identity,
                    sequence: head.lastSequence,
                    recordID: event.id,
                    sourceEventID: event.sourceEventID,
                    turnID: event.turnID,
                    kind: event.payload.kind,
                    payloadJSON: payload,
                    payloadBytes: payload.count,
                    occurredAt: event.occurredAt
                )
                try row.insert(db)
                head.recordCount += 1
                head.payloadBytes += payload.count
                head.lastSourceCursor = event.sourceEventID ?? head.lastSourceCursor

                for key in keys {
                    try TimelineDedupeRow(
                        identity: identity,
                        eventKey: key,
                        seenAt: Date().timeIntervalSince1970
                    ).insert(db)
                }
            }

            head.activeTurnID = reduction.projection.activeTurnID
            head.updatedAt = Date().timeIntervalSince1970

            if appliedTerminalEvent
                || head.recordCount >= retention.snapshotRecordThreshold
                || head.payloadBytes >= retention.snapshotByteThreshold {
                try Self.writeSnapshot(
                    reduction.projection,
                    identity: identity,
                    throughSequence: head.lastSequence,
                    encoder: encoder,
                    in: db
                )
                try TimelineRecordRow.delete(
                    identity: identity,
                    throughSequence: head.lastSequence,
                    in: db
                )
                head.snapshotSequence = head.lastSequence
                head.recordCount = 0
                head.payloadBytes = 0
                wroteSnapshot = true
            }

            try head.save(db)
            try Self.pruneDedupe(identity: identity, limit: retention.maxDedupeKeysPerSession, in: db)
            try Self.enforceLimits(
                retaining: identity,
                policy: retention,
                in: db
            )

            return TimelineCommitResult(
                projection: reduction.projection,
                applications: applications,
                lastSequence: head.lastSequence,
                wroteSnapshot: wroteSnapshot
            )
        }
    }

    /// Restore the latest snapshot and replay only records newer than it.
    func loadProjection(identity: CacheIdentity) throws -> TimelineProjection? {
        let decoder = self.decoder
        return try db.write { db in
            guard try TimelineHeadRow.fetch(identity, in: db) != nil else { return nil }
            let state = try Self.loadReductionState(identity: identity, decoder: decoder, in: db)
            let accessedAt = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                    UPDATE timeline_snapshot SET accessedAt = ?
                    WHERE serverId = ? AND profileId = ? AND sessionId = ?
                    """,
                arguments: [
                    accessedAt,
                    identity.serverId,
                    identity.profileId,
                    identity.sessionId,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE timeline_head SET updatedAt = ?
                    WHERE serverId = ? AND profileId = ? AND sessionId = ?
                    """,
                arguments: [
                    accessedAt,
                    identity.serverId,
                    identity.profileId,
                    identity.sessionId,
                ]
            )
            return state.projection
        }
    }

    /// Force a projection snapshot without requiring a terminal event. Useful
    /// for scene-background flushes and killed-app recovery boundaries.
    @discardableResult
    func compact(identity: CacheIdentity) throws -> Bool {
        let encoder = self.encoder
        let decoder = self.decoder
        return try db.write { db in
            guard var head = try TimelineHeadRow.fetch(identity, in: db) else { return false }
            let state = try Self.loadReductionState(identity: identity, decoder: decoder, in: db)
            try Self.writeSnapshot(
                state.projection,
                identity: identity,
                throughSequence: head.lastSequence,
                encoder: encoder,
                in: db
            )
            try TimelineRecordRow.delete(
                identity: identity,
                throughSequence: head.lastSequence,
                in: db
            )
            head.snapshotSequence = head.lastSequence
            head.recordCount = 0
            head.payloadBytes = 0
            head.updatedAt = Date().timeIntervalSince1970
            try head.save(db)
            return true
        }
    }

    func remove(identity: CacheIdentity) throws {
        try db.write { db in
            try TimelineHeadRow.delete(identity: identity, in: db)
        }
    }

    func stats() throws -> TimelineStoreStats {
        try db.read { db in
            let recordBytes = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(payloadBytes), 0) FROM timeline_record"
            ) ?? 0
            let snapshotBytes = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(payloadBytes), 0) FROM timeline_snapshot"
            ) ?? 0
            return TimelineStoreStats(
                heads: try TimelineHeadRow.fetchCount(db),
                records: try TimelineRecordRow.fetchCount(db),
                snapshots: try TimelineSnapshotRow.fetchCount(db),
                dedupeKeys: try TimelineDedupeRow.fetchCount(db),
                payloadBytes: recordBytes + snapshotBytes
            )
        }
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("timeline-v1") { db in
            try db.execute(sql: """
                CREATE TABLE timeline_head (
                    serverId TEXT NOT NULL,
                    profileId TEXT NOT NULL,
                    sessionId TEXT NOT NULL,
                    lastSequence INTEGER NOT NULL DEFAULT 0 CHECK(lastSequence >= 0),
                    snapshotSequence INTEGER NOT NULL DEFAULT 0 CHECK(snapshotSequence >= 0),
                    activeTurnID TEXT,
                    lastSourceCursor TEXT,
                    recordCount INTEGER NOT NULL DEFAULT 0 CHECK(recordCount >= 0),
                    payloadBytes INTEGER NOT NULL DEFAULT 0 CHECK(payloadBytes >= 0),
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(serverId, profileId, sessionId)
                ) STRICT, WITHOUT ROWID;

                CREATE TABLE timeline_record (
                    serverId TEXT NOT NULL,
                    profileId TEXT NOT NULL,
                    sessionId TEXT NOT NULL,
                    sequence INTEGER NOT NULL CHECK(sequence > 0),
                    recordID TEXT NOT NULL,
                    sourceEventID TEXT,
                    turnID TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    payloadJSON BLOB NOT NULL,
                    payloadBytes INTEGER NOT NULL CHECK(payloadBytes >= 0),
                    occurredAt REAL NOT NULL,
                    PRIMARY KEY(serverId, profileId, sessionId, sequence),
                    UNIQUE(serverId, profileId, sessionId, recordID),
                    FOREIGN KEY(serverId, profileId, sessionId)
                        REFERENCES timeline_head(serverId, profileId, sessionId)
                        ON DELETE CASCADE
                ) STRICT, WITHOUT ROWID;

                CREATE UNIQUE INDEX timeline_record_source_event
                    ON timeline_record(serverId, profileId, sessionId, sourceEventID)
                    WHERE sourceEventID IS NOT NULL;
                CREATE INDEX timeline_record_turn
                    ON timeline_record(serverId, profileId, sessionId, turnID, sequence);

                CREATE TABLE timeline_snapshot (
                    serverId TEXT NOT NULL,
                    profileId TEXT NOT NULL,
                    sessionId TEXT NOT NULL,
                    throughSequence INTEGER NOT NULL CHECK(throughSequence >= 0),
                    schemaVersion INTEGER NOT NULL,
                    projectionJSON BLOB NOT NULL,
                    payloadBytes INTEGER NOT NULL CHECK(payloadBytes >= 0),
                    accessedAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(serverId, profileId, sessionId),
                    FOREIGN KEY(serverId, profileId, sessionId)
                        REFERENCES timeline_head(serverId, profileId, sessionId)
                        ON DELETE CASCADE
                ) STRICT, WITHOUT ROWID;
                CREATE INDEX timeline_snapshot_accessed ON timeline_snapshot(accessedAt);

                CREATE TABLE timeline_dedupe (
                    serverId TEXT NOT NULL,
                    profileId TEXT NOT NULL,
                    sessionId TEXT NOT NULL,
                    eventKey TEXT NOT NULL,
                    seenAt REAL NOT NULL,
                    PRIMARY KEY(serverId, profileId, sessionId, eventKey),
                    FOREIGN KEY(serverId, profileId, sessionId)
                        REFERENCES timeline_head(serverId, profileId, sessionId)
                        ON DELETE CASCADE
                ) STRICT, WITHOUT ROWID;
                CREATE INDEX timeline_dedupe_seen
                    ON timeline_dedupe(serverId, profileId, sessionId, seenAt DESC);
                """)
        }
        return migrator
    }

    private static func loadReductionState(
        identity: CacheIdentity,
        decoder: JSONDecoder,
        in db: Database
    ) throws -> TimelineReductionState {
        let snapshot = try TimelineSnapshotRow.fetch(identity, in: db)
        let projection = try snapshot.map {
            try decoder.decode(TimelineProjection.self, from: $0.projectionJSON)
        } ?? .empty
        var state = TimelineReductionState(projection: projection)
        let after = snapshot?.throughSequence ?? 0
        for row in try TimelineRecordRow.fetch(identity: identity, afterSequence: after, in: db) {
            let event = try decoder.decode(TimelineEvent.self, from: row.payloadJSON)
            _ = state.apply(event)
        }
        return state
    }

    private static func writeSnapshot(
        _ projection: TimelineProjection,
        identity: CacheIdentity,
        throughSequence: Int,
        encoder: JSONEncoder,
        in db: Database
    ) throws {
        let data = try encoder.encode(projection)
        let now = Date().timeIntervalSince1970
        try TimelineSnapshotRow(
            identity: identity,
            throughSequence: throughSequence,
            schemaVersion: 1,
            projectionJSON: data,
            payloadBytes: data.count,
            accessedAt: now,
            updatedAt: now
        ).save(db)
    }

    private static func dedupeKeys(for event: TimelineEvent) -> [String] {
        var keys = ["record:\(event.id)"]
        if let sourceEventID = event.sourceEventID, !sourceEventID.isEmpty {
            keys.append("source:\(sourceEventID)")
        }
        return keys
    }

    private static func pruneDedupe(
        identity: CacheIdentity,
        limit: Int,
        in db: Database
    ) throws {
        guard limit > 0 else {
            try TimelineDedupeRow.delete(identity: identity, in: db)
            return
        }
        let stale = try String.fetchAll(
            db,
            sql: """
                SELECT eventKey FROM timeline_dedupe
                WHERE serverId = ? AND profileId = ? AND sessionId = ?
                ORDER BY seenAt DESC, eventKey DESC
                LIMIT -1 OFFSET ?
                """,
            arguments: [identity.serverId, identity.profileId, identity.sessionId, limit]
        )
        for key in stale {
            try db.execute(
                sql: """
                    DELETE FROM timeline_dedupe
                    WHERE serverId = ? AND profileId = ? AND sessionId = ? AND eventKey = ?
                    """,
                arguments: [identity.serverId, identity.profileId, identity.sessionId, key]
            )
        }
    }

    private static func enforceLimits(
        retaining identity: CacheIdentity,
        policy: TimelineRetentionPolicy,
        in db: Database
    ) throws {
        var headCount = try TimelineHeadRow.fetchCount(db)
        var payloadBytes = try totalPayloadBytes(in: db)
        guard headCount > policy.maxSessions || payloadBytes > policy.maxTotalBytes else { return }

        let candidates = try TimelineHeadRow
            .order(Column("updatedAt").asc)
            .fetchAll(db)
            .filter {
                $0.serverId != identity.serverId
                    || $0.profileId != identity.profileId
                    || $0.sessionId != identity.sessionId
            }
        // Prefer finalized sessions, but fall back to the oldest abandoned
        // active projection so the database remains bounded after repeated
        // crashes or never-reconciled sessions.
        let evictionOrder = candidates.filter { $0.activeTurnID == nil }
            + candidates.filter { $0.activeTurnID != nil }

        for candidate in evictionOrder {
            guard headCount > policy.maxSessions || payloadBytes > policy.maxTotalBytes else { break }
            try candidate.delete(db)
            headCount -= 1
            payloadBytes = try totalPayloadBytes(in: db)
        }
    }

    private static func totalPayloadBytes(in db: Database) throws -> Int {
        let records = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(payloadBytes), 0) FROM timeline_record"
        ) ?? 0
        let snapshots = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(payloadBytes), 0) FROM timeline_snapshot"
        ) ?? 0
        return records + snapshots
    }

    private static func databaseURL() throws -> URL {
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("HermesMobile", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(databaseName)
    }
}

private struct TimelineHeadRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "timeline_head"

    let serverId: String
    let profileId: String
    let sessionId: String
    var lastSequence: Int
    var snapshotSequence: Int
    var activeTurnID: String?
    var lastSourceCursor: String?
    var recordCount: Int
    var payloadBytes: Int
    var updatedAt: Double

    init(identity: CacheIdentity) {
        serverId = identity.serverId
        profileId = identity.profileId
        sessionId = identity.sessionId
        lastSequence = 0
        snapshotSequence = 0
        activeTurnID = nil
        lastSourceCursor = nil
        recordCount = 0
        payloadBytes = 0
        updatedAt = Date().timeIntervalSince1970
    }

    static func fetch(_ identity: CacheIdentity, in db: Database) throws -> TimelineHeadRow? {
        try filter(identity).fetchOne(db)
    }

    static func delete(identity: CacheIdentity, in db: Database) throws {
        _ = try filter(identity).deleteAll(db)
    }

    private static func filter(_ identity: CacheIdentity) -> QueryInterfaceRequest<TimelineHeadRow> {
        all()
            .filter(Column("serverId") == identity.serverId)
            .filter(Column("profileId") == identity.profileId)
            .filter(Column("sessionId") == identity.sessionId)
    }
}

private struct TimelineRecordRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "timeline_record"

    let serverId: String
    let profileId: String
    let sessionId: String
    let sequence: Int
    let recordID: String
    let sourceEventID: String?
    let turnID: String
    let kind: String
    let payloadJSON: Data
    let payloadBytes: Int
    let occurredAt: Double

    init(
        identity: CacheIdentity,
        sequence: Int,
        recordID: String,
        sourceEventID: String?,
        turnID: String,
        kind: String,
        payloadJSON: Data,
        payloadBytes: Int,
        occurredAt: Double
    ) {
        serverId = identity.serverId
        profileId = identity.profileId
        sessionId = identity.sessionId
        self.sequence = sequence
        self.recordID = recordID
        self.sourceEventID = sourceEventID
        self.turnID = turnID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.payloadBytes = payloadBytes
        self.occurredAt = occurredAt
    }

    static func fetch(
        identity: CacheIdentity,
        afterSequence: Int,
        in db: Database
    ) throws -> [TimelineRecordRow] {
        try all()
            .filter(Column("serverId") == identity.serverId)
            .filter(Column("profileId") == identity.profileId)
            .filter(Column("sessionId") == identity.sessionId)
            .filter(Column("sequence") > afterSequence)
            .order(Column("sequence").asc)
            .fetchAll(db)
    }

    static func delete(
        identity: CacheIdentity,
        throughSequence: Int,
        in db: Database
    ) throws {
        _ = try all()
            .filter(Column("serverId") == identity.serverId)
            .filter(Column("profileId") == identity.profileId)
            .filter(Column("sessionId") == identity.sessionId)
            .filter(Column("sequence") <= throughSequence)
            .deleteAll(db)
    }
}

private struct TimelineSnapshotRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "timeline_snapshot"

    let serverId: String
    let profileId: String
    let sessionId: String
    let throughSequence: Int
    let schemaVersion: Int
    let projectionJSON: Data
    let payloadBytes: Int
    let accessedAt: Double
    let updatedAt: Double

    init(
        identity: CacheIdentity,
        throughSequence: Int,
        schemaVersion: Int,
        projectionJSON: Data,
        payloadBytes: Int,
        accessedAt: Double,
        updatedAt: Double
    ) {
        serverId = identity.serverId
        profileId = identity.profileId
        sessionId = identity.sessionId
        self.throughSequence = throughSequence
        self.schemaVersion = schemaVersion
        self.projectionJSON = projectionJSON
        self.payloadBytes = payloadBytes
        self.accessedAt = accessedAt
        self.updatedAt = updatedAt
    }

    static func fetch(_ identity: CacheIdentity, in db: Database) throws -> TimelineSnapshotRow? {
        try all()
            .filter(Column("serverId") == identity.serverId)
            .filter(Column("profileId") == identity.profileId)
            .filter(Column("sessionId") == identity.sessionId)
            .fetchOne(db)
    }
}

private struct TimelineDedupeRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "timeline_dedupe"

    let serverId: String
    let profileId: String
    let sessionId: String
    let eventKey: String
    let seenAt: Double

    init(identity: CacheIdentity, eventKey: String, seenAt: Double) {
        serverId = identity.serverId
        profileId = identity.profileId
        sessionId = identity.sessionId
        self.eventKey = eventKey
        self.seenAt = seenAt
    }

    static func exists(identity: CacheIdentity, eventKey: String, in db: Database) throws -> Bool {
        try all()
            .filter(Column("serverId") == identity.serverId)
            .filter(Column("profileId") == identity.profileId)
            .filter(Column("sessionId") == identity.sessionId)
            .filter(Column("eventKey") == eventKey)
            .fetchCount(db) > 0
    }

    static func delete(identity: CacheIdentity, in db: Database) throws {
        _ = try all()
            .filter(Column("serverId") == identity.serverId)
            .filter(Column("profileId") == identity.profileId)
            .filter(Column("sessionId") == identity.sessionId)
            .deleteAll(db)
    }
}
