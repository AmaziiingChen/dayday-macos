import CSQLite
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite input aggregate repository", .serialized)
struct SQLiteInputAggregateRepositoryTests {
  @Test("Lord Howe short DST partitions and daily boundaries round trip exactly")
  func lordHoweRoundTrip() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let hour = try InputAggregationPolicy.hourlyPeriod(
      containing: instant("2026-04-04T15:15:00Z"),
      timeZoneIdentifier: "Australia/Lord_Howe"
    )
    let aggregate = try makeAggregate(
      id: id("00000000-0000-0000-0000-000000000001"),
      period: hour,
      keyCount: 7,
      includedDurationMilliseconds: 1_800_000
    )

    #expect(hour.start == instant("2026-04-04T15:00:00Z"))
    #expect(hour.end == instant("2026-04-04T15:30:00Z"))
    #expect(try await repository.insert(aggregate) == .inserted)
    #expect(
      try await repository.fetch(
        startingIn: hour.start..<hour.end
      ) == [aggregate])

    let day = try InputAggregatePeriod(
      start: instant("2026-10-03T15:30:00Z"),
      end: instant("2026-10-04T15:00:00Z"),
      granularity: .day,
      timeZoneIdentifier: "Australia/Lord_Howe",
      workdayBoundaryHour: 2
    )
    let daily = try makeAggregate(
      id: id("00000000-0000-0000-0000-000000000002"),
      period: day,
      keyCount: 9
    )
    #expect(try await repository.insert(daily) == .inserted)
    #expect(
      try await repository.fetch(
        startingIn: day.start..<day.start.addingTimeInterval(1)
      ) == [daily])
    #expect(day.end.timeIntervalSince(day.start) == 23.5 * 3_600)
  }

  @Test("same ID is idempotent and conflicting content is rejected")
  func insertIdempotencyAndConflict() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let aggregateID = id("10000000-0000-0000-0000-000000000001")
    let original = try utcAggregate(id: aggregateID, hour: 0, keyCount: 1)
    let conflict = try utcAggregate(id: aggregateID, hour: 0, keyCount: 2)

    #expect(try await repository.insert(original) == .inserted)
    #expect(try await repository.insert(original) == .alreadyPresent)
    do {
      _ = try await repository.insert(conflict)
      Issue.record("Expected identifier conflict")
    } catch let error as InputAggregateStoreError {
      #expect(error == .identifierConflict(aggregateID))
    }
    #expect(
      try await repository.fetch(
        startingIn: instant("2026-08-01T00:00:00Z")..<instant("2026-08-01T01:00:00Z")
      ) == [original])
  }

  @Test("open checkpoints replace only newer aggregate revisions and finalize atomically")
  func checkpointReplacementAndFinalization() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let aggregate = try utcAggregate(
      id: id("11000000-0000-0000-0000-000000000001"), hour: 0, keyCount: 4
    )
    let first = try InputAggregateCheckpoint(
      aggregate: aggregate, revision: 1, checkpointedAt: instant("2026-08-01T00:00:10Z")
    )
    let newerAggregate = try utcAggregate(
      id: aggregate.id, hour: 0, keyCount: 7
    )
    let newer = try InputAggregateCheckpoint(
      aggregate: newerAggregate, revision: 2, checkpointedAt: instant("2026-08-01T00:00:20Z")
    )
    try await repository.upsert(first)
    try await repository.upsert(first)
    try await repository.upsert(newer)
    #expect(try await repository.openCheckpoints() == [newer])
    await #expect(throws: InputAggregateStoreError.checkpointRevisionConflict) {
      try await repository.upsert(first)
    }
    try await repository.finalize(newerAggregate)
    #expect(try await repository.openCheckpoints().isEmpty)
    #expect(try await repository.fetch(startingIn: aggregate.period.start..<aggregate.period.end) == [newerAggregate])
  }

  @Test("fetchHoursEndingBefore returns hourly rows up to the cutoff in stable order")
  func fetchHoursEndingBeforeCutoff() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let first = try utcAggregate(
      id: id("25000000-0000-0000-0000-000000000001"),
      hour: 0,
      keyCount: 2
    )
    let second = try utcAggregate(
      id: id("25000000-0000-0000-0000-000000000002"),
      hour: 1,
      keyCount: 3
    )
    let after = try utcAggregate(
      id: id("25000000-0000-0000-0000-000000000003"),
      hour: 2,
      keyCount: 5
    )
    for aggregate in [after, first, second] {
      _ = try await repository.insert(aggregate)
    }

    let cutoff = instant("2026-08-01T02:00:00Z")
    #expect(try await repository.fetchHoursEndingBefore(cutoff) == [first, second])

    #expect(try await repository.fetchHoursEndingBefore(instant("2026-08-01T00:00:00Z")).isEmpty)
  }

  @Test("fetchHoursEndingBefore excludes daily rows and rejects non-finite cutoffs")
  func fetchHoursEndingBeforeExcludesDailyAndGuardsCutoff() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let hour = try utcAggregate(
      id: id("26000000-0000-0000-0000-000000000001"),
      hour: 0,
      keyCount: 2
    )
    let day = try makeAggregate(
      id: id("26000000-0000-0000-0000-000000000002"),
      period: InputAggregatePeriod(
        start: instant("2026-08-01T00:00:00Z"),
        end: instant("2026-08-02T00:00:00Z"),
        granularity: .day,
        timeZoneIdentifier: "UTC",
        workdayBoundaryHour: 0
      ),
      keyCount: 4
    )
    for aggregate in [hour, day] {
      _ = try await repository.insert(aggregate)
    }

    let cutoff = instant("2026-08-01T01:00:00Z")
    #expect(try await repository.fetchHoursEndingBefore(cutoff) == [hour])

    await #expect(throws: InputAggregateStoreError.invalidDateRange) {
      _ = try await repository.fetchHoursEndingBefore(
        Date(timeIntervalSinceReferenceDate: .infinity)
      )
    }
  }

  @Test("period-start range is half-open with stable tie ordering")
  func stableHalfOpenRange() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let firstID = id("20000000-0000-0000-0000-000000000001")
    let secondID = id("20000000-0000-0000-0000-000000000002")
    let first = try utcAggregate(id: firstID, hour: 0, keyCount: 1)
    let second = try utcAggregate(id: secondID, hour: 0, keyCount: 2)
    let upper = try utcAggregate(
      id: id("20000000-0000-0000-0000-000000000003"),
      hour: 1,
      keyCount: 3
    )
    for aggregate in [upper, second, first] {
      _ = try await repository.insert(aggregate)
    }

    let result = try await repository.fetch(
      startingIn: instant("2026-08-01T00:00:00Z")..<instant("2026-08-01T01:00:00Z")
    )
    #expect(result == [first, second])

    let invalid = Range(
      uncheckedBounds: (
        instant("2026-08-01T00:00:00Z"),
        instant("2026-08-01T00:00:00Z")
      ))
    await #expect(throws: InputAggregateStoreError.invalidDateRange) {
      _ = try await repository.fetch(startingIn: invalid)
    }
  }

  @Test("rollup inserts daily then deletes exactly its verified hourly sources")
  func atomicRollupAndIdempotentRetry() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let first = try utcAggregate(
      id: id("30000000-0000-0000-0000-000000000001"),
      hour: 0,
      keyCount: 2
    )
    let second = try utcAggregate(
      id: id("30000000-0000-0000-0000-000000000002"),
      hour: 1,
      keyCount: 3
    )
    let unrelated = try utcAggregate(
      id: id("30000000-0000-0000-0000-000000000003"),
      hour: 2,
      keyCount: 5
    )
    for aggregate in [first, second, unrelated] {
      _ = try await repository.insert(aggregate)
    }
    let plan = try rollup(
      id: id("30000000-0000-0000-0000-000000000004"),
      hourly: [second, first]
    )

    #expect(try await repository.apply(plan) == .applied)
    let stored = try await repository.fetch(
      startingIn: instant("2026-08-01T00:00:00Z")..<instant("2026-08-02T00:00:00Z")
    )
    #expect(stored == [plan.dailyAggregate, unrelated])
    #expect(try await repository.apply(plan) == .alreadyApplied)
  }

  @Test("rollup source mismatch rolls back without daily or unrelated deletion")
  func rollupMismatchRollsBack() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let firstID = id("40000000-0000-0000-0000-000000000001")
    let first = try utcAggregate(id: firstID, hour: 0, keyCount: 2)
    let second = try utcAggregate(
      id: id("40000000-0000-0000-0000-000000000002"),
      hour: 1,
      keyCount: 3
    )
    let plan = try rollup(
      id: id("40000000-0000-0000-0000-000000000003"),
      hourly: [first, second]
    )
    let mismatchedStoredFirst = try utcAggregate(
      id: firstID,
      hour: 0,
      keyCount: 99
    )
    _ = try await repository.insert(mismatchedStoredFirst)
    _ = try await repository.insert(second)

    await #expect(throws: InputAggregateStoreError.rollupSourceMismatch) {
      _ = try await repository.apply(plan)
    }
    #expect(
      try await repository.fetch(
        startingIn: instant("2026-08-01T00:00:00Z")..<instant("2026-08-02T00:00:00Z")
      ) == [mismatchedStoredFirst, second])
  }

  @Test("a missing rollup source leaves all present rows untouched")
  func missingRollupSourceRollsBack() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let first = try utcAggregate(
      id: id("45000000-0000-0000-0000-000000000001"),
      hour: 0,
      keyCount: 2
    )
    let missing = try utcAggregate(
      id: id("45000000-0000-0000-0000-000000000002"),
      hour: 1,
      keyCount: 3
    )
    let plan = try rollup(
      id: id("45000000-0000-0000-0000-000000000003"),
      hourly: [first, missing]
    )
    _ = try await repository.insert(first)

    await #expect(throws: InputAggregateStoreError.missingRollupSource(missing.id)) {
      _ = try await repository.apply(plan)
    }
    #expect(
      try await repository.fetch(
        startingIn: first.period.start..<missing.period.end
      ) == [first])
  }

  @Test("daily ID conflict leaves every hourly source untouched")
  func rollupDailyConflictRollsBack() async throws {
    let repository = try SQLiteInputAggregateRepository(location: .inMemory)
    let first = try utcAggregate(
      id: id("50000000-0000-0000-0000-000000000001"),
      hour: 0,
      keyCount: 2
    )
    let second = try utcAggregate(
      id: id("50000000-0000-0000-0000-000000000002"),
      hour: 1,
      keyCount: 3
    )
    let dailyID = id("50000000-0000-0000-0000-000000000003")
    let plan = try rollup(id: dailyID, hourly: [first, second])
    let conflictingDaily = try makeAggregate(
      id: dailyID,
      period: plan.dailyAggregate.period,
      keyCount: 700
    )
    for aggregate in [first, second, conflictingDaily] {
      _ = try await repository.insert(aggregate)
    }

    await #expect(throws: InputAggregateStoreError.identifierConflict(dailyID)) {
      _ = try await repository.apply(plan)
    }
    #expect(
      try await repository.fetch(
        startingIn: instant("2026-08-01T00:00:00Z")..<instant("2026-08-02T00:00:00Z")
      ) == [first, conflictingDaily, second])
  }

  @Test("a deletion failure rolls back the daily insert and every source deletion")
  func deletionFailureRollsBackWholeTransaction() async throws {
    try await withTemporaryAggregateDatabase { url in
      let repository = try SQLiteInputAggregateRepository(location: .file(url))
      let first = try utcAggregate(
        id: id("55000000-0000-0000-0000-000000000001"),
        hour: 0,
        keyCount: 2
      )
      let second = try utcAggregate(
        id: id("55000000-0000-0000-0000-000000000002"),
        hour: 1,
        keyCount: 3
      )
      let plan = try rollup(
        id: id("55000000-0000-0000-0000-000000000003"),
        hourly: [first, second]
      )
      _ = try await repository.insert(first)
      _ = try await repository.insert(second)
      try execute(
        """
        CREATE TRIGGER input_aggregate_delete_guard
        BEFORE DELETE ON input_aggregates
        BEGIN SELECT RAISE(ABORT, 'blocked'); END
        """,
        at: url
      )

      do {
        _ = try await repository.apply(plan)
        Issue.record("Expected forced deletion failure")
      } catch let error as InputAggregateStoreError {
        guard case .database = error else {
          Issue.record("Expected SQLite error, got \(error)")
          return
        }
      }
      #expect(
        try await repository.fetch(
          startingIn: first.period.start..<second.period.end
        ) == [first, second])
    }
  }

  @Test("unknown noncanonical and corrupt payloads fail closed")
  func tamperedPayloadFailsClosed() async throws {
    try await withTemporaryAggregateDatabase { url in
      let repository = try SQLiteInputAggregateRepository(location: .file(url))
      let aggregate = try utcAggregate(
        id: id("60000000-0000-0000-0000-000000000001"),
        hour: 0,
        keyCount: 1
      )
      _ = try await repository.insert(aggregate)
      let payload = try scalarText(
        "SELECT payload FROM input_aggregates",
        at: url
      )
      let unknown = payload.replacingOccurrences(
        of: "{",
        with: "{\"typedText\":\"must-not-survive\",",
        options: [],
        range: payload.startIndex..<payload.index(after: payload.startIndex)
      )
      try updateText(
        table: "input_aggregates",
        column: "payload",
        value: unknown,
        at: url
      )

      await #expect(throws: InputAggregateStoreError.nonCanonicalAggregatePayload) {
        _ = try await repository.fetch(
          startingIn: aggregate.period.start..<aggregate.period.end
        )
      }
    }

    try await withTemporaryAggregateDatabase { url in
      let repository = try SQLiteInputAggregateRepository(location: .file(url))
      let aggregate = try utcAggregate(
        id: id("60000000-0000-0000-0000-000000000002"),
        hour: 0,
        keyCount: 1
      )
      _ = try await repository.insert(aggregate)
      try updateText(
        table: "input_aggregates",
        column: "payload",
        value: "{}",
        at: url
      )
      await #expect(throws: InputAggregateStoreError.invalidAggregatePayload) {
        _ = try await repository.fetch(
          startingIn: aggregate.period.start..<aggregate.period.end
        )
      }
    }
  }

  @Test("legacy aggregates without a zero character count remain readable")
  func legacyAggregateWithoutCharacterCountRemainsReadable() async throws {
    try await withTemporaryAggregateDatabase { url in
      let repository = try SQLiteInputAggregateRepository(location: .file(url))
      let aggregate = try utcAggregate(
        id: id("60000000-0000-0000-0000-000000000003"),
        hour: 0,
        keyCount: 1
      )
      _ = try await repository.insert(aggregate)

      let payload = try scalarText("SELECT payload FROM input_aggregates", at: url)
      let payloadData = try #require(payload.data(using: .utf8))
      let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
      var legacyPayload = try #require(payloadObject as? [String: Any])
      legacyPayload.removeValue(forKey: "committedCharacterCount")
      let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)
      try updateText(
        table: "input_aggregates",
        column: "payload",
        value: try #require(String(data: legacyData, encoding: .utf8)),
        at: url
      )

      #expect(
        try await repository.fetch(
          startingIn: aggregate.period.start..<aggregate.period.end
        ) == [aggregate]
      )
    }
  }

  @Test("metadata and payload version tampering fail closed")
  func tamperedMetadataFailsClosed() async throws {
    try await withTemporaryAggregateDatabase { url in
      let repository = try SQLiteInputAggregateRepository(location: .file(url))
      let aggregate = try utcAggregate(
        id: id("70000000-0000-0000-0000-000000000001"),
        hour: 0,
        keyCount: 1
      )
      _ = try await repository.insert(aggregate)
      try execute(
        "UPDATE input_aggregates SET period_end = period_end + 1",
        at: url
      )
      await #expect(
        throws: InputAggregateStoreError.metadataPayloadMismatch(
          column: "period_end"
        )
      ) {
        _ = try await repository.fetch(
          startingIn: aggregate.period.start..<aggregate.period.end
        )
      }
    }

    try await withTemporaryAggregateDatabase { url in
      let repository = try SQLiteInputAggregateRepository(location: .file(url))
      let aggregate = try utcAggregate(
        id: id("70000000-0000-0000-0000-000000000002"),
        hour: 0,
        keyCount: 1
      )
      _ = try await repository.insert(aggregate)
      try execute(
        "UPDATE input_aggregates SET payload_schema_version = 99",
        at: url
      )
      await #expect(
        throws: InputAggregateStoreError.unsupportedPayloadSchemaVersion(
          found: 99,
          supported: 1
        )
      ) {
        _ = try await repository.fetch(
          startingIn: aggregate.period.start..<aggregate.period.end
        )
      }
    }
  }

  @Test("schema version fingerprint and definitions are fail closed")
  func schemaValidation() async throws {
    try await withTemporaryAggregateDatabase { url in
      let repository = try SQLiteInputAggregateRepository(location: .file(url))
      #expect(try await repository.schemaVersion() == 2)
      #expect(
        try await repository.schemaFingerprint()
          == SQLiteInputAggregateRepository.expectedSchemaFingerprint)
      try execute(
        "UPDATE input_aggregate_schema_metadata SET schema_fingerprint = 'tampered'",
        at: url
      )
      #expect(
        throws: InputAggregateStoreError.corruptedSchema(
          "Schema fingerprint mismatch"
        )
      ) {
        _ = try SQLiteInputAggregateRepository(location: .file(url))
      }
    }

    try await withTemporaryAggregateDatabase { url in
      _ = try SQLiteInputAggregateRepository(location: .file(url))
      try execute(
        "UPDATE input_aggregate_schema_metadata SET schema_version = 99",
        at: url
      )
      #expect(
        throws: InputAggregateStoreError.unsupportedSchemaVersion(
          found: 99,
          supported: 2
        )
      ) {
        _ = try SQLiteInputAggregateRepository(location: .file(url))
      }
    }

    try await withTemporaryAggregateDatabase { url in
      _ = try SQLiteInputAggregateRepository(location: .file(url))
      try execute("DROP INDEX input_aggregates_period_start", at: url)
      do {
        _ = try SQLiteInputAggregateRepository(location: .file(url))
        Issue.record("Expected missing index rejection")
      } catch let error as InputAggregateStoreError {
        guard case .corruptedSchema(let message) = error else {
          Issue.record("Expected corrupted schema, got \(error)")
          return
        }
        #expect(message == "Unexpected input aggregate schema object set")
      }
    }

    try await withTemporaryAggregateDatabase { url in
      _ = try SQLiteInputAggregateRepository(location: .file(url))
      try execute(
        "CREATE TABLE input_aggregate_unknown(value INTEGER) STRICT",
        at: url
      )
      #expect(
        throws: InputAggregateStoreError.corruptedSchema(
          "Unexpected input aggregate schema object set"
        )
      ) {
        _ = try SQLiteInputAggregateRepository(location: .file(url))
      }
    }

    try await withTemporaryAggregateDatabase { url in
      try execute(
        "CREATE TABLE input_aggregate_unknown(value INTEGER) STRICT",
        at: url
      )
      #expect(
        throws: InputAggregateStoreError.corruptedSchema(
          "Input aggregate namespace must be empty before initial migration"
        )
      ) {
        _ = try SQLiteInputAggregateRepository(location: .file(url))
      }
    }
  }

  @Test("file store uses WAL and its namespace coexists with objective events")
  func fileWALAndNamespaceCompatibility() async throws {
    try await withTemporaryAggregateDatabase { url in
      let objective = try SQLiteObjectiveEventRepository(location: .file(url))
      #expect(try await objective.schemaVersion() == 4)
      let aggregates = try SQLiteInputAggregateRepository(location: .file(url))
      #expect(try await aggregates.schemaVersion() == 2)
      #expect(try scalarText("PRAGMA journal_mode", at: url).lowercased() == "wal")
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'objective_events'",
          at: url
        ) == 1)
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'input_aggregates'",
          at: url
        ) == 1)
    }
  }

  @Test("stored schema and payload expose no raw input event fields")
  func noRawInputSurface() async throws {
    try await withTemporaryAggregateDatabase { url in
      let repository = try SQLiteInputAggregateRepository(location: .file(url))
      _ = try await repository.insert(
        try utcAggregate(
          id: id("80000000-0000-0000-0000-000000000001"),
          hour: 0,
          keyCount: 4
        ))
      let material = try scalarTexts(
        """
        SELECT sql FROM sqlite_schema
        WHERE name LIKE 'input_aggregate%'
        UNION ALL
        SELECT payload FROM input_aggregates
        """,
        at: url
      ).joined(separator: "\n")
      for forbidden in [
        "occurred_at", "occurredAt", "typedText", "character",
        "normalizedX", "normalizedY", "location", "\"action\"",
        "sequence", "modifier", "CMSampleBuffer",
      ] {
        #expect(!material.contains(forbidden))
      }
    }
  }

  private func rollup(
    id: InputAggregateID,
    hourly: [InputAggregate]
  ) throws -> DailyInputRollupPlan {
    let day = try InputAggregatePeriod(
      start: instant("2026-08-01T00:00:00Z"),
      end: instant("2026-08-02T00:00:00Z"),
      granularity: .day,
      timeZoneIdentifier: "UTC",
      workdayBoundaryHour: 0
    )
    return try InputAggregationPolicy.makeDailyRollup(
      id: id,
      period: day,
      hourly: hourly
    )
  }

  private func utcAggregate(
    id: InputAggregateID,
    hour: Int,
    keyCount: UInt64
  ) throws -> InputAggregate {
    let start = instant(String(format: "2026-08-01T%02d:00:00Z", hour))
    let period = try InputAggregationPolicy.hourlyPeriod(
      containing: start,
      timeZoneIdentifier: "UTC"
    )
    return try makeAggregate(id: id, period: period, keyCount: keyCount)
  }

  private func makeAggregate(
    id: InputAggregateID,
    period: InputAggregatePeriod,
    keyCount: UInt64,
    includedDurationMilliseconds: UInt64 = 1_000
  ) throws -> InputAggregate {
    try InputAggregate(
      id: id,
      period: period,
      physicalKeyCounts: [PhysicalKeyCount(hardwareKeyCode: 42, count: keyCount)],
      includedDurationMilliseconds: includedDurationMilliseconds,
      collectorVersions: ["capture-1"],
      layoutVersions: ["ansi"]
    )
  }

  private func id(_ value: String) -> InputAggregateID {
    InputAggregateID(rawValue: UUID(uuidString: value)!)
  }

  private func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}

