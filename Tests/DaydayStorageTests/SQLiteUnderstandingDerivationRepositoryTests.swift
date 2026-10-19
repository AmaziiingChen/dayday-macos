import CSQLite
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

struct SQLiteUnderstandingDerivationRepositoryTests {
  @Test("atomic rebuild inserts reloads reopens and exactly replays")
  func insertReloadReopenAndReplay() async throws {
    try await withDerivationStore { url, repository, derivation in
      #expect(try await repository.latest(for: derivation.day) == nil)
      #expect(try await repository.saveAtomically(derivation) == .inserted)
      #expect(try await repository.latest(for: derivation.day) == derivation)
      #expect(try await repository.saveAtomically(derivation) == .alreadyPresent)
      let reopened = try SQLiteUnderstandingDerivationRepository(location: .file(url))
      #expect(try await reopened.latest(for: derivation.day) == derivation)
    }
  }

  @Test("combined writes remain readable through both standalone repositories")
  func combinedWriteReopensThroughStandaloneRepositories() async throws {
    try await withDerivationStore { url, repository, derivation in
      #expect(try await repository.saveAtomically(derivation) == .inserted)
      let sessions = try SQLiteSessionRepository(location: .file(url))
      let activities = try SQLiteActivityRepository(location: .file(url))
      #expect(
        try await sessions.sessions(
          startedIn: derivation.day.boundary.startsAt..<derivation.day.boundary.endsAt)
          == derivation.sessions)
      #expect(
        try await activities.activities(
          startedIn: derivation.day.boundary.startsAt..<derivation.day.boundary.endsAt)
          == derivation.activities)
    }
  }

  @Test("workspace Session v2 persists without a fabricated display UUID")
  func workspaceSessionPersistsAndReopens() async throws {
    let url = URL(fileURLWithPath: "/tmp/dayday-workspace-session-\(UUID().uuidString).sqlite")
    defer { removeUnderstandingDatabase(at: url) }
    let start = Date(timeIntervalSince1970: 1_799_985_600)
    let day = try DayDescriptor(
      logicalDate: .init(year: 2027, month: 1, day: 15), timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400)))
    let event = try ObjectiveEvent(
      id: EventID(), kind: .systemBoundary,
      occurredAt: start.addingTimeInterval(60), timeZoneIdentifier: "UTC",
      source: try CollectorSource(
        collector: .applicationWindowContext, collectorVersion: "test-v1", payloadSchemaVersion: 1),
      securityDisposition: .allowed)
    let objective = try SQLiteObjectiveEventRepository(location: .file(url))
    _ = try await objective.insert(event)
    let session = try Session(
      id: SessionID(), scope: .workspace,
      startedAt: event.occurredAt, endedAt: event.occurredAt.addingTimeInterval(300),
      objectiveEventIDs: [event.id])
    let activity = try Activity(
      id: ActivityID(), startedAt: session.startedAt, endedAt: session.endedAt,
      sessionIDs: [session.id], title: "使用 ChatGPT", confidence: .low,
      reviewState: .needsReview,
      interpretation: try ActivityInterpretation(
        origin: .deterministicRule, producerVersion: "understanding-v1"))
    let derivation = try PersistedUnderstandingDerivation(
      sessionBatch: SessionDerivationBatch(day: day, derivationRevision: 1, sessions: [session]),
      activityBatch: ActivityDerivationBatch(
        day: day, derivationRevision: 1, activities: [activity]))

    let repository = try SQLiteUnderstandingDerivationRepository(location: .file(url))
    #expect(try await repository.saveAtomically(derivation) == .inserted)
    #expect(try await repository.latest(for: day) == derivation)
    #expect(try scalarUnderstandingText("SELECT display_id FROM h2_sessions", at: url) == "workspace")
  }

  @Test("standalone legacy migration remains compatible with combined reopen")
  func standaloneLegacyMigrationThenCombinedReopen() async throws {
    try await withDerivationStore { url, repository, derivation in
      #expect(try await repository.saveAtomically(derivation) == .inserted)
      try downgradeSessionSchemaToV3(at: url)
      try downgradeActivitySchemaToV1(at: url)
      _ = try SQLiteSessionRepository(location: .file(url))
      _ = try SQLiteActivityRepository(location: .file(url))
      let reopened = try SQLiteUnderstandingDerivationRepository(location: .file(url))
      #expect(try await reopened.latest(for: derivation.day) == derivation)
    }
  }

  @Test("legacy activity envelope mismatches fail before standalone migration")
  func legacyEnvelopeMismatchIsRejected() async throws {
    try await withDerivationStore { url, repository, derivation in
      #expect(try await repository.saveAtomically(derivation) == .inserted)
      try downgradeActivitySchemaToV1(at: url)
      try executeUnderstanding(
        "UPDATE h2_activity_batches SET boundary_end = boundary_end + 1", at: url)
      #expect(throws: ActivityStoreError.self) {
        _ = try SQLiteActivityRepository(location: .file(url))
      }
      #expect(
        try scalarUnderstanding("SELECT schema_version FROM h2_activity_schema_metadata", at: url)
          == 1)
    }
  }

  @Test("combined reads reject tampered normalized Session columns")
  func rejectsTamperedNormalizedSessionColumns() async throws {
    for mutation in [
      "UPDATE h2_sessions SET display_id = '00000000-0000-0000-0000-000000000999'",
      "UPDATE h2_sessions SET ending_boundary = 'screenLocked'",
      "UPDATE h2_sessions SET revision = 2",
      "UPDATE h2_sessions SET supersedes_id = '00000000-0000-0000-0000-000000000998'",
    ] {
      try await withDerivationStore { url, repository, derivation in
        #expect(try await repository.saveAtomically(derivation) == .inserted)
        try executeUnderstanding(mutation, at: url)
        await #expect(throws: UnderstandingDerivationStoreError.invalidStoredDerivation) {
          _ = try await repository.latest(for: derivation.day)
        }
      }
    }
  }

  @Test("concurrent identical and differing revision writes classify without partial revisions")
  func classifiesConcurrentRevisionWrites() async throws {
    try await withDerivationStore { url, _, derivation in
      let objective = try SQLiteObjectiveEventRepository(location: .file(url))
      let different = try makeDerivation()
      try await insertObjectiveEvent(for: different, into: objective)

      let identical = try await concurrentSaves(
        at: url, candidates: Array(repeating: derivation, count: 12))
      #expect(identical.filter { $0 == .inserted }.count == 1)
      #expect(identical.filter { $0 == .alreadyPresent }.count == 11)
      #expect(try scalarUnderstanding("SELECT COUNT(*) FROM h2_session_batches", at: url) == 1)
      #expect(try scalarUnderstanding("SELECT COUNT(*) FROM h2_activity_batches", at: url) == 1)

      let alternateURL = URL(
        fileURLWithPath: "/tmp/dayday-understanding-race-\(UUID().uuidString).sqlite")
      defer { removeUnderstandingDatabase(at: alternateURL) }
      let alternateObjective = try SQLiteObjectiveEventRepository(location: .file(alternateURL))
      try await insertObjectiveEvent(for: derivation, into: alternateObjective)
      try await insertObjectiveEvent(for: different, into: alternateObjective)
      let differing = try await concurrentSaves(
        at: alternateURL,
        candidates: (0..<12).map { $0.isMultiple(of: 2) ? derivation : different })
      #expect(differing.filter { $0 == .inserted }.count == 1)
      #expect(differing.filter { $0 == .conflict }.count == 6)
      #expect(differing.filter { $0 == .alreadyPresent }.count == 5)
      #expect(
        try scalarUnderstanding("SELECT COUNT(*) FROM h2_session_batches", at: alternateURL) == 1)
      #expect(
        try scalarUnderstanding("SELECT COUNT(*) FROM h2_activity_batches", at: alternateURL) == 1)
    }
  }

  @Test("Core rebuild validation rejects mismatched envelopes and cross-batch members")
  func coreValidationRejectsMismatches() async throws {
    let fixture = try makeDerivation()
    let otherDay = try DayDescriptor(
      logicalDate: .init(year: 2027, month: 1, day: 16), timeZoneIdentifier: "UTC",
      boundary: .init(
        hour: 4,
        startsAt: fixture.day.boundary.startsAt.addingTimeInterval(86_400),
        endsAt: fixture.day.boundary.endsAt.addingTimeInterval(86_400)
      ))
    let shiftedActivity = try Activity(
      id: fixture.activities[0].id,
      startedAt: fixture.activities[0].startedAt.addingTimeInterval(86_400),
      endedAt: fixture.activities[0].endedAt.addingTimeInterval(86_400),
      sessionIDs: fixture.activities[0].sessionIDs,
      title: fixture.activities[0].title,
      confidence: .low,
      reviewState: .needsReview,
      interpretation: fixture.activities[0].interpretation
    )
    #expect(throws: PersistedUnderstandingDerivation.ValidationError.mismatchedDay) {
      try PersistedUnderstandingDerivation(
        sessionBatch: fixture.sessionBatch,
        activityBatch: try ActivityDerivationBatch(
          day: otherDay, derivationRevision: 1, activities: [shiftedActivity]))
    }
    let foreign = try Activity(
      id: ActivityID(), startedAt: fixture.activities[0].startedAt,
      endedAt: fixture.activities[0].endedAt,
      sessionIDs: [SessionID()], title: "Observed application activity", confidence: .low,
      reviewState: .needsReview,
      interpretation: try ActivityInterpretation(
        origin: .deterministicRule, producerVersion: "test-v1"))
    #expect(throws: PersistedUnderstandingDerivation.ValidationError.self) {
      try PersistedUnderstandingDerivation(
        sessionBatch: fixture.sessionBatch,
        activityBatch: try ActivityDerivationBatch(
          day: fixture.day, derivationRevision: 1, activities: [foreign]))
    }
  }

  private func withDerivationStore(
    _ body: (URL, SQLiteUnderstandingDerivationRepository, PersistedUnderstandingDerivation)
      async throws -> Void
  ) async throws {
    let url = URL(fileURLWithPath: "/tmp/dayday-understanding-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let objective = try SQLiteObjectiveEventRepository(location: .file(url))
    let derivation = try makeDerivation()
    try await insertObjectiveEvent(for: derivation, into: objective)
    try await body(
      url, try SQLiteUnderstandingDerivationRepository(location: .file(url)), derivation)
  }

  private func insertObjectiveEvent(
    for derivation: PersistedUnderstandingDerivation, into objective: SQLiteObjectiveEventRepository
  ) async throws {
    let event = try ObjectiveEvent(
      id: derivation.sessions[0].objectiveEventIDs[0], kind: .systemBoundary,
      occurredAt: derivation.sessions[0].startedAt, timeZoneIdentifier: "UTC",
      source: try CollectorSource(
        collector: .applicationWindowContext, collectorVersion: "test-v1", payloadSchemaVersion: 1),
      display: DisplayContext(
        id: try #require(derivation.sessions[0].displayID), topologyRevision: 1),
      securityDisposition: .allowed)
    _ = try await objective.insert(event)
  }

  private func makeDerivation() throws -> PersistedUnderstandingDerivation {
    let start = Date(timeIntervalSince1970: 1_799_985_600)
    let day = try DayDescriptor(
      logicalDate: .init(year: 2027, month: 1, day: 15), timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400)))
    let display = DisplayID()
    let eventID = EventID()
    let session = try Session(
      id: SessionID(),
      displayID: display, startedAt: start.addingTimeInterval(60),
      endedAt: start.addingTimeInterval(120),
      objectiveEventIDs: [eventID])
    let activity = try Activity(
      id: ActivityID(),
      startedAt: session.startedAt, endedAt: session.endedAt, sessionIDs: [session.id],
      title: "Observed application activity", confidence: .low, reviewState: .needsReview,
      interpretation: try ActivityInterpretation(
        origin: .deterministicRule, producerVersion: "test-v1"))
    return try PersistedUnderstandingDerivation(
      sessionBatch: SessionDerivationBatch(day: day, derivationRevision: 1, sessions: [session]),
      activityBatch: ActivityDerivationBatch(
        day: day, derivationRevision: 1, activities: [activity]))
  }

  private func concurrentSaves(
    at url: URL, candidates: [PersistedUnderstandingDerivation]
  ) async throws -> [UnderstandingDerivationSaveResult] {
    let gate = UnderstandingSaveGate(participantCount: candidates.count)
    return try await withThrowingTaskGroup(
      of: UnderstandingDerivationSaveResult.self,
      returning: [UnderstandingDerivationSaveResult].self
    ) { group in
      for candidate in candidates {
        group.addTask {
          let repository = try SQLiteUnderstandingDerivationRepository(location: .file(url))
          await gate.wait()
          return try await repository.saveAtomically(candidate)
        }
      }
      var values: [UnderstandingDerivationSaveResult] = []
      for try await value in group { values.append(value) }
      return values
    }
  }
}

