import DaydayCore
import Foundation

public enum JournalFragmentStoreError: Error, Equatable, Sendable {
  case invalidLimit
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case corruptedSchema(String)
  case invalidStoredPayload
  case insertConflict
}

public actor SQLiteJournalFragmentRepository: JournalFragmentRepository {
  public static let currentSchemaVersion = 1

  private static let metadataSQL = """
    CREATE TABLE journal_fragment_schema_metadata (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      schema_version INTEGER NOT NULL,
      schema_fingerprint TEXT NOT NULL
    ) STRICT
    """
  private static let migrationsSQL = """
    CREATE TABLE journal_fragment_schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at REAL NOT NULL
    ) STRICT
    """
  private static let fragmentsSQL = """
    CREATE TABLE journal_fragment_items (
      fragment_id TEXT PRIMARY KEY NOT NULL,
      day_id TEXT NOT NULL,
      created_at REAL NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let fragmentsDayIndexSQL =
    "CREATE INDEX journal_fragment_items_day_created ON journal_fragment_items(day_id ASC, created_at ASC, fragment_id ASC)"
  private static let fragmentsRecentIndexSQL =
    "CREATE INDEX journal_fragment_items_created_at ON journal_fragment_items(created_at DESC, fragment_id ASC)"

  public static let expectedSchemaFingerprint = fingerprint(of: [
    metadataSQL, migrationsSQL, fragmentsSQL, fragmentsDayIndexSQL, fragmentsRecentIndexSQL,
  ])

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

  public func insert(_ fragment: JournalFragment) async throws -> JournalFragmentInsertResult {
    if try await self.fragment(withID: fragment.id.rawValue, atDay: fragment.dayID.rawValue) != nil {
      return .alreadyPresent
    }
    let statement = try database.prepare(
      "INSERT INTO journal_fragment_items(fragment_id, day_id, created_at, payload) VALUES (?, ?, ?, ?)"
    )
    try statement.bind(Self.uuid(fragment.id.rawValue), at: 1)
    try statement.bind(Self.uuid(fragment.dayID.rawValue), at: 2)
    try statement.bind(fragment.createdAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(try Self.canonicalPayload(fragment), at: 4)
    do {
      try statement.expectDone()
      return .inserted
    } catch {
      throw JournalFragmentStoreError.insertConflict
    }
  }

  private func fragment(
    withID fragmentID: UUID,
    atDay dayID: UUID
  ) async throws -> JournalFragment? {
    let statement = try database.prepare(
      "SELECT payload FROM journal_fragment_items WHERE fragment_id = ? AND day_id = ?"
    )
    try statement.bind(Self.uuid(fragmentID), at: 1)
    try statement.bind(Self.uuid(dayID), at: 2)
    guard try statement.stepRow() else { return nil }
    let payload = try statement.requiredText(at: 0, column: "payload")
    guard let fragment = try Self.decode(JournalFragment.self, payload: payload) else {
      throw JournalFragmentStoreError.invalidStoredPayload
    }
    return fragment
  }

  public func fragments(for dayID: DayID) async throws -> [JournalFragment] {
    let statement = try database.prepare(
      "SELECT payload FROM journal_fragment_items WHERE day_id = ? ORDER BY created_at ASC, fragment_id ASC"
    )
    try statement.bind(Self.uuid(dayID.rawValue), at: 1)
    var fragments: [JournalFragment] = []
    while try statement.stepRow() {
      let payload = try statement.requiredText(at: 0, column: "payload")
      guard let fragment = try Self.decode(JournalFragment.self, payload: payload),
        fragment.dayID == dayID
      else { throw JournalFragmentStoreError.invalidStoredPayload }
      fragments.append(fragment)
    }
    return fragments
  }

  public func recentFragments(limit: Int) async throws -> [JournalFragment] {
    guard (1...1_000).contains(limit) else { throw JournalFragmentStoreError.invalidLimit }
    let statement = try database.prepare(
      "SELECT day_id, fragment_id, created_at, payload FROM journal_fragment_items ORDER BY created_at DESC, fragment_id ASC LIMIT ?"
    )
    try statement.bind(Int64(limit), at: 1)
    var fragments: [JournalFragment] = []
    while try statement.stepRow() {
      let dayID = try statement.requiredText(at: 0, column: "day_id")
      let fragmentID = try statement.requiredText(at: 1, column: "fragment_id")
      let createdAt = try statement.requiredDouble(at: 2, column: "created_at")
      let payload = try statement.requiredText(at: 3, column: "payload")
      guard let id = UUID(uuidString: dayID),
        let fragment = try Self.decode(JournalFragment.self, payload: payload),
        Self.uuid(fragment.id.rawValue) == fragmentID,
        Self.uuid(fragment.dayID.rawValue) == dayID,
        fragment.createdAt.timeIntervalSinceReferenceDate == createdAt,
        fragment.dayID.rawValue == id
      else { throw JournalFragmentStoreError.invalidStoredPayload }
      fragments.append(fragment)
    }
    return fragments
  }

  public func schemaVersion() async throws -> Int { try Self.metadata(from: database).version }
  public func schemaFingerprint() async throws -> String {
    try Self.metadata(from: database).fingerprint
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "journal_fragment")
      if names.isEmpty {
        try database.execute(metadataSQL)
        try database.execute(migrationsSQL)
        try database.execute(fragmentsSQL)
        try database.execute(fragmentsDayIndexSQL)
        try database.execute(fragmentsRecentIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO journal_fragment_schema_migrations(version, applied_at) VALUES (1, ?)"
        )
        try migration.bind(Date().timeIntervalSince1970, at: 1)
        try migration.expectDone()
        let metadata = try database.prepare(
          "INSERT INTO journal_fragment_schema_metadata(singleton, schema_version, schema_fingerprint) VALUES (1, 1, ?)"
        )
        try metadata.bind(expectedSchemaFingerprint, at: 1)
        try metadata.expectDone()
      }
      let metadata = try Self.metadata(from: database)
      guard metadata.version <= currentSchemaVersion else {
        throw JournalFragmentStoreError.unsupportedSchemaVersion(
          found: metadata.version,
          supported: currentSchemaVersion
        )
      }
      guard metadata.version == currentSchemaVersion,
        metadata.fingerprint == expectedSchemaFingerprint
      else { throw JournalFragmentStoreError.corruptedSchema("Unexpected schema metadata") }

      let expected = [
        ("table", "journal_fragment_schema_metadata", metadataSQL),
        ("table", "journal_fragment_schema_migrations", migrationsSQL),
        ("table", "journal_fragment_items", fragmentsSQL),
        ("index", "journal_fragment_items_day_created", fragmentsDayIndexSQL),
        ("index", "journal_fragment_items_created_at", fragmentsRecentIndexSQL),
      ]
      guard
        try database.schemaObjectNames(withPrefix: "journal_fragment")
          == expected.map(\.1).sorted()
      else { throw JournalFragmentStoreError.corruptedSchema("Unexpected schema objects") }
      for (type, name, sql) in expected {
        guard let found = try database.schemaSQL(type: type, name: name),
          normalizedSQL(found) == normalizedSQL(sql)
        else { throw JournalFragmentStoreError.corruptedSchema("Unexpected schema object: \(name)") }
      }
      let journal = try database.prepare(
        "SELECT version FROM journal_fragment_schema_migrations ORDER BY version ASC"
      )
      guard try journal.stepRow(),
        try journal.requiredInt64(at: 0, column: "version") == 1,
        !(try journal.stepRow())
      else { throw JournalFragmentStoreError.corruptedSchema("Invalid migration journal") }
    }
  }

  private static func metadata(
    from database: SQLiteDatabase
  ) throws -> (version: Int, fingerprint: String) {
    let statement = try database.prepare(
      "SELECT schema_version, schema_fingerprint FROM journal_fragment_schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow(),
      let version = Int(exactly: try statement.requiredInt64(at: 0, column: "schema_version"))
    else { throw JournalFragmentStoreError.corruptedSchema("Missing schema metadata") }
    let fingerprint = try statement.requiredText(at: 1, column: "schema_fingerprint")
    guard !(try statement.stepRow()) else {
      throw JournalFragmentStoreError.corruptedSchema("Duplicate schema metadata")
    }
    return (version, fingerprint)
  }

  private static func canonicalPayload<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw JournalFragmentStoreError.invalidStoredPayload
    }
    return string
  }

  private static func decode<T: Codable>(_ type: T.Type, payload: String) throws -> T? {
    guard let data = payload.data(using: .utf8) else {
      throw JournalFragmentStoreError.invalidStoredPayload
    }
    guard let decoded = try? JSONDecoder().decode(type, from: data) else {
      throw JournalFragmentStoreError.invalidStoredPayload
    }
    guard try canonicalPayload(decoded) == payload else {
      throw JournalFragmentStoreError.invalidStoredPayload
    }
    return decoded
  }

  private static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }
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