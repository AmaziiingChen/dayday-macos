import CSQLite
import DaydayCore
import Dispatch
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite objective event repository")
struct SQLiteObjectiveEventRepositoryTests {
  @Test("application identity normalization and catalog resolution are stable across reopen")
  func applicationIdentityCatalog() async throws {
    let salt = Data(repeating: 7, count: 32)
    let normalized = try ApplicationIdentityCatalog.normalizedBundleIdentifier("Com.Example.Editor")
    let identifier = try ApplicationIdentityCatalog.derive(normalized: normalized, salt: salt)
      .identifier
    #expect(identifier.rawValue.uuidString.lowercased() == "f0739ba7-b81b-8a90-9063-42e87bb0d935")
    let repeated = try ApplicationIdentityCatalog.derive(normalized: normalized, salt: salt)
      .identifier
    #expect(identifier == repeated)
    let uuid = identifier.rawValue.uuidString.lowercased()
    #expect(uuid[uuid.index(uuid.startIndex, offsetBy: 14)] == "8")
    #expect(
      ["8", "9", "a", "b"].contains(uuid[uuid.index(uuid.startIndex, offsetBy: 19)].lowercased()))
    #expect(throws: ObjectiveEventStoreError.invalidApplicationIdentity) {
      _ = try ApplicationIdentityCatalog.normalizedBundleIdentifier("com.example/editor")
    }

    try await withTemporaryDatabase { url in
      let first = try SQLiteObjectiveEventRepository(location: .file(url))
      let entry = try await first.resolveApplication(
        bundleIdentifier: "com.example.editor", displayLabel: "Editor")
      let reopened = try SQLiteObjectiveEventRepository(location: .file(url))
      #expect(
        try await reopened.resolveApplication(
          bundleIdentifier: "COM.EXAMPLE.EDITOR", displayLabel: "Renamed"
        ).identifier == entry.identifier)
      #expect(
        try await reopened.applicationCatalogEntry(for: entry.identifier)?.displayLabel == "Renamed"
      )
    }
  }

  @Test("missing invalid salt and altered catalog schema fail closed without raw identity")
  func applicationCatalogCorruption() async throws {
    try await withTemporaryDatabase { url in
      _ = try SQLiteObjectiveEventRepository(location: .file(url))
      try execute("DELETE FROM objective_application_catalog_metadata", at: url)
      #expect(throws: ObjectiveEventStoreError.corruptedSchema("application identity metadata")) {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
    }
    try await withTemporaryDatabase { url in
      _ = try SQLiteObjectiveEventRepository(location: .file(url))
      try execute("DROP TABLE objective_application_catalog", at: url)
      #expect(throws: ObjectiveEventStoreError.corruptedSchema("application catalog schema")) {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
    }
  }

  @Test("salt variants, collision guard, and raw identity storage boundaries fail closed")
  func identityHardeningMatrix() async throws {
    let normalized = try ApplicationIdentityCatalog.normalizedBundleIdentifier("Com.Example.Editor")
    let first = try ApplicationIdentityCatalog.derive(
      normalized: normalized, salt: Data(repeating: 7, count: 32))
    let second = try ApplicationIdentityCatalog.derive(
      normalized: normalized, salt: Data(repeating: 8, count: 32))
    #expect(
      first.collisionGuard.map { String(format: "%02x", $0) }.joined()
        == "2364854a273da6a5758616716b94bc89")
    #expect(first.identifier != second.identifier)
    #expect(first.collisionGuard != second.collisionGuard)
    #expect(
      try ApplicationIdentityCatalog.normalizedBundleIdentifier("com.example.editor") == normalized)

    try await withTemporaryDatabase { url in
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))
      let entry = try await repository.resolveApplication(
        bundleIdentifier: "com.example.editor", displayLabel: "Original")
      try execute(
        "PRAGMA ignore_check_constraints=ON; UPDATE objective_application_catalog SET collision_guard=zeroblob(16)",
        at: url)
      do {
        _ = try await repository.resolveApplication(
          bundleIdentifier: "com.example.editor", displayLabel: "Changed")
        Issue.record("Expected collision guard mismatch to fail closed")
      } catch let error as ObjectiveEventStoreError {
        #expect(error == .applicationIdentifierCollision)
        #expect(!String(reflecting: error).contains("com.example.editor"))
      }
      #expect(
        try await repository.applicationCatalogEntry(for: entry.identifier)?.displayLabel
          == "Original")
      let schema = try scalarText(
        "SELECT sql FROM sqlite_schema WHERE name='objective_application_catalog'", at: url)
      #expect(!schema.contains("bundle"))
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM pragma_table_info('objective_application_catalog') WHERE name LIKE '%bundle%'",
          at: url) == 0)
      let durableText = try scalarText(
        "SELECT group_concat(value, '|') FROM (SELECT sql AS value FROM sqlite_schema WHERE sql IS NOT NULL UNION ALL SELECT application_id || '|' || hex(collision_guard) || '|' || display_label || '|' || record_version FROM objective_application_catalog UNION ALL SELECT salt_version || '|' || hex(installation_salt) FROM objective_application_catalog_metadata)",
        at: url)
      #expect(!durableText.lowercased().contains("com.example.editor"))
    }

    for mutation in [
      "PRAGMA ignore_check_constraints=ON; UPDATE objective_application_catalog_metadata SET installation_salt=zeroblob(31)",
      "PRAGMA ignore_check_constraints=ON; UPDATE objective_application_catalog_metadata SET salt_version=2",
    ] {
      try await withTemporaryDatabase { url in
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
        try execute(mutation, at: url)
        #expect(throws: ObjectiveEventStoreError.corruptedSchema("application identity metadata")) {
          _ = try SQLiteObjectiveEventRepository(location: .file(url))
        }
      }
    }

    try await withTemporaryDatabase { url in
      _ = try SQLiteObjectiveEventRepository(location: .file(url))
      #expect(throws: SQLiteTestError.self) {
        try execute(
          "UPDATE objective_application_catalog_metadata SET installation_salt='not-a-blob'",
          at: url)
      }
      let reopened = try SQLiteObjectiveEventRepository(location: .file(url))
      #expect(try await reopened.schemaVersion() == 4)
    }
  }

  @Test("direct concurrent first open serializes objective v4 migration")
  func concurrentFirstOpen() async throws {
    for _ in 0..<20 {
      try await withTemporaryDatabase { url in
        let gate = ObjectiveRepositoryOpenGate(participantCount: 8)
        let repositories = try await withThrowingTaskGroup(of: SQLiteObjectiveEventRepository.self)
        {
          group in
          for _ in 0..<8 {
            group.addTask {
              await gate.wait()
              return try SQLiteObjectiveEventRepository(location: .file(url))
            }
          }
          var result: [SQLiteObjectiveEventRepository] = []
          for try await repository in group { result.append(repository) }
          return result
        }
        #expect(repositories.count == 8)
        for repository in repositories { #expect(try await repository.schemaVersion() == 4) }
      }
    }
  }

  @Test("a held WAL lock fails within the bounded retry window")
  func heldWALLockFailsByDeadline() async throws {
    try await withTemporaryDatabase { url in
      let lock = try SQLiteExclusiveLock(url: url)
      let started = DispatchTime.now().uptimeNanoseconds

      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
        Issue.record("Expected WAL convergence to fail while the coordinated lock is held")
      } catch let error as ObjectiveEventStoreError {
        guard case .database(let code, _) = error else {
          Issue.record("Expected a SQLite database error, received \(error)")
          return
        }
        #expect(code & 0xFF == SQLITE_BUSY || code & 0xFF == SQLITE_LOCKED)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        #expect(elapsed >= 900_000_000)
        #expect(elapsed < 2_000_000_000)
      }
      withExtendedLifetime(lock) {}
    }
  }

  @Test("fresh file migration is recorded explicitly")
  func migration() async throws {
    try await withTemporaryDatabase { url in
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))

      #expect(try await repository.schemaVersion() == 4)
      #expect(try scalarInt("SELECT schema_version FROM schema_metadata", at: url) == 4)
      #expect(try scalarInt("SELECT COUNT(*) FROM schema_migrations", at: url) == 4)
      #expect(try scalarInt("SELECT MAX(version) FROM schema_migrations", at: url) == 4)
    }
  }

  @Test("v1 objective rows survive the transactional v4 migration")
  func versionOneMigrationPreservesObjectiveEvents() async throws {
    try await withTemporaryDatabase { url in
      let event = try makeEvent(occurredAt: Date(timeIntervalSince1970: 1_800_000_100))
      do {
        let current = try SQLiteObjectiveEventRepository(location: .file(url))
        #expect(try await current.insert(event) == .inserted)
      }
      try downgradeObjectiveSchemaToVersion3(at: url)
      try execute(
        "DROP TABLE objective_collector_pause_reasons; DROP TABLE objective_collector_states; DROP TABLE objective_application_contexts; DROP TABLE objective_application_catalog; DROP TABLE objective_application_catalog_metadata; DELETE FROM schema_migrations WHERE version >= 2; UPDATE schema_metadata SET schema_version=1",
        at: url)

      let migrated = try SQLiteObjectiveEventRepository(location: .file(url))
      #expect(try await migrated.schemaVersion() == 4)
      #expect(
        try await migrated.fetch(
          occurredIn: event.occurredAt.addingTimeInterval(
            -1)..<event.occurredAt.addingTimeInterval(1)
        ) == [event])
    }
  }

  @Test("v2 migration grandfathers legacy linked envelopes without synthesizing projections")
  func versionTwoMigrationGrandfathersEnvelopeOnlyRows() async throws {
    try await withTemporaryDatabase { url in
      let applicationEvent = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_200),
        collector: .applicationWindowContext)
      let collectorEvent = try makeEvent(
        kind: .collectorStateTransition,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_201),
        collector: .weather)
      let identifier: ApplicationIdentifier
      do {
        let current = try SQLiteObjectiveEventRepository(location: .file(url))
        identifier = try await current.resolveApplication(
          bundleIdentifier: "com.example.editor", displayLabel: "Editor"
        ).identifier
      }
      try downgradeObjectiveSchemaToVersion3(at: url)
      try execute(
        "DROP TABLE objective_collector_pause_reasons; DROP TABLE objective_collector_states; DROP TABLE objective_application_contexts; DELETE FROM schema_migrations WHERE version=3; UPDATE schema_metadata SET schema_version=2",
        at: url)
      try insertLegacyEvent(applicationEvent, at: url)
      try insertLegacyEvent(collectorEvent, at: url)

      let migrated = try SQLiteObjectiveEventRepository(location: .file(url))
      #expect(try await migrated.schemaVersion() == 4)
      #expect(try await migrated.fetchApplicationContext(for: applicationEvent.id) == nil)
      #expect(try await migrated.fetchCollectorState(for: collectorEvent.id) == nil)

      let applicationRecord = try ApplicationContextRecord(
        eventID: applicationEvent.id,
        applicationIdentifier: identifier,
        displayLabelSnapshot: "Editor")
      do {
        _ = try await migrated.insertApplicationContext(
          try ApplicationContextWrite(event: applicationEvent, record: applicationRecord))
        Issue.record("Expected legacy event-only application context to conflict")
      } catch let error as ObjectiveEventStoreError {
        #expect(error == .identifierConflict(applicationEvent.id))
      }
      let collectorRecord = try CollectorStateRecord(
        eventID: collectorEvent.id,
        state: CollectorState(kind: .weather))
      do {
        _ = try await migrated.insertCollectorState(
          try CollectorStateWrite(event: collectorEvent, record: collectorRecord))
        Issue.record("Expected legacy event-only collector state to conflict")
      } catch let error as ObjectiveEventStoreError {
        #expect(error == .identifierConflict(collectorEvent.id))
      }
    }
  }

  @Test("v3 migration rolls back every new schema object on failure")
  func versionThreeMigrationRollback() async throws {
    try await withTemporaryDatabase { url in
      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
      try downgradeObjectiveSchemaToVersion3(at: url)
      try execute(
        "DROP TABLE objective_collector_pause_reasons; DROP TABLE objective_collector_states; DROP TABLE objective_application_contexts; DELETE FROM schema_migrations WHERE version=3; UPDATE schema_metadata SET schema_version=2; CREATE TABLE objective_collector_states (event_id TEXT PRIMARY KEY) STRICT",
        at: url)

      #expect(throws: ObjectiveEventStoreError.self) {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
      #expect(try scalarInt("SELECT schema_version FROM schema_metadata", at: url) == 2)
      #expect(try scalarInt("SELECT COUNT(*) FROM schema_migrations", at: url) == 2)
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM sqlite_schema WHERE name='objective_application_contexts'",
          at: url) == 0)
    }
  }

  @Test("v3 suppressed envelopes migrate without invented suppression records")
  func versionThreeMigrationPreservesLegacySuppressionEnvelope() async throws {
    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_250),
        collector: .applicationWindowContext,
        securityDisposition: .excluded(.mandatoryExclusion))
      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
      try downgradeObjectiveSchemaToVersion3(at: url)
      try insertLegacyEvent(event, at: url)

      let migrated = try SQLiteObjectiveEventRepository(location: .file(url))
      #expect(try await migrated.schemaVersion() == 4)
      #expect(try await migrated.fetchCollectionSuppression(for: event.id) == nil)

      let write = try CollectionSuppressionWrite(
        event: event,
        record: try CollectionSuppressionRecord(
          eventID: event.id, reason: .mandatoryExclusion))
      await #expect(throws: ObjectiveEventStoreError.identifierConflict(event.id)) {
        _ = try await migrated.insertCollectionSuppression(write)
      }
    }
  }

  @Test("v4 migration rolls back every new schema object on failure")
  func versionFourMigrationRollback() async throws {
    try await withTemporaryDatabase { url in
      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
      try downgradeObjectiveSchemaToVersion3(at: url)
      try execute(
        "CREATE TRIGGER objective_collector_states_exclusive_suppression BEFORE INSERT ON objective_collector_states BEGIN SELECT 1; END",
        at: url)

      #expect(throws: ObjectiveEventStoreError.self) {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
      #expect(try scalarInt("SELECT schema_version FROM schema_metadata", at: url) == 3)
      #expect(try scalarInt("SELECT COUNT(*) FROM schema_migrations", at: url) == 3)
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM sqlite_schema WHERE name='objective_collection_suppressions'",
          at: url) == 0)
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM sqlite_schema WHERE name='objective_application_contexts_exclusive_suppression'",
          at: url) == 0)
    }
  }

  @Test("typed linked records round trip atomically without generic payloads")
  func linkedRecordRoundTrip() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let catalog = try await repository.resolveApplication(
      bundleIdentifier: "com.example.editor", displayLabel: "Editor")
    let applicationEvent = try makeEvent(
      kind: .applicationContextChanged,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_300),
      collector: .applicationWindowContext)
    let applicationRecord = try ApplicationContextRecord(
      eventID: applicationEvent.id,
      applicationIdentifier: catalog.identifier,
      displayLabelSnapshot: "Editor",
      windowTitleSnapshot: "Quarterly plan",
      documentFilenameHint: "plan.md")
    let applicationWrite = try ApplicationContextWrite(
      event: applicationEvent, record: applicationRecord)

    #expect(try await repository.insertApplicationContext(applicationWrite) == .inserted)
    #expect(
      try await repository.fetchApplicationContext(for: applicationEvent.id) == applicationRecord)

    let collectorEvent = try makeEvent(
      kind: .collectorStateTransition,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_301),
      collector: .weather,
      securityDisposition: .metadataOnly(.authorizationUnavailable))
    let collectorState = try CollectorState(
      kind: .weather,
      authorization: .authorized,
      runtime: .paused(
        reasons: [.globalUserPause, .systemSleep],
        resumeState: .degraded(.dependencyUnavailable)))
    let collectorRecord = try CollectorStateRecord(
      eventID: collectorEvent.id, state: collectorState)
    let collectorWrite = try CollectorStateWrite(event: collectorEvent, record: collectorRecord)

    #expect(try await repository.insertCollectorState(collectorWrite) == .inserted)
    #expect(try await repository.fetchCollectorState(for: collectorEvent.id) == collectorRecord)
    #expect(
      try await repository.fetchApplicationContexts(
        for: [collectorEvent.id, applicationEvent.id, applicationEvent.id]
      ) == [applicationEvent.id: applicationRecord]
    )
    let events = try await repository.fetch(
      occurredIn: applicationEvent.occurredAt..<collectorEvent.occurredAt.addingTimeInterval(1))
    #expect(events == [applicationEvent, collectorEvent])
  }

  @Test("content-free suppression records round trip atomically for both dispositions")
  func suppressionRoundTrip() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let observations: [(EventSecurityDisposition, CollectionSuppressionReason)] = [
      (.metadataOnly(.secureInput), .secureInput),
      (.excluded(.userExclusion), .userExclusion),
    ]

    for (offset, observation) in observations.enumerated() {
      let event = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_320 + Double(offset)),
        collector: .applicationWindowContext,
        securityDisposition: observation.0)
      let record = try CollectionSuppressionRecord(
        eventID: event.id, reason: observation.1)
      let write = try CollectionSuppressionWrite(event: event, record: record)
      #expect(try await repository.insertCollectionSuppression(write) == .inserted)
      #expect(try await repository.fetchCollectionSuppression(for: event.id) == record)
      #expect(try await repository.fetchApplicationContext(for: event.id) == nil)
      #expect(try await repository.fetchCollectorState(for: event.id) == nil)
    }
  }

  @Test("suppression admission rejects every non-application event before storage")
  func suppressionRejectsOtherKindsBeforeStorage() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)

    for kind in ObjectiveEventKind.allCases where kind != .applicationContextChanged {
      let event = try makeEvent(
        kind: kind,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_340),
        collector: .applicationWindowContext,
        securityDisposition: .metadataOnly(.secureInput))
      let record = try CollectionSuppressionRecord(eventID: event.id, reason: .secureInput)

      #expect(throws: ObjectiveLinkedRecordValidationError.eventLinkMismatch) {
        _ = try CollectionSuppressionWrite(event: event, record: record)
      }
      #expect(
        try await repository.fetch(
          occurredIn: event.occurredAt..<event.occurredAt.addingTimeInterval(1)
        ).isEmpty)
    }
  }

  @Test("linked retries are idempotent only for an exact event and projection")
  func linkedRecordIdempotenceAndConflict() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let catalog = try await repository.resolveApplication(
      bundleIdentifier: "com.example.editor", displayLabel: "Editor")
    let event = try makeEvent(
      kind: .applicationContextChanged,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_400),
      collector: .applicationWindowContext)
    let record = try ApplicationContextRecord(
      eventID: event.id,
      applicationIdentifier: catalog.identifier,
      displayLabelSnapshot: "Editor")
    let write = try ApplicationContextWrite(event: event, record: record)

    #expect(try await repository.insertApplicationContext(write) == .inserted)
    #expect(try await repository.insertApplicationContext(write) == .alreadyPresent)

    let conflictingRecord = try ApplicationContextRecord(
      eventID: event.id,
      applicationIdentifier: catalog.identifier,
      displayLabelSnapshot: "Renamed")
    do {
      _ = try await repository.insertApplicationContext(
        try ApplicationContextWrite(event: event, record: conflictingRecord))
      Issue.record("Expected projection conflict")
    } catch let error as ObjectiveEventStoreError {
      #expect(error == .identifierConflict(event.id))
    }
    #expect(try await repository.fetchApplicationContext(for: event.id) == record)

    let collectorEvent = try makeEvent(
      kind: .collectorStateTransition,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_401),
      collector: .weather)
    let collectorRecord = try CollectorStateRecord(
      eventID: collectorEvent.id,
      state: try CollectorState(
        kind: .weather, authorization: .authorized, runtime: .running))
    let collectorWrite = try CollectorStateWrite(
      event: collectorEvent, record: collectorRecord)
    #expect(try await repository.insertCollectorState(collectorWrite) == .inserted)
    #expect(try await repository.insertCollectorState(collectorWrite) == .alreadyPresent)

    let conflictingCollectorRecord = try CollectorStateRecord(
      eventID: collectorEvent.id,
      state: try CollectorState(
        kind: .weather,
        authorization: .authorized,
        runtime: .degraded(.resourcePressure)))
    do {
      _ = try await repository.insertCollectorState(
        try CollectorStateWrite(event: collectorEvent, record: conflictingCollectorRecord))
      Issue.record("Expected collector projection conflict")
    } catch let error as ObjectiveEventStoreError {
      #expect(error == .identifierConflict(collectorEvent.id))
    }
    #expect(try await repository.fetchCollectorState(for: collectorEvent.id) == collectorRecord)

    let suppressionID = EventID()
    let suppressionEvent = try makeEvent(
      id: suppressionID,
      kind: .applicationContextChanged,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_402),
      collector: .applicationWindowContext,
      securityDisposition: .metadataOnly(.systemSleep))
    let suppressionRecord = try CollectionSuppressionRecord(
      eventID: suppressionID, reason: .systemSleep)
    let suppressionWrite = try CollectionSuppressionWrite(
      event: suppressionEvent, record: suppressionRecord)
    #expect(try await repository.insertCollectionSuppression(suppressionWrite) == .inserted)
    #expect(try await repository.insertCollectionSuppression(suppressionWrite) == .alreadyPresent)

    let conflictingSuppressionEvent = try makeEvent(
      id: suppressionID,
      kind: .applicationContextChanged,
      occurredAt: suppressionEvent.occurredAt,
      collector: .applicationWindowContext,
      securityDisposition: .metadataOnly(.secureInput))
    let conflictingSuppressionWrite = try CollectionSuppressionWrite(
      event: conflictingSuppressionEvent,
      record: try CollectionSuppressionRecord(
        eventID: suppressionID, reason: .secureInput))
    await #expect(throws: ObjectiveEventStoreError.identifierConflict(suppressionID)) {
      _ = try await repository.insertCollectionSuppression(conflictingSuppressionWrite)
    }
    #expect(
      try await repository.fetchCollectionSuppression(for: suppressionID) == suppressionRecord)
  }

  @Test("failed projection insertion rolls back its event")
  func failedProjectionInsertionIsAtomic() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let event = try makeEvent(
      kind: .applicationContextChanged,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_450),
      collector: .applicationWindowContext)
    let record = try ApplicationContextRecord(
      eventID: event.id,
      applicationIdentifier: ApplicationIdentifier(rawValue: UUID()),
      displayLabelSnapshot: "Editor")
    await #expect(throws: ObjectiveEventStoreError.self) {
      _ = try await repository.insertApplicationContext(
        try ApplicationContextWrite(event: event, record: record))
    }
    #expect(
      try await repository.fetch(
        occurredIn: event.occurredAt..<event.occurredAt.addingTimeInterval(1)
      ).isEmpty)
    #expect(try await repository.fetchApplicationContext(for: event.id) == nil)
  }

  @Test("projection-required kinds reject generic insertion without partial rows")
  func projectionRequiredKindsRejectGenericInsert() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    for (kind, collector) in [
      (ObjectiveEventKind.applicationContextChanged, CollectorKind.applicationWindowContext),
      (.collectorStateTransition, .weather),
    ] {
      let event = try makeEvent(
        kind: kind,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_500),
        collector: collector)
      await #expect(throws: ObjectiveEventStoreError.identifierConflict(event.id)) {
        _ = try await repository.insert(event)
      }
      #expect(try await repository.fetchApplicationContext(for: event.id) == nil)
      #expect(try await repository.fetchCollectorState(for: event.id) == nil)
      #expect(try await repository.fetchCollectionSuppression(for: event.id) == nil)
    }

    let suppressedEvent = try makeEvent(
      kind: .systemBoundary,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_501),
      securityDisposition: .metadataOnly(.screenLocked))
    await #expect(throws: ObjectiveEventStoreError.identifierConflict(suppressedEvent.id)) {
      _ = try await repository.insert(suppressedEvent)
    }
    #expect(try await repository.fetchCollectionSuppression(for: suppressedEvent.id) == nil)
  }

  @Test("privacy-invalid application writes cannot leave an event row")
  func privacyInvalidApplicationWriteHasNoPartialEvent() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let catalog = try await repository.resolveApplication(
      bundleIdentifier: "com.example.editor", displayLabel: "Editor")
    let event = try makeEvent(
      kind: .applicationContextChanged,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_600),
      collector: .applicationWindowContext,
      securityDisposition: .excluded(.userExclusion))
    let record = try ApplicationContextRecord(
      eventID: event.id,
      applicationIdentifier: catalog.identifier,
      displayLabelSnapshot: "Editor")
    #expect(throws: ObjectiveLinkedRecordValidationError.eventLinkMismatch) {
      _ = try ApplicationContextWrite(event: event, record: record)
    }
    #expect(
      try await repository.fetch(
        occurredIn: event.occurredAt..<event.occurredAt.addingTimeInterval(1)
      ).isEmpty)
  }

  @Test("collector closed nullability and pause-child corruption fail closed")
  func collectorProjectionCorruption() async throws {
    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .collectorStateTransition,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_700),
        collector: .weather)
      let state = try CollectorState(
        kind: .weather,
        authorization: .authorized,
        runtime: .paused(reasons: [.systemSleep], resumeState: .running))
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        _ = try await repository.insertCollectorState(
          try CollectorStateWrite(
            event: event,
            record: try CollectorStateRecord(eventID: event.id, state: state)))
      }
      #expect(throws: SQLiteTestError.self) {
        try execute(
          "UPDATE objective_collector_states SET resume_kind=NULL WHERE event_id='\(event.id.rawValue.uuidString.lowercased())'",
          at: url)
      }
      try execute(
        "PRAGMA ignore_check_constraints=ON; UPDATE objective_collector_states SET resume_kind=NULL WHERE event_id='\(event.id.rawValue.uuidString.lowercased())'",
        at: url)
      let reopened = try SQLiteObjectiveEventRepository(location: .file(url))
      await #expect(
        throws: ObjectiveEventStoreError.invalidStoredValue(column: "collector_runtime")
      ) {
        _ = try await reopened.fetchCollectorState(for: event.id)
      }
    }

    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .collectorStateTransition,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_701),
        collector: .weather)
      let state = try CollectorState(
        kind: .weather,
        authorization: .authorized,
        runtime: .paused(reasons: [.systemSleep], resumeState: .running))
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        _ = try await repository.insertCollectorState(
          try CollectorStateWrite(
            event: event,
            record: try CollectorStateRecord(eventID: event.id, state: state)))
      }
      try execute("DELETE FROM objective_collector_pause_reasons", at: url)
      let reopened = try SQLiteObjectiveEventRepository(location: .file(url))
      await #expect(
        throws: ObjectiveEventStoreError.invalidStoredValue(column: "collector_runtime")
      ) {
        _ = try await reopened.fetchCollectorState(for: event.id)
      }
    }
  }

  @Test("linked projection event invariants fail closed after durable corruption")
  func linkedProjectionEventCorruption() async throws {
    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_710),
        collector: .applicationWindowContext)
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        let catalog = try await repository.resolveApplication(
          bundleIdentifier: "com.example.editor", displayLabel: "Editor")
        let record = try ApplicationContextRecord(
          eventID: event.id,
          applicationIdentifier: catalog.identifier,
          displayLabelSnapshot: "Editor")
        _ = try await repository.insertApplicationContext(
          try ApplicationContextWrite(event: event, record: record))
      }
      try execute(
        "UPDATE objective_events SET security_disposition='metadataOnly', suppression_reason='secureInput'",
        at: url)
      let reopened = try SQLiteObjectiveEventRepository(location: .file(url))
      await #expect(
        throws: ObjectiveEventStoreError.corruptedSchema(
          "Application-context projection has an invalid event link")
      ) {
        _ = try await reopened.fetchApplicationContext(for: event.id)
      }
    }

    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .collectorStateTransition,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_711),
        collector: .weather)
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        let record = try CollectorStateRecord(
          eventID: event.id, state: CollectorState(kind: .weather))
        _ = try await repository.insertCollectorState(
          try CollectorStateWrite(event: event, record: record))
      }
      try execute("UPDATE objective_events SET collector_kind='screenUnderstanding'", at: url)
      let reopened = try SQLiteObjectiveEventRepository(location: .file(url))
      await #expect(
        throws: ObjectiveEventStoreError.corruptedSchema(
          "Collector-state projection has an invalid event link")
      ) {
        _ = try await reopened.fetchCollectorState(for: event.id)
      }
    }

    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_712),
        collector: .applicationWindowContext,
        securityDisposition: .metadataOnly(.secureInput))
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        _ = try await repository.insertCollectionSuppression(
          try CollectionSuppressionWrite(
            event: event,
            record: try CollectionSuppressionRecord(
              eventID: event.id, reason: .secureInput)))
      }
      try execute(
        "UPDATE objective_events SET suppression_reason='incognito' WHERE id='\(event.id.rawValue.uuidString.lowercased())'",
        at: url)
      let reopened = try SQLiteObjectiveEventRepository(location: .file(url))
      await #expect(
        throws: ObjectiveEventStoreError.corruptedSchema(
          "Collection-suppression projection has an invalid event link")
      ) {
        _ = try await reopened.fetchCollectionSuppression(for: event.id)
      }
    }
  }

  @Test("dual durable projection ownership always fails closed")
  func dualProjectionOwnershipCorruption() async throws {
    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .collectorStateTransition,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_720),
        collector: .weather)
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))
      let catalog = try await repository.resolveApplication(
        bundleIdentifier: "com.example.editor", displayLabel: "Editor")
      let record = try CollectorStateRecord(
        eventID: event.id, state: CollectorState(kind: .weather))
      let write = try CollectorStateWrite(event: event, record: record)
      #expect(try await repository.insertCollectorState(write) == .inserted)

      let corruptProjectionSQL =
        "INSERT INTO objective_application_contexts(event_id, application_id, display_label_snapshot, window_title_snapshot, document_filename_hint, record_version) VALUES ('\(event.id.rawValue.uuidString.lowercased())', '\(catalog.identifier.rawValue.uuidString.lowercased())', 'Editor', NULL, NULL, 1)"
      #expect(throws: SQLiteTestError.self) {
        try execute(corruptProjectionSQL, at: url)
      }
      try execute(
        "DROP TRIGGER objective_application_contexts_exclusive_projection; \(corruptProjectionSQL)",
        at: url)

      let dualProjectionError = ObjectiveEventStoreError.corruptedSchema(
        "Objective event has multiple typed projections")
      await #expect(throws: dualProjectionError) {
        _ = try await repository.fetchApplicationContext(for: event.id)
      }
      await #expect(throws: dualProjectionError) {
        _ = try await repository.fetchCollectorState(for: event.id)
      }
      await #expect(throws: dualProjectionError) {
        _ = try await repository.fetchCollectionSuppression(for: event.id)
      }
      await #expect(throws: dualProjectionError) {
        _ = try await repository.insertCollectorState(write)
      }
    }
  }

  @Test("suppression ownership corruption fails every typed path closed")
  func suppressionProjectionOwnershipCorruption() async throws {
    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_721),
        collector: .applicationWindowContext,
        securityDisposition: .excluded(.userExclusion))
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))
      let catalog = try await repository.resolveApplication(
        bundleIdentifier: "com.example.editor", displayLabel: "Editor")
      let record = try CollectionSuppressionRecord(
        eventID: event.id, reason: .userExclusion)
      let write = try CollectionSuppressionWrite(event: event, record: record)
      #expect(try await repository.insertCollectionSuppression(write) == .inserted)

      let corruptProjectionSQL =
        "INSERT INTO objective_application_contexts(event_id, application_id, display_label_snapshot, window_title_snapshot, document_filename_hint, record_version) VALUES ('\(event.id.rawValue.uuidString.lowercased())', '\(catalog.identifier.rawValue.uuidString.lowercased())', 'Editor', NULL, NULL, 1)"
      #expect(throws: SQLiteTestError.self) {
        try execute(corruptProjectionSQL, at: url)
      }
      try execute(
        "DROP TRIGGER objective_application_contexts_exclusive_suppression; \(corruptProjectionSQL)",
        at: url)

      let multipleProjectionError = ObjectiveEventStoreError.corruptedSchema(
        "Objective event has multiple typed projections")
      await #expect(throws: multipleProjectionError) {
        _ = try await repository.fetchApplicationContext(for: event.id)
      }
      await #expect(throws: multipleProjectionError) {
        _ = try await repository.fetchCollectorState(for: event.id)
      }
      await #expect(throws: multipleProjectionError) {
        _ = try await repository.fetchCollectionSuppression(for: event.id)
      }
      await #expect(throws: multipleProjectionError) {
        _ = try await repository.insertCollectionSuppression(write)
      }
    }
  }

  @Test("v4 ownership triggers block every suppression projection direction")
  func suppressionOwnershipTriggersBlockEveryInsertDirection() async throws {
    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_722),
        collector: .applicationWindowContext)
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))
      let catalog = try await repository.resolveApplication(
        bundleIdentifier: "com.example.editor", displayLabel: "Editor")
      _ = try await repository.insertApplicationContext(
        try ApplicationContextWrite(
          event: event,
          record: try ApplicationContextRecord(
            eventID: event.id,
            applicationIdentifier: catalog.identifier,
            displayLabelSnapshot: "Editor")))
      #expect(throws: SQLiteTestError.self) {
        try execute(
          "INSERT INTO objective_collection_suppressions(event_id, reason, record_version) VALUES ('\(event.id.rawValue.uuidString.lowercased())', 'secureInput', 1)",
          at: url)
      }
    }

    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .collectorStateTransition,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_723),
        collector: .weather)
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))
      _ = try await repository.insertCollectorState(
        try CollectorStateWrite(
          event: event,
          record: try CollectorStateRecord(
            eventID: event.id, state: CollectorState(kind: .weather))))
      #expect(throws: SQLiteTestError.self) {
        try execute(
          "INSERT INTO objective_collection_suppressions(event_id, reason, record_version) VALUES ('\(event.id.rawValue.uuidString.lowercased())', 'secureInput', 1)",
          at: url)
      }
    }

    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_724),
        collector: .applicationWindowContext,
        securityDisposition: .metadataOnly(.secureInput))
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))
      _ = try await repository.insertCollectionSuppression(
        try CollectionSuppressionWrite(
          event: event,
          record: try CollectionSuppressionRecord(
            eventID: event.id, reason: .secureInput)))
      #expect(throws: SQLiteTestError.self) {
        try execute(
          "INSERT INTO objective_collector_states(event_id, collector_kind, authorization, runtime_kind, runtime_reason, resume_kind, resume_reason, record_version) VALUES ('\(event.id.rawValue.uuidString.lowercased())', 'weather', 'notRequired', 'unconfigured', NULL, NULL, NULL, 1)",
          at: url)
      }
    }
  }

  @Test("v3 typed table fingerprints reject replacement")
  func typedProjectionSchemaFingerprint() async throws {
    try await withTemporaryDatabase { url in
      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
      try execute(
        "DROP TABLE objective_collector_pause_reasons; CREATE TABLE objective_collector_pause_reasons (event_id TEXT, reason TEXT) STRICT",
        at: url)
      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
        Issue.record("Expected typed projection fingerprint rejection")
      } catch let error as ObjectiveEventStoreError {
        guard case .corruptedSchema(let message) = error else {
          Issue.record("Expected corrupted schema, received \(error)")
          return
        }
        #expect(message.contains("objective_collector_pause_reasons"))
      }
    }
  }

  @Test("v3 ownership trigger fingerprints reject missing and replaced definitions")
  func ownershipTriggerSchemaFingerprint() async throws {
    let mutations = [
      (
        "DROP TRIGGER objective_application_contexts_exclusive_projection",
        "objective_application_contexts_exclusive_projection"
      ),
      (
        "DROP TRIGGER objective_collector_states_exclusive_projection",
        "objective_collector_states_exclusive_projection"
      ),
      (
        "DROP TRIGGER objective_application_contexts_exclusive_projection; CREATE TRIGGER objective_application_contexts_exclusive_projection BEFORE INSERT ON objective_application_contexts BEGIN SELECT 1; END",
        "objective_application_contexts_exclusive_projection"
      ),
      (
        "DROP TRIGGER objective_collector_states_exclusive_projection; CREATE TRIGGER objective_collector_states_exclusive_projection BEFORE INSERT ON objective_collector_states BEGIN SELECT 1; END",
        "objective_collector_states_exclusive_projection"
      ),
    ]

    for (mutation, triggerName) in mutations {
      try await withTemporaryDatabase { url in
        do {
          _ = try SQLiteObjectiveEventRepository(location: .file(url))
        }
        try execute(mutation, at: url)
        do {
          _ = try SQLiteObjectiveEventRepository(location: .file(url))
          Issue.record("Expected ownership trigger fingerprint rejection")
        } catch let error as ObjectiveEventStoreError {
          guard case .corruptedSchema(let message) = error else {
            Issue.record("Expected corrupted schema, received \(error)")
            return
          }
          #expect(message.contains(triggerName))
        }
      }
    }
  }

  @Test("v4 suppression table checks and fingerprint fail closed")
  func suppressionTableSchemaAndChecks() async throws {
    try await withTemporaryDatabase { url in
      let event = try makeEvent(
        kind: .applicationContextChanged,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_730),
        collector: .applicationWindowContext,
        securityDisposition: .metadataOnly(.secureInput))
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        _ = try await repository.insertCollectionSuppression(
          try CollectionSuppressionWrite(
            event: event,
            record: try CollectionSuppressionRecord(
              eventID: event.id, reason: .secureInput)))
      }
      for mutation in [
        "UPDATE objective_collection_suppressions SET reason='futureReason'",
        "UPDATE objective_collection_suppressions SET record_version=2",
      ] {
        #expect(throws: SQLiteTestError.self) {
          try execute(mutation, at: url)
        }
      }
    }

    for mutation in [
      "DROP TABLE objective_collection_suppressions",
      "DROP TABLE objective_collection_suppressions; CREATE TABLE objective_collection_suppressions (event_id TEXT PRIMARY KEY, reason TEXT, record_version INTEGER) STRICT",
    ] {
      try await withTemporaryDatabase { url in
        do {
          _ = try SQLiteObjectiveEventRepository(location: .file(url))
        }
        try execute(mutation, at: url)
        #expect(throws: ObjectiveEventStoreError.self) {
          _ = try SQLiteObjectiveEventRepository(location: .file(url))
        }
      }
    }
  }

  @Test("v4 suppression ownership trigger fingerprints reject missing and replacement")
  func suppressionOwnershipTriggerSchemaFingerprint() async throws {
    let triggerNames = [
      "objective_application_contexts_exclusive_suppression",
      "objective_collector_states_exclusive_suppression",
      "objective_collection_suppressions_exclusive_projection",
    ]
    for triggerName in triggerNames {
      for replacement in [false, true] {
        try await withTemporaryDatabase { url in
          do {
            _ = try SQLiteObjectiveEventRepository(location: .file(url))
          }
          var mutation = "DROP TRIGGER \(triggerName)"
          if replacement {
            mutation +=
              "; CREATE TRIGGER \(triggerName) BEFORE INSERT ON objective_events BEGIN SELECT 1; END"
          }
          try execute(mutation, at: url)
          do {
            _ = try SQLiteObjectiveEventRepository(location: .file(url))
            Issue.record("Expected suppression trigger fingerprint rejection")
          } catch let error as ObjectiveEventStoreError {
            guard case .corruptedSchema(let message) = error else {
              Issue.record("Expected corrupted schema, received \(error)")
              return
            }
            #expect(message.contains(triggerName))
          }
        }
      }
    }
  }

  @Test("v3 typed projections contain no generic payload or blob columns")
  func typedProjectionColumnsAreNormalized() async throws {
    try await withTemporaryDatabase { url in
      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
      }
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM (SELECT name, type FROM pragma_table_info('objective_application_contexts') UNION ALL SELECT name, type FROM pragma_table_info('objective_collector_states') UNION ALL SELECT name, type FROM pragma_table_info('objective_collector_pause_reasons')) WHERE lower(name) LIKE '%payload%' OR lower(name) LIKE '%json%' OR upper(type)='BLOB'",
          at: url) == 0)
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM pragma_table_info('objective_collection_suppressions') WHERE lower(name) LIKE '%payload%' OR lower(name) LIKE '%json%' OR lower(name) LIKE '%content%' OR lower(name) LIKE '%source%' OR lower(name) LIKE '%platform%' OR upper(type)='BLOB'",
          at: url) == 0)
      #expect(
        try scalarInt(
          "SELECT COUNT(*) FROM pragma_table_info('objective_collection_suppressions')",
          at: url) == 3)
    }
  }

  @Test("all closed envelope fields round trip without a Codable blob")
  func roundTrip() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let event = try makeEvent(
      kind: .applicationContextChanged,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_000.125),
      endedAt: Date(timeIntervalSince1970: 1_800_000_015.75),
      display: DisplayContext(
        id: DisplayID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
        topologyRevision: .max
      ),
      collector: .applicationWindowContext,
      securityDisposition: .metadataOnly(.secureInput)
    )

    #expect(
      try await repository.insertCollectionSuppression(
        try CollectionSuppressionWrite(
          event: event,
          record: try CollectionSuppressionRecord(
            eventID: event.id, reason: .secureInput))) == .inserted)
    let results = try await repository.fetch(
      occurredIn: Date(
        timeIntervalSince1970: 1_799_999_999)..<Date(timeIntervalSince1970: 1_800_000_001)
    )

    #expect(results == [event])
  }

  @Test("date range is half-open and results have a stable order")
  func rangeAndOrder() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let boundary = Date(timeIntervalSince1970: 1_800_010_000)
    let before = try makeEvent(
      id: EventID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
      occurredAt: boundary.addingTimeInterval(-1)
    )
    let tieB = try makeEvent(
      id: EventID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
      occurredAt: boundary
    )
    let tieA = try makeEvent(
      id: EventID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
      occurredAt: boundary
    )
    let upperBoundary = try makeEvent(
      id: EventID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
      occurredAt: boundary.addingTimeInterval(1)
    )
    for event in [upperBoundary, tieB, before, tieA] {
      _ = try await repository.insert(event)
    }

    let results = try await repository.fetch(
      occurredIn: boundary..<boundary.addingTimeInterval(1)
    )
    #expect(results == [tieA, tieB])
  }

  @Test("same event ID is idempotent but conflicting content is rejected")
  func duplicateAndConflict() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let id = EventID()
    let original = try makeEvent(id: id, occurredAt: Date(timeIntervalSince1970: 1_800_020_000))
    let conflict = try makeEvent(
      id: id,
      kind: .systemBoundary,
      occurredAt: original.occurredAt
    )

    #expect(try await repository.insert(original) == .inserted)
    #expect(try await repository.insert(original) == .alreadyPresent)

    do {
      _ = try await repository.insert(conflict)
      Issue.record("Expected an identifier conflict")
    } catch let error as ObjectiveEventStoreError {
      #expect(error == .identifierConflict(id))
    }

    let results = try await repository.fetch(
      occurredIn: original.occurredAt.addingTimeInterval(
        -1)..<original.occurredAt.addingTimeInterval(1)
    )
    #expect(results == [original])
  }

  @Test("Foundation Date precision survives round trip and idempotent retry")
  func exactDatePrecision() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let seconds = Double(800_000_000).nextUp
    let occurredAt = Date(timeIntervalSinceReferenceDate: seconds)
    let endedAt = Date(timeIntervalSinceReferenceDate: seconds.nextUp)
    let event = try makeEvent(occurredAt: occurredAt, endedAt: endedAt)

    #expect(occurredAt.timeIntervalSinceReferenceDate == seconds)
    #expect(try await repository.insert(event) == .inserted)
    #expect(try await repository.insert(event) == .alreadyPresent)

    let results = try await repository.fetch(
      occurredIn: occurredAt..<Date(timeIntervalSinceReferenceDate: seconds.nextUp)
    )
    #expect(results == [event])
  }

  @Test("adjacent representable Date bounds remain a non-empty range")
  func adjacentDateBounds() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let lowerSeconds = Double(800_000_000).nextUp
    let lower = Date(timeIntervalSinceReferenceDate: lowerSeconds)
    let upper = Date(timeIntervalSinceReferenceDate: lowerSeconds.nextUp)
    let event = try makeEvent(occurredAt: lower)

    _ = try await repository.insert(event)
    #expect(try await repository.fetch(occurredIn: lower..<upper) == [event])
  }

  @Test("Cursor pages are newest-first and preserve equal-timestamp boundaries")
  func cursorPaging() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let start = Date(timeIntervalSince1970: 1_800_020_000)
    let sameMoment = start.addingTimeInterval(60)
    let earliest = try makeEvent(
      id: .init(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))),
      occurredAt: sameMoment
    )
    let laterAtSameMoment = try makeEvent(
      id: .init(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))),
      occurredAt: sameMoment
    )
    let newest = try makeEvent(
      id: .init(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))),
      occurredAt: start.addingTimeInterval(120)
    )
    for event in [earliest, laterAtSameMoment, newest] {
      #expect(try await repository.insert(event) == .inserted)
    }

    let first = try await repository.fetchPage(
      occurredIn: start..<start.addingTimeInterval(180), before: nil, limit: 2
    )
    #expect(first.events == [newest, laterAtSameMoment])
    #expect(first.nextCursor == .init(occurredAt: laterAtSameMoment.occurredAt, eventID: laterAtSameMoment.id))

    let second = try await repository.fetchPage(
      occurredIn: start..<start.addingTimeInterval(180), before: first.nextCursor, limit: 2
    )
    #expect(second.events == [earliest])
    #expect(second.nextCursor == nil)
    await #expect(throws: ObjectiveEventStoreError.invalidPageLimit) {
      _ = try await repository.fetchPage(
        occurredIn: start..<start.addingTimeInterval(180), before: nil, limit: 0
      )
    }
  }

  @Test("empty and non-finite date ranges fail closed")
  func invalidRanges() async throws {
    let repository = try SQLiteObjectiveEventRepository(location: .inMemory)
    let date = Date(timeIntervalSince1970: 1_800_030_000)
    let ranges = [
      Range(uncheckedBounds: (date, date)),
      Date(timeIntervalSince1970: -.infinity)..<date,
      date..<Date(timeIntervalSince1970: .infinity),
    ]

    for range in ranges {
      do {
        _ = try await repository.fetch(occurredIn: range)
        Issue.record("Expected invalid range rejection")
      } catch let error as ObjectiveEventStoreError {
        #expect(error == .invalidDateRange)
      }
    }
  }

  @Test("unknown enum in an otherwise type-valid row fails closed")
  func corruptRow() async throws {
    try await withTemporaryDatabase { url in
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))
      let event = try makeEvent(occurredAt: Date(timeIntervalSince1970: 1_800_040_000))
      _ = try await repository.insert(event)
      try execute("UPDATE objective_events SET kind = 'futureUnknownKind'", at: url)

      do {
        _ = try await repository.fetch(
          occurredIn: event.occurredAt.addingTimeInterval(
            -1)..<event.occurredAt.addingTimeInterval(1)
        )
        Issue.record("Expected corrupt row rejection")
      } catch let error as ObjectiveEventStoreError {
        #expect(error == .invalidStoredValue(column: "kind"))
      }
    }
  }

  @Test("newer schema version is never opened or rewritten")
  func newerSchema() async throws {
    try await withTemporaryDatabase { url in
      let repository = try SQLiteObjectiveEventRepository(location: .file(url))
      #expect(try await repository.schemaVersion() == 4)
      try execute("UPDATE schema_metadata SET schema_version = 99", at: url)

      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
        Issue.record("Expected unsupported schema rejection")
      } catch let error as ObjectiveEventStoreError {
        #expect(error == .unsupportedSchemaVersion(found: 99, supported: 4))
      }
      #expect(try scalarInt("SELECT schema_version FROM schema_metadata", at: url) == 99)
    }
  }

  @Test("a valid ledger cannot hide a missing required index")
  func missingIndexIsCorruption() async throws {
    try await withTemporaryDatabase { url in
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        #expect(try await repository.schemaVersion() == 4)
      }
      try execute("DROP INDEX objective_events_occurred_at", at: url)

      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
        Issue.record("Expected missing index rejection")
      } catch let error as ObjectiveEventStoreError {
        guard case .corruptedSchema(let message) = error else {
          Issue.record("Expected corrupted schema, received \(error)")
          return
        }
        #expect(message.contains("objective_events_occurred_at"))
      }
    }
  }

  @Test("a valid ledger cannot hide a replaced event table")
  func replacedTableIsCorruption() async throws {
    try await withTemporaryDatabase { url in
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        #expect(try await repository.schemaVersion() == 4)
      }
      try execute(
        """
        DROP INDEX objective_events_occurred_at;
        DROP TABLE objective_events;
        CREATE TABLE objective_events (id INTEGER PRIMARY KEY) STRICT;
        CREATE INDEX objective_events_occurred_at ON objective_events(id);
        """,
        at: url
      )

      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
        Issue.record("Expected replaced table rejection")
      } catch let error as ObjectiveEventStoreError {
        guard case .corruptedSchema(let message) = error else {
          Issue.record("Expected corrupted schema, received \(error)")
          return
        }
        #expect(message.contains("objective_events"))
      }
    }
  }

  @Test("schema fingerprint preserves the semantics of quoted check literals")
  func alteredCheckLiteralIsCorruption() async throws {
    try await withTemporaryDatabase { url in
      do {
        let repository = try SQLiteObjectiveEventRepository(location: .file(url))
        #expect(try await repository.schemaVersion() == 4)
      }
      try execute(
        """
        DROP INDEX objective_events_occurred_at;
        DROP TABLE objective_events;
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
                (security_disposition = 'ALLOWED' AND suppression_reason IS NULL)
                OR
                (security_disposition != 'ALLOWED' AND suppression_reason IS NOT NULL)
            )
        ) STRICT;
        CREATE INDEX objective_events_occurred_at
        ON objective_events(occurred_at, id);
        """,
        at: url
      )

      do {
        _ = try SQLiteObjectiveEventRepository(location: .file(url))
        Issue.record("Expected altered CHECK literal rejection")
      } catch let error as ObjectiveEventStoreError {
        guard case .corruptedSchema(let message) = error else {
          Issue.record("Expected corrupted schema, received \(error)")
          return
        }
        #expect(message.contains("objective_events"))
      }
    }
  }

  private func makeEvent(
    id: EventID = EventID(),
    kind: ObjectiveEventKind = .stableStateObservation,
    occurredAt: Date,
    endedAt: Date? = nil,
    display: DisplayContext? = nil,
    collector: CollectorKind = .screenUnderstanding,
    securityDisposition: EventSecurityDisposition = .allowed
  ) throws -> ObjectiveEvent {
    try ObjectiveEvent(
      id: id,
      kind: kind,
      occurredAt: occurredAt,
      endedAt: endedAt,
      timeZoneIdentifier: "Asia/Shanghai",
      source: CollectorSource(
        collector: collector,
        collectorVersion: "screen-1.2.0+alpha",
        payloadSchemaVersion: 7
      ),
      display: display,
      securityDisposition: securityDisposition
    )
  }
}