private actor UnderstandingSaveGate {
  private let participantCount: Int
  private var arrivals = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(participantCount: Int) { self.participantCount = participantCount }

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

private enum UnderstandingSQLiteTestError: Error { case database }

private func executeUnderstanding(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database
  else { throw UnderstandingSQLiteTestError.database }
  defer { sqlite3_close_v2(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw UnderstandingSQLiteTestError.database
  }
}

private func scalarUnderstanding(_ sql: String, at url: URL) throws -> Int64 {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database
  else { throw UnderstandingSQLiteTestError.database }
  defer { sqlite3_close_v2(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement,
    sqlite3_step(statement) == SQLITE_ROW
  else { throw UnderstandingSQLiteTestError.database }
  defer { sqlite3_finalize(statement) }
  return sqlite3_column_int64(statement, 0)
}

private func scalarUnderstandingText(_ sql: String, at url: URL) throws -> String {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database
  else { throw UnderstandingSQLiteTestError.database }
  defer { sqlite3_close_v2(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement,
    sqlite3_step(statement) == SQLITE_ROW,
    let value = sqlite3_column_text(statement, 0)
  else { throw UnderstandingSQLiteTestError.database }
  defer { sqlite3_finalize(statement) }
  return String(cString: value)
}

private func removeUnderstandingDatabase(at url: URL) {
  for suffix in ["", "-wal", "-shm"] {
    try? FileManager.default.removeItem(atPath: url.path + suffix)
  }
}

private func downgradeActivitySchemaToV1(at url: URL) throws {
  let metadata =
    "CREATE TABLE h2_activity_schema_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL, schema_fingerprint TEXT NOT NULL) STRICT"
  let batches =
    "CREATE TABLE h2_activity_batches (batch_id TEXT PRIMARY KEY NOT NULL, logical_date TEXT NOT NULL, time_zone TEXT NOT NULL, boundary_start REAL NOT NULL, boundary_end REAL NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), activity_ids TEXT NOT NULL UNIQUE) STRICT"
  let records =
    "CREATE TABLE h2_activity_records (activity_id TEXT PRIMARY KEY NOT NULL, batch_id TEXT NOT NULL REFERENCES h2_activity_batches(batch_id) ON DELETE RESTRICT, started_at REAL NOT NULL, ended_at REAL NOT NULL, payload TEXT NOT NULL) STRICT"
  let membership =
    "CREATE TABLE h2_activity_membership (activity_id TEXT NOT NULL REFERENCES h2_activity_records(activity_id) ON DELETE RESTRICT, ordinal INTEGER NOT NULL CHECK(ordinal >= 0), session_id TEXT NOT NULL REFERENCES h2_sessions(session_id) ON DELETE RESTRICT, PRIMARY KEY(activity_id, ordinal), UNIQUE(activity_id, session_id)) WITHOUT ROWID, STRICT"
  let index =
    "CREATE INDEX h2_activity_records_started_at ON h2_activity_records(started_at ASC, activity_id ASC)"
  let fingerprint = understandingFingerprint([metadata, batches, records, membership, index])
  try executeUnderstanding(
    """
    PRAGMA foreign_keys = OFF;
    DROP INDEX h2_activity_records_started_at;
    ALTER TABLE h2_activity_membership RENAME TO h2_activity_membership_v2;
    ALTER TABLE h2_activity_records RENAME TO h2_activity_records_v2;
    ALTER TABLE h2_activity_batches RENAME TO h2_activity_batches_v2;
    \(batches);
    \(records);
    \(membership);
    \(index);
    INSERT INTO h2_activity_batches(batch_id,logical_date,time_zone,boundary_start,boundary_end,revision,activity_ids) SELECT batch_id,logical_date,time_zone,boundary_start,boundary_end,revision,activity_ids FROM h2_activity_batches_v2;
    INSERT INTO h2_activity_records(activity_id,batch_id,started_at,ended_at,payload) SELECT activity_id,batch_id,started_at,ended_at,payload FROM h2_activity_records_v2;
    INSERT INTO h2_activity_membership(activity_id,ordinal,session_id) SELECT activity_id,ordinal,session_id FROM h2_activity_membership_v2;
    DROP TABLE h2_activity_membership_v2;
    DROP TABLE h2_activity_records_v2;
    DROP TABLE h2_activity_batches_v2;
    UPDATE h2_activity_schema_metadata SET schema_version=1,schema_fingerprint='\(fingerprint)' WHERE singleton=1;
    PRAGMA foreign_keys = ON;
    """, at: url)
}

private func downgradeSessionSchemaToV3(at url: URL) throws {
  let metadata =
    "CREATE TABLE h2_session_schema_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL, schema_fingerprint TEXT NOT NULL DEFAULT '') STRICT"
  let batches =
    "CREATE TABLE h2_session_batches (batch_id TEXT PRIMARY KEY NOT NULL, logical_date TEXT NOT NULL, time_zone TEXT NOT NULL, boundary_start REAL NOT NULL, boundary_end REAL NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), session_ids TEXT NOT NULL UNIQUE) STRICT"
  let sessions =
    "CREATE TABLE h2_sessions (session_id TEXT PRIMARY KEY NOT NULL, batch_id TEXT NOT NULL REFERENCES h2_session_batches(batch_id) ON DELETE RESTRICT, started_at REAL NOT NULL, ended_at REAL NOT NULL, display_id TEXT NOT NULL, ending_boundary TEXT, revision INTEGER NOT NULL CHECK (revision > 0), supersedes_id TEXT, payload TEXT NOT NULL) STRICT"
  let membership =
    "CREATE TABLE h2_session_membership (session_id TEXT NOT NULL REFERENCES h2_sessions(session_id) ON DELETE RESTRICT, ordinal INTEGER NOT NULL CHECK (ordinal >= 0), event_id TEXT NOT NULL REFERENCES objective_events(id) ON DELETE RESTRICT, PRIMARY KEY(session_id, ordinal), UNIQUE(session_id, event_id)) WITHOUT ROWID, STRICT"
  let index = "CREATE INDEX h2_sessions_started_at ON h2_sessions(started_at ASC, session_id ASC)"
  let fingerprint = understandingFingerprint([metadata, batches, sessions, membership, index])
  try executeUnderstanding(
    """
    DROP INDEX h2_session_batches_day_revision;
    UPDATE h2_session_schema_metadata SET schema_version=3,schema_fingerprint='\(fingerprint)' WHERE singleton=1;
    """, at: url)
}

private func understandingFingerprint(_ definitions: [String]) -> String {
  var value: UInt64 = 14_695_981_039_346_656_037
  for byte in definitions.map(understandingNormalizedSQL).joined(separator: "\n").utf8 {
    value ^= UInt64(byte)
    value &*= 1_099_511_628_211
  }
  return String(format: "fnv1a64-%016llx", value)
}

private func understandingNormalizedSQL(_ value: String) -> String {
  value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
