import Foundation
import SQLite3

struct HealthFactRecord: Codable, Equatable, Identifiable, Sendable {
    enum Payload: Codable, Equatable, Sendable {
        case quantity(value: Double, unit: String)
        case category(rawValue: Int)
        case workout(activityType: UInt, duration: TimeInterval, activeEnergyKilocalories: Double?)

        private enum CodingKeys: String, CodingKey {
            case kind
            case value
            case unit
            case rawValue
            case activityType
            case duration
            case activeEnergyKilocalories
        }

        private enum Kind: String, Codable {
            case quantity
            case category
            case workout
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .quantity(value, unit):
                try container.encode(Kind.quantity, forKey: .kind)
                try container.encode(value, forKey: .value)
                try container.encode(unit, forKey: .unit)
            case let .category(rawValue):
                try container.encode(Kind.category, forKey: .kind)
                try container.encode(rawValue, forKey: .rawValue)
            case let .workout(activityType, duration, activeEnergyKilocalories):
                try container.encode(Kind.workout, forKey: .kind)
                try container.encode(activityType, forKey: .activityType)
                try container.encode(duration, forKey: .duration)
                try container.encode(activeEnergyKilocalories, forKey: .activeEnergyKilocalories)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .quantity:
                self = try .quantity(
                    value: container.decode(Double.self, forKey: .value),
                    unit: container.decode(String.self, forKey: .unit)
                )
            case .category:
                self = try .category(rawValue: container.decode(Int.self, forKey: .rawValue))
            case .workout:
                self = try .workout(
                    activityType: container.decode(UInt.self, forKey: .activityType),
                    duration: container.decode(TimeInterval.self, forKey: .duration),
                    activeEnergyKilocalories: container.decodeIfPresent(Double.self, forKey: .activeEnergyKilocalories)
                )
            }
        }
    }

    let id: UUID
    let kind: HealthReadKind
    let startDate: Date
    let endDate: Date
    let sourceName: String
    let sourceBundleIdentifier: String
    let payload: Payload
}

struct HealthFactTombstone: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: HealthReadKind
    let deletedAt: Date
}

/// A factual local summary. It is intentionally not an aggregate, health score, or diagnosis.
struct HealthFactCoverage: Equatable, Identifiable, Sendable {
    let kind: HealthReadKind
    let factCount: Int
    let latestFactEndDate: Date?

    var id: HealthReadKind { kind }
}

struct HealthFactQueueSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var observations: [UUID: HealthFactRecord]
    var tombstones: [UUID: HealthFactTombstone]

    static let empty = HealthFactQueueSnapshot(version: currentVersion, observations: [:], tombstones: [:])

    mutating func apply(
        records: [HealthFactRecord],
        deletedIDs: [UUID],
        kind: HealthReadKind,
        at date: Date
    ) {
        for record in records {
            observations[record.id] = record
            tombstones.removeValue(forKey: record.id)
        }

        for id in deletedIDs {
            observations.removeValue(forKey: id)
            tombstones[id] = HealthFactTombstone(id: id, kind: kind, deletedAt: date)
        }
    }
}

protocol HealthFactQueueStoring: Sendable {
    func status() throws -> HealthFactQueueStatus
    func apply(
        records: [HealthFactRecord],
        deletedIDs: [UUID],
        kind: HealthReadKind,
        at date: Date
    ) throws
    func pendingTransfer(sourceInstallationID: UUID, maximumMutations: Int, at: Date) throws -> HealthFactPendingTransfer?
    func acknowledgeTransfer(_ acknowledgement: HealthSyncAcknowledgement) throws
}

/// A stable, persisted export unit. It remains available until the Mac confirms the same batch;
/// a retry therefore never invents a second batch for the same mutations.
struct HealthFactPendingTransfer: Equatable, Sendable {
    let batch: HealthArchiveBatch
    let mutationCount: Int
}

