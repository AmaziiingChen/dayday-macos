import DaydayCore
import Foundation

public enum HealthArchiveStoreError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case corruptedSchema(String)
  case invalidStoredPayload
  case conflictingBatchReuse
}

/// A separate SQLite namespace for health facts. It shares Dayday's protected database location,
/// but no table, query, or foreign key with work reports, journals, mood, or AI usage.
public actor SQLiteHealthArchiveRepository: HealthArchiveRepository {
  public static let currentSchemaVersion = 6

  private static let metadataSQL = """
    CREATE TABLE health_archive_schema_metadata (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      schema_version INTEGER NOT NULL,
      schema_fingerprint TEXT NOT NULL
    ) STRICT
    """
  private static let migrationsSQL = """
    CREATE TABLE health_archive_schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at REAL NOT NULL
    ) STRICT
    """
  private static let observationsSQL = """
    CREATE TABLE health_archive_observations (
      source_installation_id TEXT NOT NULL,
      healthkit_uuid TEXT NOT NULL,
      kind TEXT NOT NULL,
      started_at REAL NOT NULL,
      ended_at REAL NOT NULL,
      received_at REAL NOT NULL,
      payload TEXT NOT NULL,
      PRIMARY KEY (source_installation_id, healthkit_uuid)
    ) STRICT
    """
  private static let tombstonesSQL = """
    CREATE TABLE health_archive_tombstones (
      source_installation_id TEXT NOT NULL,
      healthkit_uuid TEXT NOT NULL,
      kind TEXT NOT NULL,
      deleted_at REAL NOT NULL,
      payload TEXT NOT NULL,
      PRIMARY KEY (source_installation_id, healthkit_uuid)
    ) STRICT
    """
  private static let legacyBatchesSQL = """
    CREATE TABLE health_archive_batches (
      source_installation_id TEXT NOT NULL,
      batch_id TEXT NOT NULL,
      created_at REAL NOT NULL,
      payload TEXT NOT NULL,
      PRIMARY KEY (source_installation_id, batch_id)
    ) STRICT
    """
  private static let batchesSQL = """
    CREATE TABLE health_archive_batches (
      source_installation_id TEXT NOT NULL,
      batch_id TEXT NOT NULL,
      created_at REAL NOT NULL,
      received_at REAL NOT NULL,
      observation_count INTEGER NOT NULL CHECK (observation_count >= 0),
      tombstone_count INTEGER NOT NULL CHECK (tombstone_count >= 0),
      payload TEXT NOT NULL,
      PRIMARY KEY (source_installation_id, batch_id)
    ) STRICT
    """
  private static let localSuppressionsSQL = """
    CREATE TABLE health_archive_local_suppressions (
      source_installation_id TEXT NOT NULL,
      healthkit_uuid TEXT NOT NULL,
      suppressed_at REAL NOT NULL,
      PRIMARY KEY (source_installation_id, healthkit_uuid)
    ) STRICT
    """
  private static let statisticsStateSQL = """
    CREATE TABLE health_archive_statistics_state (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      archive_revision INTEGER NOT NULL CHECK (archive_revision >= 0),
      observation_count INTEGER NOT NULL CHECK (observation_count >= 0),
      received_batch_count INTEGER NOT NULL CHECK (received_batch_count >= 0),
      earliest_ended_at REAL,
      latest_ended_at REAL,
      latest_batch_received_at REAL
    ) STRICT
    """
  private static let kindTotalsSQL = """
    CREATE TABLE health_archive_kind_totals (
      kind TEXT PRIMARY KEY,
      observation_count INTEGER NOT NULL CHECK (observation_count > 0),
      latest_ended_at REAL NOT NULL
    ) STRICT
    """
  private static let sourceTotalsSQL = """
    CREATE TABLE health_archive_source_totals (
      source_installation_id TEXT PRIMARY KEY,
      observation_count INTEGER NOT NULL CHECK (observation_count > 0)
    ) STRICT
    """
  private static let dailyRollupsSQL = """
    CREATE TABLE health_archive_daily_rollups (
      time_zone_identifier TEXT NOT NULL,
      logical_date TEXT NOT NULL,
      kind TEXT NOT NULL,
      observation_count INTEGER NOT NULL CHECK (observation_count > 0),
      latest_ended_at REAL NOT NULL,
      PRIMARY KEY (time_zone_identifier, logical_date, kind)
    ) STRICT
    """
  private static let rollupStatesSQL = """
    CREATE TABLE health_archive_rollup_states (
      time_zone_identifier TEXT PRIMARY KEY,
      archive_revision INTEGER NOT NULL CHECK (archive_revision >= 0)
    ) STRICT
    """
  private static let metricDailyRollupsSQL = """
    CREATE TABLE health_archive_metric_daily_rollups (
      time_zone_identifier TEXT NOT NULL,
      logical_date TEXT NOT NULL,
      kind TEXT NOT NULL,
      value REAL NOT NULL,
      minimum REAL,
      maximum REAL,
      sample_count INTEGER NOT NULL CHECK (sample_count > 0),
      PRIMARY KEY (time_zone_identifier, logical_date, kind)
    ) STRICT
    """
  private static let metricRollupStatesSQL = """
    CREATE TABLE health_archive_metric_rollup_states (
      time_zone_identifier TEXT PRIMARY KEY,
      archive_revision INTEGER NOT NULL CHECK (archive_revision >= 0),
      target_revision INTEGER NOT NULL CHECK (target_revision >= 0),
      next_definition_index INTEGER NOT NULL CHECK (next_definition_index >= 0)
    ) STRICT
    """
  private static let metricDailyQueryIndexSQL =
    "CREATE INDEX health_archive_metric_daily_query ON health_archive_metric_daily_rollups(time_zone_identifier, kind, logical_date)"
  private static let dailyRollupBuildStatesSQL = """
    CREATE TABLE health_archive_daily_rollup_build_states (
      time_zone_identifier TEXT PRIMARY KEY,
      target_revision INTEGER NOT NULL CHECK (target_revision >= 0),
      next_kind_index INTEGER NOT NULL CHECK (next_kind_index >= 0)
    ) STRICT
    """
  private static let observationsQueryIndexSQL =
    "CREATE INDEX health_archive_observations_query ON health_archive_observations(kind, ended_at DESC, healthkit_uuid ASC)"
  private static let observationsEndedAtIndexSQL =
    "CREATE INDEX health_archive_observations_ended_at ON health_archive_observations(ended_at DESC, kind ASC)"
  private static let observationsSourceIndexSQL =
    "CREATE INDEX health_archive_observations_source ON health_archive_observations(source_installation_id ASC)"
  private static let batchesReceivedAtIndexSQL =
    "CREATE INDEX health_archive_batches_received_at ON health_archive_batches(received_at DESC, batch_id ASC)"

  private static let v1Definitions = [
    metadataSQL, migrationsSQL, observationsSQL, tombstonesSQL, legacyBatchesSQL,
    observationsQueryIndexSQL,
  ]
  private static let v2Definitions = v1Definitions + [localSuppressionsSQL]
  private static let v3Definitions = [
    metadataSQL, migrationsSQL, observationsSQL, tombstonesSQL, batchesSQL,
    observationsQueryIndexSQL,
    observationsEndedAtIndexSQL, batchesReceivedAtIndexSQL, localSuppressionsSQL,
  ]
  private static let v4Definitions =
    v3Definitions + [
      observationsSourceIndexSQL, statisticsStateSQL, kindTotalsSQL, sourceTotalsSQL,
      dailyRollupsSQL,
      rollupStatesSQL,
    ]
  private static let v5Definitions =
    v4Definitions + [
      metricDailyRollupsSQL, metricRollupStatesSQL, metricDailyQueryIndexSQL,
    ]
  private static let currentDefinitions = v5Definitions + [dailyRollupBuildStatesSQL]
  /// Kept internal for a migration fixture; production callers cannot choose a schema version.
  static let legacyV1SchemaFingerprint = fingerprint(of: v1Definitions)
  static let legacyV2SchemaFingerprint = fingerprint(of: v2Definitions)
  static let legacyV3SchemaFingerprint = fingerprint(of: v3Definitions)
  static let legacyV4SchemaFingerprint = fingerprint(of: v4Definitions)
  static let legacyV5SchemaFingerprint = fingerprint(of: v5Definitions)
  public static let expectedSchemaFingerprint = fingerprint(of: currentDefinitions)

  private let database: SQLiteDatabase
  private let fixedTimeZone: TimeZone?
  private var metricRollupBackfillTask: Task<Void, Never>?
  private var metricRollupBackfillLaunchCount = 0
  private var dailyRollupBackfillTask: Task<Void, Never>?
  private var statisticsBackfillTask: Task<Void, Never>?

  init(location: SQLiteDatabaseLocation, timeZone: TimeZone? = nil) throws {
    let database = try SQLiteDatabase(location: location)
    do {
      try Self.migrate(database)
    } catch {
      database.close()
      throw error
    }
    self.database = database
    self.fixedTimeZone = timeZone
  }

  public func apply(_ batch: HealthArchiveBatch) async throws -> HealthArchiveApplyResult {
    let receivedAt = Date()
    let timeZone = fixedTimeZone ?? .autoupdatingCurrent
    try await ensurePersistentStatisticsCurrentForMutation()
    return try database.transaction {
      let payload = try Self.canonicalPayload(batch)
      if let existing = try Self.batchPayload(
        sourceInstallationID: batch.sourceInstallationID, batchID: batch.batchID, from: database
      ) {
        guard existing == payload else { throw HealthArchiveStoreError.conflictingBatchReuse }
        return .alreadyApplied
      }

      let state = try Self.statisticsState(in: database)
      let maintainsCurrentRollup =
        try Self.rollupRevision(for: timeZone.identifier, in: database) == state.revision
      let maintainsCurrentMetricRollup =
        try Self.metricRollupRevision(for: timeZone.identifier, in: database) == state.revision
      var affectedRollupCells: Set<DailyRollupCell> = []
      var affectedMetricRollupCells: Set<DailyRollupCell> = []
      var observationCountDelta = 0
      var kindCountDeltas: [HealthObservationKind: Int] = [:]
      var sourceCountDeltas: [UUID: Int] = [:]
      var latestCandidates: [HealthObservationKind: Date] = [:]
      var removedObservationTimes: [HealthObservationKind: Set<Date>] = [:]
      var insertedEndedAts: [Date] = []
      var removedEndedAts: Set<Date> = []

      for observation in batch.observations {
        if !(try Self.isLocallySuppressed(observation.key, in: database)) {
          if let existing = try Self.storedObservationIndex(for: observation.key, in: database) {
            if maintainsCurrentRollup {
              affectedRollupCells.insert(Self.rollupCell(for: existing, timeZone: timeZone))
            }
            if maintainsCurrentMetricRollup {
              affectedMetricRollupCells.formUnion(
                Self.metricRollupCells(for: existing, timeZone: timeZone))
            }
            if existing.kind != observation.kind {
              kindCountDeltas[existing.kind, default: 0] -= 1
              kindCountDeltas[observation.kind, default: 0] += 1
            }
            removedObservationTimes[existing.kind, default: []].insert(existing.endedAt)
            removedEndedAts.insert(existing.endedAt)
          } else {
            observationCountDelta += 1
            kindCountDeltas[observation.kind, default: 0] += 1
            sourceCountDeltas[observation.key.sourceInstallationID, default: 0] += 1
          }
          try Self.upsert(observation, into: database)
          try Self.deleteTombstone(for: observation.key, from: database)
          if maintainsCurrentRollup {
            affectedRollupCells.insert(Self.rollupCell(for: observation, timeZone: timeZone))
          }
          if maintainsCurrentMetricRollup {
            affectedMetricRollupCells.formUnion(
              Self.metricRollupCells(for: observation, timeZone: timeZone))
          }
          latestCandidates[observation.kind] = max(
            latestCandidates[observation.kind] ?? observation.endedAt,
            observation.endedAt
          )
          insertedEndedAts.append(observation.endedAt)
        }
      }
      for tombstone in batch.tombstones {
        if let existing = try Self.storedObservationIndex(for: tombstone.key, in: database) {
          observationCountDelta -= 1
          kindCountDeltas[existing.kind, default: 0] -= 1
          sourceCountDeltas[existing.sourceInstallationID, default: 0] -= 1
          removedObservationTimes[existing.kind, default: []].insert(existing.endedAt)
          removedEndedAts.insert(existing.endedAt)
          if maintainsCurrentRollup {
            affectedRollupCells.insert(Self.rollupCell(for: existing, timeZone: timeZone))
          }
          if maintainsCurrentMetricRollup {
            affectedMetricRollupCells.formUnion(
              Self.metricRollupCells(for: existing, timeZone: timeZone))
          }
        }
        try Self.deleteObservation(for: tombstone.key, from: database)
        try Self.upsert(tombstone, into: database)
      }
      let statement = try database.prepare(
        "INSERT INTO health_archive_batches(source_installation_id, batch_id, created_at, received_at, observation_count, tombstone_count, payload) VALUES (?, ?, ?, ?, ?, ?, ?)"
      )
      try statement.bind(Self.uuid(batch.sourceInstallationID), at: 1)
      try statement.bind(Self.uuid(batch.batchID), at: 2)
      try statement.bind(batch.createdAt.timeIntervalSinceReferenceDate, at: 3)
      try statement.bind(receivedAt.timeIntervalSinceReferenceDate, at: 4)
      try statement.bind(Int64(batch.observations.count), at: 5)
      try statement.bind(Int64(batch.tombstones.count), at: 6)
      try statement.bind(payload, at: 7)
      try statement.expectDone()
      let newRevision = try Self.advancedRevision(state.revision)
      try Self.applyKindTotalDeltas(
        kindCountDeltas,
        latestCandidates: latestCandidates,
        removedObservationTimes: removedObservationTimes,
        in: database
      )
      try Self.applySourceTotalDeltas(sourceCountDeltas, in: database)
      try Self.updateStatisticsState(
        revision: newRevision,
        observationCount: state.observationCount + observationCountDelta,
        receivedBatchCount: state.receivedBatchCount + 1,
        latestBatchReceivedAt: max(state.latestBatchReceivedAt ?? receivedAt, receivedAt),
        previousState: state,
        insertedEndedAts: insertedEndedAts,
        removedEndedAts: removedEndedAts,
        in: database
      )
      try Self.setRollupRevision(
        newRevision, for: Self.statisticsRollupIdentifier, in: database)
      if maintainsCurrentRollup {
        try Self.rebuildRollupCells(
          affectedRollupCells,
          timeZone: timeZone,
          in: database
        )
        try Self.setRollupRevision(newRevision, for: timeZone.identifier, in: database)
      }
      if maintainsCurrentMetricRollup {
        try Self.rebuildMetricRollupCells(
          affectedMetricRollupCells,
          timeZone: timeZone,
          in: database
        )
        try Self.setMetricRollupRevision(newRevision, for: timeZone.identifier, in: database)
      }
      return .applied
    }
  }

  public func observations(matching query: HealthArchiveQuery) async throws -> [HealthObservation] {
    var clauses: [String] = []
    var bindings: [String] = []
    if let kinds = query.kinds, !kinds.isEmpty {
      clauses.append(
        "kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))")
      bindings.append(contentsOf: kinds.map(\.rawValue).sorted())
    }
    if let startsAtOrAfter = query.startsAtOrAfter {
      clauses.append("ended_at >= ?")
      bindings.append(String(startsAtOrAfter.timeIntervalSinceReferenceDate))
    }
    if let endsAtOrBefore = query.endsAtOrBefore {
      clauses.append("started_at <= ?")
      bindings.append(String(endsAtOrBefore.timeIntervalSinceReferenceDate))
    }
    let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
    let statement = try database.prepare(
      "SELECT source_installation_id, healthkit_uuid, kind, started_at, ended_at, received_at, payload FROM health_archive_observations\(whereClause) ORDER BY ended_at DESC, healthkit_uuid ASC LIMIT ?"
    )
    var index: Int32 = 1
    for value in bindings {
      if let number = Double(value) {
        try statement.bind(number, at: index)
      } else {
        try statement.bind(value, at: index)
      }
      index += 1
    }
    try statement.bind(Int64(query.limit), at: index)

    var results: [HealthObservation] = []
    while try statement.stepRow() {
      results.append(try Self.decodeObservation(from: statement))
    }
    return results
  }

  public func coverage() async throws -> [HealthObservationCoverage] {
    try Self.coverage(
      matching: nil,
      timeZone: fixedTimeZone ?? .autoupdatingCurrent,
      in: database
    )
  }

  public func dashboard(matching query: HealthArchiveStatisticsQuery) async throws
    -> HealthArchiveDashboard
  {
    let timeZone = fixedTimeZone ?? .autoupdatingCurrent
    let storedState = try Self.statisticsState(in: database)
    let statisticsCurrent =
      try Self.rollupRevision(for: Self.statisticsRollupIdentifier, in: database)
      == storedState.revision
    let state =
      statisticsCurrent
      ? storedState : try Self.fallbackStatisticsState(revision: storedState.revision, in: database)
    let dailyRollupsCurrent =
      try Self.rollupRevision(for: timeZone.identifier, in: database) == state.revision
    let metricRollupsCurrent =
      try Self.metricRollupRevision(for: timeZone.identifier, in: database) == state.revision
    let coverage = try Self.coverage(
      matching: query,
      timeZone: timeZone,
      usesDailyRollups: dailyRollupsCurrent,
      in: database
    )
    let dashboard = HealthArchiveDashboard(
      archiveRevision: state.revision,
      summary: statisticsCurrent
        ? try Self.summary(state: state, in: database)
        : try Self.fallbackSummary(state: state, in: database),
      coverage: coverage,
      recentSyncs: try Self.recentSyncs(limit: query.recentSyncLimit, in: database),
      dailyCounts: try Self.dailyCounts(
        matching: query,
        timeZone: timeZone,
        usesDailyRollups: dailyRollupsCurrent,
        in: database
      ),
      metricSeries: try Self.metricSeries(
        matching: query,
        timeZone: timeZone,
        usesDailyRollups: metricRollupsCurrent,
        in: database
      )
    )
    if !metricRollupsCurrent {
      scheduleMetricRollupBackfill(timeZone: timeZone)
    }
    if !dailyRollupsCurrent {
      scheduleDailyRollupBackfill(timeZone: timeZone)
    }
    if !statisticsCurrent {
      scheduleStatisticsBackfill()
    }
    return dashboard
  }

  private func scheduleMetricRollupBackfill(timeZone: TimeZone) {
    guard metricRollupBackfillTask == nil else { return }
    metricRollupBackfillLaunchCount += 1
    metricRollupBackfillTask = Task(priority: .utility) { [weak self] in
      await self?.runMetricRollupBackfill(timeZone: timeZone)
    }
  }

  private func runMetricRollupBackfill(timeZone: TimeZone) async {
    defer { metricRollupBackfillTask = nil }
    while !Task.isCancelled {
      do {
        let storedState = try Self.statisticsState(in: database)
        let statisticsCurrent =
          try Self.rollupRevision(for: Self.statisticsRollupIdentifier, in: database)
          == storedState.revision
        let state =
          statisticsCurrent
          ? storedState
          : try Self.fallbackStatisticsState(revision: storedState.revision, in: database)
        if try Self.metricRollupRevision(for: timeZone.identifier, in: database) == state.revision {
          return
        }
        try Self.prepareMetricRollupBackfill(
          revision: state.revision,
          timeZone: timeZone,
          in: database
        )
        guard
          try Self.rebuildNextMetricRollupDefinition(
            revision: state.revision,
            timeZone: timeZone,
            state: state,
            in: database
          )
        else { return }
      } catch {
        // The raw archive remains authoritative and dashboard reads keep using the bounded
        // fallback. A later dashboard request starts another recoverable attempt.
        return
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func waitForMetricRollupBackfillForTesting() async {
    await metricRollupBackfillTask?.value
  }

  func metricRollupBackfillStatusForTesting() -> (isRunning: Bool, launchCount: Int) {
    (metricRollupBackfillTask != nil, metricRollupBackfillLaunchCount)
  }

  private func scheduleDailyRollupBackfill(timeZone: TimeZone) {
    guard dailyRollupBackfillTask == nil else { return }
    dailyRollupBackfillTask = Task(priority: .utility) { [weak self] in
      await self?.runDailyRollupBackfill(timeZone: timeZone)
    }
  }

  private func runDailyRollupBackfill(timeZone: TimeZone) async {
    defer { dailyRollupBackfillTask = nil }
    while !Task.isCancelled {
      do {
        let state = try Self.statisticsState(in: database)
        if try Self.rollupRevision(for: timeZone.identifier, in: database) == state.revision {
          return
        }
        try Self.prepareDailyRollupBackfill(
          revision: state.revision, timeZone: timeZone, in: database)
        guard
          try Self.rebuildNextDailyRollupKind(
            revision: state.revision, timeZone: timeZone, in: database)
        else { return }
      } catch {
        return
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  private func scheduleStatisticsBackfill() {
    guard statisticsBackfillTask == nil else { return }
    statisticsBackfillTask = Task(priority: .utility) { [weak self] in
      await self?.runStatisticsBackfill()
    }
  }

  private func runStatisticsBackfill() async {
    defer { statisticsBackfillTask = nil }
    guard !Task.isCancelled else { return }
    try? database.transaction {
      try Self.rebuildPersistentStatistics(in: database)
    }
  }

  private func ensurePersistentStatisticsCurrentForMutation() async throws {
    let state = try Self.statisticsState(in: database)
    guard
      try Self.rollupRevision(for: Self.statisticsRollupIdentifier, in: database) != state.revision
    else { return }
    scheduleStatisticsBackfill()
    await statisticsBackfillTask?.value
    let refreshed = try Self.statisticsState(in: database)
    guard
      try Self.rollupRevision(for: Self.statisticsRollupIdentifier, in: database)
        == refreshed.revision
    else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
  }

  func waitForAllHealthBackfillsForTesting() async {
    await statisticsBackfillTask?.value
    await dailyRollupBackfillTask?.value
    await metricRollupBackfillTask?.value
  }

  func cancelHealthBackfillsForTesting() async {
    statisticsBackfillTask?.cancel()
    dailyRollupBackfillTask?.cancel()
    metricRollupBackfillTask?.cancel()
    await waitForAllHealthBackfillsForTesting()
  }

  private static func summary(
    state: StatisticsState,
    in database: SQLiteDatabase
  ) throws -> HealthArchiveSummary {
    let kinds = try database.prepare(
      "SELECT COUNT(*) FROM health_archive_kind_totals"
    )
    guard try kinds.stepRow(),
      let coveredKindCount = Int(
        exactly: try kinds.requiredInt64(at: 0, column: "covered_kind_count")),
      !(try kinds.stepRow())
    else { throw HealthArchiveStoreError.invalidStoredPayload }

    let sources = try database.prepare(
      "SELECT COUNT(*) FROM health_archive_source_totals"
    )
    guard try sources.stepRow(),
      let sourceCount = Int(exactly: try sources.requiredInt64(at: 0, column: "source_count")),
      !(try sources.stepRow())
    else { throw HealthArchiveStoreError.invalidStoredPayload }

    return HealthArchiveSummary(
      observationCount: state.observationCount,
      coveredKindCount: coveredKindCount,
      sourceInstallationCount: sourceCount,
      receivedBatchCount: state.receivedBatchCount,
      earliestEndedAt: state.earliestEndedAt,
      latestEndedAt: state.latestEndedAt,
      latestBatchReceivedAt: state.latestBatchReceivedAt
    )
  }

  private static func recentSyncs(limit: Int, in database: SQLiteDatabase) throws
    -> [HealthSyncReceipt]
  {
    let statement = try database.prepare(
      "SELECT batch_id, received_at, observation_count, tombstone_count FROM health_archive_batches ORDER BY received_at DESC, batch_id ASC LIMIT ?"
    )
    try statement.bind(Int64(limit), at: 1)
    var receipts: [HealthSyncReceipt] = []
    while try statement.stepRow() {
      guard let batchID = UUID(uuidString: try statement.requiredText(at: 0, column: "batch_id")),
        let observationCount = Int(
          exactly: try statement.requiredInt64(at: 2, column: "observation_count")),
        let tombstoneCount = Int(
          exactly: try statement.requiredInt64(at: 3, column: "tombstone_count")),
        observationCount >= 0, tombstoneCount >= 0
      else { throw HealthArchiveStoreError.invalidStoredPayload }
      receipts.append(
        HealthSyncReceipt(
          batchID: batchID,
          receivedAt: Date(
            timeIntervalSinceReferenceDate: try statement.requiredDouble(
              at: 1, column: "received_at")),
          observationCount: observationCount,
          tombstoneCount: tombstoneCount
        ))
    }
    return receipts
  }

  /// SQLite's `localtime` modifier consults the operating-system timezone for every row. On a
  /// personal archive that turns a small covering-index scan into seconds of system calls. Build
  /// the finite timezone-offset transitions once, then let SQLite evaluate only numeric CASE
  /// branches. This preserves local calendar days, including daylight-saving transitions.
  static func localDayOffsetIntervals(
    startsAt: Date,
    endsAt: Date,
    timeZone: TimeZone
  ) -> [(upperBound: Date?, secondsFromGMT: Int)] {
    var intervals: [(Date?, Int)] = []
    var cursor = startsAt
    while let transition = timeZone.nextDaylightSavingTimeTransition(after: cursor),
      transition <= endsAt
    {
      intervals.append((transition, timeZone.secondsFromGMT(for: cursor)))
      cursor = transition.addingTimeInterval(1)
    }
    intervals.append((nil, timeZone.secondsFromGMT(for: cursor)))
    return intervals
  }

  static func localDayOffsetSQL(
    startsAt: Date,
    endsAt: Date,
    timeZone: TimeZone
  ) -> String {
    let intervals = localDayOffsetIntervals(
      startsAt: startsAt,
      endsAt: endsAt,
      timeZone: timeZone
    )
    guard let finalInterval = intervals.last else { return "0" }
    guard intervals.count > 1 else { return String(finalInterval.secondsFromGMT) }
    let branches = intervals.dropLast().map { interval in
      let upperBound = interval.upperBound ?? endsAt
      return
        "WHEN ended_at < \(upperBound.timeIntervalSinceReferenceDate) THEN \(interval.secondsFromGMT)"
    }.joined(separator: " ")
    return "CASE \(branches) ELSE \(finalInterval.secondsFromGMT) END"
  }

  public func delete(_ request: HealthArchiveDeletionRequest) async throws
    -> HealthArchiveDeletionResult
  {
    let timeZone = fixedTimeZone ?? .autoupdatingCurrent
    try await ensurePersistentStatisticsCurrentForMutation()
    return try database.transaction {
      let matching = try Self.matchingKeys(for: request, in: database)
      guard !matching.isEmpty else {
        return HealthArchiveDeletionResult(removedObservationCount: 0)
      }
      let state = try Self.statisticsState(in: database)
      let maintainsCurrentRollup =
        try Self.rollupRevision(for: timeZone.identifier, in: database) == state.revision
      let maintainsCurrentMetricRollup =
        try Self.metricRollupRevision(for: timeZone.identifier, in: database) == state.revision
      var affectedRollupCells: Set<DailyRollupCell> = []
      var affectedMetricRollupCells: Set<DailyRollupCell> = []
      var kindCountDeltas: [HealthObservationKind: Int] = [:]
      var sourceCountDeltas: [UUID: Int] = [:]
      var removedObservationTimes: [HealthObservationKind: Set<Date>] = [:]
      var removedEndedAts: Set<Date> = []
      for key in matching {
        if let existing = try Self.storedObservationIndex(for: key, in: database) {
          kindCountDeltas[existing.kind, default: 0] -= 1
          sourceCountDeltas[existing.sourceInstallationID, default: 0] -= 1
          removedObservationTimes[existing.kind, default: []].insert(existing.endedAt)
          removedEndedAts.insert(existing.endedAt)
          if maintainsCurrentRollup {
            affectedRollupCells.insert(Self.rollupCell(for: existing, timeZone: timeZone))
          }
          if maintainsCurrentMetricRollup {
            affectedMetricRollupCells.formUnion(
              Self.metricRollupCells(for: existing, timeZone: timeZone))
          }
        }
        try Self.deleteObservation(for: key, from: database)
        try Self.suppressLocally(key, at: Date(), in: database)
      }
      let newRevision = try Self.advancedRevision(state.revision)
      try Self.applyKindTotalDeltas(
        kindCountDeltas,
        latestCandidates: [:],
        removedObservationTimes: removedObservationTimes,
        in: database
      )
      try Self.applySourceTotalDeltas(sourceCountDeltas, in: database)
      try Self.updateStatisticsState(
        revision: newRevision,
        observationCount: state.observationCount - matching.count,
        receivedBatchCount: state.receivedBatchCount,
        latestBatchReceivedAt: state.latestBatchReceivedAt,
        previousState: state,
        insertedEndedAts: [],
        removedEndedAts: removedEndedAts,
        in: database
      )
      try Self.setRollupRevision(
        newRevision, for: Self.statisticsRollupIdentifier, in: database)
      if maintainsCurrentRollup {
        try Self.rebuildRollupCells(
          affectedRollupCells,
          timeZone: timeZone,
          in: database
        )
        try Self.setRollupRevision(newRevision, for: timeZone.identifier, in: database)
      }
      if maintainsCurrentMetricRollup {
        try Self.rebuildMetricRollupCells(
          affectedMetricRollupCells,
          timeZone: timeZone,
          in: database
        )
        try Self.setMetricRollupRevision(newRevision, for: timeZone.identifier, in: database)
      }
      return HealthArchiveDeletionResult(removedObservationCount: matching.count)
    }
  }

  public func export(matching query: HealthArchiveQuery, exportedAt: Date) async throws
    -> HealthArchiveExport
  {
    var clauses: [String] = []
    var bindings: [String] = []
    if let kinds = query.kinds, !kinds.isEmpty {
      clauses.append(
        "kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))")
      bindings.append(contentsOf: kinds.map(\.rawValue).sorted())
    }
    if let startsAtOrAfter = query.startsAtOrAfter {
      clauses.append("ended_at >= ?")
      bindings.append(String(startsAtOrAfter.timeIntervalSinceReferenceDate))
    }
    if let endsAtOrBefore = query.endsAtOrBefore {
      clauses.append("started_at <= ?")
      bindings.append(String(endsAtOrBefore.timeIntervalSinceReferenceDate))
    }
    let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
    let statement = try database.prepare(
      "SELECT source_installation_id, healthkit_uuid, kind, started_at, ended_at, received_at, payload FROM health_archive_observations\(whereClause) ORDER BY ended_at DESC, healthkit_uuid ASC"
    )
    try Self.bind(bindings, to: statement)
    var facts: [HealthObservation] = []
    while try statement.stepRow() { facts.append(try Self.decodeObservation(from: statement)) }
    return HealthArchiveExport(exportedAt: exportedAt, observations: facts)
  }

  public func schemaVersion() async throws -> Int { try Self.metadata(from: database).version }
  public func schemaFingerprint() async throws -> String {
    try Self.metadata(from: database).fingerprint
  }

  private static func upsert(_ observation: HealthObservation, into database: SQLiteDatabase) throws
  {
    let statement = try database.prepare(
      """
      INSERT INTO health_archive_observations(
        source_installation_id, healthkit_uuid, kind, started_at, ended_at, received_at, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_installation_id, healthkit_uuid) DO UPDATE SET
        kind = excluded.kind, started_at = excluded.started_at, ended_at = excluded.ended_at,
        received_at = excluded.received_at, payload = excluded.payload
      """)
    try statement.bind(uuid(observation.key.sourceInstallationID), at: 1)
    try statement.bind(uuid(observation.key.healthKitUUID), at: 2)
    try statement.bind(observation.kind.rawValue, at: 3)
    try statement.bind(observation.startedAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(observation.endedAt.timeIntervalSinceReferenceDate, at: 5)
    try statement.bind(observation.receivedAt.timeIntervalSinceReferenceDate, at: 6)
    try statement.bind(try canonicalPayload(observation), at: 7)
    try statement.expectDone()
  }

  private static func upsert(_ tombstone: HealthObservationTombstone, into database: SQLiteDatabase)
    throws
  {
    let statement = try database.prepare(
      """
      INSERT INTO health_archive_tombstones(source_installation_id, healthkit_uuid, kind, deleted_at, payload)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(source_installation_id, healthkit_uuid) DO UPDATE SET
        kind = excluded.kind, deleted_at = excluded.deleted_at, payload = excluded.payload
      """)
    try statement.bind(uuid(tombstone.key.sourceInstallationID), at: 1)
    try statement.bind(uuid(tombstone.key.healthKitUUID), at: 2)
    try statement.bind(tombstone.kind.rawValue, at: 3)
    try statement.bind(tombstone.deletedAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(try canonicalPayload(tombstone), at: 5)
    try statement.expectDone()
  }

  private static func deleteObservation(
    for key: HealthObservationKey, from database: SQLiteDatabase
  ) throws {
    let statement = try database.prepare(
      "DELETE FROM health_archive_observations WHERE source_installation_id = ? AND healthkit_uuid = ?"
    )
    try statement.bind(uuid(key.sourceInstallationID), at: 1)
    try statement.bind(uuid(key.healthKitUUID), at: 2)
    try statement.expectDone()
  }

  private static func deleteTombstone(for key: HealthObservationKey, from database: SQLiteDatabase)
    throws
  {
    let statement = try database.prepare(
      "DELETE FROM health_archive_tombstones WHERE source_installation_id = ? AND healthkit_uuid = ?"
    )
    try statement.bind(uuid(key.sourceInstallationID), at: 1)
    try statement.bind(uuid(key.healthKitUUID), at: 2)
    try statement.expectDone()
  }

  private static func matchingKeys(
    for request: HealthArchiveDeletionRequest, in database: SQLiteDatabase
  ) throws -> [HealthObservationKey] {
    let orderedKinds = request.kinds.map(\.rawValue).sorted()
    let statement = try database.prepare(
      """
      SELECT source_installation_id, healthkit_uuid FROM health_archive_observations
      WHERE kind IN (\(Array(repeating: "?", count: orderedKinds.count).joined(separator: ", ")))
      AND ended_at >= ? AND started_at <= ?
      """)
    var index: Int32 = 1
    for kind in orderedKinds {
      try statement.bind(kind, at: index)
      index += 1
    }
    try statement.bind(request.startsAtOrAfter.timeIntervalSinceReferenceDate, at: index)
    index += 1
    try statement.bind(request.endsAtOrBefore.timeIntervalSinceReferenceDate, at: index)
    var keys: [HealthObservationKey] = []
    while try statement.stepRow() {
      guard
        let source = UUID(
          uuidString: try statement.requiredText(at: 0, column: "source_installation_id")),
        let sample = UUID(uuidString: try statement.requiredText(at: 1, column: "healthkit_uuid"))
      else { throw HealthArchiveStoreError.invalidStoredPayload }
      keys.append(HealthObservationKey(sourceInstallationID: source, healthKitUUID: sample))
    }
    return keys
  }

  private static func isLocallySuppressed(_ key: HealthObservationKey, in database: SQLiteDatabase)
    throws -> Bool
  {
    let statement = try database.prepare(
      """
      SELECT 1 FROM health_archive_local_suppressions
      WHERE source_installation_id = ? AND healthkit_uuid = ?
      """)
    try statement.bind(uuid(key.sourceInstallationID), at: 1)
    try statement.bind(uuid(key.healthKitUUID), at: 2)
    return try statement.stepRow()
  }

  private static func suppressLocally(
    _ key: HealthObservationKey, at date: Date, in database: SQLiteDatabase
  ) throws {
    let statement = try database.prepare(
      """
      INSERT INTO health_archive_local_suppressions(source_installation_id, healthkit_uuid, suppressed_at)
      VALUES (?, ?, ?)
      ON CONFLICT(source_installation_id, healthkit_uuid) DO UPDATE SET suppressed_at = excluded.suppressed_at
      """)
    try statement.bind(uuid(key.sourceInstallationID), at: 1)
    try statement.bind(uuid(key.healthKitUUID), at: 2)
    try statement.bind(date.timeIntervalSinceReferenceDate, at: 3)
    try statement.expectDone()
  }

  private static func bind(_ values: [String], to statement: SQLiteStatement) throws {
    var index: Int32 = 1
    for value in values {
      if let number = Double(value) {
        try statement.bind(number, at: index)
      } else {
        try statement.bind(value, at: index)
      }
      index += 1
    }
  }

  private static func batchPayload(
    sourceInstallationID: UUID, batchID: UUID, from database: SQLiteDatabase
  ) throws -> String? {
    let statement = try database.prepare(
      "SELECT payload FROM health_archive_batches WHERE source_installation_id = ? AND batch_id = ?"
    )
    try statement.bind(uuid(sourceInstallationID), at: 1)
    try statement.bind(uuid(batchID), at: 2)
    guard try statement.stepRow() else { return nil }
    let payload = try statement.requiredText(at: 0, column: "payload")
    guard !(try statement.stepRow()) else { throw HealthArchiveStoreError.invalidStoredPayload }
    return payload
  }

  private static func decodeObservation(from statement: SQLiteStatement) throws -> HealthObservation
  {
    let sourceRaw = try statement.requiredText(at: 0, column: "source_installation_id")
    let healthKitRaw = try statement.requiredText(at: 1, column: "healthkit_uuid")
    let kindRaw = try statement.requiredText(at: 2, column: "kind")
    let startedAt = try statement.requiredDouble(at: 3, column: "started_at")
    let endedAt = try statement.requiredDouble(at: 4, column: "ended_at")
    let receivedAt = try statement.requiredDouble(at: 5, column: "received_at")
    let payload = try statement.requiredText(at: 6, column: "payload")
    guard let sourceInstallationID = UUID(uuidString: sourceRaw),
      let healthKitUUID = UUID(uuidString: healthKitRaw),
      let kind = HealthObservationKind(rawValue: kindRaw),
      let observation = try? decode(HealthObservation.self, payload: payload),
      observation.key
        == HealthObservationKey(
          sourceInstallationID: sourceInstallationID, healthKitUUID: healthKitUUID
        ),
      observation.kind == kind,
      observation.startedAt.timeIntervalSinceReferenceDate == startedAt,
      observation.endedAt.timeIntervalSinceReferenceDate == endedAt,
      observation.receivedAt.timeIntervalSinceReferenceDate == receivedAt
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    return observation
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "health_archive")
      if names.isEmpty {
        try database.execute(metadataSQL)
        try database.execute(migrationsSQL)
        try database.execute(observationsSQL)
        try database.execute(tombstonesSQL)
        try database.execute(batchesSQL)
        try database.execute(observationsQueryIndexSQL)
        try database.execute(observationsEndedAtIndexSQL)
        try database.execute(batchesReceivedAtIndexSQL)
        try database.execute(localSuppressionsSQL)
        try database.execute(observationsSourceIndexSQL)
        try database.execute(statisticsStateSQL)
        try database.execute(kindTotalsSQL)
        try database.execute(sourceTotalsSQL)
        try database.execute(dailyRollupsSQL)
        try database.execute(rollupStatesSQL)
        try database.execute(metricDailyRollupsSQL)
        try database.execute(metricRollupStatesSQL)
        try database.execute(metricDailyQueryIndexSQL)
        try database.execute(dailyRollupBuildStatesSQL)
        let migration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (1, ?)"
        )
        try migration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try migration.expectDone()
        let secondMigration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (2, ?)"
        )
        try secondMigration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try secondMigration.expectDone()
        let thirdMigration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (3, ?)"
        )
        try thirdMigration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try thirdMigration.expectDone()
        let fourthMigration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (4, ?)"
        )
        try fourthMigration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try fourthMigration.expectDone()
        let fifthMigration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (5, ?)"
        )
        try fifthMigration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try fifthMigration.expectDone()
        let sixthMigration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (6, ?)"
        )
        try sixthMigration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try sixthMigration.expectDone()
        try Self.initializePersistentStatisticsPlaceholder(in: database)
        try Self.rebuildPersistentStatistics(in: database)
        let metadata = try database.prepare(
          "INSERT INTO health_archive_schema_metadata(singleton, schema_version, schema_fingerprint) VALUES (1, 6, ?)"
        )
        try metadata.bind(expectedSchemaFingerprint, at: 1)
        try metadata.expectDone()
      }
      var storedMetadata = try Self.metadata(from: database)
      guard storedMetadata.version <= currentSchemaVersion else {
        throw HealthArchiveStoreError.unsupportedSchemaVersion(
          found: storedMetadata.version, supported: currentSchemaVersion)
      }
      if storedMetadata.version == 1 {
        try Self.verifySchema(database, definitions: v1Definitions)
        guard storedMetadata.fingerprint == legacyV1SchemaFingerprint else {
          throw HealthArchiveStoreError.corruptedSchema("Unexpected v1 schema metadata")
        }
        try database.execute(localSuppressionsSQL)
        let migration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (2, ?)"
        )
        try migration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE health_archive_schema_metadata SET schema_version = 2, schema_fingerprint = ? WHERE singleton = 1"
        )
        try update.bind(legacyV2SchemaFingerprint, at: 1)
        try update.expectDone()
        storedMetadata = (2, legacyV2SchemaFingerprint)
      }
      if storedMetadata.version == 2 {
        try Self.verifySchema(database, definitions: v2Definitions)
        guard storedMetadata.fingerprint == legacyV2SchemaFingerprint else {
          throw HealthArchiveStoreError.corruptedSchema("Unexpected v2 schema metadata")
        }
        try database.execute(
          "ALTER TABLE health_archive_batches RENAME TO health_archive_batches_v2")
        try database.execute(batchesSQL)
        try database.execute(
          """
          INSERT INTO health_archive_batches(
            source_installation_id, batch_id, created_at, received_at,
            observation_count, tombstone_count, payload
          )
          SELECT source_installation_id, batch_id, created_at, created_at,
                 COALESCE(json_array_length(payload, '$.observations'), 0),
                 COALESCE(json_array_length(payload, '$.tombstones'), 0),
                 payload
          FROM health_archive_batches_v2
          """)
        try database.execute("DROP TABLE health_archive_batches_v2")
        try database.execute(observationsEndedAtIndexSQL)
        try database.execute(batchesReceivedAtIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (3, ?)"
        )
        try migration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE health_archive_schema_metadata SET schema_version = 3, schema_fingerprint = ? WHERE singleton = 1"
        )
        try update.bind(legacyV3SchemaFingerprint, at: 1)
        try update.expectDone()
        storedMetadata = (3, legacyV3SchemaFingerprint)
      }
      if storedMetadata.version == 3 {
        try Self.verifySchema(database, definitions: v3Definitions)
        guard storedMetadata.fingerprint == legacyV3SchemaFingerprint else {
          throw HealthArchiveStoreError.corruptedSchema("Unexpected v3 schema metadata")
        }
        try database.execute(statisticsStateSQL)
        try database.execute(observationsSourceIndexSQL)
        try database.execute(kindTotalsSQL)
        try database.execute(sourceTotalsSQL)
        try database.execute(dailyRollupsSQL)
        try database.execute(rollupStatesSQL)
        try Self.initializePersistentStatisticsPlaceholder(in: database)
        let migration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (4, ?)"
        )
        try migration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE health_archive_schema_metadata SET schema_version = 4, schema_fingerprint = ? WHERE singleton = 1"
        )
        try update.bind(legacyV4SchemaFingerprint, at: 1)
        try update.expectDone()
        storedMetadata = (4, legacyV4SchemaFingerprint)
      }
      if storedMetadata.version == 4 {
        try Self.verifySchema(database, definitions: v4Definitions)
        guard storedMetadata.fingerprint == legacyV4SchemaFingerprint else {
          throw HealthArchiveStoreError.corruptedSchema("Unexpected v4 schema metadata")
        }
        try database.execute(metricDailyRollupsSQL)
        try database.execute(metricRollupStatesSQL)
        try database.execute(metricDailyQueryIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (5, ?)"
        )
        try migration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE health_archive_schema_metadata SET schema_version = 5, schema_fingerprint = ? WHERE singleton = 1"
        )
        try update.bind(legacyV5SchemaFingerprint, at: 1)
        try update.expectDone()
        storedMetadata = (5, legacyV5SchemaFingerprint)
      }
      if storedMetadata.version == 5 {
        if storedMetadata.fingerprint == legacyV5SchemaFingerprint {
          try Self.verifySchema(database, definitions: v5Definitions)
          try database.execute(dailyRollupBuildStatesSQL)
        } else if storedMetadata.fingerprint == expectedSchemaFingerprint {
          // A short-lived development build wrote the v6 object set while still labelling it v5.
          // Accept that exact, fully verified shape so those local archives can advance safely too.
          try Self.verifySchema(database, definitions: currentDefinitions)
        } else {
          throw HealthArchiveStoreError.corruptedSchema("Unexpected v5 schema metadata")
        }
        let migration = try database.prepare(
          "INSERT INTO health_archive_schema_migrations(version, applied_at) VALUES (6, ?)"
        )
        try migration.bind(Date().timeIntervalSinceReferenceDate, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE health_archive_schema_metadata SET schema_version = 6, schema_fingerprint = ? WHERE singleton = 1"
        )
        try update.bind(expectedSchemaFingerprint, at: 1)
        try update.expectDone()
      }
      let finalMetadata = try Self.metadata(from: database)
      guard finalMetadata.version == currentSchemaVersion,
        finalMetadata.fingerprint == expectedSchemaFingerprint
      else {
        throw HealthArchiveStoreError.corruptedSchema("Unexpected schema metadata")
      }
      try Self.verifySchema(database, definitions: currentDefinitions)
    }
  }

  private static func verifySchema(_ database: SQLiteDatabase, definitions: [String]) throws {
    let expectedBatchesSQL = definitions.contains(legacyBatchesSQL) ? legacyBatchesSQL : batchesSQL
    let expected =
      [
        ("table", "health_archive_schema_metadata", metadataSQL),
        ("table", "health_archive_schema_migrations", migrationsSQL),
        ("table", "health_archive_observations", observationsSQL),
        ("table", "health_archive_tombstones", tombstonesSQL),
        ("table", "health_archive_batches", expectedBatchesSQL),
        ("index", "health_archive_observations_query", observationsQueryIndexSQL),
      ]
      + (definitions.contains(observationsEndedAtIndexSQL)
        ? [("index", "health_archive_observations_ended_at", observationsEndedAtIndexSQL)] : [])
      + (definitions.contains(batchesReceivedAtIndexSQL)
        ? [("index", "health_archive_batches_received_at", batchesReceivedAtIndexSQL)] : [])
      + (definitions.contains(localSuppressionsSQL)
        ? [("table", "health_archive_local_suppressions", localSuppressionsSQL)] : [])
      + (definitions.contains(observationsSourceIndexSQL)
        ? [("index", "health_archive_observations_source", observationsSourceIndexSQL)] : [])
      + (definitions.contains(statisticsStateSQL)
        ? [
          ("table", "health_archive_statistics_state", statisticsStateSQL),
          ("table", "health_archive_kind_totals", kindTotalsSQL),
          ("table", "health_archive_source_totals", sourceTotalsSQL),
          ("table", "health_archive_daily_rollups", dailyRollupsSQL),
          ("table", "health_archive_rollup_states", rollupStatesSQL),
        ] : [])
      + (definitions.contains(metricDailyRollupsSQL)
        ? [
          ("table", "health_archive_metric_daily_rollups", metricDailyRollupsSQL),
          ("table", "health_archive_metric_rollup_states", metricRollupStatesSQL),
          ("index", "health_archive_metric_daily_query", metricDailyQueryIndexSQL),
        ] : [])
      + (definitions.contains(dailyRollupBuildStatesSQL)
        ? [("table", "health_archive_daily_rollup_build_states", dailyRollupBuildStatesSQL)] : [])
    guard try database.schemaObjectNames(withPrefix: "health_archive") == expected.map(\.1).sorted()
    else {
      throw HealthArchiveStoreError.corruptedSchema("Unexpected schema objects")
    }
    for (type, name, sql) in expected {
      guard let found = try database.schemaSQL(type: type, name: name),
        normalizedSQL(found) == normalizedSQL(sql)
      else {
        throw HealthArchiveStoreError.corruptedSchema("Unexpected schema object: \(name)")
      }
    }
  }

  private static func rebuildPersistentStatistics(in database: SQLiteDatabase) throws {
    try database.execute("DELETE FROM health_archive_kind_totals")
    try database.execute("DELETE FROM health_archive_source_totals")
    try database.execute(
      """
      INSERT INTO health_archive_kind_totals(kind, observation_count, latest_ended_at)
      SELECT kind, COUNT(*), MAX(ended_at)
      FROM health_archive_observations
      GROUP BY kind
      """)
    try database.execute(
      """
      INSERT INTO health_archive_source_totals(source_installation_id, observation_count)
      SELECT source_installation_id, COUNT(*)
      FROM health_archive_observations
      GROUP BY source_installation_id
      """)
    try database.execute(
      """
      UPDATE health_archive_statistics_state
      SET observation_count = (SELECT COUNT(*) FROM health_archive_observations),
          received_batch_count = (SELECT COUNT(*) FROM health_archive_batches),
          earliest_ended_at = (SELECT MIN(ended_at) FROM health_archive_observations),
          latest_ended_at = (SELECT MAX(ended_at) FROM health_archive_observations),
          latest_batch_received_at = (SELECT MAX(received_at) FROM health_archive_batches)
      WHERE singleton = 1
      """)
    let state = try statisticsState(in: database)
    try setRollupRevision(state.revision, for: statisticsRollupIdentifier, in: database)
  }

  private static func initializePersistentStatisticsPlaceholder(
    in database: SQLiteDatabase
  ) throws {
    try database.execute("DELETE FROM health_archive_statistics_state")
    try database.execute("DELETE FROM health_archive_kind_totals")
    try database.execute("DELETE FROM health_archive_source_totals")
    try database.execute(
      """
      INSERT INTO health_archive_statistics_state(
        singleton, archive_revision, observation_count, received_batch_count,
        earliest_ended_at, latest_ended_at, latest_batch_received_at
      )
      VALUES (
        1,
        CASE WHEN EXISTS(SELECT 1 FROM health_archive_observations)
                  OR EXISTS(SELECT 1 FROM health_archive_batches) THEN 1 ELSE 0 END,
        0, 0, NULL, NULL, NULL
      )
      """)
  }

  private static func metadata(from database: SQLiteDatabase) throws -> (
    version: Int, fingerprint: String
  ) {
    let statement = try database.prepare(
      "SELECT schema_version, schema_fingerprint FROM health_archive_schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow(),
      let version = Int(exactly: try statement.requiredInt64(at: 0, column: "schema_version"))
    else {
      throw HealthArchiveStoreError.corruptedSchema("Missing schema metadata")
    }
    let fingerprint = try statement.requiredText(at: 1, column: "schema_fingerprint")
    guard !(try statement.stepRow()) else {
      throw HealthArchiveStoreError.corruptedSchema("Duplicate schema metadata")
    }
    return (version, fingerprint)
  }

  private static func canonicalPayload<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    return string
  }

  private static func decode<T: Codable>(_ type: T.Type, payload: String) throws -> T {
    guard let data = payload.data(using: .utf8) else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    let value = try JSONDecoder().decode(type, from: data)
    guard try canonicalPayload(value) == payload else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    return value
  }

  static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }
  private static func normalizedSQL(_ sql: String) -> String {
    sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
  private static func fingerprint(of definitions: [String]) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in definitions.map(normalizedSQL).joined(separator: "\n").utf8 {
      value ^= UInt64(byte)
      value &*= 1_099_511_628_211
    }
    return String(format: "fnv1a64-%016llx", value)
  }
}
