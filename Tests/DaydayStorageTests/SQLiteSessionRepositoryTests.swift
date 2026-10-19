import CSQLite
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite session repository", .serialized)
struct SQLiteSessionRepositoryTests {
  @Test("reopen validates the exact v3 fingerprinted schema")
  func reopensDeterministically() async throws {
    try await withSessionDatabase { url, _, _ in
      let first = try SQLiteSessionRepository(location: .file(url))
      let second = try SQLiteSessionRepository(location: .file(url))
      withExtendedLifetime((first, second)) {}
      #expect(
        try text(
          "SELECT schema_fingerprint FROM h2_session_schema_metadata WHERE singleton = 1", at: url
        ) == SQLiteSessionRepository.expectedSchemaFingerprint)
    }
  }

  @Test("partial, extra, renamed, replaced, and envelope schema mutations fail closed")
  func rejectsSchemaMutations() async throws {
    for mutation in [
      "DROP INDEX h2_sessions_started_at",
      "CREATE TRIGGER h2_session_extra AFTER INSERT ON h2_sessions BEGIN SELECT 1; END",
      "ALTER TABLE h2_session_batches ADD COLUMN forged TEXT",
      "ALTER TABLE h2_session_membership ADD COLUMN forged TEXT",
      "ALTER TABLE h2_session_batches RENAME TO h2_session_batches_renamed",
      "DROP TABLE h2_session_batches; CREATE TABLE h2_session_batches (batch_id TEXT PRIMARY KEY) STRICT",
    ] {
      try await withSessionDatabase { url, _, _ in
        try execute(mutation, at: url)
        #expect(throws: SessionStoreError.self) {
          _ = try SQLiteSessionRepository(location: .file(url))
        }
      }
    }
  }

  @Test("a complete development-only v2 schema migrates to the current version without synthetic sessions")
  func migratesV2Schema() async throws {
    try await withTemporarySessionDatabase { url in
      try execute(v2SchemaSQL, at: url)
      _ = try SQLiteSessionRepository(location: .file(url))
      #expect(
        try integer("SELECT schema_version FROM h2_session_schema_metadata", at: url)
          == SQLiteSessionRepository.currentSchemaVersion)
      #expect(
        try text("SELECT schema_fingerprint FROM h2_session_schema_metadata", at: url)
          == SQLiteSessionRepository.expectedSchemaFingerprint)
      #expect(try integer("SELECT COUNT(*) FROM h2_sessions", at: url) == 0)
      _ = try SQLiteSessionRepository(location: .file(url))
    }
  }

  @Test("development-only v1 is rejected without rewriting it")
  func rejectsV1WithoutInventingData() async throws {
    try await withTemporarySessionDatabase { url in
      try execute(
        "CREATE TABLE h2_session_schema_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL) STRICT; INSERT INTO h2_session_schema_metadata VALUES(1,1)",
        at: url
      )
      #expect(throws: SessionStoreError.self) {
        _ = try SQLiteSessionRepository(location: .file(url))
      }
      #expect(try integer("SELECT schema_version FROM h2_session_schema_metadata", at: url) == 1)
      #expect(
        try integer("SELECT COUNT(*) FROM sqlite_schema WHERE name LIKE 'h2_session%'", at: url)
          == 1)
    }
  }

  @Test("concurrent direct first opens serialize the session migration")
  func concurrentDirectFirstOpen() async throws {
    for _ in 0..<10 {
      try await withTemporarySessionDatabase { url in
        let gate = SessionOpenGate(participantCount: 12)
        let repositories = try await withThrowingTaskGroup(
          of: SQLiteSessionRepository.self,
          returning: [SQLiteSessionRepository].self
        ) { group in
          for _ in 0..<12 {
            group.addTask {
              await gate.wait()
              return try SQLiteSessionRepository(location: .file(url))
            }
          }
          var result: [SQLiteSessionRepository] = []
          for try await repository in group { result.append(repository) }
          return result
        }
        #expect(repositories.count == 12)
        #expect(
          try integer("SELECT schema_version FROM h2_session_schema_metadata", at: url)
            == SQLiteSessionRepository.currentSchemaVersion)
      }
    }
  }

  @Test("exact full replay validates its canonical stored batch")
  func exactFullReplayIsAlreadyPresent() async throws {
    try await withSessionDatabase { url, repository, objective in
      let day = try fixtureDay()
      let first = try fixtureEvent(
        id: "00000000-0000-0000-0000-000000000001", at: day.boundary.startsAt)
      let second = try fixtureEvent(
        id: "00000000-0000-0000-0000-000000000002",
        at: day.boundary.startsAt.addingTimeInterval(120)
      )
      _ = try await objective.insert(first)
      _ = try await objective.insert(second)
      let batch = try fixtureBatch(day: day, events: [first, second])

      #expect(try await repository.save(batch) == .inserted)
      #expect(try await repository.save(batch) == .alreadyPresent)
      #expect(
        try await repository.sessions(
          startedIn: day.boundary.startsAt..<day.boundary.endsAt
        ) == Array(batch.sessions.reversed()))
    }
  }

  @Test("subset, mixed, forged-day, and different-content batches conflict without writes")
  func rejectsPartialAndForgedReplaysAtomically() async throws {
    try await withSessionDatabase { _, repository, objective in
      let day = try fixtureDay()
      let first = try fixtureEvent(
        id: "00000000-0000-0000-0000-000000000001", at: day.boundary.startsAt)
      let second = try fixtureEvent(
        id: "00000000-0000-0000-0000-000000000002",
        at: day.boundary.startsAt.addingTimeInterval(120)
      )
      let third = try fixtureEvent(
        id: "00000000-0000-0000-0000-000000000003",
        at: day.boundary.startsAt.addingTimeInterval(240)
      )
      _ = try await objective.insert(first)
      _ = try await objective.insert(second)
      _ = try await objective.insert(third)

      let original = try fixtureBatch(day: day, events: [first, second])
      #expect(try await repository.save(original) == .inserted)
      let baseline = try await repository.sessions(
        startedIn: day.boundary.startsAt..<day.boundary.endsAt
      )

      let subset = try fixtureBatch(day: day, events: [first])
      let mixed = try fixtureBatch(day: day, events: [first, third])
      let differentSameID = try fixtureBatch(
        day: day,
        events: [first, second],
        firstSessionEndOffset: 90
      )
      let forgedDay = try fixtureBatch(
        day: try fixtureDay(day: 2),
        events: [
          try fixtureEvent(
            id: "00000000-0000-0000-0000-000000000011",
            at: try fixtureDay(day: 2).boundary.startsAt
          )
        ],
        sessionIDs: [original.sessions[0].id]
      )

      #expect(try await repository.save(subset) == .conflict)
      #expect(try await repository.save(mixed) == .conflict)
      #expect(try await repository.save(differentSameID) == .conflict)
      #expect(try await repository.save(forgedDay) == .conflict)
      #expect(
        try await repository.sessions(
          startedIn: day.boundary.startsAt..<day.boundary.endsAt
        ) == baseline)
    }
  }

  @Test("tampered envelope, missing Session, membership, and changed content fail closed")
  func rejectsTamperedStoredReplays() async throws {
    for mutation in [
      "UPDATE h2_session_batches SET revision = revision + 1",
      "UPDATE h2_session_batches SET session_ids = 'forged'",
      "DELETE FROM h2_sessions",
      "DELETE FROM h2_session_membership",
      "UPDATE h2_sessions SET ended_at = ended_at + 1",
    ] {
      try await withSessionDatabase { url, repository, objective in
        let day = try fixtureDay()
        let event = try fixtureEvent(
          id: "00000000-0000-0000-0000-000000000001", at: day.boundary.startsAt)
        _ = try await objective.insert(event)
        let batch = try fixtureBatch(day: day, events: [event])
        #expect(try await repository.save(batch) == .inserted)

        try execute(mutation, at: url)
        #expect(try await repository.save(batch) == .conflict)
      }
    }
  }

  @Test("membership without a durable objective event fails closed")
  func rejectsDanglingMembership() async throws {
    try await withSessionDatabase { _, repository, _ in
      let day = try fixtureDay()
      let event = try fixtureEvent(
        id: "00000000-0000-0000-0000-000000000001", at: day.boundary.startsAt)
      await #expect(throws: SessionStoreError.missingObjectiveEvent) {
        _ = try await repository.save(try fixtureBatch(day: day, events: [event]))
      }
    }
  }

  @Test("an unrepresentable revision conflicts before any batch write")
  func rejectsRevisionOutsideSQLiteIntegerRange() async throws {
    try await withSessionDatabase { _, repository, objective in
      let day = try fixtureDay()
      let event = try fixtureEvent(
        id: "00000000-0000-0000-0000-000000000001", at: day.boundary.startsAt)
      _ = try await objective.insert(event)
      let batch = try fixtureBatch(day: day, events: [event], derivationRevision: UInt64.max)

      #expect(try await repository.save(batch) == .conflict)
      #expect(
        try await repository.sessions(
          startedIn: day.boundary.startsAt..<day.boundary.endsAt
        ).isEmpty)
    }
  }

  private func fixtureBatch(
    day: DayDescriptor,
    events: [ObjectiveEvent],
    sessionIDs: [SessionID]? = nil,
    firstSessionEndOffset: TimeInterval = 60,
    derivationRevision: UInt64 = 1
  ) throws -> SessionDerivationBatch {
    let identifiers =
      sessionIDs ?? [
        SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!),
        SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!),
      ]
    let sessions = try zip(events, identifiers).enumerated().map { offset, pair in
      let (event, identifier) = pair
      return try Session(
        id: identifier,
        displayID: DisplayID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!),
        startedAt: event.occurredAt,
        endedAt: event.occurredAt.addingTimeInterval(offset == 0 ? firstSessionEndOffset : 60),
        objectiveEventIDs: [event.id],
        lineage: try SessionLineage(derivationRevision: derivationRevision)
      )
    }
    return try .init(
      day: day,
      derivationRevision: derivationRevision,
      sessions: sessions.reversed()
    )
  }

  private func fixtureDay(day: Int = 1) throws -> DayDescriptor {
    let start = Date(timeIntervalSince1970: 1_704_081_600 + TimeInterval(day - 1) * 86_400)
    return try .init(
      logicalDate: .init(year: 2024, month: 1, day: day),
      timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400))
    )
  }

  private func fixtureEvent(id: String, at date: Date) throws -> ObjectiveEvent {
    try .init(
      id: .init(rawValue: UUID(uuidString: id)!),
      kind: .stableStateObservation,
      occurredAt: date,
      timeZoneIdentifier: "UTC",
      source: .init(
        collector: .applicationWindowContext,
        collectorVersion: "test",
        payloadSchemaVersion: 1
      ),
      securityDisposition: .allowed
    )
  }
}