private struct HealthFactMutation: Codable, Sendable {
    enum Change: Codable, Sendable {
        case observation(HealthFactRecord)
        case tombstone(HealthFactTombstone)

        private enum CodingKeys: String, CodingKey { case kind, record, tombstone }
        private enum Kind: String, Codable { case observation, tombstone }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .observation(record):
                try container.encode(Kind.observation, forKey: .kind)
                try container.encode(record, forKey: .record)
            case let .tombstone(tombstone):
                try container.encode(Kind.tombstone, forKey: .kind)
                try container.encode(tombstone, forKey: .tombstone)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .observation: self = .observation(try container.decode(HealthFactRecord.self, forKey: .record))
            case .tombstone: self = .tombstone(try container.decode(HealthFactTombstone.self, forKey: .tombstone))
            }
        }
    }

    let sequence: Int64
    let id: UUID
    let change: Change
}

private struct HealthFactPendingBatchRecord: Sendable {
    let batch: HealthArchiveBatch
    let mutationCount: Int
    let throughSequence: Int64
}

final class HealthFactQueueStore: HealthFactQueueStoring, @unchecked Sendable {
    private let databaseURL: URL
    private let legacyFileURL: URL
    private let fileManager: FileManager

    init(
        databaseURL: URL? = nil,
        legacyFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL(fileManager: fileManager)
        self.legacyFileURL = legacyFileURL ?? Self.defaultLegacyFileURL(fileManager: fileManager)
    }

    func status() throws -> HealthFactQueueStatus {
        try withDatabase { database in
            try ensureOutboxBaseline(on: database)
            let factCount = try countRows(in: database, table: "observations")
            let tombstoneCount = try countRows(in: database, table: "tombstones")
            let pendingMutationCount = try countRows(in: database, table: "sync_mutations")
            let recentFacts = try readRecentFacts(from: database, limit: 50)
            let coverage = try readCoverage(from: database)
            return HealthFactQueueStatus(
                factCount: factCount,
                tombstoneCount: tombstoneCount,
                pendingMutationCount: pendingMutationCount,
                recentFacts: recentFacts,
                coverage: coverage
            )
        }
    }

