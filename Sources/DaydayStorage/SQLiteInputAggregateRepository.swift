import CSQLite
import DaydayCore
import Foundation

public enum InputAggregateInsertResult: Equatable, Sendable {
  case inserted
  case alreadyPresent
}

public enum DailyInputRollupApplyResult: Equatable, Sendable {
  case applied
  case alreadyApplied
}

public enum InputAggregateStoreError: Error, Equatable, Sendable {
  case invalidDateRange
  case invalidFileURL
  case database(code: Int32, message: String)
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case unsupportedPayloadSchemaVersion(found: Int, supported: Int)
  case corruptedSchema(String)
  case invalidStoredValue(column: String)
  case invalidAggregatePayload
  case nonCanonicalAggregatePayload
  case metadataPayloadMismatch(column: String)
  case identifierConflict(InputAggregateID)
  case invalidRollupPlan
  case missingRollupSource(InputAggregateID)
  case rollupSourceMismatch
  case checkpointRevisionConflict
  case checkpointPayloadConflict
}

/// Versioned SQLite storage for privacy-closed input aggregates only.
///
/// The repository has no API that accepts a key, pointer, screenshot, or raw
/// event. Production composition must inject a dedicated database file; table
/// names are additionally namespaced so an accidental shared test file cannot
/// collide with the objective-event v1 schema.
public actor SQLiteInputAggregateRepository {
  public static let currentSchemaVersion = 2
  public static let currentPayloadSchemaVersion = 1

  private static let schemaMetadataSQL =
    """
    CREATE TABLE input_aggregate_schema_metadata (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        schema_version INTEGER NOT NULL,
        schema_fingerprint TEXT NOT NULL
    ) STRICT
    """
  private static let schemaMigrationsSQL =
    """
    CREATE TABLE input_aggregate_schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at REAL NOT NULL
    ) STRICT
    """
  private static let aggregatesSQL =
    """
    CREATE TABLE input_aggregates (
        id TEXT PRIMARY KEY NOT NULL,
        period_start REAL NOT NULL,
        period_end REAL NOT NULL,
        granularity TEXT NOT NULL CHECK (granularity IN ('hour', 'day')),
        time_zone_identifier TEXT NOT NULL,
        workday_boundary_hour INTEGER,
        payload_schema_version INTEGER NOT NULL,
        payload TEXT NOT NULL,
        CHECK (period_end > period_start),
        CHECK (
            (granularity = 'hour' AND workday_boundary_hour IS NULL)
            OR
            (granularity = 'day' AND workday_boundary_hour BETWEEN 0 AND 23)
        )
    ) STRICT
    """
  private static let periodIndexSQL =
    "CREATE INDEX input_aggregates_period_start ON input_aggregates(period_start, id)"

  private static let checkpointsSQL =
    """
    CREATE TABLE input_aggregate_open_checkpoints (
        aggregate_id TEXT PRIMARY KEY NOT NULL,
        period_start REAL NOT NULL,
        period_end REAL NOT NULL,
        granularity TEXT NOT NULL CHECK (granularity = 'hour'),
        time_zone_identifier TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK (revision > 0),
        checkpointed_at REAL NOT NULL,
        payload_schema_version INTEGER NOT NULL,
        payload TEXT NOT NULL,
        CHECK (period_end > period_start)
    ) STRICT
    """
  private static let checkpointsPeriodIndexSQL =
    "CREATE INDEX input_aggregate_open_checkpoints_period_start ON input_aggregate_open_checkpoints(period_start, aggregate_id)"

  static let schema1Fingerprint = fingerprint(
    of: [schemaMetadataSQL, schemaMigrationsSQL, aggregatesSQL, periodIndexSQL]
  )
  public static let expectedSchemaFingerprint = fingerprint(
    of: [
      schemaMetadataSQL, schemaMigrationsSQL, aggregatesSQL, periodIndexSQL,
      checkpointsSQL, checkpointsPeriodIndexSQL,
    ]
  )

  private let database: InputAggregateSQLiteDatabase

  init(location: SQLiteDatabaseLocation) throws {
    let database = try InputAggregateSQLiteDatabase(location: location)
    do {
      try Self.migrate(database)
    } catch {
      database.close()
      throw error
    }
    self.database = database
  }

  public func insert(_ aggregate: InputAggregate) throws -> InputAggregateInsertResult {
    try database.transaction {
      try Self.insert(aggregate, into: database)
    }
  }

  public func openCheckpoints() throws -> [InputAggregateCheckpoint] {
    let statement = try database.prepare(
      """
      SELECT aggregate_id, period_start, period_end, granularity,
             time_zone_identifier, revision, checkpointed_at,
             payload_schema_version, payload
      FROM input_aggregate_open_checkpoints
      ORDER BY period_start ASC, aggregate_id ASC
      """
    )
    var checkpoints: [InputAggregateCheckpoint] = []
    while try statement.stepRow() {
      checkpoints.append(try Self.decodeCheckpoint(from: statement))
    }
    return checkpoints
  }

  /// Replaces one open-hour checkpoint only when its monotonically increasing
  /// revision advances. The payload is the same closed aggregate JSON used by
  /// finalized rows, never an input-event record.
  public func upsert(_ checkpoint: InputAggregateCheckpoint) throws {
    try database.transaction {
      let existing = try Self.fetchCheckpoint(id: checkpoint.aggregate.id, from: database)
      if let existing {
        guard checkpoint.revision >= existing.revision else {
          throw InputAggregateStoreError.checkpointRevisionConflict
        }
        if checkpoint.revision == existing.revision {
          guard checkpoint == existing else {
            throw InputAggregateStoreError.checkpointPayloadConflict
          }
          return
        }
        guard checkpoint.aggregate.period == existing.aggregate.period else {
          throw InputAggregateStoreError.checkpointPayloadConflict
        }
      }
      let payload = try Self.canonicalPayload(for: checkpoint.aggregate)
      let statement = try database.prepare(
        """
        INSERT INTO input_aggregate_open_checkpoints (
            aggregate_id, period_start, period_end, granularity,
            time_zone_identifier, revision, checkpointed_at,
            payload_schema_version, payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(aggregate_id) DO UPDATE SET
            period_start = excluded.period_start,
            period_end = excluded.period_end,
            granularity = excluded.granularity,
            time_zone_identifier = excluded.time_zone_identifier,
            revision = excluded.revision,
            checkpointed_at = excluded.checkpointed_at,
            payload_schema_version = excluded.payload_schema_version,
            payload = excluded.payload
        """
      )
      try Self.bind(checkpoint, payload: payload, to: statement)
      try statement.expectDone()
    }
  }

  /// Seals a completed hour atomically with removal of its open checkpoint.
  public func finalize(_ aggregate: InputAggregate) throws {
    try database.transaction {
      _ = try Self.insert(aggregate, into: database)
      let delete = try database.prepare(
        "DELETE FROM input_aggregate_open_checkpoints WHERE aggregate_id = ?"
      )
      try delete.bind(aggregate.id.rawValue.uuidString.lowercased(), at: 1)
      try delete.expectDone()
    }
  }

  /// Returns aggregates whose period start is inside the half-open range.
  /// Ordering is stable by absolute start instant and then aggregate UUID.
  public func fetch(startingIn range: Range<Date>) throws -> [InputAggregate] {
    let lower = range.lowerBound.timeIntervalSinceReferenceDate
    let upper = range.upperBound.timeIntervalSinceReferenceDate
    guard lower.isFinite, upper.isFinite, lower < upper else {
      throw InputAggregateStoreError.invalidDateRange
    }

    let statement = try database.prepare(
      """
      SELECT
          id, period_start, period_end, granularity,
          time_zone_identifier, workday_boundary_hour,
          payload_schema_version, payload
      FROM input_aggregates
      WHERE period_start >= ? AND period_start < ?
      ORDER BY period_start ASC, id ASC
      """
    )
    try statement.bind(lower, at: 1)
    try statement.bind(upper, at: 2)

    var aggregates: [InputAggregate] = []
    while try statement.stepRow() {
      aggregates.append(try Self.decodeAggregate(from: statement))
    }
    return aggregates
  }

  /// Returns hourly aggregates whose period ends at or before `cutoff`, ordered
  /// by period start. This is the retention scan for daily rollup; daily rows
  /// are excluded because they are already-coarsened retained evidence.
  public func fetchHoursEndingBefore(_ cutoff: Date) throws -> [InputAggregate] {
    guard cutoff.timeIntervalSinceReferenceDate.isFinite else {
      throw InputAggregateStoreError.invalidDateRange
    }

    let statement = try database.prepare(
      """
      SELECT
          id, period_start, period_end, granularity,
          time_zone_identifier, workday_boundary_hour,
          payload_schema_version, payload
      FROM input_aggregates
      WHERE granularity = 'hour' AND period_end <= ?
      ORDER BY period_start ASC, id ASC
      """
    )
    try statement.bind(cutoff.timeIntervalSinceReferenceDate, at: 1)

    var aggregates: [InputAggregate] = []
    while try statement.stepRow() {
      aggregates.append(try Self.decodeAggregate(from: statement))
    }
    return aggregates
  }

  /// Atomically verifies and applies a Core rollup plan.
  /// Stored hourly sources are decoded and used to recompute the daily value.
  /// The daily row is inserted before exactly the declared sources are
  /// deleted. Any missing/mismatched source, ID conflict, or deletion anomaly
  /// rolls the entire transaction back.
  public func apply(
    _ plan: DailyInputRollupPlan
  ) throws -> DailyInputRollupApplyResult {
    try database.transaction {
      let daily = plan.dailyAggregate
      let sourceIDs = plan.sourceHourlyAggregateIDs
      guard daily.period.granularity == .day,
        !sourceIDs.isEmpty,
        Set(sourceIDs).count == sourceIDs.count,
        !sourceIDs.contains(daily.id)
      else {
        throw InputAggregateStoreError.invalidRollupPlan
      }

      let existingDaily = try Self.fetch(id: daily.id, from: database)
      if let existingDaily, existingDaily != daily {
        throw InputAggregateStoreError.identifierConflict(daily.id)
      }

      var sources: [InputAggregate] = []
      var missing: [InputAggregateID] = []
      for sourceID in sourceIDs {
        if let source = try Self.fetch(id: sourceID, from: database) {
          sources.append(source)
        } else {
          missing.append(sourceID)
        }
      }

      if missing.count == sourceIDs.count, existingDaily == daily {
        return .alreadyApplied
      }
      if let firstMissing = missing.first {
        throw InputAggregateStoreError.missingRollupSource(firstMissing)
      }

      let recomputed: DailyInputRollupPlan
      do {
        recomputed = try InputAggregationPolicy.makeDailyRollup(
          id: daily.id,
          period: daily.period,
          hourly: sources
        )
      } catch {
        throw InputAggregateStoreError.rollupSourceMismatch
      }
      guard recomputed.dailyAggregate == daily,
        recomputed.sourceHourlyAggregateIDs == sourceIDs
      else {
        throw InputAggregateStoreError.rollupSourceMismatch
      }

      if existingDaily == nil {
        guard try Self.insert(daily, into: database) == .inserted else {
          throw InputAggregateStoreError.corruptedSchema(
            "Daily insert produced an impossible idempotent result"
          )
        }
      }

      let delete = try database.prepare("DELETE FROM input_aggregates WHERE id = ?")
      for sourceID in sourceIDs {
        try delete.bind(sourceID.rawValue.uuidString.lowercased(), at: 1)
        try delete.expectDone()
        guard database.changedRowCount == 1 else {
          throw InputAggregateStoreError.corruptedSchema(
            "Rollup source deletion count was not one"
          )
        }
        try delete.reset()
      }
      return .applied
    }
  }

  public func schemaVersion() throws -> Int {
    try Self.readSchemaMetadata(database).version
  }

  public func schemaFingerprint() throws -> String {
    try Self.readSchemaMetadata(database).fingerprint
  }

  private static func insert(
    _ aggregate: InputAggregate,
    into database: InputAggregateSQLiteDatabase
  ) throws -> InputAggregateInsertResult {
    let payload = try canonicalPayload(for: aggregate)
    let statement = try database.prepare(
      """
      INSERT OR IGNORE INTO input_aggregates (
          id, period_start, period_end, granularity,
          time_zone_identifier, workday_boundary_hour,
          payload_schema_version, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """
    )
    try bind(aggregate, payload: payload, to: statement)
    try statement.expectDone()

    if database.changedRowCount == 1 {
      return .inserted
    }
    guard let stored = try fetch(id: aggregate.id, from: database) else {
      throw InputAggregateStoreError.corruptedSchema(
        "Unique insert was ignored without an existing aggregate"
      )
    }
    guard stored == aggregate else {
      throw InputAggregateStoreError.identifierConflict(aggregate.id)
    }
    return .alreadyPresent
  }

  private static func bind(
    _ aggregate: InputAggregate,
    payload: String,
    to statement: InputAggregateSQLiteStatement
  ) throws {
    try statement.bind(aggregate.id.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(aggregate.period.start.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(aggregate.period.end.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(aggregate.period.granularity.rawValue, at: 4)
    try statement.bind(aggregate.period.timeZoneIdentifier, at: 5)
    if let boundaryHour = aggregate.period.workdayBoundaryHour {
      try statement.bind(Int64(boundaryHour), at: 6)
    } else {
      try statement.bindNull(at: 6)
    }
    try statement.bind(Int64(currentPayloadSchemaVersion), at: 7)
    try statement.bind(payload, at: 8)
  }

  private static func bind(
    _ checkpoint: InputAggregateCheckpoint,
    payload: String,
    to statement: InputAggregateSQLiteStatement
  ) throws {
    let aggregate = checkpoint.aggregate
    try statement.bind(aggregate.id.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(aggregate.period.start.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(aggregate.period.end.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(aggregate.period.granularity.rawValue, at: 4)
    try statement.bind(aggregate.period.timeZoneIdentifier, at: 5)
    guard checkpoint.revision <= UInt64(Int64.max) else {
      throw InputAggregateStoreError.checkpointRevisionConflict
    }
    try statement.bind(Int64(checkpoint.revision), at: 6)
    try statement.bind(checkpoint.checkpointedAt.timeIntervalSinceReferenceDate, at: 7)
    try statement.bind(Int64(currentPayloadSchemaVersion), at: 8)
    try statement.bind(payload, at: 9)
  }

  private static func fetch(
    id: InputAggregateID,
    from database: InputAggregateSQLiteDatabase
  ) throws -> InputAggregate? {
    let statement = try database.prepare(
      """
      SELECT
          id, period_start, period_end, granularity,
          time_zone_identifier, workday_boundary_hour,
          payload_schema_version, payload
      FROM input_aggregates WHERE id = ?
      """
    )
    try statement.bind(id.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    return try decodeAggregate(from: statement)
  }

  private static func decodeAggregate(
    from statement: InputAggregateSQLiteStatement
  ) throws -> InputAggregate {
    let idText = try statement.requiredText(at: 0, column: "id")
    guard let idValue = UUID(uuidString: idText) else {
      throw InputAggregateStoreError.invalidStoredValue(column: "id")
    }
    let id = InputAggregateID(rawValue: idValue)

    let startValue = try statement.requiredDouble(at: 1, column: "period_start")
    let endValue = try statement.requiredDouble(at: 2, column: "period_end")
    guard startValue.isFinite, endValue.isFinite, endValue > startValue else {
      throw InputAggregateStoreError.invalidStoredValue(column: "period")
    }
    let granularityText = try statement.requiredText(at: 3, column: "granularity")
    guard let granularity = InputAggregateGranularity(rawValue: granularityText) else {
      throw InputAggregateStoreError.invalidStoredValue(column: "granularity")
    }
    let timeZoneIdentifier = try statement.requiredText(
      at: 4,
      column: "time_zone_identifier"
    )
    let boundaryHour: Int?
    if statement.isNull(at: 5) {
      boundaryHour = nil
    } else {
      let value = try statement.requiredInt64(at: 5, column: "workday_boundary_hour")
      guard let exact = Int(exactly: value) else {
        throw InputAggregateStoreError.invalidStoredValue(
          column: "workday_boundary_hour"
        )
      }
      boundaryHour = exact
    }

    let payloadVersionValue = try statement.requiredInt64(
      at: 6,
      column: "payload_schema_version"
    )
    guard let payloadVersion = Int(exactly: payloadVersionValue) else {
      throw InputAggregateStoreError.invalidStoredValue(
        column: "payload_schema_version"
      )
    }
    guard payloadVersion == currentPayloadSchemaVersion else {
      throw InputAggregateStoreError.unsupportedPayloadSchemaVersion(
        found: payloadVersion,
        supported: currentPayloadSchemaVersion
      )
    }

    let payload = try statement.requiredText(at: 7, column: "payload")
    guard let payloadData = payload.data(using: .utf8) else {
      throw InputAggregateStoreError.invalidAggregatePayload
    }
    let aggregate: InputAggregate
    do {
      aggregate = try JSONDecoder().decode(InputAggregate.self, from: payloadData)
    } catch {
      throw InputAggregateStoreError.invalidAggregatePayload
    }
    // Stored aggregates from an earlier app build may differ only in JSON
    // whitespace, key order, or numeric spelling. A byte-for-byte comparison
    // makes those otherwise valid local facts unreadable after an encoder
    // update. Keep the unknown-field/tamper guard, but compare the parsed JSON
    // values so equivalent payloads remain backward-compatible.
    guard try hasEquivalentCanonicalPayload(for: aggregate, storedPayload: payload) else {
      throw InputAggregateStoreError.nonCanonicalAggregatePayload
    }

    guard aggregate.id == id else {
      throw InputAggregateStoreError.metadataPayloadMismatch(column: "id")
    }
    guard aggregate.period.start.timeIntervalSinceReferenceDate == startValue else {
      throw InputAggregateStoreError.metadataPayloadMismatch(column: "period_start")
    }
    guard aggregate.period.end.timeIntervalSinceReferenceDate == endValue else {
      throw InputAggregateStoreError.metadataPayloadMismatch(column: "period_end")
    }
    guard aggregate.period.granularity == granularity else {
      throw InputAggregateStoreError.metadataPayloadMismatch(column: "granularity")
    }
    guard aggregate.period.timeZoneIdentifier == timeZoneIdentifier else {
      throw InputAggregateStoreError.metadataPayloadMismatch(
        column: "time_zone_identifier"
      )
    }
    guard aggregate.period.workdayBoundaryHour == boundaryHour else {
      throw InputAggregateStoreError.metadataPayloadMismatch(
        column: "workday_boundary_hour"
      )
    }
    return aggregate
  }

  private static func fetchCheckpoint(
    id: InputAggregateID,
    from database: InputAggregateSQLiteDatabase
  ) throws -> InputAggregateCheckpoint? {
    let statement = try database.prepare(
      """
      SELECT aggregate_id, period_start, period_end, granularity,
             time_zone_identifier, revision, checkpointed_at,
             payload_schema_version, payload
      FROM input_aggregate_open_checkpoints WHERE aggregate_id = ?
      """
    )
    try statement.bind(id.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    return try decodeCheckpoint(from: statement)
  }

  private static func decodeCheckpoint(
    from statement: InputAggregateSQLiteStatement
  ) throws -> InputAggregateCheckpoint {
    let idText = try statement.requiredText(at: 0, column: "aggregate_id")
    guard let idValue = UUID(uuidString: idText) else {
      throw InputAggregateStoreError.invalidStoredValue(column: "aggregate_id")
    }
    let start = try statement.requiredDouble(at: 1, column: "period_start")
    let end = try statement.requiredDouble(at: 2, column: "period_end")
    let granularity = try statement.requiredText(at: 3, column: "granularity")
    let timeZone = try statement.requiredText(at: 4, column: "time_zone_identifier")
    let revisionValue = try statement.requiredInt64(at: 5, column: "revision")
    let checkpointedAt = try statement.requiredDouble(at: 6, column: "checkpointed_at")
    guard start.isFinite, end.isFinite, end > start,
          granularity == InputAggregateGranularity.hour.rawValue,
          revisionValue > 0, checkpointedAt.isFinite,
          let revision = UInt64(exactly: revisionValue)
    else { throw InputAggregateStoreError.invalidStoredValue(column: "checkpoint") }
    let payloadVersion = try statement.requiredInt64(at: 7, column: "payload_schema_version")
    guard payloadVersion == Int64(currentPayloadSchemaVersion) else {
      throw InputAggregateStoreError.unsupportedPayloadSchemaVersion(
        found: Int(payloadVersion), supported: currentPayloadSchemaVersion
      )
    }
    let payload = try statement.requiredText(at: 8, column: "payload")
    guard let data = payload.data(using: .utf8),
          let aggregate = try? JSONDecoder().decode(InputAggregate.self, from: data),
          try hasEquivalentCanonicalPayload(for: aggregate, storedPayload: payload),
          aggregate.id == InputAggregateID(rawValue: idValue),
          aggregate.period.start.timeIntervalSinceReferenceDate == start,
          aggregate.period.end.timeIntervalSinceReferenceDate == end,
          aggregate.period.granularity.rawValue == granularity,
          aggregate.period.timeZoneIdentifier == timeZone
    else { throw InputAggregateStoreError.invalidAggregatePayload }
    do {
      return try InputAggregateCheckpoint(
        aggregate: aggregate,
        revision: revision,
        checkpointedAt: Date(timeIntervalSinceReferenceDate: checkpointedAt)
      )
    } catch {
      throw InputAggregateStoreError.invalidAggregatePayload
    }
  }

  private static func canonicalPayload(for aggregate: InputAggregate) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(aggregate)
    guard let payload = String(data: data, encoding: .utf8) else {
      throw InputAggregateStoreError.invalidAggregatePayload
    }
    return payload
  }

  private static func hasEquivalentCanonicalPayload(
    for aggregate: InputAggregate,
    storedPayload: String
  ) throws -> Bool {
    let canonicalPayload = try canonicalPayload(for: aggregate)
    guard let storedData = storedPayload.data(using: .utf8),
          let canonicalData = canonicalPayload.data(using: .utf8)
    else { return false }

    do {
      let storedObject = try JSONSerialization.jsonObject(with: storedData)
      let canonicalObject = try JSONSerialization.jsonObject(with: canonicalData)
      if (storedObject as AnyObject).isEqual(canonicalObject) { return true }

      // Both fields below were added as zero-defaulted aggregate facts. Older
      // local rows legitimately omit them, so accept only the exact canonical
      // payload with those zero values removed. Any other omission/addition
      // remains invalid.
      var legacyCandidates = [canonicalObject]
      if aggregate.committedCharacterCount == 0,
         let canonicalDictionary = canonicalObject as? [String: Any] {
        var withoutCommittedCharacters = canonicalDictionary
        withoutCommittedCharacters.removeValue(forKey: "committedCharacterCount")
        legacyCandidates.append(withoutCommittedCharacters)
      }
      if allScrollEventCountsAreZero(in: aggregate) {
        legacyCandidates += legacyCandidates.map {
          removingLegacyScrollEventCounts(from: $0)
        }
      }
      return legacyCandidates.contains { candidate in
        (storedObject as AnyObject).isEqual(candidate)
      }
    } catch {
      return false
    }
  }

  private static func allScrollEventCountsAreZero(in aggregate: InputAggregate) -> Bool {
    aggregate.displays.allSatisfy { $0.pointer.scrollEventCount == 0 }
      && aggregate.applicationTotals.allSatisfy { $0.pointer.scrollEventCount == 0 }
  }

  private static func removingLegacyScrollEventCounts(from value: Any) -> Any {
    if var dictionary = value as? [String: Any] {
      dictionary.removeValue(forKey: "scrollEventCount")
      return dictionary.mapValues(removingLegacyScrollEventCounts)
    }
    if let values = value as? [Any] {
      return values.map(removingLegacyScrollEventCounts)
    }
    return value
  }

  private static func migrate(_ database: InputAggregateSQLiteDatabase) throws {
    try database.transaction {
      let metadataExists = try database.tableExists("input_aggregate_schema_metadata")
      let migrationsExists = try database.tableExists("input_aggregate_schema_migrations")
      let aggregatesExists = try database.tableExists("input_aggregates")

      if !metadataExists, !migrationsExists, !aggregatesExists {
        guard try database.schemaObjectNames(withPrefix: "input_aggregate").isEmpty else {
          throw InputAggregateStoreError.corruptedSchema(
            "Input aggregate namespace must be empty before initial migration"
          )
        }
        try applyMigration1(database)
      } else {
        guard metadataExists, migrationsExists, aggregatesExists else {
          throw InputAggregateStoreError.corruptedSchema(
            "Input aggregate schema objects must exist together"
          )
        }
      }

      let metadata = try readSchemaMetadata(database)
      guard metadata.version <= currentSchemaVersion else {
        throw InputAggregateStoreError.unsupportedSchemaVersion(
          found: metadata.version,
          supported: currentSchemaVersion
        )
      }
      guard metadata.version >= 1 else {
        throw InputAggregateStoreError.corruptedSchema("Invalid schema version")
      }
      switch metadata.version {
      case 1:
        guard metadata.fingerprint == schema1Fingerprint else {
          throw InputAggregateStoreError.corruptedSchema("Schema fingerprint mismatch")
        }
        try validateSchema1(database)
        try applyMigration2(database)
      case 2:
        guard metadata.fingerprint == expectedSchemaFingerprint else {
          throw InputAggregateStoreError.corruptedSchema("Schema fingerprint mismatch")
        }
        try validateSchema2(database)
      default:
        throw InputAggregateStoreError.corruptedSchema("Invalid schema version")
      }
      let migrated = try readSchemaMetadata(database)
      guard migrated.version == currentSchemaVersion,
            migrated.fingerprint == expectedSchemaFingerprint else {
        throw InputAggregateStoreError.corruptedSchema("Missing registered migration")
      }
      try validateSchema2(database)
      try validateMigrationJournal(database, expectedVersion: migrated.version)
    }
  }

  private static func applyMigration1(_ database: InputAggregateSQLiteDatabase) throws {
    try database.execute(schemaMetadataSQL)
    try database.execute(schemaMigrationsSQL)
    try database.execute(aggregatesSQL)
    try database.execute(periodIndexSQL)

    let migration = try database.prepare(
      """
      INSERT INTO input_aggregate_schema_migrations(version, applied_at)
      VALUES (?, ?)
      """
    )
    try migration.bind(Int64(1), at: 1)
    try migration.bind(Date().timeIntervalSince1970, at: 2)
    try migration.expectDone()

    let metadata = try database.prepare(
      """
      INSERT INTO input_aggregate_schema_metadata(
          singleton, schema_version, schema_fingerprint
      ) VALUES (1, ?, ?)
      """
    )
    try metadata.bind(Int64(1), at: 1)
    try metadata.bind(schema1Fingerprint, at: 2)
    try metadata.expectDone()
  }

  private static func applyMigration2(_ database: InputAggregateSQLiteDatabase) throws {
    try database.execute(checkpointsSQL)
    try database.execute(checkpointsPeriodIndexSQL)
    let migration = try database.prepare(
      "INSERT INTO input_aggregate_schema_migrations(version, applied_at) VALUES (?, ?)"
    )
    try migration.bind(Int64(2), at: 1)
    try migration.bind(Date().timeIntervalSince1970, at: 2)
    try migration.expectDone()
    let metadata = try database.prepare(
      "UPDATE input_aggregate_schema_metadata SET schema_version = ?, schema_fingerprint = ? WHERE singleton = 1"
    )
    try metadata.bind(Int64(2), at: 1)
    try metadata.bind(expectedSchemaFingerprint, at: 2)
    try metadata.expectDone()
    guard database.changedRowCount == 1 else {
      throw InputAggregateStoreError.corruptedSchema("Missing schema metadata row")
    }
  }

  private static func readSchemaMetadata(
    _ database: InputAggregateSQLiteDatabase
  ) throws -> (version: Int, fingerprint: String) {
    let statement = try database.prepare(
      """
      SELECT schema_version, schema_fingerprint
      FROM input_aggregate_schema_metadata WHERE singleton = 1
      """
    )
    guard try statement.stepRow() else {
      throw InputAggregateStoreError.corruptedSchema("Missing schema metadata row")
    }
    let versionValue = try statement.requiredInt64(at: 0, column: "schema_version")
    let fingerprint = try statement.requiredText(at: 1, column: "schema_fingerprint")
    guard !(try statement.stepRow()), let version = Int(exactly: versionValue) else {
      throw InputAggregateStoreError.corruptedSchema("Invalid schema metadata rows")
    }
    return (version, fingerprint)
  }

  private static func validateMigrationJournal(
    _ database: InputAggregateSQLiteDatabase,
    expectedVersion: Int
  ) throws {
    let statement = try database.prepare(
      """
      SELECT version FROM input_aggregate_schema_migrations ORDER BY version ASC
      """
    )
    var expected: Int64 = 1
    while try statement.stepRow() {
      guard try statement.requiredInt64(at: 0, column: "version") == expected else {
        throw InputAggregateStoreError.corruptedSchema(
          "Non-contiguous input aggregate migration journal"
        )
      }
      expected += 1
    }
    guard expected - 1 == Int64(expectedVersion) else {
      throw InputAggregateStoreError.corruptedSchema(
        "Schema version and migration journal disagree"
      )
    }
  }

  private static func validateSchema1(_ database: InputAggregateSQLiteDatabase) throws {
    let objects = [
      (type: "table", name: "input_aggregate_schema_metadata", sql: schemaMetadataSQL),
      (type: "table", name: "input_aggregate_schema_migrations", sql: schemaMigrationsSQL),
      (type: "table", name: "input_aggregates", sql: aggregatesSQL),
      (type: "index", name: "input_aggregates_period_start", sql: periodIndexSQL),
    ]
    let expectedNames = objects.map(\.name).sorted()
    let actualNames = try database.schemaObjectNames(
      withPrefix: "input_aggregate"
    )
    guard actualNames == expectedNames else {
      throw InputAggregateStoreError.corruptedSchema(
        "Unexpected input aggregate schema object set"
      )
    }
    for object in objects {
      guard let actual = try database.schemaSQL(type: object.type, name: object.name) else {
        throw InputAggregateStoreError.corruptedSchema(
          "Missing schema object: \(object.name)"
        )
      }
      guard normalizedSQL(actual) == normalizedSQL(object.sql) else {
        throw InputAggregateStoreError.corruptedSchema(
          "Unexpected schema object definition: \(object.name)"
        )
      }
    }
  }

  private static func normalizedSQL(_ sql: String) -> String {
    sql.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
  }

  private static func fingerprint(of definitions: [String]) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in definitions.map(normalizedSQL).joined(separator: "\n").utf8 {
      value ^= UInt64(byte)
      value &*= 1_099_511_628_211
    }
    return String(format: "fnv1a64-%016llx", value)
  }

  private static func validateSchema2(_ database: InputAggregateSQLiteDatabase) throws {
    let objects = [
      (type: "table", name: "input_aggregate_schema_metadata", sql: schemaMetadataSQL),
      (type: "table", name: "input_aggregate_schema_migrations", sql: schemaMigrationsSQL),
      (type: "table", name: "input_aggregates", sql: aggregatesSQL),
      (type: "index", name: "input_aggregates_period_start", sql: periodIndexSQL),
      (type: "table", name: "input_aggregate_open_checkpoints", sql: checkpointsSQL),
      (type: "index", name: "input_aggregate_open_checkpoints_period_start", sql: checkpointsPeriodIndexSQL),
    ]
    let expectedNames = objects.map(\.name).sorted()
    guard try database.schemaObjectNames(withPrefix: "input_aggregate") == expectedNames else {
      throw InputAggregateStoreError.corruptedSchema("Unexpected input aggregate schema object set")
    }
    for object in objects {
      guard let actual = try database.schemaSQL(type: object.type, name: object.name),
            normalizedSQL(actual) == normalizedSQL(object.sql) else {
        throw InputAggregateStoreError.corruptedSchema("Unexpected schema object definition: \(object.name)")
      }
    }
  }
}

extension SQLiteInputAggregateRepository: InputAggregateCheckpointRepository {}

private final class InputAggregateSQLiteDatabase {
  private var handle: OpaquePointer?

  init(location: SQLiteDatabaseLocation) throws {
    let path: String
    switch location {
    case .inMemory:
      path = ":memory:"
    case .file(let url):
      guard let canonicalPath = canonicalSQLiteFilePath(url) else {
        throw InputAggregateStoreError.invalidFileURL
      }
      path = canonicalPath
    }

    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      path,
      &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        | SQLITE_OPEN_NOFOLLOW,
      nil
    )
    guard result == SQLITE_OK, let opened else {
      let message =
        opened.map { String(cString: sqlite3_errmsg($0)) }
        ?? "Unable to open database"
      if let opened { sqlite3_close_v2(opened) }
      throw InputAggregateStoreError.database(code: result, message: message)
    }
    handle = opened
    do {
      try execute("PRAGMA foreign_keys = ON")
      try execute("PRAGMA busy_timeout = 5000")
      if path != ":memory:" {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
      }
    } catch {
      close()
      throw error
    }
  }

  deinit { close() }

  var changedRowCount: Int32 { handle.map(sqlite3_changes) ?? 0 }

  func close() {
    if let handle {
      sqlite3_close_v2(handle)
      self.handle = nil
    }
  }

  func execute(_ sql: String) throws {
    guard let handle else {
      throw InputAggregateStoreError.corruptedSchema("Database is closed")
    }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw InputAggregateStoreError.database(code: result, message: message)
    }
  }

  func prepare(_ sql: String) throws -> InputAggregateSQLiteStatement {
    guard let handle else {
      throw InputAggregateStoreError.corruptedSchema("Database is closed")
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw InputAggregateStoreError.database(
        code: result,
        message: String(cString: sqlite3_errmsg(handle))
      )
    }
    return InputAggregateSQLiteStatement(database: handle, statement: statement)
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func tableExists(_ name: String) throws -> Bool {
    let statement = try prepare(
      "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ? LIMIT 1"
    )
    try statement.bind(name, at: 1)
    return try statement.stepRow()
  }

  func schemaSQL(type: String, name: String) throws -> String? {
    let statement = try prepare(
      "SELECT sql FROM sqlite_schema WHERE type = ? AND name = ? LIMIT 1"
    )
    try statement.bind(type, at: 1)
    try statement.bind(name, at: 2)
    guard try statement.stepRow() else { return nil }
    return try statement.requiredText(at: 0, column: "sqlite_schema.sql")
  }

  func schemaObjectNames(withPrefix prefix: String) throws -> [String] {
    let statement = try prepare(
      """
      SELECT name FROM sqlite_schema
      WHERE name LIKE ? ESCAPE '\\'
      ORDER BY name ASC
      """
    )
    let escaped =
      prefix
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    try statement.bind(escaped + "%", at: 1)
    var names: [String] = []
    while try statement.stepRow() {
      names.append(try statement.requiredText(at: 0, column: "sqlite_schema.name"))
    }
    return names
  }
}

private final class InputAggregateSQLiteStatement {
  private let database: OpaquePointer
  private var statement: OpaquePointer?

  init(database: OpaquePointer, statement: OpaquePointer) {
    self.database = database
    self.statement = statement
  }

  deinit {
    if let statement { sqlite3_finalize(statement) }
  }

  func bind(_ value: String, at index: Int32) throws {
    try check(sqlite3_bind_text(statement, index, value, -1, dayday_sqlite_transient()))
  }

  func bind(_ value: Int64, at index: Int32) throws {
    try check(sqlite3_bind_int64(statement, index, value))
  }

  func bind(_ value: Double, at index: Int32) throws {
    try check(sqlite3_bind_double(statement, index, value))
  }

  func bindNull(at index: Int32) throws {
    try check(sqlite3_bind_null(statement, index))
  }

  func stepRow() throws -> Bool {
    let result = sqlite3_step(statement)
    switch result {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: throw databaseError(code: result)
    }
  }

  func expectDone() throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else { throw databaseError(code: result) }
  }

  func reset() throws {
    try check(sqlite3_reset(statement))
    try check(sqlite3_clear_bindings(statement))
  }

  func isNull(at index: Int32) -> Bool {
    sqlite3_column_type(statement, index) == SQLITE_NULL
  }

  func requiredText(at index: Int32, column: String) throws -> String {
    guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
      let pointer = sqlite3_column_text(statement, index)
    else {
      throw InputAggregateStoreError.invalidStoredValue(column: column)
    }
    return String(cString: pointer)
  }

  func requiredInt64(at index: Int32, column: String) throws -> Int64 {
    guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
      throw InputAggregateStoreError.invalidStoredValue(column: column)
    }
    return sqlite3_column_int64(statement, index)
  }

  func requiredDouble(at index: Int32, column: String) throws -> Double {
    let type = sqlite3_column_type(statement, index)
    guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else {
      throw InputAggregateStoreError.invalidStoredValue(column: column)
    }
    return sqlite3_column_double(statement, index)
  }

  private func check(_ result: Int32) throws {
    guard result == SQLITE_OK else { throw databaseError(code: result) }
  }

  private func databaseError(code: Int32) -> InputAggregateStoreError {
    InputAggregateStoreError.database(
      code: code,
      message: String(cString: sqlite3_errmsg(database))
    )
  }
}
