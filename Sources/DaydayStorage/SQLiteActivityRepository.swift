import CryptoKit
import DaydayCore
import Foundation

public enum ActivityStoreError: Error, Equatable, Sendable {
  case corruptedSchema(String)
  case invalidRange
  case invalidStoredActivity
  case missingSession
}

/// H2's append-only store for deterministic provisional Activity interpretations.
public actor SQLiteActivityRepository: ActivityRepository {
  public static let currentSchemaVersion = 2
  private static let migrationLock = NSLock()
  private let database: SQLiteDatabase

  private static let metadata =
    "CREATE TABLE h2_activity_schema_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL, schema_fingerprint TEXT NOT NULL) STRICT"
  private static let batches =
    "CREATE TABLE h2_activity_batches (batch_id TEXT PRIMARY KEY NOT NULL, session_batch_id TEXT NOT NULL REFERENCES h2_session_batches(batch_id) ON DELETE RESTRICT, logical_date TEXT NOT NULL, time_zone TEXT NOT NULL, boundary_start REAL NOT NULL, boundary_end REAL NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), activity_ids TEXT NOT NULL UNIQUE, UNIQUE(logical_date,time_zone,boundary_start,boundary_end,revision)) STRICT"
  private static let activities =
    "CREATE TABLE h2_activity_records (activity_id TEXT PRIMARY KEY NOT NULL, batch_id TEXT NOT NULL REFERENCES h2_activity_batches(batch_id) ON DELETE RESTRICT, started_at REAL NOT NULL, ended_at REAL NOT NULL, payload TEXT NOT NULL) STRICT"
  private static let membership =
    "CREATE TABLE h2_activity_membership (activity_id TEXT NOT NULL REFERENCES h2_activity_records(activity_id) ON DELETE RESTRICT, ordinal INTEGER NOT NULL CHECK(ordinal >= 0), session_id TEXT NOT NULL REFERENCES h2_sessions(session_id) ON DELETE RESTRICT, PRIMARY KEY(activity_id, ordinal), UNIQUE(activity_id, session_id)) WITHOUT ROWID, STRICT"
  private static let index =
    "CREATE INDEX h2_activity_records_started_at ON h2_activity_records(started_at ASC, activity_id ASC)"
  private static let v1Definitions = [
    metadata,
    "CREATE TABLE h2_activity_batches (batch_id TEXT PRIMARY KEY NOT NULL, logical_date TEXT NOT NULL, time_zone TEXT NOT NULL, boundary_start REAL NOT NULL, boundary_end REAL NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), activity_ids TEXT NOT NULL UNIQUE) STRICT",
    activities, membership, index,
  ]
  private static let definitions = [metadata, batches, activities, membership, index]
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

  public func save(_ batch: ActivityDerivationBatch) throws -> ActivityBatchSaveResult {
    guard let revision = Int64(exactly: batch.derivationRevision) else { return .conflict }
    return try database.transaction {
      let identity = try Self.batchIdentity(batch)
      if try Self.batchExists(identity, database: database) {
        do {
          return try Self.exactReplay(
            batch, identity: identity, revision: revision, database: database)
            ? .alreadyPresent : .conflict
        } catch { return .conflict }
      }
      for activity in batch.activities
      where try Self.activity(id: activity.id, database: database) != nil { return .conflict }
      let ordered = Self.canonical(batch.activities)
      let sessionBatchID = try Self.sessionBatchID(for: batch, database: database)
      let statement = try database.prepare(
        "INSERT INTO h2_activity_batches(batch_id,session_batch_id,logical_date,time_zone,boundary_start,boundary_end,revision,activity_ids) VALUES(?,?,?,?,?,?,?,?)"
      )
      let date = batch.day.logicalDate
      try statement.bind(identity, at: 1)
      try statement.bind(sessionBatchID, at: 2)
      try statement.bind(String(format: "%04d-%02d-%02d", date.year, date.month, date.day), at: 3)
      try statement.bind(batch.day.timeZoneIdentifier, at: 4)
      try statement.bind(batch.day.boundary.startsAt.timeIntervalSinceReferenceDate, at: 5)
      try statement.bind(batch.day.boundary.endsAt.timeIntervalSinceReferenceDate, at: 6)
      try statement.bind(revision, at: 7)
      try statement.bind(Self.serializedIDs(ordered), at: 8)
      try statement.expectDone()
      for value in ordered { try Self.insert(value, batchID: identity, database: database) }
      return .inserted
    }
  }

  public func activities(startedIn range: Range<Date>) throws -> [Activity] {
    guard range.lowerBound < range.upperBound,
      range.lowerBound.timeIntervalSinceReferenceDate.isFinite,
      range.upperBound.timeIntervalSinceReferenceDate.isFinite
    else { throw ActivityStoreError.invalidRange }
    let statement = try database.prepare(
      "SELECT activity_id FROM h2_activity_records WHERE started_at >= ? AND started_at < ? ORDER BY started_at ASC, activity_id ASC"
    )
    try statement.bind(range.lowerBound.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(range.upperBound.timeIntervalSinceReferenceDate, at: 2)
    var values: [Activity] = []
    while try statement.stepRow() {
      guard let id = UUID(uuidString: try statement.requiredText(at: 0, column: "activity_id")),
        let value = try Self.activity(id: .init(rawValue: id), database: database)
      else { throw ActivityStoreError.invalidStoredActivity }
      values.append(value)
    }
    return values
  }

  private static func exactReplay(
    _ batch: ActivityDerivationBatch, identity: String, revision: Int64, database: SQLiteDatabase
  ) throws -> Bool {
    let statement = try database.prepare(
      "SELECT logical_date,time_zone,boundary_start,boundary_end,revision,activity_ids FROM h2_activity_batches WHERE batch_id=?"
    )
    try statement.bind(identity, at: 1)
    guard try statement.stepRow() else { return false }
    let date = batch.day.logicalDate
    let ordered = canonical(batch.activities)
    guard
      try statement.requiredText(at: 0, column: "logical_date")
        == String(format: "%04d-%02d-%02d", date.year, date.month, date.day),
      try statement.requiredText(at: 1, column: "time_zone") == batch.day.timeZoneIdentifier,
      try statement.requiredDouble(at: 2, column: "boundary_start")
        == batch.day.boundary.startsAt.timeIntervalSinceReferenceDate,
      try statement.requiredDouble(at: 3, column: "boundary_end")
        == batch.day.boundary.endsAt.timeIntervalSinceReferenceDate,
      try statement.requiredInt64(at: 4, column: "revision") == revision,
      try statement.requiredText(at: 5, column: "activity_ids") == serializedIDs(ordered),
      !(try statement.stepRow())
    else { return false }
    let count = try database.prepare("SELECT COUNT(*) FROM h2_activity_records WHERE batch_id=?")
    try count.bind(identity, at: 1)
    guard try count.stepRow(),
      try count.requiredInt64(at: 0, column: "count") == Int64(ordered.count)
    else { return false }
    return try ordered.allSatisfy { try activity(id: $0.id, database: database) == $0 }
  }

  private static func insert(_ value: Activity, batchID: String, database: SQLiteDatabase) throws {
    let statement = try database.prepare(
      "INSERT INTO h2_activity_records(activity_id,batch_id,started_at,ended_at,payload) VALUES(?,?,?,?,?)"
    )
    try statement.bind(value.id.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(batchID, at: 2)
    try statement.bind(value.startedAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(value.endedAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(try payload(value), at: 5)
    try statement.expectDone()
    for (ordinal, session) in value.sessionIDs.enumerated() {
      do {
        let membership = try database.prepare(
          "INSERT INTO h2_activity_membership(activity_id,ordinal,session_id) VALUES(?,?,?)")
        try membership.bind(value.id.rawValue.uuidString.lowercased(), at: 1)
        try membership.bind(Int64(ordinal), at: 2)
        try membership.bind(session.rawValue.uuidString.lowercased(), at: 3)
        try membership.expectDone()
      } catch { throw ActivityStoreError.missingSession }
    }
  }

  private static func activity(id: ActivityID, database: SQLiteDatabase) throws -> Activity? {
    let statement = try database.prepare(
      "SELECT started_at,ended_at,payload FROM h2_activity_records WHERE activity_id=?")
    try statement.bind(id.rawValue.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    let started = try statement.requiredDouble(at: 0, column: "started_at")
    let ended = try statement.requiredDouble(at: 1, column: "ended_at")
    let value = try decode(Activity.self, try statement.requiredText(at: 2, column: "payload"))
    guard value.id == id, value.startedAt.timeIntervalSinceReferenceDate == started,
      value.endedAt.timeIntervalSinceReferenceDate == ended,
      value.interpretation.origin == .deterministicRule, value.confidence == .low,
      value.reviewState == .needsReview, value.evidenceReferences.isEmpty,
      !(try statement.stepRow())
    else { throw ActivityStoreError.invalidStoredActivity }
    let members = try database.prepare(
      "SELECT session_id FROM h2_activity_membership WHERE activity_id=? ORDER BY ordinal ASC")
    try members.bind(id.rawValue.uuidString.lowercased(), at: 1)
    var ids: [SessionID] = []
    while try members.stepRow() {
      guard let raw = UUID(uuidString: try members.requiredText(at: 0, column: "session_id")) else {
        throw ActivityStoreError.invalidStoredActivity
      }
      ids.append(.init(rawValue: raw))
    }
    guard ids == value.sessionIDs else { throw ActivityStoreError.invalidStoredActivity }
    return value
  }

  private static func batchExists(_ id: String, database: SQLiteDatabase) throws -> Bool {
    let statement = try database.prepare(
      "SELECT batch_id FROM h2_activity_batches WHERE batch_id=?")
    try statement.bind(id, at: 1)
    return try statement.stepRow()
  }
  private static func sessionBatchID(for batch: ActivityDerivationBatch, database: SQLiteDatabase)
    throws -> String
  {
    let ids = Set(batch.activities.flatMap(\.sessionIDs))
    var candidates: Set<String> = []
    for id in ids {
      let statement = try database.prepare(
        "SELECT s.batch_id FROM h2_sessions s JOIN h2_session_batches b ON b.batch_id=s.batch_id WHERE s.session_id=? AND b.logical_date=? AND b.time_zone=? AND b.boundary_start=? AND b.boundary_end=? AND b.revision=?"
      )
      try statement.bind(id.rawValue.uuidString.lowercased(), at: 1)
      let date = batch.day.logicalDate
      try statement.bind(String(format: "%04d-%02d-%02d", date.year, date.month, date.day), at: 2)
      try statement.bind(batch.day.timeZoneIdentifier, at: 3)
      try statement.bind(batch.day.boundary.startsAt.timeIntervalSinceReferenceDate, at: 4)
      try statement.bind(batch.day.boundary.endsAt.timeIntervalSinceReferenceDate, at: 5)
      try statement.bind(Int64(batch.derivationRevision), at: 6)
      guard try statement.stepRow() else { throw ActivityStoreError.missingSession }
      candidates.insert(try statement.requiredText(at: 0, column: "batch_id"))
      guard !(try statement.stepRow()) else { throw ActivityStoreError.missingSession }
    }
    guard candidates.count == 1, let value = candidates.first else {
      throw ActivityStoreError.missingSession
    }
    return value
  }
  private static func canonical(_ activities: [Activity]) -> [Activity] {
    activities.sorted {
      $0.startedAt != $1.startedAt
        ? $0.startedAt < $1.startedAt : $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
    }
  }
  private static func serializedIDs(_ activities: [Activity]) -> String {
    activities.map { $0.id.rawValue.uuidString.lowercased() }.joined(separator: "|")
  }
  private static func batchIdentity(_ batch: ActivityDerivationBatch) throws -> String {
    let date = batch.day.logicalDate
    let envelope = ActivityBatchIdentityEnvelope(
      logicalDate: String(format: "%04d-%02d-%02d", date.year, date.month, date.day),
      timeZoneIdentifier: batch.day.timeZoneIdentifier,
      boundaryStart: batch.day.boundary.startsAt.timeIntervalSinceReferenceDate,
      boundaryEnd: batch.day.boundary.endsAt.timeIntervalSinceReferenceDate,
      derivationRevision: batch.derivationRevision,
      activityIDs: canonical(batch.activities).map { $0.id.rawValue.uuidString.lowercased() }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return "h2-activity-v1-"
      + SHA256.hash(data: try encoder.encode(envelope)).map {
        String(format: "%02x", $0)
      }.joined()
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "h2_activity")
      if names.isEmpty {
        try database.execute(metadata)
        try database.execute(batches)
        try database.execute(activities)
        try database.execute(membership)
        try database.execute(index)
        let statement = try database.prepare(
          "INSERT INTO h2_activity_schema_metadata(singleton,schema_version,schema_fingerprint) VALUES(1,2,?)"
        )
        try statement.bind(expectedSchemaFingerprint, at: 1)
        try statement.expectDone()
      }
      let metadataRow = try database.prepare(
        "SELECT schema_version,schema_fingerprint FROM h2_activity_schema_metadata WHERE singleton=1"
      )
      guard try metadataRow.stepRow(),
        let version = Int(exactly: try metadataRow.requiredInt64(at: 0, column: "schema_version")),
        !(try metadataRow.stepRow())
      else { throw ActivityStoreError.corruptedSchema("Invalid activity schema metadata") }
      if version == 1 {
        guard try metadataFingerprint(database) == fingerprint(of: v1Definitions) else {
          throw ActivityStoreError.corruptedSchema("Invalid v1 activity schema")
        }
        try migrateV1ToV2(database)
      }
      guard version == 1 || version == currentSchemaVersion,
        try metadataFingerprint(database) == expectedSchemaFingerprint
      else { throw ActivityStoreError.corruptedSchema("Invalid activity schema metadata") }
      let objects = [
        ("table", "h2_activity_schema_metadata"), ("table", "h2_activity_batches"),
        ("table", "h2_activity_records"), ("table", "h2_activity_membership"),
        ("index", "h2_activity_records_started_at"),
      ]
      guard try database.schemaObjectNames(withPrefix: "h2_activity") == objects.map(\.1).sorted()
      else { throw ActivityStoreError.corruptedSchema("Unexpected activity schema object set") }
      var actual: [String] = []
      for (object, expected) in zip(objects, definitions) {
        guard let sql = try database.schemaSQL(type: object.0, name: object.1),
          normalizedSQL(sql) == normalizedSQL(expected)
        else { throw ActivityStoreError.corruptedSchema("Unexpected activity schema definition") }
        actual.append(sql)
      }
      guard fingerprint(of: actual) == expectedSchemaFingerprint else {
        throw ActivityStoreError.corruptedSchema("Activity schema fingerprint mismatch")
      }
    }
  }
  private static func metadataFingerprint(_ database: SQLiteDatabase) throws -> String {
    let statement = try database.prepare(
      "SELECT schema_fingerprint FROM h2_activity_schema_metadata WHERE singleton=1")
    guard try statement.stepRow(),
      let value = try? statement.requiredText(at: 0, column: "schema_fingerprint"),
      !(try statement.stepRow())
    else { throw ActivityStoreError.corruptedSchema("Invalid activity schema metadata") }
    return value
  }
  private static func migrateV1ToV2(_ database: SQLiteDatabase) throws {
    let missing = try database.prepare(
      "SELECT b.batch_id FROM h2_activity_batches b WHERE NOT EXISTS (SELECT 1 FROM h2_activity_records r JOIN h2_activity_membership m ON m.activity_id=r.activity_id WHERE r.batch_id=b.batch_id)"
    )
    guard !(try missing.stepRow()) else {
      throw ActivityStoreError.corruptedSchema("Incomplete legacy activity batch")
    }
    let ambiguous = try database.prepare(
      "SELECT r.batch_id FROM h2_activity_records r JOIN h2_activity_membership m ON m.activity_id=r.activity_id JOIN h2_sessions s ON s.session_id=m.session_id GROUP BY r.batch_id HAVING COUNT(DISTINCT s.batch_id) != 1"
    )
    guard !(try ambiguous.stepRow()) else {
      throw ActivityStoreError.corruptedSchema("Ambiguous legacy activity batch")
    }
    let mismatched = try database.prepare(
      "SELECT b.batch_id FROM h2_activity_batches b JOIN h2_activity_records r ON r.batch_id=b.batch_id JOIN h2_activity_membership m ON m.activity_id=r.activity_id JOIN h2_sessions s ON s.session_id=m.session_id JOIN h2_session_batches sb ON sb.batch_id=s.batch_id WHERE sb.logical_date != b.logical_date OR sb.time_zone != b.time_zone OR sb.boundary_start != b.boundary_start OR sb.boundary_end != b.boundary_end OR sb.revision != b.revision LIMIT 1"
    )
    guard !(try mismatched.stepRow()) else {
      throw ActivityStoreError.corruptedSchema("Legacy activity batch does not match Session batch")
    }
    try database.execute("DROP INDEX h2_activity_records_started_at")
    try database.execute("ALTER TABLE h2_activity_membership RENAME TO h2_activity_membership_v1")
    try database.execute("ALTER TABLE h2_activity_records RENAME TO h2_activity_records_v1")
    try database.execute("ALTER TABLE h2_activity_batches RENAME TO h2_activity_batches_v1")
    try database.execute(batches)
    try database.execute(activities)
    try database.execute(membership)
    try database.execute(index)
    try database.execute(
      "INSERT INTO h2_activity_batches(batch_id,session_batch_id,logical_date,time_zone,boundary_start,boundary_end,revision,activity_ids) SELECT b.batch_id,MIN(s.batch_id),b.logical_date,b.time_zone,b.boundary_start,b.boundary_end,b.revision,b.activity_ids FROM h2_activity_batches_v1 b JOIN h2_activity_records_v1 r ON r.batch_id=b.batch_id JOIN h2_activity_membership_v1 m ON m.activity_id=r.activity_id JOIN h2_sessions s ON s.session_id=m.session_id GROUP BY b.batch_id"
    )
    try database.execute(
      "INSERT INTO h2_activity_records SELECT activity_id,batch_id,started_at,ended_at,payload FROM h2_activity_records_v1"
    )
    try database.execute(
      "INSERT INTO h2_activity_membership SELECT activity_id,ordinal,session_id FROM h2_activity_membership_v1"
    )
    try database.execute("DROP TABLE h2_activity_membership_v1")
    try database.execute("DROP TABLE h2_activity_records_v1")
    try database.execute("DROP TABLE h2_activity_batches_v1")
    try database.execute(
      "UPDATE h2_activity_schema_metadata SET schema_version=2,schema_fingerprint='"
        + expectedSchemaFingerprint + "' WHERE singleton=1")
  }
  private static func normalizedSQL(_ value: String) -> String {
    value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
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
  private static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    do { return try JSONDecoder().decode(type, from: Data(value.utf8)) } catch {
      throw ActivityStoreError.invalidStoredActivity
    }
  }
}

private struct ActivityBatchIdentityEnvelope: Encodable {
  let logicalDate: String
  let timeZoneIdentifier: String
  let boundaryStart: TimeInterval
  let boundaryEnd: TimeInterval
  let derivationRevision: UInt64
  let activityIDs: [String]
}
