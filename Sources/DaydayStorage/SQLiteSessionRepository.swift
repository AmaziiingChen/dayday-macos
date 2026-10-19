import CryptoKit
import DaydayCore
import Foundation

public enum SessionStoreError: Error, Equatable, Sendable {
  case corruptedSchema(String)
  case invalidRange
  case invalidStoredSession
  case missingObjectiveEvent
}

/// H2's append-only namespace. It references, but never mutates, H1 objective rows.
public actor SQLiteSessionRepository: SessionRepository {
  public static let currentSchemaVersion = 5

  private let database: SQLiteDatabase
  private static let migrationLock = NSLock()

  private static let metadataV2 =
    "CREATE TABLE h2_session_schema_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL) STRICT"
  private static let metadata =
    "CREATE TABLE h2_session_schema_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL, schema_fingerprint TEXT NOT NULL DEFAULT '') STRICT"
  private static let batches =
    "CREATE TABLE h2_session_batches (batch_id TEXT PRIMARY KEY NOT NULL, logical_date TEXT NOT NULL, time_zone TEXT NOT NULL, boundary_start REAL NOT NULL, boundary_end REAL NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), session_ids TEXT NOT NULL UNIQUE) STRICT"
  private static let sessions =
    "CREATE TABLE h2_sessions (session_id TEXT PRIMARY KEY NOT NULL, batch_id TEXT NOT NULL REFERENCES h2_session_batches(batch_id) ON DELETE RESTRICT, started_at REAL NOT NULL, ended_at REAL NOT NULL, display_id TEXT NOT NULL, ending_boundary TEXT, revision INTEGER NOT NULL CHECK (revision > 0), supersedes_id TEXT, payload TEXT NOT NULL) STRICT"
  private static let membership =
    "CREATE TABLE h2_session_membership (session_id TEXT NOT NULL REFERENCES h2_sessions(session_id) ON DELETE RESTRICT, ordinal INTEGER NOT NULL CHECK (ordinal >= 0), event_id TEXT NOT NULL REFERENCES objective_events(id) ON DELETE RESTRICT, PRIMARY KEY(session_id, ordinal), UNIQUE(session_id, event_id)) WITHOUT ROWID, STRICT"
  private static let index =
    "CREATE INDEX h2_sessions_started_at ON h2_sessions(started_at ASC, session_id ASC)"
  private static let dayRevisionIndex =
    "CREATE UNIQUE INDEX h2_session_batches_day_revision ON h2_session_batches(logical_date ASC, time_zone ASC, boundary_start ASC, boundary_end ASC, revision ASC)"
  private static let v2Definitions = [metadataV2, batches, sessions, membership, index]
  private static let v3Definitions = [metadata, batches, sessions, membership, index]
  private static let definitions = [
    metadata, batches, sessions, membership, index, dayRevisionIndex,
  ]
  private static let v2Fingerprint = fingerprint(of: v2Definitions)
  static let expectedSchemaFingerprint = fingerprint(of: definitions)

  init(location: SQLiteDatabaseLocation) throws {
    database = try Self.migrationLock.withLock {
      let database = try SQLiteDatabase(location: location)
      do {
        try Self.migrate(database)
        return database
      } catch {
        database.close()
        throw error
      }
    }
  }

  public func save(_ batch: SessionDerivationBatch) throws -> SessionBatchSaveResult {
    guard let storageRevision = Int64(exactly: batch.derivationRevision) else {
      return .conflict
    }
    return try database.transaction {
      let identity = try Self.batchIdentity(batch)
      if try Self.batchExists(identity, database: database) {
        do {
          let isExactReplay = try Self.isExactStoredReplay(
            batch,
            storageRevision: storageRevision,
            identity: identity,
            database: database
          )
          return isExactReplay ? SessionBatchSaveResult.alreadyPresent : .conflict
        } catch {
          return .conflict
        }
      }

      for session in batch.sessions {
        guard try Self.session(id: session.id, database: database) == nil else {
          return .conflict
        }
      }

      let orderedSessions = Self.canonicalSessions(in: batch)
      let insertBatch = try database.prepare(
        "INSERT INTO h2_session_batches(batch_id,logical_date,time_zone,boundary_start,boundary_end,revision,session_ids) VALUES(?,?,?,?,?,?,?)"
      )
      let date = batch.day.logicalDate
      try insertBatch.bind(identity, at: 1)
      try insertBatch.bind(
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day), at: 2)
      try insertBatch.bind(batch.day.timeZoneIdentifier, at: 3)
      try insertBatch.bind(batch.day.boundary.startsAt.timeIntervalSinceReferenceDate, at: 4)
      try insertBatch.bind(batch.day.boundary.endsAt.timeIntervalSinceReferenceDate, at: 5)
      try insertBatch.bind(storageRevision, at: 6)
      try insertBatch.bind(Self.serializedSessionIDs(orderedSessions), at: 7)
      try insertBatch.expectDone()

      for session in orderedSessions {
        try Self.insert(session, batchID: identity, database: database)
      }
      return .inserted
    }
  }

  public func sessions(startedIn range: Range<Date>) throws -> [Session] {
    guard
      range.lowerBound < range.upperBound,
      range.lowerBound.timeIntervalSinceReferenceDate.isFinite,
      range.upperBound.timeIntervalSinceReferenceDate.isFinite
    else {
      throw SessionStoreError.invalidRange
    }

    let statement = try database.prepare(
      "SELECT session_id FROM h2_sessions WHERE started_at >= ? AND started_at < ? ORDER BY started_at ASC, session_id ASC"
    )
    try statement.bind(range.lowerBound.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(range.upperBound.timeIntervalSinceReferenceDate, at: 2)

    var result: [Session] = []
    while try statement.stepRow() {
      guard let uuid = UUID(uuidString: try statement.requiredText(at: 0, column: "session_id")),
        let session = try Self.session(id: .init(rawValue: uuid), database: database)
      else {
        throw SessionStoreError.invalidStoredSession
      }
      result.append(session)
    }
    return result
  }

  private static func batchExists(_ identity: String, database: SQLiteDatabase) throws -> Bool {
    let statement = try database.prepare(
      "SELECT batch_id FROM h2_session_batches WHERE batch_id = ?")
    try statement.bind(identity, at: 1)
    guard try statement.stepRow() else { return false }
    guard !(try statement.stepRow()) else { throw SessionStoreError.invalidStoredSession }
    return true
  }

  private static func isExactStoredReplay(
    _ batch: SessionDerivationBatch,
    storageRevision: Int64,
    identity: String,
    database: SQLiteDatabase
  ) throws -> Bool {
    let statement = try database.prepare(
      "SELECT logical_date,time_zone,boundary_start,boundary_end,revision,session_ids FROM h2_session_batches WHERE batch_id = ?"
    )
    try statement.bind(identity, at: 1)
    guard try statement.stepRow() else { return false }

    let date = batch.day.logicalDate
    let storedDate = try statement.requiredText(at: 0, column: "logical_date")
    let storedTimeZone = try statement.requiredText(at: 1, column: "time_zone")
    let storedStart = try statement.requiredDouble(at: 2, column: "boundary_start")
    let storedEnd = try statement.requiredDouble(at: 3, column: "boundary_end")
    let storedRevision = try statement.requiredInt64(at: 4, column: "revision")
    let storedSessionIDs = try statement.requiredText(at: 5, column: "session_ids")
    guard !(try statement.stepRow()) else { throw SessionStoreError.invalidStoredSession }

    let orderedSessions = Self.canonicalSessions(in: batch)
    guard
      storedDate == String(format: "%04d-%02d-%02d", date.year, date.month, date.day),
      storedTimeZone == batch.day.timeZoneIdentifier,
      storedStart == batch.day.boundary.startsAt.timeIntervalSinceReferenceDate,
      storedEnd == batch.day.boundary.endsAt.timeIntervalSinceReferenceDate,
      storedRevision == storageRevision,
      storedSessionIDs == Self.serializedSessionIDs(orderedSessions)
    else {
      return false
    }

    let count = try database.prepare("SELECT COUNT(*) FROM h2_sessions WHERE batch_id = ?")
    try count.bind(identity, at: 1)
    guard try count.stepRow(),
      try count.requiredInt64(at: 0, column: "session_count") == Int64(orderedSessions.count),
      !(try count.stepRow())
    else {
      throw SessionStoreError.invalidStoredSession
    }

    for session in orderedSessions {
      guard try Self.session(id: session.id, database: database) == session else { return false }
    }
    return true
  }

  private static func insert(_ session: Session, batchID: String, database: SQLiteDatabase) throws {
    let statement = try database.prepare(
      "INSERT INTO h2_sessions(session_id,batch_id,started_at,ended_at,display_id,ending_boundary,revision,supersedes_id,payload) VALUES(?,?,?,?,?,?,?,?,?)"
    )
    try statement.bind(session.id.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(batchID, at: 2)
    try statement.bind(session.startedAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(session.endedAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(Self.storageKey(for: session.scope), at: 5)
    if let reason = session.endingHardBoundary {
      try statement.bind(reason.rawValue, at: 6)
    } else {
      try statement.bindNull(at: 6)
    }
    try statement.bind(Int64(session.lineage.derivationRevision), at: 7)
    if let identifier = session.lineage.supersedesSessionID {
      try statement.bind(identifier.rawValue.uuidString.lowercased(), at: 8)
    } else {
      try statement.bindNull(at: 8)
    }
    try statement.bind(try payload(session), at: 9)
    try statement.expectDone()

    for (ordinal, event) in session.objectiveEventIDs.enumerated() {
      let membership = try database.prepare(
        "INSERT INTO h2_session_membership(session_id,ordinal,event_id) VALUES(?,?,?)"
      )
      try membership.bind(session.id.rawValue.uuidString.lowercased(), at: 1)
      try membership.bind(Int64(ordinal), at: 2)
      try membership.bind(event.rawValue.uuidString.lowercased(), at: 3)
      do {
        try membership.expectDone()
      } catch {
        throw SessionStoreError.missingObjectiveEvent
      }
    }
  }

  private static func session(id: SessionID, database: SQLiteDatabase) throws -> Session? {
    let statement = try database.prepare(
      "SELECT started_at,ended_at,display_id,ending_boundary,revision,supersedes_id,payload FROM h2_sessions WHERE session_id = ?"
    )
    try statement.bind(id.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }

    let started = try statement.requiredDouble(at: 0, column: "started_at")
    let ended = try statement.requiredDouble(at: 1, column: "ended_at")
    let display = try statement.requiredText(at: 2, column: "display_id")
    let boundary =
      statement.isNull(at: 3)
      ? nil : try statement.requiredText(at: 3, column: "ending_boundary")
    let revision = try statement.requiredInt64(at: 4, column: "revision")
    let supersedes =
      statement.isNull(at: 5)
      ? nil : try statement.requiredText(at: 5, column: "supersedes_id")
    let value = try decode(Session.self, try statement.requiredText(at: 6, column: "payload"))
    guard
      value.id == id,
      value.startedAt.timeIntervalSinceReferenceDate == started,
      value.endedAt.timeIntervalSinceReferenceDate == ended,
      Self.storageKey(for: value.scope) == display.lowercased(),
      value.endingHardBoundary?.rawValue == boundary,
      UInt64(exactly: revision) == value.lineage.derivationRevision,
      value.lineage.supersedesSessionID?.rawValue.uuidString.lowercased()
        == supersedes?.lowercased(),
      !(try statement.stepRow())
    else {
      throw SessionStoreError.invalidStoredSession
    }

    let membership = try database.prepare(
      "SELECT event_id FROM h2_session_membership WHERE session_id = ? ORDER BY ordinal ASC"
    )
    try membership.bind(id.rawValue.uuidString.lowercased(), at: 1)
    var identifiers: [EventID] = []
    while try membership.stepRow() {
      guard let raw = UUID(uuidString: try membership.requiredText(at: 0, column: "event_id"))
      else {
        throw SessionStoreError.invalidStoredSession
      }
      identifiers.append(.init(rawValue: raw))
    }
    guard identifiers == value.objectiveEventIDs else {
      throw SessionStoreError.invalidStoredSession
    }
    return value
  }

  private static func canonicalSessions(in batch: SessionDerivationBatch) -> [Session] {
    batch.sessions.sorted {
      if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
      if $0.endedAt != $1.endedAt { return $0.endedAt < $1.endedAt }
      return $0.id.rawValue.uuidString.lowercased() < $1.id.rawValue.uuidString.lowercased()
    }
  }

  private static func storageKey(for scope: SessionScope) -> String {
    switch scope {
    case .workspace: return "workspace"
    case .display(let displayID): return displayID.rawValue.uuidString.lowercased()
    }
  }

  private static func serializedSessionIDs(_ sessions: [Session]) -> String {
    sessions.map { $0.id.rawValue.uuidString.lowercased() }.joined(separator: "|")
  }

  private static func batchIdentity(_ batch: SessionDerivationBatch) throws -> String {
    let orderedSessions = canonicalSessions(in: batch)
    let date = batch.day.logicalDate
    let envelope = BatchIdentityEnvelope(
      logicalDate: String(format: "%04d-%02d-%02d", date.year, date.month, date.day),
      timeZoneIdentifier: batch.day.timeZoneIdentifier,
      boundaryStart: batch.day.boundary.startsAt.timeIntervalSinceReferenceDate,
      boundaryEnd: batch.day.boundary.endsAt.timeIntervalSinceReferenceDate,
      derivationRevision: batch.derivationRevision,
      sessionIDs: orderedSessions.map { $0.id.rawValue.uuidString.lowercased() }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let digest = SHA256.hash(data: try encoder.encode(envelope))
    return "h2-session-batch-v1-" + digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "h2_session")
      if names.isEmpty {
        try database.execute(metadata)
        try database.execute(batches)
        try database.execute(sessions)
        try database.execute(membership)
        try database.execute(index)
        try database.execute(dayRevisionIndex)
        try database.execute(
          "INSERT INTO h2_session_schema_metadata(singleton,schema_version,schema_fingerprint) VALUES(1,5,'')"
        )
        let fingerprint = try database.prepare(
          "UPDATE h2_session_schema_metadata SET schema_fingerprint = ? WHERE singleton = 1"
        )
        try fingerprint.bind(expectedSchemaFingerprint, at: 1)
        try fingerprint.expectDone()
      }

      let version = try schemaVersion(database)
      switch version {
      case 1:
        throw SessionStoreError.corruptedSchema(
          "Development-only H2 session schema version 1 cannot be migrated"
        )
      case 2:
        guard try schemaFingerprint(of: database, definitions: v2Definitions) == v2Fingerprint
        else {
          throw SessionStoreError.corruptedSchema("Schema fingerprint mismatch")
        }
        try migrateV2ToV3(database)
        try migrateV3ToV4(database)
        try migrateV4ToV5(database)
      case 3:
        guard
          try schemaFingerprint(of: database, definitions: v3Definitions)
            == fingerprint(of: v3Definitions)
        else { throw SessionStoreError.corruptedSchema("Schema fingerprint mismatch") }
        try migrateV3ToV4(database)
        try migrateV4ToV5(database)
      case 4:
        guard try storedFingerprint(database) == expectedSchemaFingerprint,
          try schemaFingerprint(of: database, definitions: definitions) == expectedSchemaFingerprint
        else { throw SessionStoreError.corruptedSchema("Schema fingerprint mismatch") }
        try migrateV4ToV5(database)
      case currentSchemaVersion:
        break
      default:
        throw SessionStoreError.corruptedSchema("Unsupported session schema version")
      }

      guard try schemaVersion(database) == currentSchemaVersion,
        try storedFingerprint(database) == expectedSchemaFingerprint,
        try schemaFingerprint(of: database, definitions: definitions) == expectedSchemaFingerprint
      else { throw SessionStoreError.corruptedSchema("Invalid session schema") }
    }
  }

  private static func migrateV2ToV3(_ database: SQLiteDatabase) throws {
    try database.execute(
      "ALTER TABLE h2_session_schema_metadata ADD COLUMN schema_fingerprint TEXT NOT NULL DEFAULT ''"
    )
    let statement = try database.prepare(
      "UPDATE h2_session_schema_metadata SET schema_version = 3, schema_fingerprint = ? WHERE singleton = 1 AND schema_version = 2"
    )
    try statement.bind(fingerprint(of: v3Definitions), at: 1)
    try statement.expectDone()
    guard database.changedRowCount == 1 else {
      throw SessionStoreError.corruptedSchema("Invalid v2 session schema metadata")
    }
  }

  private static func migrateV3ToV4(_ database: SQLiteDatabase) throws {
    try database.execute(dayRevisionIndex)
    let statement = try database.prepare(
      "UPDATE h2_session_schema_metadata SET schema_version=4, schema_fingerprint=? WHERE singleton=1 AND schema_version=3"
    )
    try statement.bind(expectedSchemaFingerprint, at: 1)
    try statement.expectDone()
    guard database.changedRowCount == 1 else {
      throw SessionStoreError.corruptedSchema("Invalid v3 session schema metadata")
    }
  }

  /// V5 keeps the physical column shape and broadens `display_id` into a closed lane key. UUIDs
  /// remain display-local V1 rows; the literal `workspace` is admitted only when the V2 payload
  /// independently decodes to `SessionScope.workspace`.
  private static func migrateV4ToV5(_ database: SQLiteDatabase) throws {
    let statement = try database.prepare(
      "UPDATE h2_session_schema_metadata SET schema_version=5, schema_fingerprint=? WHERE singleton=1 AND schema_version=4"
    )
    try statement.bind(expectedSchemaFingerprint, at: 1)
    try statement.expectDone()
    guard database.changedRowCount == 1 else {
      throw SessionStoreError.corruptedSchema("Invalid v4 session schema metadata")
    }
  }

  private static func schemaVersion(_ database: SQLiteDatabase) throws -> Int {
    let statement = try database.prepare(
      "SELECT schema_version FROM h2_session_schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow(),
      let version = Int(exactly: try statement.requiredInt64(at: 0, column: "schema_version")),
      !(try statement.stepRow())
    else { throw SessionStoreError.corruptedSchema("Invalid session schema metadata") }
    return version
  }

  private static func storedFingerprint(_ database: SQLiteDatabase) throws -> String {
    let statement = try database.prepare(
      "SELECT schema_fingerprint FROM h2_session_schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow(),
      let fingerprint = try? statement.requiredText(at: 0, column: "schema_fingerprint"),
      !(try statement.stepRow())
    else { throw SessionStoreError.corruptedSchema("Invalid session schema fingerprint") }
    return fingerprint
  }

  private static func schemaFingerprint(
    of database: SQLiteDatabase,
    definitions: [String]
  ) throws -> String {
    let objects =
      [
        (type: "table", name: "h2_session_schema_metadata"),
        (type: "table", name: "h2_session_batches"),
        (type: "table", name: "h2_sessions"),
        (type: "table", name: "h2_session_membership"),
        (type: "index", name: "h2_sessions_started_at"),
      ] + (definitions.count == 6 ? [(type: "index", name: "h2_session_batches_day_revision")] : [])
    let expectedNames = objects.map(\.name).sorted()
    guard try database.schemaObjectNames(withPrefix: "h2_session") == expectedNames else {
      throw SessionStoreError.corruptedSchema("Unexpected H2 session schema object set")
    }

    var actualDefinitions: [String] = []
    for (object, expected) in zip(objects, definitions) {
      guard let actual = try database.schemaSQL(type: object.type, name: object.name),
        normalizedSQL(actual) == normalizedSQL(expected)
      else {
        throw SessionStoreError.corruptedSchema(
          "Unexpected H2 session schema object definition: \(object.name)"
        )
      }
      actualDefinitions.append(actual)
    }
    return fingerprint(of: actualDefinitions)
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

  private static func payload<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: Data(text.utf8))
    } catch {
      throw SessionStoreError.invalidStoredSession
    }
  }
}

private struct BatchIdentityEnvelope: Encodable {
  let logicalDate: String
  let timeZoneIdentifier: String
  let boundaryStart: TimeInterval
  let boundaryEnd: TimeInterval
  let derivationRevision: UInt64
  let sessionIDs: [String]
}