    func apply(
        records: [HealthFactRecord],
        deletedIDs: [UUID],
        kind: HealthReadKind,
        at date: Date
    ) throws {
        try withDatabase { database in
            try ensureOutboxBaseline(on: database)
            try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
            do {
                for record in records {
                    try upsert(record, into: database)
                    try deleteTombstone(id: record.id, from: database)
                    try appendMutation(.observation(record), to: database)
                }

                for id in deletedIDs {
                    try deleteObservation(id: id, from: database)
                    let tombstone = HealthFactTombstone(id: id, kind: kind, deletedAt: date)
                    try upsertTombstone(tombstone, into: database)
                    try appendMutation(.tombstone(tombstone), to: database)
                }
                try execute("COMMIT", on: database)
            } catch {
                try? execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    func pendingTransfer(
        sourceInstallationID: UUID,
        maximumMutations: Int = 2_000,
        at date: Date = .now
    ) throws -> HealthFactPendingTransfer? {
        guard (1...2_000).contains(maximumMutations) else { throw QueueError.invalidMutationLimit }
        return try withDatabase { database in
            try ensureOutboxBaseline(on: database)
            if let existing = try readPendingBatch(from: database) { return existing }
            let mutations = try readMutations(from: database, limit: maximumMutations)
            guard !mutations.isEmpty else { return nil }
            let latestByID = Dictionary(
                mutations.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let ordered = latestByID.values.sorted { $0.sequence < $1.sequence }
            let observations = try ordered.compactMap { mutation -> HealthObservation? in
                guard case let .observation(record) = mutation.change else { return nil }
                return try archiveObservation(record, sourceInstallationID: sourceInstallationID, receivedAt: date)
            }
            let tombstones = try ordered.compactMap { mutation -> HealthObservationTombstone? in
                guard case let .tombstone(tombstone) = mutation.change else { return nil }
                return try archiveTombstone(tombstone, sourceInstallationID: sourceInstallationID)
            }
            let batch = try HealthArchiveBatch(
                sourceInstallationID: sourceInstallationID,
                createdAt: date,
                observations: observations,
                tombstones: tombstones
            )
            let pending = HealthFactPendingTransfer(batch: batch, mutationCount: mutations.count)
            try writePendingBatch(pending, throughSequence: mutations.last!.sequence, to: database)
            return pending
        }
    }

    func acknowledgeTransfer(_ acknowledgement: HealthSyncAcknowledgement) throws {
        try withDatabase { database in
            try ensureOutboxBaseline(on: database)
            guard let pending = try readPendingBatchRecord(from: database) else { return }
            guard pending.batch.sourceInstallationID == acknowledgement.sourceInstallationID,
                  pending.batch.batchID == acknowledgement.batchID else {
                throw QueueError.unexpectedAcknowledgement
            }
            try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
            do {
                let statement = try prepare("DELETE FROM sync_mutations WHERE sequence <= ?", on: database)
                defer { sqlite3_finalize(statement) }
                bind(pending.throughSequence, to: statement, at: 1)
                try stepDone(statement, on: database)
                try execute("DELETE FROM sync_outbound_batches", on: database)
                try execute("COMMIT", on: database)
            } catch {
                try? execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw QueueError.openFailed(databaseURL.path)
        }
        defer { sqlite3_close(database) }

        try execute("PRAGMA journal_mode = WAL", on: database)
        try execute("PRAGMA synchronous = FULL", on: database)
        try createTablesIfNeeded(on: database)
        try migrateLegacyJSONIfNeeded(on: database)
        let result = try operation(database)
        try applyFileProtection()
        return result
    }

    private func createTablesIfNeeded(on database: OpaquePointer) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS observations (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            start_date REAL NOT NULL,
            end_date REAL NOT NULL,
            source_name TEXT NOT NULL,
            source_bundle_identifier TEXT NOT NULL,
            payload_kind INTEGER NOT NULL,
            quantity_value REAL,
            quantity_unit TEXT,
            category_raw_value INTEGER,
            workout_activity_type INTEGER,
            workout_duration REAL,
            workout_energy_kilocalories REAL
        )
        """, on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS tombstones (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            deleted_at REAL NOT NULL
        )
        """, on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS queue_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        )
        """, on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS sync_mutations (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            fact_id TEXT NOT NULL,
            payload TEXT NOT NULL
        )
        """, on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS sync_outbound_batches (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            batch_id TEXT NOT NULL,
            source_installation_id TEXT NOT NULL,
            through_sequence INTEGER NOT NULL,
            mutation_count INTEGER NOT NULL,
            payload TEXT NOT NULL
        )
        """, on: database)
        try execute(
            "CREATE INDEX IF NOT EXISTS observations_start_date ON observations(start_date DESC)",
            on: database
        )
    }

    private func migrateLegacyJSONIfNeeded(on database: OpaquePointer) throws {
        guard try metadataValue(for: "legacy-json-migrated", in: database) == nil else { return }
        guard fileManager.fileExists(atPath: legacyFileURL.path) else {
            try setMetadataValue("none", for: "legacy-json-migrated", in: database)
            return
        }

        let data = try Data(contentsOf: legacyFileURL)
        let snapshot = try JSONDecoder().decode(HealthFactQueueSnapshot.self, from: data)
        guard snapshot.version == HealthFactQueueSnapshot.currentVersion else {
            throw QueueError.unsupportedVersion(snapshot.version)
        }

        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            for record in snapshot.observations.values {
                try upsert(record, into: database)
            }
            for tombstone in snapshot.tombstones.values {
                try deleteObservation(id: tombstone.id, from: database)
                try upsertTombstone(tombstone, into: database)
            }
            try setMetadataValue("complete", for: "legacy-json-migrated", in: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    private func upsert(_ record: HealthFactRecord, into database: OpaquePointer) throws {
        let statement = try prepare("""
        INSERT INTO observations (
            id, kind, start_date, end_date, source_name, source_bundle_identifier, payload_kind,
            quantity_value, quantity_unit, category_raw_value, workout_activity_type,
            workout_duration, workout_energy_kilocalories
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            start_date = excluded.start_date,
            end_date = excluded.end_date,
            source_name = excluded.source_name,
            source_bundle_identifier = excluded.source_bundle_identifier,
            payload_kind = excluded.payload_kind,
            quantity_value = excluded.quantity_value,
            quantity_unit = excluded.quantity_unit,
            category_raw_value = excluded.category_raw_value,
            workout_activity_type = excluded.workout_activity_type,
            workout_duration = excluded.workout_duration,
            workout_energy_kilocalories = excluded.workout_energy_kilocalories
        """, on: database)
        defer { sqlite3_finalize(statement) }

        bind(record.id.uuidString, to: statement, at: 1)
        bind(record.kind.rawValue, to: statement, at: 2)
        bind(record.startDate.timeIntervalSince1970, to: statement, at: 3)
        bind(record.endDate.timeIntervalSince1970, to: statement, at: 4)
        bind(record.sourceName, to: statement, at: 5)
        bind(record.sourceBundleIdentifier, to: statement, at: 6)

        switch record.payload {
        case let .quantity(value, unit):
            bind(Int64(0), to: statement, at: 7)
            bind(value, to: statement, at: 8)
            bind(unit, to: statement, at: 9)
            bindNulls(statement, indexes: [10, 11, 12, 13])
        case let .category(rawValue):
            bind(Int64(1), to: statement, at: 7)
            bindNulls(statement, indexes: [8, 9])
            bind(Int64(rawValue), to: statement, at: 10)
            bindNulls(statement, indexes: [11, 12, 13])
        case let .workout(activityType, duration, activeEnergyKilocalories):
            bind(Int64(2), to: statement, at: 7)
            bindNulls(statement, indexes: [8, 9, 10])
            bind(Int64(activityType), to: statement, at: 11)
            bind(duration, to: statement, at: 12)
            if let activeEnergyKilocalories {
                bind(activeEnergyKilocalories, to: statement, at: 13)
            } else {
                sqlite3_bind_null(statement, 13)
            }
        }
        try stepDone(statement, on: database)
    }

    /// Existing queue databases predate the durable outbox. Their current factual state becomes
    /// the first transfer exactly once, so upgrading the app cannot silently skip past history.
    private func ensureOutboxBaseline(on database: OpaquePointer) throws {
        guard try metadataValue(for: "sync-outbox-baseline-v1", in: database) == nil else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            for record in try readAllFacts(from: database) {
                try appendMutation(.observation(record), to: database)
            }
            for tombstone in try readAllTombstones(from: database) {
                try appendMutation(.tombstone(tombstone), to: database)
            }
            try setMetadataValue("complete", for: "sync-outbox-baseline-v1", in: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    private func appendMutation(_ change: HealthFactMutation.Change, to database: OpaquePointer) throws {
        let id: UUID
        switch change {
        case let .observation(record): id = record.id
        case let .tombstone(tombstone): id = tombstone.id
        }
        let statement = try prepare("INSERT INTO sync_mutations(fact_id, payload) VALUES (?, ?)", on: database)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        bind(try canonicalJSON(change), to: statement, at: 2)
        try stepDone(statement, on: database)
    }

    private func readMutations(from database: OpaquePointer, limit: Int) throws -> [HealthFactMutation] {
        let statement = try prepare(
            "SELECT sequence, fact_id, payload FROM sync_mutations ORDER BY sequence ASC LIMIT ?",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        bind(Int64(limit), to: statement, at: 1)
        var result: [HealthFactMutation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: stringColumn(statement, 1)) else {
                throw QueueError.invalidStoredSyncData
            }
            let change = try decodeJSON(HealthFactMutation.Change.self, from: stringColumn(statement, 2))
            let changeID: UUID
            switch change {
            case let .observation(record): changeID = record.id
            case let .tombstone(tombstone): changeID = tombstone.id
            }
            guard id == changeID else { throw QueueError.invalidStoredSyncData }
            result.append(HealthFactMutation(sequence: sqlite3_column_int64(statement, 0), id: id, change: change))
        }
        return result
    }

    private func readPendingBatch(from database: OpaquePointer) throws -> HealthFactPendingTransfer? {
        guard let record = try readPendingBatchRecord(from: database) else { return nil }
        return HealthFactPendingTransfer(batch: record.batch, mutationCount: record.mutationCount)
    }

    private func readPendingBatchRecord(from database: OpaquePointer) throws -> HealthFactPendingBatchRecord? {
        let statement = try prepare(
            "SELECT batch_id, source_installation_id, through_sequence, mutation_count, payload FROM sync_outbound_batches WHERE singleton = 1",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let batchIDRaw = stringColumn(statement, 0)
        let sourceRaw = stringColumn(statement, 1)
        let throughSequence = sqlite3_column_int64(statement, 2)
        let mutationCountRaw = sqlite3_column_int64(statement, 3)
        let payload = stringColumn(statement, 4)
        guard sqlite3_step(statement) != SQLITE_ROW,
              let batchID = UUID(uuidString: batchIDRaw),
              let sourceInstallationID = UUID(uuidString: sourceRaw) else {
            throw QueueError.invalidStoredSyncData
        }
        let batch = try decodeJSON(HealthArchiveBatch.self, from: payload)
        guard batch.batchID == batchID, batch.sourceInstallationID == sourceInstallationID else {
            throw QueueError.invalidStoredSyncData
        }
        let mutationCount = Int(mutationCountRaw)
        guard mutationCount > 0 else { throw QueueError.invalidStoredSyncData }
        return HealthFactPendingBatchRecord(
            batch: batch,
            mutationCount: mutationCount,
            throughSequence: throughSequence
        )
    }

    private func writePendingBatch(
        _ pending: HealthFactPendingTransfer,
        throughSequence: Int64,
        to database: OpaquePointer
    ) throws {
        let statement = try prepare("""
        INSERT INTO sync_outbound_batches(
            singleton, batch_id, source_installation_id, through_sequence, mutation_count, payload
        ) VALUES (1, ?, ?, ?, ?, ?)
        """, on: database)
        defer { sqlite3_finalize(statement) }
        bind(pending.batch.batchID.uuidString, to: statement, at: 1)
        bind(pending.batch.sourceInstallationID.uuidString, to: statement, at: 2)
        bind(throughSequence, to: statement, at: 3)
        bind(Int64(pending.mutationCount), to: statement, at: 4)
        bind(try canonicalJSON(pending.batch), to: statement, at: 5)
        try stepDone(statement, on: database)
    }

    private func readAllFacts(from database: OpaquePointer) throws -> [HealthFactRecord] {
        try readFacts(
            sql: """
            SELECT id, kind, start_date, end_date, source_name, source_bundle_identifier, payload_kind,
                   quantity_value, quantity_unit, category_raw_value, workout_activity_type,
                   workout_duration, workout_energy_kilocalories
            FROM observations ORDER BY start_date ASC, id ASC
            """,
            from: database
        )
    }

    private func readAllTombstones(from database: OpaquePointer) throws -> [HealthFactTombstone] {
        let statement = try prepare("SELECT id, kind, deleted_at FROM tombstones ORDER BY deleted_at ASC, id ASC", on: database)
        defer { sqlite3_finalize(statement) }
        var result: [HealthFactTombstone] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: stringColumn(statement, 0)),
                  let kind = HealthReadKind(rawValue: stringColumn(statement, 1)) else {
                throw QueueError.invalidStoredSyncData
            }
            result.append(HealthFactTombstone(
                id: id, kind: kind,
                deletedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return result
    }

    private func archiveObservation(
        _ record: HealthFactRecord,
        sourceInstallationID: UUID,
        receivedAt: Date
    ) throws -> HealthObservation {
        guard let kind = HealthObservationKind(rawValue: record.kind.rawValue) else {
            throw QueueError.invalidStoredSyncData
        }
        let payload: HealthObservationPayload
        switch record.payload {
        case let .quantity(value, unit): payload = try .init(quantityValue: value, unit: unit)
        case let .category(rawValue): payload = .category(rawValue: rawValue)
        case let .workout(activityType, duration, activeEnergyKilocalories):
            payload = .workout(
                activityType: activityType,
                duration: duration,
                activeEnergyKilocalories: activeEnergyKilocalories
            )
        }
        return try HealthObservation(
            key: HealthObservationKey(sourceInstallationID: sourceInstallationID, healthKitUUID: record.id),
            kind: kind,
            startedAt: record.startDate,
            endedAt: record.endDate,
            source: try HealthObservationSource(
                name: record.sourceName, bundleIdentifier: record.sourceBundleIdentifier
            ),
            payload: payload,
            receivedAt: receivedAt
        )
    }

    private func archiveTombstone(
        _ tombstone: HealthFactTombstone,
        sourceInstallationID: UUID
    ) throws -> HealthObservationTombstone {
        guard let kind = HealthObservationKind(rawValue: tombstone.kind.rawValue) else {
            throw QueueError.invalidStoredSyncData
        }
        return try HealthObservationTombstone(
            key: HealthObservationKey(sourceInstallationID: sourceInstallationID, healthKitUUID: tombstone.id),
            kind: kind,
            deletedAt: tombstone.deletedAt
        )
    }

    private func upsertTombstone(_ tombstone: HealthFactTombstone, into database: OpaquePointer) throws {
        let statement = try prepare("""
        INSERT INTO tombstones (id, kind, deleted_at) VALUES (?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, deleted_at = excluded.deleted_at
        """, on: database)
        defer { sqlite3_finalize(statement) }
        bind(tombstone.id.uuidString, to: statement, at: 1)
        bind(tombstone.kind.rawValue, to: statement, at: 2)
        bind(tombstone.deletedAt.timeIntervalSince1970, to: statement, at: 3)
        try stepDone(statement, on: database)
    }

    private func deleteObservation(id: UUID, from database: OpaquePointer) throws {
        try delete(id: id, from: "observations", database: database)
    }

    private func deleteTombstone(id: UUID, from database: OpaquePointer) throws {
        try delete(id: id, from: "tombstones", database: database)
    }

    private func delete(id: UUID, from table: String, database: OpaquePointer) throws {
        let statement = try prepare("DELETE FROM \(table) WHERE id = ?", on: database)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        try stepDone(statement, on: database)
    }

    private func countRows(in database: OpaquePointer, table: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM \(table)", on: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw QueueError.queryFailed(databaseError(database)) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func readRecentFacts(from database: OpaquePointer, limit: Int) throws -> [HealthFactRecord] {
        let statement = try prepare("""
        SELECT id, kind, start_date, end_date, source_name, source_bundle_identifier, payload_kind,
               quantity_value, quantity_unit, category_raw_value, workout_activity_type,
               workout_duration, workout_energy_kilocalories
        FROM observations ORDER BY start_date DESC LIMIT ?
        """, on: database)
        defer { sqlite3_finalize(statement) }
        bind(Int64(limit), to: statement, at: 1)

        var records: [HealthFactRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: stringColumn(statement, 0)),
                  let kind = HealthReadKind(rawValue: stringColumn(statement, 1)) else {
                continue
            }
            let payload: HealthFactRecord.Payload
            switch sqlite3_column_int(statement, 6) {
            case 0:
                payload = .quantity(value: sqlite3_column_double(statement, 7), unit: stringColumn(statement, 8))
            case 1:
                payload = .category(rawValue: Int(sqlite3_column_int64(statement, 9)))
            case 2:
                payload = .workout(
                    activityType: UInt(sqlite3_column_int64(statement, 10)),
                    duration: sqlite3_column_double(statement, 11),
                    activeEnergyKilocalories: nullableDoubleColumn(statement, 12)
                )
            default:
                continue
            }
            records.append(HealthFactRecord(
                id: id,
                kind: kind,
                startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                sourceName: stringColumn(statement, 4),
                sourceBundleIdentifier: stringColumn(statement, 5),
                payload: payload
            ))
        }
        return records
    }

    private func readFacts(sql: String, from database: OpaquePointer) throws -> [HealthFactRecord] {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        var records: [HealthFactRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: stringColumn(statement, 0)),
                  let kind = HealthReadKind(rawValue: stringColumn(statement, 1)) else {
                throw QueueError.invalidStoredSyncData
            }
            let payload: HealthFactRecord.Payload
            switch sqlite3_column_int(statement, 6) {
            case 0:
                payload = .quantity(value: sqlite3_column_double(statement, 7), unit: stringColumn(statement, 8))
            case 1:
                payload = .category(rawValue: Int(sqlite3_column_int64(statement, 9)))
            case 2:
                payload = .workout(
                    activityType: UInt(sqlite3_column_int64(statement, 10)),
                    duration: sqlite3_column_double(statement, 11),
                    activeEnergyKilocalories: nullableDoubleColumn(statement, 12)
                )
            default:
                throw QueueError.invalidStoredSyncData
            }
            records.append(HealthFactRecord(
                id: id,
                kind: kind,
                startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                sourceName: stringColumn(statement, 4),
                sourceBundleIdentifier: stringColumn(statement, 5),
                payload: payload
            ))
        }
        return records
    }

    private func readCoverage(from database: OpaquePointer) throws -> [HealthFactCoverage] {
        let statement = try prepare("""
        SELECT kind, COUNT(*), MAX(end_date)
        FROM observations
        GROUP BY kind
        ORDER BY kind ASC
        """, on: database)
        defer { sqlite3_finalize(statement) }

        var coverage: [HealthFactCoverage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kind = HealthReadKind(rawValue: stringColumn(statement, 0)) else {
                continue
            }
            coverage.append(HealthFactCoverage(
                kind: kind,
                factCount: Int(sqlite3_column_int64(statement, 1)),
                latestFactEndDate: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return coverage
    }

    private func metadataValue(for key: String, in database: OpaquePointer) throws -> String? {
        let statement = try prepare("SELECT value FROM queue_metadata WHERE key = ?", on: database)
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return stringColumn(statement, 0)
    }

    private func setMetadataValue(_ value: String, for key: String, in database: OpaquePointer) throws {
        let statement = try prepare("""
        INSERT INTO queue_metadata (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, on: database)
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        bind(value, to: statement, at: 2)
        try stepDone(statement, on: database)
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw QueueError.invalidStoredSyncData
        }
        return result
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else { throw QueueError.invalidStoredSyncData }
        return try JSONDecoder().decode(type, from: data)
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw QueueError.queryFailed(databaseError(database))
        }
    }

    private func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw QueueError.queryFailed(databaseError(database))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, on database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw QueueError.queryFailed(databaseError(database))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func bindNulls(_ statement: OpaquePointer, indexes: [Int32]) {
        indexes.forEach { sqlite3_bind_null(statement, $0) }
    }

    private func stringColumn(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func nullableDoubleColumn(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func databaseError(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private func applyFileProtection() throws {
        let sidecars = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        for url in sidecars where fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }

    private static func defaultDatabaseURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("DaydayHealthCompanion", isDirectory: true)
            .appendingPathComponent("health-fact-queue-v2.sqlite", isDirectory: false)
    }

    private static func defaultLegacyFileURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("DaydayHealthCompanion", isDirectory: true)
            .appendingPathComponent("health-fact-queue-v1.json", isDirectory: false)
    }

    enum QueueError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case openFailed(String)
        case queryFailed(String)
        case invalidMutationLimit
        case invalidStoredSyncData
        case unexpectedAcknowledgement

        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version):
                return "无法读取未来版本的本地健康队列（版本 \(version)）。"
            case let .openFailed(path):
                return "无法打开本机健康队列：\(path)。"
            case let .queryFailed(message):
                return "无法更新本机健康队列：\(message)。"
            case .invalidMutationLimit:
                return "同步批次大小无效。"
            case .invalidStoredSyncData:
                return "本机健康同步队列的数据不完整或已损坏。"
            case .unexpectedAcknowledgement:
                return "收到的同步确认不属于当前待发送批次。"
            }
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HealthFactQueueStatus: Sendable {
    let factCount: Int
    let tombstoneCount: Int
    let pendingMutationCount: Int
    let recentFacts: [HealthFactRecord]
    let coverage: [HealthFactCoverage]

    init(
        factCount: Int,
        tombstoneCount: Int,
        pendingMutationCount: Int = 0,
        recentFacts: [HealthFactRecord],
        coverage: [HealthFactCoverage] = []
    ) {
        self.factCount = factCount
        self.tombstoneCount = tombstoneCount
        self.pendingMutationCount = pendingMutationCount
        self.recentFacts = recentFacts
        self.coverage = coverage
    }
}

enum HealthFactQueueWorkResult: Sendable {
    case succeeded(HealthFactQueueStatus)
    case failed(String)
}

/// The queue file can grow substantially during the first HealthKit history import. File I/O,
/// decoding, encoding, and the recent-facts projection must never run on SwiftUI's main actor.
final class HealthFactQueueWorker: @unchecked Sendable {
    private let store: HealthFactQueueStoring
    private let queue = DispatchQueue(label: "app.dayday.health-companion.queue", qos: .utility)

    init(store: HealthFactQueueStoring) {
        self.store = store
    }

    func loadStatus(completion: @escaping @MainActor (HealthFactQueueWorkResult) -> Void) {
        queue.async { [store] in
            let result: HealthFactQueueWorkResult
            do {
                result = .succeeded(try store.status())
            } catch {
                result = .failed(error.localizedDescription)
            }
            Task { @MainActor in completion(result) }
        }
    }

    func apply(
        records: [HealthFactRecord],
        deletedIDs: [UUID],
        kind: HealthReadKind,
        at date: Date,
        completion: @escaping @MainActor (HealthFactQueueWorkResult) -> Void
    ) {
        queue.async { [store] in
            let result: HealthFactQueueWorkResult
            do {
                try store.apply(records: records, deletedIDs: deletedIDs, kind: kind, at: date)
                result = .succeeded(try store.status())
            } catch {
                result = .failed(error.localizedDescription)
            }
            Task { @MainActor in completion(result) }
        }
    }

    func pendingTransfer(
        sourceInstallationID: UUID,
        maximumMutations: Int = 2_000,
        completion: @escaping @MainActor (Result<HealthFactPendingTransfer?, Error>) -> Void
    ) {
        queue.async { [store] in
            let result: Result<HealthFactPendingTransfer?, Error>
            do {
                result = .success(try store.pendingTransfer(
                    sourceInstallationID: sourceInstallationID,
                    maximumMutations: maximumMutations,
                    at: .now
                ))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in completion(result) }
        }
    }

    func acknowledgeTransfer(
        _ acknowledgement: HealthSyncAcknowledgement,
        completion: @escaping @MainActor (Result<HealthFactQueueStatus, Error>) -> Void
    ) {
        queue.async { [store] in
            let result: Result<HealthFactQueueStatus, Error>
            do {
                try store.acknowledgeTransfer(acknowledgement)
                result = .success(try store.status())
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in completion(result) }
        }
    }
}