private func downgradeObjectiveSchemaToVersion3(at url: URL) throws {
  try execute(
    """
    DROP TRIGGER objective_application_contexts_exclusive_suppression;
    DROP TRIGGER objective_collector_states_exclusive_suppression;
    DROP TRIGGER objective_collection_suppressions_exclusive_projection;
    DROP TABLE objective_collection_suppressions;
    DELETE FROM schema_migrations WHERE version=4;
    UPDATE schema_metadata SET schema_version=3;
    """,
    at: url
  )
}

private func insertLegacyEvent(_ event: ObjectiveEvent, at url: URL) throws {
  let endedAt = event.endedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "NULL"
  let disposition: String
  let reason: String
  switch event.securityDisposition {
  case .allowed:
    disposition = "allowed"
    reason = "NULL"
  case .metadataOnly(let value):
    disposition = "metadataOnly"
    reason = "'\(value.rawValue)'"
  case .excluded(let value):
    disposition = "excluded"
    reason = "'\(value.rawValue)'"
  }
  try execute(
    "INSERT INTO objective_events(id, kind, occurred_at, ended_at, time_zone_identifier, collector_kind, collector_version, payload_schema_version, display_id, topology_revision, security_disposition, suppression_reason) VALUES ('\(event.id.rawValue.uuidString.lowercased())', '\(event.kind.rawValue)', \(event.occurredAt.timeIntervalSinceReferenceDate), \(endedAt), '\(event.timeZoneIdentifier)', '\(event.source.collector.rawValue)', '\(event.source.collectorVersion)', \(event.source.payloadSchemaVersion), NULL, NULL, '\(disposition)', \(reason))",
    at: url)
}

