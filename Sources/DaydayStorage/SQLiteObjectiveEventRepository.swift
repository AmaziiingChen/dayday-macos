import CSQLite
import DaydayCore
import Foundation

enum SQLiteDatabaseLocation: Sendable {
  case inMemory
  case file(URL)
}

public enum ObjectiveEventStoreError: Error, Equatable, Sendable {
  case invalidDateRange
  case invalidPageLimit
  case invalidFileURL
  case database(code: Int32, message: String)
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case corruptedSchema(String)
  case invalidStoredValue(column: String)
  case identifierConflict(EventID)
  case invalidApplicationIdentity
  case applicationIdentifierCollision
}

public actor SQLiteObjectiveEventRepository: ObjectiveLinkedRecordRepository,
  ObjectiveEventPageRepository, ObjectiveApplicationContextBatchFetching
{
  public static let currentSchemaVersion = 4

  private static let applicationMetadataSQL =
    "CREATE TABLE objective_application_catalog_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), salt_version INTEGER NOT NULL CHECK (salt_version = 1), installation_salt BLOB NOT NULL CHECK (length(installation_salt) = 32)) STRICT"
  private static let applicationCatalogSQL =
    "CREATE TABLE objective_application_catalog (application_id TEXT PRIMARY KEY NOT NULL, collision_guard BLOB NOT NULL CHECK (length(collision_guard) = 16), display_label TEXT NOT NULL, record_version INTEGER NOT NULL CHECK (record_version = 1)) STRICT"
  private static let applicationContextsSQL =
    """
    CREATE TABLE objective_application_contexts (
        event_id TEXT PRIMARY KEY NOT NULL REFERENCES objective_events(id) ON DELETE CASCADE,
        application_id TEXT NOT NULL REFERENCES objective_application_catalog(application_id),
        display_label_snapshot TEXT NOT NULL,
        window_title_snapshot TEXT,
        document_filename_hint TEXT,
        record_version INTEGER NOT NULL CHECK (record_version = 1)
    ) STRICT
    """
  private static let collectorStatesSQL =
    """
    CREATE TABLE objective_collector_states (
        event_id TEXT PRIMARY KEY NOT NULL REFERENCES objective_events(id) ON DELETE CASCADE,
        collector_kind TEXT NOT NULL CHECK (collector_kind IN ('screenUnderstanding', 'applicationWindowContext', 'chromeContext', 'keyboardAggregates', 'pointerAggregates', 'calendar', 'reminders', 'weather')),
        authorization TEXT NOT NULL CHECK (authorization IN ('notRequired', 'notDetermined', 'authorized', 'denied', 'restricted', 'revoked', 'insufficientAccess', 'unknown')),
        runtime_kind TEXT NOT NULL CHECK (runtime_kind IN ('unconfigured', 'waitingForAuthorization', 'running', 'paused', 'degraded', 'failed')),
        runtime_reason TEXT,
        resume_kind TEXT,
        resume_reason TEXT,
        record_version INTEGER NOT NULL CHECK (record_version = 1),
        CHECK (
            (runtime_kind IN ('unconfigured', 'waitingForAuthorization', 'running', 'paused') AND runtime_reason IS NULL)
            OR (runtime_kind = 'degraded' AND runtime_reason IS NOT NULL AND runtime_reason IN ('partialCapability', 'dependencyUnavailable', 'unsupportedEnvironment', 'resourcePressure'))
            OR (runtime_kind = 'failed' AND runtime_reason IS NOT NULL AND runtime_reason IN ('initializationFailed', 'serviceUnavailable', 'invariantViolated', 'unexpectedTermination'))
        ),
        CHECK (
            (runtime_kind != 'paused' AND resume_kind IS NULL AND resume_reason IS NULL)
            OR (runtime_kind = 'paused' AND resume_kind IS NOT NULL AND (
                (resume_kind IN ('waitingForAuthorization', 'running') AND resume_reason IS NULL)
                OR (resume_kind = 'degraded' AND resume_reason IS NOT NULL AND resume_reason IN ('partialCapability', 'dependencyUnavailable', 'unsupportedEnvironment', 'resourcePressure'))
                OR (resume_kind = 'failed' AND resume_reason IS NOT NULL AND resume_reason IN ('initializationFailed', 'serviceUnavailable', 'invariantViolated', 'unexpectedTermination'))
            ))
        ),
        CHECK (
            runtime_kind IN ('unconfigured', 'failed')
            OR (runtime_kind = 'waitingForAuthorization' AND authorization NOT IN ('notRequired', 'authorized'))
            OR (runtime_kind IN ('running', 'degraded') AND authorization IN ('notRequired', 'authorized'))
            OR (runtime_kind = 'paused' AND (
                (authorization IN ('notRequired', 'authorized') AND resume_kind != 'waitingForAuthorization')
                OR (authorization NOT IN ('notRequired', 'authorized') AND resume_kind IN ('waitingForAuthorization', 'failed'))
            ))
        )
    ) STRICT
    """
  private static let collectorPauseReasonsSQL =
    """
    CREATE TABLE objective_collector_pause_reasons (
        event_id TEXT NOT NULL REFERENCES objective_collector_states(event_id) ON DELETE CASCADE,
        reason TEXT NOT NULL CHECK (reason IN ('globalUserPause', 'userSessionInactive', 'screensAsleep', 'screenLocked', 'systemSleep', 'secureInput', 'privacyExclusion')),
        PRIMARY KEY (event_id, reason)
    ) WITHOUT ROWID, STRICT
    """
  private static let applicationContextOwnershipTriggerSQL =
    """
    CREATE TRIGGER objective_application_contexts_exclusive_projection
    BEFORE INSERT ON objective_application_contexts
    WHEN EXISTS (
        SELECT 1 FROM objective_collector_states WHERE event_id = NEW.event_id
    )
    BEGIN
        SELECT RAISE(ABORT, 'objective event already owns collector-state projection');
    END
    """
  private static let collectorStateOwnershipTriggerSQL =
    """
    CREATE TRIGGER objective_collector_states_exclusive_projection
    BEFORE INSERT ON objective_collector_states
    WHEN EXISTS (
        SELECT 1 FROM objective_application_contexts WHERE event_id = NEW.event_id
    )
    BEGIN
        SELECT RAISE(ABORT, 'objective event already owns application-context projection');
    END
    """
  private static let collectionSuppressionsSQL =
    """
    CREATE TABLE objective_collection_suppressions (
        event_id TEXT PRIMARY KEY NOT NULL REFERENCES objective_events(id) ON DELETE CASCADE,
        reason TEXT NOT NULL CHECK (reason IN ('globalPause', 'screenLocked', 'systemSleep', 'secureInput', 'incognito', 'authenticationContext', 'passwordManager', 'userExclusion', 'mandatoryExclusion', 'authorizationUnavailable', 'uncertainSafetyState')),
        record_version INTEGER NOT NULL CHECK (record_version = 1)
    ) STRICT
    """
  private static let applicationContextSuppressionOwnershipTriggerSQL =
    """
    CREATE TRIGGER objective_application_contexts_exclusive_suppression
    BEFORE INSERT ON objective_application_contexts
    WHEN EXISTS (
        SELECT 1 FROM objective_collection_suppressions WHERE event_id = NEW.event_id
    )
    BEGIN
        SELECT RAISE(ABORT, 'objective event already owns collection-suppression projection');
    END
    """
  private static let collectorStateSuppressionOwnershipTriggerSQL =
    """
    CREATE TRIGGER objective_collector_states_exclusive_suppression
    BEFORE INSERT ON objective_collector_states
    WHEN EXISTS (
        SELECT 1 FROM objective_collection_suppressions WHERE event_id = NEW.event_id
    )
    BEGIN
        SELECT RAISE(ABORT, 'objective event already owns collection-suppression projection');
    END
    """
  private static let collectionSuppressionOwnershipTriggerSQL =
    """
    CREATE TRIGGER objective_collection_suppressions_exclusive_projection
    BEFORE INSERT ON objective_collection_suppressions
    WHEN EXISTS (
        SELECT 1 FROM objective_application_contexts WHERE event_id = NEW.event_id
    ) OR EXISTS (
        SELECT 1 FROM objective_collector_states WHERE event_id = NEW.event_id
    )
    BEGIN
        SELECT RAISE(ABORT, 'objective event already owns another typed projection');
    END
    """

  private static let schemaMetadataSQL =
    """
    CREATE TABLE schema_metadata (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        schema_version INTEGER NOT NULL
    ) STRICT
    """
  private static let schemaMigrationsSQL =
    """
    CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at REAL NOT NULL
    ) STRICT
    """
  private static let objectiveEventsSQL =
    """
    CREATE TABLE objective_events (
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        occurred_at REAL NOT NULL,
        ended_at REAL,
        time_zone_identifier TEXT NOT NULL,
        collector_kind TEXT NOT NULL,
        collector_version TEXT NOT NULL,
        payload_schema_version INTEGER NOT NULL,
        display_id TEXT,
        topology_revision TEXT,
        security_disposition TEXT NOT NULL,
        suppression_reason TEXT,
        CHECK ((display_id IS NULL) = (topology_revision IS NULL)),
        CHECK (
            (security_disposition = 'allowed' AND suppression_reason IS NULL)
            OR
            (security_disposition != 'allowed' AND suppression_reason IS NOT NULL)
        )
    ) STRICT
    """
  private static let objectiveEventsIndexSQL =
    "CREATE INDEX objective_events_occurred_at ON objective_events(occurred_at, id)"

  private let database: SQLiteDatabase

  init(location: SQLiteDatabaseLocation) throws {
    let database = try SQLiteDatabase(location: location)
    do {
      try Self.migrate(database)
    } catch {
      database.close()
      throw error
    }
    self.database = database
  }

  public func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult {
    guard event.kind != .applicationContextChanged, event.kind != .collectorStateTransition,
      event.securityDisposition == .allowed
    else {
      throw ObjectiveEventStoreError.identifierConflict(event.id)
    }
    return try database.transaction { () -> ObjectiveEventInsertResult in
      let statement = try database.prepare(
        """
        INSERT OR IGNORE INTO objective_events (
            id, kind, occurred_at, ended_at, time_zone_identifier,
            collector_kind, collector_version, payload_schema_version,
            display_id, topology_revision,
            security_disposition, suppression_reason
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
      )
      try Self.bind(event, to: statement)
      try statement.expectDone()

      if database.changedRowCount == 1 {
        return .inserted
      }

      guard let stored = try Self.fetch(id: event.id, from: database) else {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Unique insert was ignored without an existing event"
        )
      }
      guard stored == event else {
        throw ObjectiveEventStoreError.identifierConflict(event.id)
      }
      return .alreadyPresent
    }
  }

  public func insertApplicationContext(_ write: ApplicationContextWrite) async throws
    -> ObjectiveEventInsertResult
  {
    return try database.transaction { () -> ObjectiveEventInsertResult in
      let occupancy = try Self.projectionOccupancy(eventID: write.event.id, from: database)
      try Self.rejectMultipleProjections(occupancy)
      let storedEvent = try Self.fetch(id: write.event.id, from: database)
      let storedRecord = try Self.fetchApplicationContextRecord(
        eventID: write.event.id, from: database)
      if storedEvent == nil,
        occupancy.applicationContext || occupancy.collectorState || occupancy.collectionSuppression
      {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Linked projection exists without its objective event")
      }
      switch (storedEvent, storedRecord) {
      case (nil, nil):
        try Self.insertEventRow(write.event, into: database)
        try Self.insertApplicationContextRow(write.record, into: database)
        return .inserted
      case (let event?, let record?) where event == write.event && record == write.record:
        return .alreadyPresent
      case (nil, _?):
        throw ObjectiveEventStoreError.corruptedSchema(
          "Application-context projection exists without its event")
      default:
        throw ObjectiveEventStoreError.identifierConflict(write.event.id)
      }
    }
  }

  public func insertCollectorState(_ write: CollectorStateWrite) async throws
    -> ObjectiveEventInsertResult
  {
    return try database.transaction { () -> ObjectiveEventInsertResult in
      let occupancy = try Self.projectionOccupancy(eventID: write.event.id, from: database)
      try Self.rejectMultipleProjections(occupancy)
      let storedEvent = try Self.fetch(id: write.event.id, from: database)
      let storedRecord = try Self.fetchCollectorStateRecord(eventID: write.event.id, from: database)
      if storedEvent == nil,
        occupancy.applicationContext || occupancy.collectorState || occupancy.collectionSuppression
      {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Linked projection exists without its objective event")
      }
      switch (storedEvent, storedRecord) {
      case (nil, nil):
        try Self.insertEventRow(write.event, into: database)
        try Self.insertCollectorStateRow(write.record, into: database)
        return .inserted
      case (let event?, let record?) where event == write.event && record == write.record:
        return .alreadyPresent
      case (nil, _?):
        throw ObjectiveEventStoreError.corruptedSchema(
          "Collector-state projection exists without its event")
      default:
        throw ObjectiveEventStoreError.identifierConflict(write.event.id)
      }
    }
  }

  public func insertCollectionSuppression(_ write: CollectionSuppressionWrite) async throws
    -> ObjectiveEventInsertResult
  {
    return try database.transaction { () -> ObjectiveEventInsertResult in
      let occupancy = try Self.projectionOccupancy(eventID: write.event.id, from: database)
      try Self.rejectMultipleProjections(occupancy)
      let storedEvent = try Self.fetch(id: write.event.id, from: database)
      let storedRecord = try Self.fetchCollectionSuppressionRecord(
        eventID: write.event.id, from: database)
      if storedEvent == nil,
        occupancy.applicationContext || occupancy.collectorState || occupancy.collectionSuppression
      {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Linked projection exists without its objective event")
      }
      switch (storedEvent, storedRecord) {
      case (nil, nil):
        try Self.insertEventRow(write.event, into: database)
        try Self.insertCollectionSuppressionRow(write.record, into: database)
        return .inserted
      case (let event?, let record?) where event == write.event && record == write.record:
        return .alreadyPresent
      case (nil, _?):
        throw ObjectiveEventStoreError.corruptedSchema(
          "Collection-suppression projection exists without its event")
      default:
        throw ObjectiveEventStoreError.identifierConflict(write.event.id)
      }
    }
  }

  public func fetchApplicationContext(for eventID: EventID) async throws
    -> ApplicationContextRecord?
  {
    let occupancy = try Self.projectionOccupancy(eventID: eventID, from: database)
    try Self.rejectMultipleProjections(occupancy)
    guard let record = try Self.fetchApplicationContextRecord(eventID: eventID, from: database)
    else { return nil }
    guard let event = try Self.fetch(id: eventID, from: database),
      event.kind == .applicationContextChanged,
      event.source.collector == .applicationWindowContext,
      event.securityDisposition == .allowed
    else {
      throw ObjectiveEventStoreError.corruptedSchema(
        "Application-context projection has an invalid event link")
    }
    return record
  }

  /// Fetches linked application projections in bounded SQL batches. Insights
  /// commonly needs hundreds of context changes for a day; issuing one actor
  /// hop and one prepared statement per event makes opening the native view
  /// visibly stall even though SQLite already has the complete local index.
  public func fetchApplicationContexts(for eventIDs: [EventID]) async throws
    -> [EventID: ApplicationContextRecord]
  {
    let uniqueIDs = Array(Set(eventIDs))
    guard !uniqueIDs.isEmpty else { return [:] }

    var records: [EventID: ApplicationContextRecord] = [:]
    records.reserveCapacity(uniqueIDs.count)
    for offset in stride(from: 0, to: uniqueIDs.count, by: 500) {
      let batch = Array(uniqueIDs[offset..<min(offset + 500, uniqueIDs.count)])
      let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
      let statement = try database.prepare(
        """
        SELECT context.event_id, context.application_id,
            context.display_label_snapshot, context.window_title_snapshot,
            context.document_filename_hint, context.record_version,
            event.kind, event.collector_kind, event.security_disposition,
            EXISTS(
              SELECT 1 FROM objective_application_catalog catalog
              WHERE catalog.application_id = context.application_id
            ) AS catalog_exists,
            EXISTS(
              SELECT 1 FROM objective_collector_states collector
              WHERE collector.event_id = context.event_id
            ) AS collector_state_exists,
            EXISTS(
              SELECT 1 FROM objective_collection_suppressions suppression
              WHERE suppression.event_id = context.event_id
            ) AS suppression_exists
        FROM objective_application_contexts context
        JOIN objective_events event ON event.id = context.event_id
        WHERE context.event_id IN (\(placeholders))
        """
      )
      for (index, eventID) in batch.enumerated() {
        try statement.bind(
          eventID.rawValue.uuidString.lowercased(),
          at: Int32(index + 1)
        )
      }
      let expected = Set(batch)
      while try statement.stepRow() {
        do {
          let eventID = EventID(
            rawValue: try Self.decodeUUID(statement, at: 0, column: "event_id")
          )
          guard expected.contains(eventID),
                try statement.requiredText(at: 6, column: "kind")
                  == ObjectiveEventKind.applicationContextChanged.rawValue,
                try statement.requiredText(at: 7, column: "collector_kind")
                  == CollectorKind.applicationWindowContext.rawValue,
                try statement.requiredText(at: 8, column: "security_disposition")
                  == "allowed",
                try statement.requiredInt64(at: 9, column: "catalog_exists") == 1,
                try statement.requiredInt64(at: 10, column: "collector_state_exists") == 0,
                try statement.requiredInt64(at: 11, column: "suppression_exists") == 0
          else {
            throw ObjectiveEventStoreError.corruptedSchema(
              "Application-context projection has an invalid event link"
            )
          }
          let record = try ApplicationContextRecord(
            eventID: eventID,
            applicationIdentifier: ApplicationIdentifier(
              rawValue: try Self.decodeUUID(
                statement, at: 1, column: "application_id"
              )
            ),
            displayLabelSnapshot: statement.requiredText(
              at: 2, column: "display_label_snapshot"
            ),
            windowTitleSnapshot: try Self.optionalText(
              statement, at: 3, column: "window_title_snapshot"
            ),
            documentFilenameHint: try Self.optionalText(
              statement, at: 4, column: "document_filename_hint"
            ),
            recordVersion: Int(
              statement.requiredInt64(at: 5, column: "record_version")
            )
          )
          records[eventID] = record
        } catch let error as ObjectiveEventStoreError {
          throw error
        } catch {
          throw ObjectiveEventStoreError.invalidStoredValue(
            column: "application_context"
          )
        }
      }
    }
    return records
  }

  public func fetchCollectorState(for eventID: EventID) async throws -> CollectorStateRecord? {
    let occupancy = try Self.projectionOccupancy(eventID: eventID, from: database)
    try Self.rejectMultipleProjections(occupancy)
    guard let record = try Self.fetchCollectorStateRecord(eventID: eventID, from: database)
    else { return nil }
    guard let event = try Self.fetch(id: eventID, from: database),
      event.kind == .collectorStateTransition,
      event.source.collector == record.state.kind
    else {
      throw ObjectiveEventStoreError.corruptedSchema(
        "Collector-state projection has an invalid event link")
    }
    return record
  }

  public func fetchCollectionSuppression(for eventID: EventID) async throws
    -> CollectionSuppressionRecord?
  {
    let occupancy = try Self.projectionOccupancy(eventID: eventID, from: database)
    try Self.rejectMultipleProjections(occupancy)
    guard
      let record = try Self.fetchCollectionSuppressionRecord(
        eventID: eventID, from: database)
    else { return nil }
    guard let event = try Self.fetch(id: eventID, from: database) else {
      throw ObjectiveEventStoreError.corruptedSchema(
        "Collection-suppression projection has an invalid event link")
    }
    do {
      _ = try CollectionSuppressionWrite(event: event, record: record)
    } catch {
      throw ObjectiveEventStoreError.corruptedSchema(
        "Collection-suppression projection has an invalid event link")
    }
    return record
  }

  public func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] {
    let lower = range.lowerBound.timeIntervalSinceReferenceDate
    let upper = range.upperBound.timeIntervalSinceReferenceDate
    guard lower.isFinite, upper.isFinite, lower < upper else {
      throw ObjectiveEventStoreError.invalidDateRange
    }

    let statement = try database.prepare(
      """
      SELECT
          id, kind, occurred_at, ended_at, time_zone_identifier,
          collector_kind, collector_version, payload_schema_version,
          display_id, topology_revision,
          security_disposition, suppression_reason
      FROM objective_events
      WHERE occurred_at >= ? AND occurred_at < ?
      ORDER BY occurred_at ASC, id ASC
      """
    )
    try statement.bind(lower, at: 1)
    try statement.bind(upper, at: 2)

    var events: [ObjectiveEvent] = []
    while try statement.stepRow() {
      events.append(try Self.decodeEvent(from: statement))
    }
    return events
  }

  public func fetchPage(
    occurredIn range: Range<Date>,
    before cursor: ObjectiveEventPageCursor?,
    limit: Int
  ) async throws -> ObjectiveEventPage {
    let lower = range.lowerBound.timeIntervalSinceReferenceDate
    let upper = range.upperBound.timeIntervalSinceReferenceDate
    guard lower.isFinite, upper.isFinite, lower < upper else {
      throw ObjectiveEventStoreError.invalidDateRange
    }
    guard limit > 0, limit < Int(Int64.max) else {
      throw ObjectiveEventStoreError.invalidPageLimit
    }

    let cursorClause: String
    if cursor == nil {
      cursorClause = ""
    } else {
      cursorClause = "AND (occurred_at < ? OR (occurred_at = ? AND id < ?))"
    }
    let statement = try database.prepare(
      """
      SELECT
          id, kind, occurred_at, ended_at, time_zone_identifier,
          collector_kind, collector_version, payload_schema_version,
          display_id, topology_revision,
          security_disposition, suppression_reason
      FROM objective_events
      WHERE occurred_at >= ? AND occurred_at < ?
      \(cursorClause)
      ORDER BY occurred_at DESC, id DESC
      LIMIT ?
      """
    )
    try statement.bind(lower, at: 1)
    try statement.bind(upper, at: 2)
    var bindingIndex: Int32 = 3
    if let cursor {
      let occurredAt = cursor.occurredAt.timeIntervalSinceReferenceDate
      guard occurredAt.isFinite else { throw ObjectiveEventStoreError.invalidDateRange }
      try statement.bind(occurredAt, at: bindingIndex)
      bindingIndex += 1
      try statement.bind(occurredAt, at: bindingIndex)
      bindingIndex += 1
      try statement.bind(cursor.eventID.rawValue.uuidString.lowercased(), at: bindingIndex)
      bindingIndex += 1
    }
    try statement.bind(Int64(limit) + 1, at: bindingIndex)

    var values: [ObjectiveEvent] = []
    while try statement.stepRow() {
      values.append(try Self.decodeEvent(from: statement))
    }
    let hasMore = values.count > limit
    if hasMore { values.removeLast() }
    let nextCursor = hasMore
      ? values.last.map { ObjectiveEventPageCursor(occurredAt: $0.occurredAt, eventID: $0.id) }
      : nil
    return ObjectiveEventPage(events: values, nextCursor: nextCursor)
  }

  public func schemaVersion() throws -> Int {
    try Self.readSchemaVersion(database)
  }

  /// Accepts a raw bundle identifier only ephemerally; it is never stored.
  public func resolveApplication(bundleIdentifier: String, displayLabel: String) throws
    -> ApplicationCatalogEntry
  {
    try database.transaction {
      let normalized = try ApplicationIdentityCatalog.normalizedBundleIdentifier(bundleIdentifier)
      let salt = try Self.applicationSalt(database)
      let derived = try ApplicationIdentityCatalog.derive(normalized: normalized, salt: salt)
      let entry = try ApplicationCatalogEntry(
        identifier: derived.identifier, displayLabel: displayLabel)
      let statement = try database.prepare(
        "INSERT OR IGNORE INTO objective_application_catalog(application_id, collision_guard, display_label, record_version) VALUES (?, ?, ?, 1)"
      )
      try statement.bind(derived.identifier.rawValue.uuidString.lowercased(), at: 1)
      try statement.bind(derived.collisionGuard, at: 2)
      try statement.bind(displayLabel, at: 3)
      try statement.expectDone()
      if database.changedRowCount == 0 {
        let existing = try database.prepare(
          "SELECT collision_guard FROM objective_application_catalog WHERE application_id=?")
        try existing.bind(derived.identifier.rawValue.uuidString.lowercased(), at: 1)
        guard try existing.stepRow(),
          try existing.requiredData(at: 0, column: "collision_guard") == derived.collisionGuard
        else { throw ObjectiveEventStoreError.applicationIdentifierCollision }
        let update = try database.prepare(
          "UPDATE objective_application_catalog SET display_label=? WHERE application_id=?")
        try update.bind(displayLabel, at: 1)
        try update.bind(derived.identifier.rawValue.uuidString.lowercased(), at: 2)
        try update.expectDone()
      }
      return entry
    }
  }

  public func applicationCatalogEntry(for identifier: ApplicationIdentifier) throws
    -> ApplicationCatalogEntry?
  {
    let statement = try database.prepare(
      "SELECT display_label, record_version FROM objective_application_catalog WHERE application_id=?"
    )
    try statement.bind(identifier.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    return try ApplicationCatalogEntry(
      identifier: identifier, displayLabel: statement.requiredText(at: 0, column: "display_label"),
      recordVersion: Int(statement.requiredInt64(at: 1, column: "record_version")))
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      // The write transaction serializes first-open probing and migration
      // across processes/connections. Every contender rechecks after it
      // acquires the lock instead of acting on a stale empty observation.
      let metadataExists = try database.tableExists("schema_metadata")
      let migrationsExists = try database.tableExists("schema_migrations")

      guard metadataExists == migrationsExists else {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Schema metadata and migration journal must exist together"
        )
      }

      if !metadataExists {
        try applyMigration1(database)
      }

      var version = try readSchemaVersion(database)
      guard version <= currentSchemaVersion else {
        throw ObjectiveEventStoreError.unsupportedSchemaVersion(
          found: version,
          supported: currentSchemaVersion
        )
      }
      guard version >= 1 else {
        throw ObjectiveEventStoreError.corruptedSchema("Invalid schema version")
      }
      try validateSchema1(database)
      try validateMigrationJournal(database, expectedVersion: version)

      if version == 1 {
        try applyMigration2(database)
        version = 2
      }
      try validateSchema2(database)
      if version == 2 {
        try applyMigration3(database)
        version = 3
      }
      try validateSchema3(database)
      if version == 3 {
        try applyMigration4(database)
        version = 4
      }
      guard version == currentSchemaVersion else {
        throw ObjectiveEventStoreError.corruptedSchema("Missing registered migration")
      }
      try validateSchema4(database)
      try validateMigrationJournal(database, expectedVersion: currentSchemaVersion)
    }
  }

  private static func applyMigration1(_ database: SQLiteDatabase) throws {
    try database.execute(schemaMetadataSQL)
    try database.execute(schemaMigrationsSQL)
    try database.execute(objectiveEventsSQL)
    try database.execute(objectiveEventsIndexSQL)

    let now = Date().timeIntervalSince1970
    let migration = try database.prepare(
      "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)"
    )
    try migration.bind(Int64(1), at: 1)
    try migration.bind(now, at: 2)
    try migration.expectDone()

    let metadata = try database.prepare(
      "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, ?)"
    )
    try metadata.bind(Int64(1), at: 1)
    try metadata.expectDone()
  }

  private static func applyMigration2(_ database: SQLiteDatabase) throws {
    try database.execute(applicationMetadataSQL)
    try database.execute(applicationCatalogSQL)
    let salt = try ApplicationIdentityCatalog.newSalt()
    let metadata = try database.prepare(
      "INSERT INTO objective_application_catalog_metadata(singleton, salt_version, installation_salt) VALUES (1, 1, ?)"
    )
    try metadata.bind(salt, at: 1)
    try metadata.expectDone()
    let migration = try database.prepare(
      "INSERT INTO schema_migrations(version, applied_at) VALUES (2, ?)")
    try migration.bind(Date().timeIntervalSince1970, at: 1)
    try migration.expectDone()
    let version = try database.prepare(
      "UPDATE schema_metadata SET schema_version=2 WHERE singleton=1")
    try version.expectDone()
  }

  private static func validateSchema2(_ database: SQLiteDatabase) throws {
    guard
      let metadata = try database.schemaSQL(
        type: "table", name: "objective_application_catalog_metadata"),
      let catalog = try database.schemaSQL(type: "table", name: "objective_application_catalog"),
      normalizedSQL(metadata) == normalizedSQL(applicationMetadataSQL),
      normalizedSQL(catalog) == normalizedSQL(applicationCatalogSQL)
    else {
      throw ObjectiveEventStoreError.corruptedSchema("application catalog schema")
    }
    _ = try applicationSalt(database)
  }

  private static func applyMigration3(_ database: SQLiteDatabase) throws {
    try database.execute(applicationContextsSQL)
    try database.execute(collectorStatesSQL)
    try database.execute(collectorPauseReasonsSQL)
    try database.execute(applicationContextOwnershipTriggerSQL)
    try database.execute(collectorStateOwnershipTriggerSQL)
    let migration = try database.prepare(
      "INSERT INTO schema_migrations(version, applied_at) VALUES (3, ?)")
    try migration.bind(Date().timeIntervalSince1970, at: 1)
    try migration.expectDone()
    let version = try database.prepare(
      "UPDATE schema_metadata SET schema_version=3 WHERE singleton=1")
    try version.expectDone()
  }

  private static func validateSchema3(_ database: SQLiteDatabase) throws {
    let objects = [
      (type: "table", name: "objective_application_contexts", sql: applicationContextsSQL),
      (type: "table", name: "objective_collector_states", sql: collectorStatesSQL),
      (type: "table", name: "objective_collector_pause_reasons", sql: collectorPauseReasonsSQL),
      (
        type: "trigger", name: "objective_application_contexts_exclusive_projection",
        sql: applicationContextOwnershipTriggerSQL
      ),
      (
        type: "trigger", name: "objective_collector_states_exclusive_projection",
        sql: collectorStateOwnershipTriggerSQL
      ),
    ]
    for object in objects {
      guard let actual = try database.schemaSQL(type: object.type, name: object.name),
        normalizedSQL(actual) == normalizedSQL(object.sql)
      else {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Unexpected schema object definition: \(object.name)")
      }
    }
  }

  private static func applyMigration4(_ database: SQLiteDatabase) throws {
    try database.execute(collectionSuppressionsSQL)
    try database.execute(applicationContextSuppressionOwnershipTriggerSQL)
    try database.execute(collectorStateSuppressionOwnershipTriggerSQL)
    try database.execute(collectionSuppressionOwnershipTriggerSQL)
    let migration = try database.prepare(
      "INSERT INTO schema_migrations(version, applied_at) VALUES (4, ?)")
    try migration.bind(Date().timeIntervalSince1970, at: 1)
    try migration.expectDone()
    let version = try database.prepare(
      "UPDATE schema_metadata SET schema_version=4 WHERE singleton=1")
    try version.expectDone()
  }

  private static func validateSchema4(_ database: SQLiteDatabase) throws {
    let objects = [
      (
        type: "table", name: "objective_collection_suppressions",
        sql: collectionSuppressionsSQL
      ),
      (
        type: "trigger", name: "objective_application_contexts_exclusive_suppression",
        sql: applicationContextSuppressionOwnershipTriggerSQL
      ),
      (
        type: "trigger", name: "objective_collector_states_exclusive_suppression",
        sql: collectorStateSuppressionOwnershipTriggerSQL
      ),
      (
        type: "trigger", name: "objective_collection_suppressions_exclusive_projection",
        sql: collectionSuppressionOwnershipTriggerSQL
      ),
    ]
    for object in objects {
      guard let actual = try database.schemaSQL(type: object.type, name: object.name),
        normalizedSQL(actual) == normalizedSQL(object.sql)
      else {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Unexpected schema object definition: \(object.name)")
      }
    }
  }

  private static func applicationSalt(_ database: SQLiteDatabase) throws -> Data {
    let statement = try database.prepare(
      "SELECT salt_version, installation_salt FROM objective_application_catalog_metadata WHERE singleton=1"
    )
    guard try statement.stepRow(), try statement.requiredInt64(at: 0, column: "salt_version") == 1
    else { throw ObjectiveEventStoreError.corruptedSchema("application identity metadata") }
    let salt = try statement.requiredData(at: 1, column: "installation_salt")
    guard !(try statement.stepRow()), salt.count == 32 else {
      throw ObjectiveEventStoreError.corruptedSchema("application identity metadata")
    }
    return salt
  }

  private static func readSchemaVersion(_ database: SQLiteDatabase) throws -> Int {
    let statement = try database.prepare(
      "SELECT schema_version FROM schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow() else {
      throw ObjectiveEventStoreError.corruptedSchema("Missing schema version row")
    }
    let version = try statement.requiredInt64(at: 0, column: "schema_version")
    guard !((try statement.stepRow())), let exact = Int(exactly: version) else {
      throw ObjectiveEventStoreError.corruptedSchema("Invalid schema version rows")
    }
    return exact
  }

  private static func validateMigrationJournal(
    _ database: SQLiteDatabase,
    expectedVersion: Int
  ) throws {
    let statement = try database.prepare(
      "SELECT version FROM schema_migrations ORDER BY version ASC"
    )
    var expected = 1
    while try statement.stepRow() {
      let version = try statement.requiredInt64(at: 0, column: "version")
      guard version == expected else {
        throw ObjectiveEventStoreError.corruptedSchema("Non-contiguous migration journal")
      }
      expected += 1
    }
    guard expected - 1 == expectedVersion else {
      throw ObjectiveEventStoreError.corruptedSchema("Schema version and journal disagree")
    }
  }

  private static func validateSchema1(_ database: SQLiteDatabase) throws {
    let objects = [
      (type: "table", name: "schema_metadata", sql: schemaMetadataSQL),
      (type: "table", name: "schema_migrations", sql: schemaMigrationsSQL),
      (type: "table", name: "objective_events", sql: objectiveEventsSQL),
      (type: "index", name: "objective_events_occurred_at", sql: objectiveEventsIndexSQL),
    ]

    for object in objects {
      guard let actual = try database.schemaSQL(type: object.type, name: object.name) else {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Missing schema object: \(object.name)"
        )
      }
      guard normalizedSQL(actual) == normalizedSQL(object.sql) else {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Unexpected schema object definition: \(object.name)"
        )
      }
    }
  }

  private static func normalizedSQL(_ sql: String) -> String {
    sql.split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
  }

  private static func projectionOccupancy(
    eventID: EventID,
    from database: SQLiteDatabase
  ) throws -> (applicationContext: Bool, collectorState: Bool, collectionSuppression: Bool) {
    let statement = try database.prepare(
      """
      SELECT
          EXISTS(SELECT 1 FROM objective_application_contexts WHERE event_id = ?),
          EXISTS(SELECT 1 FROM objective_collector_states WHERE event_id = ?),
          EXISTS(SELECT 1 FROM objective_collection_suppressions WHERE event_id = ?)
      """
    )
    let id = eventID.rawValue.uuidString.lowercased()
    try statement.bind(id, at: 1)
    try statement.bind(id, at: 2)
    try statement.bind(id, at: 3)
    guard try statement.stepRow() else {
      throw ObjectiveEventStoreError.corruptedSchema("Unable to inspect linked projections")
    }
    let applicationContext = try statement.requiredInt64(
      at: 0, column: "application_context_exists")
    let collectorState = try statement.requiredInt64(at: 1, column: "collector_state_exists")
    let collectionSuppression = try statement.requiredInt64(
      at: 2, column: "collection_suppression_exists")
    guard applicationContext == 0 || applicationContext == 1,
      collectorState == 0 || collectorState == 1,
      collectionSuppression == 0 || collectionSuppression == 1
    else {
      throw ObjectiveEventStoreError.corruptedSchema("Invalid linked projection occupancy")
    }
    return (
      applicationContext == 1,
      collectorState == 1,
      collectionSuppression == 1
    )
  }

  private static func rejectMultipleProjections(
    _ occupancy: (
      applicationContext: Bool, collectorState: Bool, collectionSuppression: Bool
    )
  ) throws {
    let projectionCount = [
      occupancy.applicationContext,
      occupancy.collectorState,
      occupancy.collectionSuppression,
    ].count(where: { $0 })
    guard projectionCount <= 1 else {
      throw ObjectiveEventStoreError.corruptedSchema(
        "Objective event has multiple typed projections")
    }
  }

  private static func insertEventRow(_ event: ObjectiveEvent, into database: SQLiteDatabase) throws
  {
    let statement = try database.prepare(
      """
      INSERT INTO objective_events (
          id, kind, occurred_at, ended_at, time_zone_identifier,
          collector_kind, collector_version, payload_schema_version,
          display_id, topology_revision,
          security_disposition, suppression_reason
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    )
    try bind(event, to: statement)
    try statement.expectDone()
  }

  private static func insertApplicationContextRow(
    _ record: ApplicationContextRecord,
    into database: SQLiteDatabase
  ) throws {
    let statement = try database.prepare(
      """
      INSERT INTO objective_application_contexts (
          event_id, application_id, display_label_snapshot,
          window_title_snapshot, document_filename_hint, record_version
      ) VALUES (?, ?, ?, ?, ?, ?)
      """
    )
    try statement.bind(record.eventID.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(record.applicationIdentifier.rawValue.uuidString.lowercased(), at: 2)
    try statement.bind(record.displayLabelSnapshot, at: 3)
    try bind(record.windowTitleSnapshot, to: statement, at: 4)
    try bind(record.documentFilenameHint, to: statement, at: 5)
    guard let recordVersion = Int64(exactly: record.recordVersion) else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "record_version")
    }
    try statement.bind(recordVersion, at: 6)
    try statement.expectDone()
  }

  private static func insertCollectorStateRow(
    _ record: CollectorStateRecord,
    into database: SQLiteDatabase
  ) throws {
    let encoded = encode(record.state.runtime)
    let statement = try database.prepare(
      """
      INSERT INTO objective_collector_states (
          event_id, collector_kind, authorization,
          runtime_kind, runtime_reason, resume_kind, resume_reason, record_version
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """
    )
    try statement.bind(record.eventID.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(record.state.kind.rawValue, at: 2)
    try statement.bind(record.state.authorization.rawValue, at: 3)
    try statement.bind(encoded.runtimeKind, at: 4)
    try bind(encoded.runtimeReason, to: statement, at: 5)
    try bind(encoded.resumeKind, to: statement, at: 6)
    try bind(encoded.resumeReason, to: statement, at: 7)
    guard let recordVersion = Int64(exactly: record.recordVersion) else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "record_version")
    }
    try statement.bind(recordVersion, at: 8)
    try statement.expectDone()

    for reason in encoded.pauseReasons.sorted(by: { $0.rawValue < $1.rawValue }) {
      let pause = try database.prepare(
        "INSERT INTO objective_collector_pause_reasons(event_id, reason) VALUES (?, ?)")
      try pause.bind(record.eventID.rawValue.uuidString.lowercased(), at: 1)
      try pause.bind(reason.rawValue, at: 2)
      try pause.expectDone()
    }
  }

  private static func insertCollectionSuppressionRow(
    _ record: CollectionSuppressionRecord,
    into database: SQLiteDatabase
  ) throws {
    let statement = try database.prepare(
      """
      INSERT INTO objective_collection_suppressions (
          event_id, reason, record_version
      ) VALUES (?, ?, ?)
      """
    )
    try statement.bind(record.eventID.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(record.reason.rawValue, at: 2)
    guard let recordVersion = Int64(exactly: record.recordVersion) else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "record_version")
    }
    try statement.bind(recordVersion, at: 3)
    try statement.expectDone()
  }

  private static func fetchApplicationContextRecord(
    eventID: EventID,
    from database: SQLiteDatabase
  ) throws -> ApplicationContextRecord? {
    let statement = try database.prepare(
      """
      SELECT event_id, application_id, display_label_snapshot,
          window_title_snapshot, document_filename_hint, record_version
      FROM objective_application_contexts WHERE event_id = ?
      """
    )
    try statement.bind(eventID.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    do {
      let storedEventID = EventID(rawValue: try decodeUUID(statement, at: 0, column: "event_id"))
      let applicationID = ApplicationIdentifier(
        rawValue: try decodeUUID(statement, at: 1, column: "application_id"))
      let catalog = try database.prepare(
        "SELECT 1 FROM objective_application_catalog WHERE application_id = ?")
      try catalog.bind(applicationID.rawValue.uuidString.lowercased(), at: 1)
      guard try catalog.stepRow() else {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Application-context projection has no catalog identity")
      }
      let record = try ApplicationContextRecord(
        eventID: storedEventID,
        applicationIdentifier: applicationID,
        displayLabelSnapshot: statement.requiredText(at: 2, column: "display_label_snapshot"),
        windowTitleSnapshot: try optionalText(
          statement, at: 3, column: "window_title_snapshot"),
        documentFilenameHint: try optionalText(
          statement, at: 4, column: "document_filename_hint"),
        recordVersion: Int(statement.requiredInt64(at: 5, column: "record_version"))
      )
      guard storedEventID == eventID else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "event_id")
      }
      return record
    } catch let error as ObjectiveEventStoreError {
      throw error
    } catch {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "application_context")
    }
  }

  private static func fetchCollectorStateRecord(
    eventID: EventID,
    from database: SQLiteDatabase
  ) throws -> CollectorStateRecord? {
    let statement = try database.prepare(
      """
      SELECT event_id, collector_kind, authorization,
          runtime_kind, runtime_reason, resume_kind, resume_reason, record_version
      FROM objective_collector_states WHERE event_id = ?
      """
    )
    try statement.bind(eventID.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else {
      let orphan = try database.prepare(
        "SELECT 1 FROM objective_collector_pause_reasons WHERE event_id = ? LIMIT 1")
      try orphan.bind(eventID.rawValue.uuidString.lowercased(), at: 1)
      guard !(try orphan.stepRow()) else {
        throw ObjectiveEventStoreError.corruptedSchema(
          "Collector pause reason exists without its state")
      }
      return nil
    }

    do {
      let storedEventID = EventID(rawValue: try decodeUUID(statement, at: 0, column: "event_id"))
      guard storedEventID == eventID else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "event_id")
      }
      let collectorText = try statement.requiredText(at: 1, column: "collector_kind")
      guard let collector = CollectorKind(rawValue: collectorText) else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "collector_kind")
      }
      let authorizationText = try statement.requiredText(at: 2, column: "authorization")
      guard let authorization = AuthorizationState(rawValue: authorizationText) else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "authorization")
      }
      let runtimeKind = try statement.requiredText(at: 3, column: "runtime_kind")
      let runtimeReason = try optionalText(statement, at: 4, column: "runtime_reason")
      let resumeKind = try optionalText(statement, at: 5, column: "resume_kind")
      let resumeReason = try optionalText(statement, at: 6, column: "resume_reason")
      let pauseReasons = try fetchPauseReasons(eventID: eventID, from: database)
      let runtime = try decodeRuntime(
        kind: runtimeKind,
        reason: runtimeReason,
        resumeKind: resumeKind,
        resumeReason: resumeReason,
        pauseReasons: pauseReasons
      )
      let state = try CollectorState(
        kind: collector, authorization: authorization, runtime: runtime)
      return try CollectorStateRecord(
        eventID: storedEventID,
        state: state,
        recordVersion: Int(statement.requiredInt64(at: 7, column: "record_version"))
      )
    } catch let error as ObjectiveEventStoreError {
      throw error
    } catch {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "collector_state")
    }
  }

  private static func fetchCollectionSuppressionRecord(
    eventID: EventID,
    from database: SQLiteDatabase
  ) throws -> CollectionSuppressionRecord? {
    let statement = try database.prepare(
      """
      SELECT event_id, reason, record_version
      FROM objective_collection_suppressions WHERE event_id = ?
      """
    )
    try statement.bind(eventID.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    do {
      let storedEventID = EventID(rawValue: try decodeUUID(statement, at: 0, column: "event_id"))
      guard storedEventID == eventID else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "event_id")
      }
      let rawReason = try statement.requiredText(at: 1, column: "reason")
      guard let reason = CollectionSuppressionReason(rawValue: rawReason) else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "reason")
      }
      return try CollectionSuppressionRecord(
        eventID: storedEventID,
        reason: reason,
        recordVersion: Int(statement.requiredInt64(at: 2, column: "record_version"))
      )
    } catch let error as ObjectiveEventStoreError {
      throw error
    } catch {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "collection_suppression")
    }
  }

  private static func fetchPauseReasons(
    eventID: EventID,
    from database: SQLiteDatabase
  ) throws -> Set<CollectionPauseReason> {
    let statement = try database.prepare(
      "SELECT reason FROM objective_collector_pause_reasons WHERE event_id = ? ORDER BY reason")
    try statement.bind(eventID.rawValue.uuidString.lowercased(), at: 1)
    var reasons: Set<CollectionPauseReason> = []
    while try statement.stepRow() {
      let raw = try statement.requiredText(at: 0, column: "reason")
      guard let reason = CollectionPauseReason(rawValue: raw), reasons.insert(reason).inserted
      else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "reason")
      }
    }
    return reasons
  }

  private static func encode(
    _ runtime: CollectorRuntimeState
  ) -> (
    runtimeKind: String,
    runtimeReason: String?,
    resumeKind: String?,
    resumeReason: String?,
    pauseReasons: Set<CollectionPauseReason>
  ) {
    switch runtime {
    case .unconfigured:
      return ("unconfigured", nil, nil, nil, [])
    case .waitingForAuthorization:
      return ("waitingForAuthorization", nil, nil, nil, [])
    case .running:
      return ("running", nil, nil, nil, [])
    case .paused(let reasons, let resumeState):
      let resume = encode(resumeState)
      return ("paused", nil, resume.kind, resume.reason, reasons)
    case .degraded(let reason):
      return ("degraded", reason.rawValue, nil, nil, [])
    case .failed(let reason):
      return ("failed", reason.rawValue, nil, nil, [])
    }
  }

  private static func encode(_ resume: CollectorResumeState) -> (kind: String, reason: String?) {
    switch resume {
    case .waitingForAuthorization:
      return ("waitingForAuthorization", nil)
    case .running:
      return ("running", nil)
    case .degraded(let reason):
      return ("degraded", reason.rawValue)
    case .failed(let reason):
      return ("failed", reason.rawValue)
    }
  }

  private static func decodeRuntime(
    kind: String,
    reason: String?,
    resumeKind: String?,
    resumeReason: String?,
    pauseReasons: Set<CollectionPauseReason>
  ) throws -> CollectorRuntimeState {
    switch (kind, reason, resumeKind, resumeReason, pauseReasons.isEmpty) {
    case ("unconfigured", nil, nil, nil, true):
      return .unconfigured
    case ("waitingForAuthorization", nil, nil, nil, true):
      return .waitingForAuthorization
    case ("running", nil, nil, nil, true):
      return .running
    case ("paused", nil, let resumeKind?, let resumeReason, false):
      return .paused(
        reasons: pauseReasons,
        resumeState: try decodeResumeState(kind: resumeKind, reason: resumeReason))
    case ("degraded", let reason?, nil, nil, true):
      guard let value = CollectorDegradationReason(rawValue: reason) else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "runtime_reason")
      }
      return .degraded(value)
    case ("failed", let reason?, nil, nil, true):
      guard let value = CollectorFailureReason(rawValue: reason) else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "runtime_reason")
      }
      return .failed(value)
    default:
      throw ObjectiveEventStoreError.invalidStoredValue(column: "collector_runtime")
    }
  }

  private static func decodeResumeState(
    kind: String,
    reason: String?
  ) throws -> CollectorResumeState {
    switch (kind, reason) {
    case ("waitingForAuthorization", nil):
      return .waitingForAuthorization
    case ("running", nil):
      return .running
    case ("degraded", let reason?):
      guard let value = CollectorDegradationReason(rawValue: reason) else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "resume_reason")
      }
      return .degraded(value)
    case ("failed", let reason?):
      guard let value = CollectorFailureReason(rawValue: reason) else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "resume_reason")
      }
      return .failed(value)
    default:
      throw ObjectiveEventStoreError.invalidStoredValue(column: "collector_resume")
    }
  }

  private static func bind(_ value: String?, to statement: SQLiteStatement, at index: Int32) throws
  {
    if let value {
      try statement.bind(value, at: index)
    } else {
      try statement.bindNull(at: index)
    }
  }

  private static func optionalText(
    _ statement: SQLiteStatement,
    at index: Int32,
    column: String
  ) throws -> String? {
    statement.isNull(at: index) ? nil : try statement.requiredText(at: index, column: column)
  }

  private static func bind(_ event: ObjectiveEvent, to statement: SQLiteStatement) throws {
    try statement.bind(event.id.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(event.kind.rawValue, at: 2)
    try statement.bind(event.occurredAt.timeIntervalSinceReferenceDate, at: 3)
    if let endedAt = event.endedAt {
      try statement.bind(endedAt.timeIntervalSinceReferenceDate, at: 4)
    } else {
      try statement.bindNull(at: 4)
    }
    try statement.bind(event.timeZoneIdentifier, at: 5)
    try statement.bind(event.source.collector.rawValue, at: 6)
    try statement.bind(event.source.collectorVersion, at: 7)
    guard let payloadVersion = Int64(exactly: event.source.payloadSchemaVersion) else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "payload_schema_version")
    }
    try statement.bind(payloadVersion, at: 8)
    if let display = event.display {
      try statement.bind(display.id.rawValue.uuidString.lowercased(), at: 9)
      try statement.bind(String(display.topologyRevision), at: 10)
    } else {
      try statement.bindNull(at: 9)
      try statement.bindNull(at: 10)
    }
    let security = encode(event.securityDisposition)
    try statement.bind(security.disposition, at: 11)
    if let reason = security.reason {
      try statement.bind(reason, at: 12)
    } else {
      try statement.bindNull(at: 12)
    }
  }

  private static func fetch(id: EventID, from database: SQLiteDatabase) throws -> ObjectiveEvent? {
    let statement = try database.prepare(
      """
      SELECT
          id, kind, occurred_at, ended_at, time_zone_identifier,
          collector_kind, collector_version, payload_schema_version,
          display_id, topology_revision,
          security_disposition, suppression_reason
      FROM objective_events WHERE id = ?
      """
    )
    try statement.bind(id.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    return try decodeEvent(from: statement)
  }

  private static func decodeEvent(from statement: SQLiteStatement) throws -> ObjectiveEvent {
    let id = try decodeUUID(statement, at: 0, column: "id")
    let kindText = try statement.requiredText(at: 1, column: "kind")
    guard let kind = ObjectiveEventKind(rawValue: kindText) else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "kind")
    }
    let occurred = try statement.requiredDouble(at: 2, column: "occurred_at")
    guard occurred.isFinite else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "occurred_at")
    }
    let ended: Date?
    if statement.isNull(at: 3) {
      ended = nil
    } else {
      let value = try statement.requiredDouble(at: 3, column: "ended_at")
      guard value.isFinite else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "ended_at")
      }
      ended = Date(timeIntervalSinceReferenceDate: value)
    }
    let timeZone = try statement.requiredText(at: 4, column: "time_zone_identifier")
    let collectorText = try statement.requiredText(at: 5, column: "collector_kind")
    guard let collector = CollectorKind(rawValue: collectorText) else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "collector_kind")
    }
    let collectorVersion = try statement.requiredText(at: 6, column: "collector_version")
    let payloadValue = try statement.requiredInt64(at: 7, column: "payload_schema_version")
    guard let payloadVersion = Int(exactly: payloadValue) else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "payload_schema_version")
    }

    let display: DisplayContext?
    if statement.isNull(at: 8), statement.isNull(at: 9) {
      display = nil
    } else if !statement.isNull(at: 8), !statement.isNull(at: 9) {
      let displayID = try decodeUUID(statement, at: 8, column: "display_id")
      let topologyText = try statement.requiredText(at: 9, column: "topology_revision")
      guard let topology = UInt64(topologyText) else {
        throw ObjectiveEventStoreError.invalidStoredValue(column: "topology_revision")
      }
      display = DisplayContext(id: DisplayID(rawValue: displayID), topologyRevision: topology)
    } else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "display_id")
    }

    let dispositionText = try statement.requiredText(at: 10, column: "security_disposition")
    let reasonText =
      statement.isNull(at: 11)
      ? nil
      : try statement.requiredText(at: 11, column: "suppression_reason")
    let disposition = try decodeDisposition(dispositionText, reason: reasonText)

    do {
      return try ObjectiveEvent(
        id: EventID(rawValue: id),
        kind: kind,
        occurredAt: Date(timeIntervalSinceReferenceDate: occurred),
        endedAt: ended,
        timeZoneIdentifier: timeZone,
        source: try CollectorSource(
          collector: collector,
          collectorVersion: collectorVersion,
          payloadSchemaVersion: payloadVersion
        ),
        display: display,
        securityDisposition: disposition
      )
    } catch {
      throw ObjectiveEventStoreError.invalidStoredValue(column: "objective_event")
    }
  }

  private static func decodeUUID(
    _ statement: SQLiteStatement,
    at index: Int32,
    column: String
  ) throws -> UUID {
    let text = try statement.requiredText(at: index, column: column)
    guard let value = UUID(uuidString: text) else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: column)
    }
    return value
  }

  private static func encode(
    _ disposition: EventSecurityDisposition
  ) -> (disposition: String, reason: String?) {
    switch disposition {
    case .allowed:
      return ("allowed", nil)
    case .metadataOnly(let reason):
      return ("metadataOnly", reason.rawValue)
    case .excluded(let reason):
      return ("excluded", reason.rawValue)
    }
  }

  private static func decodeDisposition(
    _ disposition: String,
    reason: String?
  ) throws -> EventSecurityDisposition {
    switch (disposition, reason.flatMap(CollectionSuppressionReason.init(rawValue:))) {
    case ("allowed", nil):
      return .allowed
    case ("metadataOnly", let reason?):
      return .metadataOnly(reason)
    case ("excluded", let reason?):
      return .excluded(reason)
    default:
      throw ObjectiveEventStoreError.invalidStoredValue(column: "security_disposition")
    }
  }
}
