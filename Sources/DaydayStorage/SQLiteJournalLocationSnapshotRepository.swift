import DaydayCore
import Foundation

public enum JournalLocationSnapshotStoreError: Error, Equatable, Sendable {
  case corruptedSchema(String)
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case invalidStoredPayload
  case insertConflict
}

public actor SQLiteJournalLocationSnapshotRepository: JournalLocationSnapshotRepository {
  public static let currentSchemaVersion = 1
  private static let metadataSQL = """
    CREATE TABLE journal_location_schema_metadata (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      schema_version INTEGER NOT NULL,
      schema_fingerprint TEXT NOT NULL
    ) STRICT
    """
  private static let migrationsSQL = """
    CREATE TABLE journal_location_schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at REAL NOT NULL
    ) STRICT
    """
  private static let snapshotsSQL = """
    CREATE TABLE journal_location_snapshots (
      snapshot_id TEXT PRIMARY KEY NOT NULL,
      entry_id TEXT NOT NULL,
      day_id TEXT NOT NULL,
      captured_at REAL NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let dayIndexSQL =
    "CREATE INDEX journal_location_snapshots_day_captured ON journal_location_snapshots(day_id ASC, captured_at ASC, snapshot_id ASC)"
  public static let expectedSchemaFingerprint = fingerprint(of: [
    metadataSQL, migrationsSQL, snapshotsSQL, dayIndexSQL,
  ])

  private let database: SQLiteDatabase

  init(location: SQLiteDatabaseLocation) throws {
    let database = try SQLiteDatabase(location: location)
    do { try Self.migrate(database) } catch { database.close(); throw error }
    self.database = database
  }

  public func insert(_ snapshot: JournalLocationSnapshot) async throws -> JournalLocationSnapshotInsertResult {
    if let existing = try storedSnapshot(withID: snapshot.id) {
      guard existing == snapshot else { throw JournalLocationSnapshotStoreError.insertConflict }
      return .alreadyPresent
    }
    let statement = try database.prepare(
      "INSERT INTO journal_location_snapshots(snapshot_id, entry_id, day_id, captured_at, payload) VALUES (?, ?, ?, ?, ?)"
    )
    try statement.bind(Self.uuid(snapshot.id.rawValue), at: 1)
    try statement.bind(Self.uuid(snapshot.journalEntryID.rawValue), at: 2)
    try statement.bind(Self.uuid(snapshot.dayID.rawValue), at: 3)
    try statement.bind(snapshot.capturedAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(try Self.canonicalPayload(snapshot), at: 5)
    do { try statement.expectDone(); return .inserted } catch {
      throw JournalLocationSnapshotStoreError.insertConflict
    }
  }

  public func snapshots(for dayID: DayID) async throws -> [JournalLocationSnapshot] {
    let statement = try database.prepare(
      "SELECT snapshot_id, entry_id, day_id, captured_at, payload FROM journal_location_snapshots WHERE day_id = ? ORDER BY captured_at ASC, snapshot_id ASC"
    )
    try statement.bind(Self.uuid(dayID.rawValue), at: 1)
    var snapshots: [JournalLocationSnapshot] = []
    while try statement.stepRow() {
      let id = try statement.requiredText(at: 0, column: "snapshot_id")
      let entry = try statement.requiredText(at: 1, column: "entry_id")
      let day = try statement.requiredText(at: 2, column: "day_id")
      let captured = try statement.requiredDouble(at: 3, column: "captured_at")
      let payload = try statement.requiredText(at: 4, column: "payload")
      guard let snapshot = try Self.decode(JournalLocationSnapshot.self, payload: payload),
        Self.uuid(snapshot.id.rawValue) == id,
        Self.uuid(snapshot.journalEntryID.rawValue) == entry,
        Self.uuid(snapshot.dayID.rawValue) == day,
        snapshot.dayID == dayID,
        snapshot.capturedAt.timeIntervalSinceReferenceDate == captured
      else { throw JournalLocationSnapshotStoreError.invalidStoredPayload }
      snapshots.append(snapshot)
    }
    return snapshots
  }

  public func schemaVersion() async throws -> Int { try Self.metadata(from: database).version }
  public func schemaFingerprint() async throws -> String { try Self.metadata(from: database).fingerprint }

  private func storedSnapshot(withID id: JournalLocationSnapshotID) throws -> JournalLocationSnapshot? {
    let statement = try database.prepare("SELECT payload FROM journal_location_snapshots WHERE snapshot_id = ?")
    try statement.bind(Self.uuid(id.rawValue), at: 1)
    guard try statement.stepRow() else { return nil }
    let payload = try statement.requiredText(at: 0, column: "payload")
    guard !(try statement.stepRow()), let snapshot = try Self.decode(JournalLocationSnapshot.self, payload: payload), snapshot.id == id
    else { throw JournalLocationSnapshotStoreError.invalidStoredPayload }
    return snapshot
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "journal_location")
      if names.isEmpty {
        try database.execute(metadataSQL); try database.execute(migrationsSQL)
        try database.execute(snapshotsSQL); try database.execute(dayIndexSQL)
        let migration = try database.prepare("INSERT INTO journal_location_schema_migrations(version, applied_at) VALUES (1, ?)")
        try migration.bind(Date().timeIntervalSince1970, at: 1); try migration.expectDone()
        let metadata = try database.prepare("INSERT INTO journal_location_schema_metadata(singleton, schema_version, schema_fingerprint) VALUES (1, 1, ?)")
        try metadata.bind(expectedSchemaFingerprint, at: 1); try metadata.expectDone()
      }
      let metadata = try Self.metadata(from: database)
      guard metadata.version <= currentSchemaVersion else {
        throw JournalLocationSnapshotStoreError.unsupportedSchemaVersion(found: metadata.version, supported: currentSchemaVersion)
      }
      guard metadata.version == currentSchemaVersion, metadata.fingerprint == expectedSchemaFingerprint
      else { throw JournalLocationSnapshotStoreError.corruptedSchema("Unexpected schema metadata") }
      let expected = [
        ("table", "journal_location_schema_metadata", metadataSQL),
        ("table", "journal_location_schema_migrations", migrationsSQL),
        ("table", "journal_location_snapshots", snapshotsSQL),
        ("index", "journal_location_snapshots_day_captured", dayIndexSQL),
      ]
      guard try database.schemaObjectNames(withPrefix: "journal_location") == expected.map(\.1).sorted()
      else { throw JournalLocationSnapshotStoreError.corruptedSchema("Unexpected schema objects") }
      for (type, name, sql) in expected {
        guard let found = try database.schemaSQL(type: type, name: name), normalizedSQL(found) == normalizedSQL(sql)
        else { throw JournalLocationSnapshotStoreError.corruptedSchema("Unexpected schema object: \(name)") }
      }
      let migration = try database.prepare("SELECT version FROM journal_location_schema_migrations ORDER BY version ASC")
      guard try migration.stepRow(), try migration.requiredInt64(at: 0, column: "version") == 1, !(try migration.stepRow())
      else { throw JournalLocationSnapshotStoreError.corruptedSchema("Invalid migration journal") }
    }
  }

  private static func metadata(from database: SQLiteDatabase) throws -> (version: Int, fingerprint: String) {
    let statement = try database.prepare("SELECT schema_version, schema_fingerprint FROM journal_location_schema_metadata WHERE singleton = 1")
    guard try statement.stepRow(), let version = Int(exactly: try statement.requiredInt64(at: 0, column: "schema_version"))
    else { throw JournalLocationSnapshotStoreError.corruptedSchema("Missing schema metadata") }
    let fingerprint = try statement.requiredText(at: 1, column: "schema_fingerprint")
    guard !(try statement.stepRow()) else { throw JournalLocationSnapshotStoreError.corruptedSchema("Duplicate schema metadata") }
    return (version, fingerprint)
  }

  private static func canonicalPayload<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let payload = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw JournalLocationSnapshotStoreError.invalidStoredPayload
    }
    return payload
  }
  private static func decode<T: Codable>(_ type: T.Type, payload: String) throws -> T? {
    guard let data = payload.data(using: .utf8), let value = try? JSONDecoder().decode(type, from: data),
      try canonicalPayload(value) == payload
    else { throw JournalLocationSnapshotStoreError.invalidStoredPayload }
    return value
  }
  private static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }
  private static func normalizedSQL(_ sql: String) -> String { sql.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
  private static func fingerprint(of definitions: [String]) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in definitions.map(normalizedSQL).joined(separator: "\n").utf8 { value ^= UInt64(byte); value &*= 1_099_511_628_211 }
    return String(format: "fnv1a64-%016llx", value)
  }
}