private func withTemporaryDatabase(
  _ body: (URL) async throws -> Void
) async throws {
  let url = URL(fileURLWithPath: "/tmp/dayday-storage-\(UUID().uuidString).sqlite")
  defer {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
  }
  try await body(url)
}

private enum SQLiteTestError: Error {
  case open(Int32)
  case execute(Int32, String)
  case query(Int32, String)
  case missingValue
}

private actor ObjectiveRepositoryOpenGate {
  private let participantCount: Int
  private var arrivals = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(participantCount: Int) {
    self.participantCount = participantCount
  }

  func wait() async {
    arrivals += 1
    guard arrivals < participantCount else {
      let waiting = continuations
      continuations.removeAll()
      for continuation in waiting { continuation.resume() }
      return
    }
    await withCheckedContinuation { continuations.append($0) }
  }
}

private final class SQLiteExclusiveLock {
  private let database: OpaquePointer

  init(url: URL) throws {
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK, let opened else {
      if let opened { sqlite3_close_v2(opened) }
      throw SQLiteTestError.open(result)
    }
    database = opened

    var message: UnsafeMutablePointer<CChar>?
    let begin = sqlite3_exec(database, "BEGIN EXCLUSIVE", nil, nil, &message)
    guard begin == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? "SQLite error"
      sqlite3_free(message)
      sqlite3_close_v2(database)
      throw SQLiteTestError.execute(begin, text)
    }
  }

  deinit {
    sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
    sqlite3_close_v2(database)
  }
}

private func execute(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
  guard openResult == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw SQLiteTestError.open(openResult)
  }
  defer { sqlite3_close_v2(database) }

  var message: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &message)
  guard result == SQLITE_OK else {
    let text = message.map { String(cString: $0) } ?? "SQLite error"
    sqlite3_free(message)
    throw SQLiteTestError.execute(result, text)
  }
}

private func scalarInt(_ sql: String, at url: URL) throws -> Int64 {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
  guard openResult == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw SQLiteTestError.open(openResult)
  }
  defer { sqlite3_close_v2(database) }

  var statement: OpaquePointer?
  let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
  guard prepareResult == SQLITE_OK, let statement else {
    throw SQLiteTestError.query(prepareResult, String(cString: sqlite3_errmsg(database)))
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw SQLiteTestError.missingValue
  }
  return sqlite3_column_int64(statement, 0)
}

private func scalarText(_ sql: String, at url: URL) throws -> String {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database
  else {
    throw SQLiteTestError.missingValue
  }
  defer { sqlite3_close_v2(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement,
    sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0)
  else {
    throw SQLiteTestError.missingValue
  }
  defer { sqlite3_finalize(statement) }
  return String(cString: value)
}