private actor SessionOpenGate {
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

private func withSessionDatabase(
  _ body: (URL, SQLiteSessionRepository, SQLiteObjectiveEventRepository) async throws -> Void
) async throws {
  let url = URL(fileURLWithPath: "/tmp/dayday-session-\(UUID().uuidString).sqlite")
  defer {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }
  let objective = try SQLiteObjectiveEventRepository(location: .file(url))
  let repository = try SQLiteSessionRepository(location: .file(url))
  try await body(url, repository, objective)
}

private func withTemporarySessionDatabase(
  _ body: (URL) async throws -> Void
) async throws {
  let url = URL(fileURLWithPath: "/tmp/dayday-session-\(UUID().uuidString).sqlite")
  defer {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }
  try await body(url)
}

private let v2SchemaSQL = """
  CREATE TABLE h2_session_schema_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL) STRICT;
  CREATE TABLE h2_session_batches (batch_id TEXT PRIMARY KEY NOT NULL, logical_date TEXT NOT NULL, time_zone TEXT NOT NULL, boundary_start REAL NOT NULL, boundary_end REAL NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), session_ids TEXT NOT NULL UNIQUE) STRICT;
  CREATE TABLE h2_sessions (session_id TEXT PRIMARY KEY NOT NULL, batch_id TEXT NOT NULL REFERENCES h2_session_batches(batch_id) ON DELETE RESTRICT, started_at REAL NOT NULL, ended_at REAL NOT NULL, display_id TEXT NOT NULL, ending_boundary TEXT, revision INTEGER NOT NULL CHECK (revision > 0), supersedes_id TEXT, payload TEXT NOT NULL) STRICT;
  CREATE TABLE h2_session_membership (session_id TEXT NOT NULL REFERENCES h2_sessions(session_id) ON DELETE RESTRICT, ordinal INTEGER NOT NULL CHECK (ordinal >= 0), event_id TEXT NOT NULL REFERENCES objective_events(id) ON DELETE RESTRICT, PRIMARY KEY(session_id, ordinal), UNIQUE(session_id, event_id)) WITHOUT ROWID, STRICT;
  CREATE INDEX h2_sessions_started_at ON h2_sessions(started_at ASC, session_id ASC);
  INSERT INTO h2_session_schema_metadata(singleton, schema_version) VALUES(1, 2);
  """

private enum SessionSQLiteTestError: Error {
  case open(Int32)
  case execute(Int32, String)
  case query
  case missingValue
}

private func execute(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
  guard result == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw SessionSQLiteTestError.open(result)
  }
  defer { sqlite3_close_v2(database) }

  var message: UnsafeMutablePointer<CChar>?
  let execution = sqlite3_exec(database, sql, nil, nil, &message)
  guard execution == SQLITE_OK else {
    let text = message.map { String(cString: $0) } ?? "SQLite error"
    sqlite3_free(message)
    throw SessionSQLiteTestError.execute(execution, text)
  }
}

private func integer(_ sql: String, at url: URL) throws -> Int64 {
  try scalar(sql, at: url) { sqlite3_column_int64($0, 0) }
}

private func text(_ sql: String, at url: URL) throws -> String {
  try scalar(sql, at: url) { statement in
    guard let value = sqlite3_column_text(statement, 0) else {
      throw SessionSQLiteTestError.missingValue
    }
    return String(cString: value)
  }
}

private func scalar<Value>(
  _ sql: String,
  at url: URL,
  read: (OpaquePointer) throws -> Value
) throws -> Value {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database
  else { throw SessionSQLiteTestError.open(SQLITE_CANTOPEN) }
  defer { sqlite3_close_v2(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw SessionSQLiteTestError.query
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else { throw SessionSQLiteTestError.missingValue }
  return try read(statement)
}