private func withTemporaryAggregateDatabase(
  _ body: (URL) async throws -> Void
) async throws {
  let url = URL(fileURLWithPath: "/tmp/dayday-input-\(UUID().uuidString).sqlite")
  defer {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
  }
  try await body(url)
}

private enum InputAggregateSQLiteTestError: Error {
  case open(Int32)
  case execute(Int32, String)
  case query(Int32, String)
  case missingValue
}

private func execute(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(
    url.path,
    &database,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
    nil
  )
  guard openResult == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw InputAggregateSQLiteTestError.open(openResult)
  }
  defer { sqlite3_close_v2(database) }
  var message: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &message)
  guard result == SQLITE_OK else {
    let text = message.map { String(cString: $0) } ?? "SQLite error"
    sqlite3_free(message)
    throw InputAggregateSQLiteTestError.execute(result, text)
  }
}

private func updateText(
  table: String,
  column: String,
  value: String,
  at url: URL
) throws {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
  guard openResult == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw InputAggregateSQLiteTestError.open(openResult)
  }
  defer { sqlite3_close_v2(database) }
  var statement: OpaquePointer?
  let prepareResult = sqlite3_prepare_v2(
    database,
    "UPDATE \(table) SET \(column) = ?",
    -1,
    &statement,
    nil
  )
  guard prepareResult == SQLITE_OK, let statement else {
    throw InputAggregateSQLiteTestError.query(
      prepareResult,
      String(cString: sqlite3_errmsg(database))
    )
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_bind_text(statement, 1, value, -1, dayday_sqlite_transient()) == SQLITE_OK,
    sqlite3_step(statement) == SQLITE_DONE
  else {
    throw InputAggregateSQLiteTestError.query(
      sqlite3_errcode(database),
      String(cString: sqlite3_errmsg(database))
    )
  }
}

