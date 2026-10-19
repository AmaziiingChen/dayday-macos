import DaydayCore
import Foundation

public enum JournalEntryStoreError: Error, Equatable, Sendable {
  case invalidLimit
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case corruptedSchema(String)
  case invalidStoredPayload
  case entryConflict
  case originalVersionConflict
  case derivedVersionConflict
  case invalidVersionLineage
}

public actor SQLiteJournalEntryRepository: JournalEntryRepository, JournalDerivedVersionRepository {
  public static let currentSchemaVersion = 2

  private static let metadataSQL = """
    CREATE TABLE journal_artifact_schema_metadata (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      schema_version INTEGER NOT NULL,
      schema_fingerprint TEXT NOT NULL
    ) STRICT
    """
  private static let migrationsSQL = """
    CREATE TABLE journal_artifact_schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at REAL NOT NULL
    ) STRICT
    """
  private static let entriesSQL = """
    CREATE TABLE journal_artifact_entries (
      entry_id TEXT PRIMARY KEY NOT NULL,
      day_id TEXT UNIQUE NOT NULL,
      updated_at REAL NOT NULL,
      day_payload TEXT NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let originalsSQL = """
    CREATE TABLE journal_artifact_originals (
      original_id TEXT PRIMARY KEY NOT NULL,
      entry_id TEXT NOT NULL REFERENCES journal_artifact_entries(entry_id) ON DELETE CASCADE,
      version_number INTEGER NOT NULL CHECK (version_number > 0),
      saved_at REAL NOT NULL,
      payload TEXT NOT NULL,
      UNIQUE (entry_id, version_number)
    ) STRICT
    """
  private static let entriesUpdatedIndexSQL =
    "CREATE INDEX journal_artifact_entries_updated_at ON journal_artifact_entries(updated_at DESC, entry_id ASC)"
  private static let derivedVersionsSQL = """
    CREATE TABLE journal_artifact_derived_versions (
      derived_id TEXT PRIMARY KEY NOT NULL,
      entry_id TEXT NOT NULL REFERENCES journal_artifact_entries(entry_id) ON DELETE CASCADE,
      source_original_id TEXT NOT NULL REFERENCES journal_artifact_originals(original_id) ON DELETE CASCADE,
      operation TEXT NOT NULL,
      created_at REAL NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let derivedVersionsEntryIndexSQL =
    "CREATE INDEX journal_artifact_derived_versions_entry_created ON journal_artifact_derived_versions(entry_id, created_at DESC, derived_id ASC)"

  private static let versionOneSchemaFingerprint = fingerprint(of: [
    metadataSQL, migrationsSQL, entriesSQL, originalsSQL, entriesUpdatedIndexSQL,
  ])

  public static let expectedSchemaFingerprint = fingerprint(of: [
    metadataSQL, migrationsSQL, entriesSQL, originalsSQL, entriesUpdatedIndexSQL,
    derivedVersionsSQL, derivedVersionsEntryIndexSQL,
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

  public func save(_ record: PersistedJournalEntryRecord) async throws -> JournalEntrySaveResult {
    try database.transaction {
      if let existing = try Self.record(for: record.entry.dayID, from: database) {
        if existing == record { return .alreadyPresent }
        try Self.validateReplacement(record, after: existing)
        try Self.updateCurrentOriginal(record.currentOriginal, into: database)
        let statement = try database.prepare(
          "UPDATE journal_artifact_entries SET updated_at = ?, day_payload = ?, payload = ? WHERE entry_id = ? AND day_id = ?"
        )
        try statement.bind(record.entry.updatedAt.timeIntervalSinceReferenceDate, at: 1)
        try statement.bind(try Self.canonicalPayload(record.day), at: 2)
        try statement.bind(try Self.canonicalPayload(record.entry), at: 3)
        try statement.bind(Self.uuid(record.entry.id.rawValue), at: 4)
        try statement.bind(Self.uuid(record.entry.dayID.rawValue), at: 5)
        try statement.expectDone()
        guard database.changedRowCount == 1 else { throw JournalEntryStoreError.entryConflict }
        return .updated
      }

      guard record.entry.currentOriginalVersionNumber == 1,
        record.currentOriginal.versionNumber == 1,
        record.currentOriginal.previousVersionID == nil
      else { throw JournalEntryStoreError.invalidVersionLineage }
      try Self.insertEntry(record, into: database)
      try Self.insertOriginal(record.currentOriginal, into: database)
      return .inserted
    }
  }

  public func entry(for dayID: DayID) async throws -> PersistedJournalEntryRecord? {
    try Self.record(for: dayID, from: database)
  }

  public func originals(for dayID: DayID) async throws -> [JournalOriginalVersion] {
    let record = try Self.record(for: dayID, from: database)
    guard let record else { return [] }
    let statement = try database.prepare(
      "SELECT original_id, version_number FROM journal_artifact_originals WHERE entry_id = ? ORDER BY version_number ASC"
    )
    try statement.bind(Self.uuid(record.entry.id.rawValue), at: 1)
    var originals: [JournalOriginalVersion] = []
    while try statement.stepRow() {
      let originalID = try statement.requiredText(at: 0, column: "original_id")
      let versionNumber = try statement.requiredInt64(at: 1, column: "version_number")
      let original = try Self.original(
        for: record.entry.id, versionNumber: Int(versionNumber), from: database
      )
      guard let original, Self.uuid(original.id.rawValue) == originalID else {
        throw JournalEntryStoreError.invalidStoredPayload
      }
      originals.append(original)
    }
    return originals
  }

  public func recentEntries(limit: Int) async throws -> [PersistedJournalEntryRecord] {
    guard (1...10_000).contains(limit) else { throw JournalEntryStoreError.invalidLimit }
    let statement = try database.prepare(
      "SELECT day_id FROM journal_artifact_entries ORDER BY updated_at DESC, entry_id ASC LIMIT ?"
    )
    try statement.bind(Int64(limit), at: 1)
    var records: [PersistedJournalEntryRecord] = []
    while try statement.stepRow() {
      let raw = try statement.requiredText(at: 0, column: "day_id")
      guard let id = UUID(uuidString: raw),
        let record = try Self.record(for: DayID(rawValue: id), from: database)
      else { throw JournalEntryStoreError.invalidStoredPayload }
      records.append(record)
    }
    return records
  }

  public func schemaVersion() async throws -> Int { try Self.metadata(from: database).version }
  public func schemaFingerprint() async throws -> String {
    try Self.metadata(from: database).fingerprint
  }

  public func saveDerivedVersion(
    _ version: JournalDerivedVersion
  ) async throws -> JournalDerivedVersionSaveResult {
    try database.transaction {
      let existing = try Self.derivedVersion(for: version.id, from: database)
      if let existing {
        guard existing == version else { throw JournalEntryStoreError.derivedVersionConflict }
        return .alreadyPresent
      }
      let source = try database.prepare(
        "SELECT entry_id FROM journal_artifact_originals WHERE original_id = ?"
      )
      try source.bind(Self.uuid(version.sourceOriginalVersionID.rawValue), at: 1)
      guard try source.stepRow(),
        try source.requiredText(at: 0, column: "entry_id")
          == Self.uuid(version.journalEntryID.rawValue),
        !(try source.stepRow())
      else { throw JournalEntryStoreError.invalidVersionLineage }

      let statement = try database.prepare(
        "INSERT INTO journal_artifact_derived_versions(derived_id, entry_id, source_original_id, operation, created_at, payload) VALUES (?, ?, ?, ?, ?, ?)"
      )
      try statement.bind(Self.uuid(version.id.rawValue), at: 1)
      try statement.bind(Self.uuid(version.journalEntryID.rawValue), at: 2)
      try statement.bind(Self.uuid(version.sourceOriginalVersionID.rawValue), at: 3)
      try statement.bind(version.operation.rawValue, at: 4)
      try statement.bind(version.createdAt.timeIntervalSinceReferenceDate, at: 5)
      try statement.bind(try Self.canonicalPayload(version), at: 6)
      do { try statement.expectDone() } catch {
        throw JournalEntryStoreError.derivedVersionConflict
      }
      return .inserted
    }
  }

  public func derivedVersions(
    for entryID: JournalEntryID,
    limit: Int
  ) async throws -> [JournalDerivedVersion] {
    guard (1...200).contains(limit) else { throw JournalEntryStoreError.invalidLimit }
    let statement = try database.prepare(
      "SELECT derived_id FROM journal_artifact_derived_versions WHERE entry_id = ? ORDER BY created_at DESC, derived_id ASC LIMIT ?"
    )
    try statement.bind(Self.uuid(entryID.rawValue), at: 1)
    try statement.bind(Int64(limit), at: 2)
    var versions: [JournalDerivedVersion] = []
    while try statement.stepRow() {
      let rawID = try statement.requiredText(at: 0, column: "derived_id")
      guard let uuid = UUID(uuidString: rawID),
        let version = try Self.derivedVersion(
          for: JournalDerivedVersionID(rawValue: uuid), from: database
        )
      else { throw JournalEntryStoreError.invalidStoredPayload }
      versions.append(version)
    }
    return versions
  }

  private static func validateReplacement(
    _ next: PersistedJournalEntryRecord,
    after current: PersistedJournalEntryRecord
  ) throws {
    let entry = next.entry
    guard entry.id == current.entry.id,
      entry.dayID == current.entry.dayID,
      next.day == current.day,
      entry.createdAt == current.entry.createdAt,
      entry.currentOriginalVersionID == current.entry.currentOriginalVersionID,
      entry.currentOriginalVersionNumber == current.entry.currentOriginalVersionNumber,
      next.currentOriginal.id == current.currentOriginal.id,
      next.currentOriginal.versionNumber == current.currentOriginal.versionNumber,
      next.currentOriginal.previousVersionID == current.currentOriginal.previousVersionID,
      entry.updatedAt >= current.entry.updatedAt
    else { throw JournalEntryStoreError.invalidVersionLineage }
  }

  private static func updateCurrentOriginal(
    _ original: JournalOriginalVersion,
    into database: SQLiteDatabase
  ) throws {
    let statement = try database.prepare(
      "UPDATE journal_artifact_originals SET saved_at = ?, payload = ? WHERE original_id = ? AND entry_id = ? AND version_number = ?"
    )
    try statement.bind(original.savedAt.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(try canonicalPayload(original), at: 2)
    try statement.bind(uuid(original.id.rawValue), at: 3)
    try statement.bind(uuid(original.journalEntryID.rawValue), at: 4)
    try statement.bind(Int64(original.versionNumber), at: 5)
    try statement.expectDone()
    guard database.changedRowCount == 1 else { throw JournalEntryStoreError.originalVersionConflict }
  }

  private static func insertEntry(
    _ record: PersistedJournalEntryRecord,
    into database: SQLiteDatabase
  ) throws {
    let entry = record.entry
    let statement = try database.prepare(
      "INSERT INTO journal_artifact_entries(entry_id, day_id, updated_at, day_payload, payload) VALUES (?, ?, ?, ?, ?)"
    )
    try statement.bind(uuid(entry.id.rawValue), at: 1)
    try statement.bind(uuid(entry.dayID.rawValue), at: 2)
    try statement.bind(entry.updatedAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(try canonicalPayload(record.day), at: 4)
    try statement.bind(try canonicalPayload(entry), at: 5)
    do {
      try statement.expectDone()
    } catch {
      throw JournalEntryStoreError.entryConflict
    }
  }

  private static func insertOriginal(
    _ original: JournalOriginalVersion,
    into database: SQLiteDatabase
  ) throws {
    let statement = try database.prepare(
      "INSERT INTO journal_artifact_originals(original_id, entry_id, version_number, saved_at, payload) VALUES (?, ?, ?, ?, ?)"
    )
    try statement.bind(uuid(original.id.rawValue), at: 1)
    try statement.bind(uuid(original.journalEntryID.rawValue), at: 2)
    try statement.bind(Int64(original.versionNumber), at: 3)
    try statement.bind(original.savedAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(try canonicalPayload(original), at: 5)
    do {
      try statement.expectDone()
    } catch {
      throw JournalEntryStoreError.originalVersionConflict
    }
  }

  private static func original(
    for entryID: JournalEntryID,
    versionNumber: Int,
    from database: SQLiteDatabase
  ) throws -> JournalOriginalVersion? {
    let statement = try database.prepare(
      "SELECT original_id, entry_id, version_number, saved_at, payload FROM journal_artifact_originals WHERE entry_id = ? AND version_number = ?"
    )
    try statement.bind(uuid(entryID.rawValue), at: 1)
    try statement.bind(Int64(versionNumber), at: 2)
    guard try statement.stepRow() else { return nil }
    let originalID = try statement.requiredText(at: 0, column: "original_id")
    let originalEntryID = try statement.requiredText(at: 1, column: "entry_id")
    let storedNumber = try statement.requiredInt64(at: 2, column: "version_number")
    let savedAt = try statement.requiredDouble(at: 3, column: "saved_at")
    let payload = try statement.requiredText(at: 4, column: "payload")
    guard !(try statement.stepRow()),
      let original = try? decode(JournalOriginalVersion.self, payload: payload),
      Self.uuid(original.id.rawValue) == originalID,
      Self.uuid(original.journalEntryID.rawValue) == originalEntryID,
      original.versionNumber == versionNumber,
      Int(versionNumber) == Int(storedNumber),
      original.savedAt.timeIntervalSinceReferenceDate == savedAt
    else { throw JournalEntryStoreError.invalidStoredPayload }
    return original
  }

  private static func record(
    for dayID: DayID,
    from database: SQLiteDatabase
  ) throws -> PersistedJournalEntryRecord? {
    let entryStatement = try database.prepare(
      "SELECT entry_id, day_id, updated_at, day_payload, payload FROM journal_artifact_entries WHERE day_id = ?"
    )
    try entryStatement.bind(uuid(dayID.rawValue), at: 1)
    guard try entryStatement.stepRow() else { return nil }
    let entryID = try entryStatement.requiredText(at: 0, column: "entry_id")
    let storedDayID = try entryStatement.requiredText(at: 1, column: "day_id")
    let updatedAt = try entryStatement.requiredDouble(at: 2, column: "updated_at")
    let dayPayload = try entryStatement.requiredText(at: 3, column: "day_payload")
    let entryPayload = try entryStatement.requiredText(at: 4, column: "payload")
    guard !(try entryStatement.stepRow()),
      let day = try? decode(DayDescriptor.self, payload: dayPayload),
      let entry = try? decode(JournalEntry.self, payload: entryPayload),
      day.id == entry.dayID,
      uuid(entry.id.rawValue) == entryID,
      uuid(entry.dayID.rawValue) == storedDayID,
      entry.updatedAt.timeIntervalSinceReferenceDate == updatedAt
    else { throw JournalEntryStoreError.invalidStoredPayload }

    let originalStatement = try database.prepare(
      "SELECT original_id, entry_id, version_number, saved_at, payload FROM journal_artifact_originals WHERE original_id = ?"
    )
    try originalStatement.bind(uuid(entry.currentOriginalVersionID.rawValue), at: 1)
    guard try originalStatement.stepRow() else {
      throw JournalEntryStoreError.invalidStoredPayload
    }
    let originalID = try originalStatement.requiredText(at: 0, column: "original_id")
    let originalEntryID = try originalStatement.requiredText(at: 1, column: "entry_id")
    let versionNumber = try originalStatement.requiredInt64(at: 2, column: "version_number")
    let savedAt = try originalStatement.requiredDouble(at: 3, column: "saved_at")
    let originalPayload = try originalStatement.requiredText(at: 4, column: "payload")
    guard !(try originalStatement.stepRow()),
      let original = try? decode(JournalOriginalVersion.self, payload: originalPayload),
      uuid(original.id.rawValue) == originalID,
      uuid(original.journalEntryID.rawValue) == originalEntryID,
      original.versionNumber == versionNumber,
      original.savedAt.timeIntervalSinceReferenceDate == savedAt
    else { throw JournalEntryStoreError.invalidStoredPayload }
    return try PersistedJournalEntryRecord(day: day, entry: entry, currentOriginal: original)
  }

  private static func derivedVersion(
    for id: JournalDerivedVersionID,
    from database: SQLiteDatabase
  ) throws -> JournalDerivedVersion? {
    let statement = try database.prepare(
      "SELECT derived_id, entry_id, source_original_id, operation, created_at, payload FROM journal_artifact_derived_versions WHERE derived_id = ?"
    )
    try statement.bind(uuid(id.rawValue), at: 1)
    guard try statement.stepRow() else { return nil }
    let storedID = try statement.requiredText(at: 0, column: "derived_id")
    let storedEntryID = try statement.requiredText(at: 1, column: "entry_id")
    let storedSourceID = try statement.requiredText(at: 2, column: "source_original_id")
    let storedOperation = try statement.requiredText(at: 3, column: "operation")
    let storedCreatedAt = try statement.requiredDouble(at: 4, column: "created_at")
    let payload = try statement.requiredText(at: 5, column: "payload")
    guard !(try statement.stepRow()),
      let version = try? decode(JournalDerivedVersion.self, payload: payload),
      uuid(version.id.rawValue) == storedID,
      uuid(version.journalEntryID.rawValue) == storedEntryID,
      uuid(version.sourceOriginalVersionID.rawValue) == storedSourceID,
      version.operation.rawValue == storedOperation,
      version.createdAt.timeIntervalSinceReferenceDate == storedCreatedAt
    else { throw JournalEntryStoreError.invalidStoredPayload }
    return version
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "journal_artifact")
      if names.isEmpty {
        try database.execute(metadataSQL)
        try database.execute(migrationsSQL)
        try database.execute(entriesSQL)
        try database.execute(originalsSQL)
        try database.execute(entriesUpdatedIndexSQL)
        try database.execute(derivedVersionsSQL)
        try database.execute(derivedVersionsEntryIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO journal_artifact_schema_migrations(version, applied_at) VALUES (1, ?)"
        )
        try migration.bind(Date().timeIntervalSince1970, at: 1)
        try migration.expectDone()
        let secondMigration = try database.prepare(
          "INSERT INTO journal_artifact_schema_migrations(version, applied_at) VALUES (2, ?)"
        )
        try secondMigration.bind(Date().timeIntervalSince1970, at: 1)
        try secondMigration.expectDone()
        let metadata = try database.prepare(
          "INSERT INTO journal_artifact_schema_metadata(singleton, schema_version, schema_fingerprint) VALUES (1, 2, ?)"
        )
        try metadata.bind(expectedSchemaFingerprint, at: 1)
        try metadata.expectDone()
      }
      let metadata = try Self.metadata(from: database)
      guard metadata.version <= currentSchemaVersion else {
        throw JournalEntryStoreError.unsupportedSchemaVersion(
          found: metadata.version,
          supported: currentSchemaVersion
        )
      }
      if metadata.version == 1 {
        guard metadata.fingerprint == versionOneSchemaFingerprint else {
          throw JournalEntryStoreError.corruptedSchema("Unexpected v1 schema metadata")
        }
        try database.execute(derivedVersionsSQL)
        try database.execute(derivedVersionsEntryIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO journal_artifact_schema_migrations(version, applied_at) VALUES (2, ?)"
        )
        try migration.bind(Date().timeIntervalSince1970, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE journal_artifact_schema_metadata SET schema_version = 2, schema_fingerprint = ? WHERE singleton = 1"
        )
        try update.bind(expectedSchemaFingerprint, at: 1)
        try update.expectDone()
      }
      let migratedMetadata = try Self.metadata(from: database)
      guard migratedMetadata.version == currentSchemaVersion,
        migratedMetadata.fingerprint == expectedSchemaFingerprint
      else { throw JournalEntryStoreError.corruptedSchema("Unexpected schema metadata") }

      let expected = [
        ("table", "journal_artifact_schema_metadata", metadataSQL),
        ("table", "journal_artifact_schema_migrations", migrationsSQL),
        ("table", "journal_artifact_entries", entriesSQL),
        ("table", "journal_artifact_originals", originalsSQL),
        ("index", "journal_artifact_entries_updated_at", entriesUpdatedIndexSQL),
        ("table", "journal_artifact_derived_versions", derivedVersionsSQL),
        ("index", "journal_artifact_derived_versions_entry_created", derivedVersionsEntryIndexSQL),
      ]
      guard
        try database.schemaObjectNames(withPrefix: "journal_artifact")
          == expected.map(\.1).sorted()
      else { throw JournalEntryStoreError.corruptedSchema("Unexpected schema objects") }
      for (type, name, sql) in expected {
        guard let found = try database.schemaSQL(type: type, name: name),
          normalizedSQL(found) == normalizedSQL(sql)
        else { throw JournalEntryStoreError.corruptedSchema("Unexpected schema object: \(name)") }
      }
      let journal = try database.prepare(
        "SELECT version FROM journal_artifact_schema_migrations ORDER BY version ASC"
      )
      guard try journal.stepRow(),
        try journal.requiredInt64(at: 0, column: "version") == 1,
        try journal.stepRow(),
        try journal.requiredInt64(at: 0, column: "version") == 2,
        !(try journal.stepRow())
      else { throw JournalEntryStoreError.corruptedSchema("Invalid migration journal") }
    }
  }

  private static func metadata(
    from database: SQLiteDatabase
  ) throws -> (version: Int, fingerprint: String) {
    let statement = try database.prepare(
      "SELECT schema_version, schema_fingerprint FROM journal_artifact_schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow(),
      let version = Int(exactly: try statement.requiredInt64(at: 0, column: "schema_version"))
    else { throw JournalEntryStoreError.corruptedSchema("Missing schema metadata") }
    let fingerprint = try statement.requiredText(at: 1, column: "schema_fingerprint")
    guard !(try statement.stepRow()) else {
      throw JournalEntryStoreError.corruptedSchema("Duplicate schema metadata")
    }
    return (version, fingerprint)
  }

  private static func canonicalPayload<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw JournalEntryStoreError.invalidStoredPayload
    }
    return string
  }

  private static func decode<T: Codable>(_ type: T.Type, payload: String) throws -> T {
    guard let data = payload.data(using: .utf8) else {
      throw JournalEntryStoreError.invalidStoredPayload
    }
    let decoded = try JSONDecoder().decode(type, from: data)
    guard try canonicalPayload(decoded) == payload else {
      throw JournalEntryStoreError.invalidStoredPayload
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