private func scalarInt(_ sql: String, at url: URL) throws -> Int64 {
  var database: OpaquePointer?
  let statement = try prepareScalar(sql, at: url, databaseOut: &database)
  defer {
    sqlite3_finalize(statement)
    if let database { sqlite3_close_v2(database) }
  }
  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw InputAggregateSQLiteTestError.missingValue
  }
  return sqlite3_column_int64(statement, 0)
}

private func scalarText(_ sql: String, at url: URL) throws -> String {
  let values = try scalarTexts(sql, at: url)
  guard let first = values.first else {
    throw InputAggregateSQLiteTestError.missingValue
  }
  return first
}

private func scalarTexts(_ sql: String, at url: URL) throws -> [String] {
  var database: OpaquePointer?
  let statement = try prepareScalar(sql, at: url, databaseOut: &database)
  defer {
    sqlite3_finalize(statement)
    if let database { sqlite3_close_v2(database) }
  }
  var values: [String] = []
  while sqlite3_step(statement) == SQLITE_ROW {
    guard let text = sqlite3_column_text(statement, 0) else {
      throw InputAggregateSQLiteTestError.missingValue
    }
    values.append(String(cString: text))
  }
  return values
}

private func prepareScalar(
  _ sql: String,
  at url: URL,
  databaseOut: inout OpaquePointer?
) throws -> OpaquePointer {
  let openResult = sqlite3_open_v2(url.path, &databaseOut, SQLITE_OPEN_READONLY, nil)
  guard openResult == SQLITE_OK, let database = databaseOut else {
    if let databaseOut { sqlite3_close_v2(databaseOut) }
    throw InputAggregateSQLiteTestError.open(openResult)
  }
  var statement: OpaquePointer?
  let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
  guard result == SQLITE_OK, let statement else {
    let message = String(cString: sqlite3_errmsg(database))
    sqlite3_close_v2(database)
    databaseOut = nil
    throw InputAggregateSQLiteTestError.query(result, message)
  }
  return statement
}
