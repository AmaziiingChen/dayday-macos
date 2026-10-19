import DaydayCore
import Foundation

public enum JournalAttachmentStoreError: Error, Equatable, Sendable {
  case corruptedSchema(String)
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case invalidStoredPayload
  case insertConflict
}

public actor SQLiteJournalAttachmentRepository: JournalAttachmentRepository {
  public static let currentSchemaVersion = 1

  private static let metadataSQL = """
    CREATE TABLE journal_attachment_schema_metadata (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      schema_version INTEGER NOT NULL,
      schema_fingerprint TEXT NOT NULL
    ) STRICT
    """
  private static let migrationsSQL = """
    CREATE TABLE journal_attachment_schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at REAL NOT NULL
    ) STRICT
    """
  private static let attachmentsSQL = """
    CREATE TABLE journal_attachment_items (
      attachment_id TEXT PRIMARY KEY NOT NULL,
      entry_id TEXT NOT NULL,
      day_id TEXT NOT NULL,
      created_at REAL NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let dayIndexSQL =
    "CREATE INDEX journal_attachment_items_day_created ON journal_attachment_items(day_id ASC, created_at ASC, attachment_id ASC)"

  public static let expectedSchemaFingerprint = fingerprint(of: [
    metadataSQL, migrationsSQL, attachmentsSQL, dayIndexSQL,
  ])

  private let database: SQLiteDatabase

  init(location: SQLiteDatabaseLocation) throws {
    let database = try SQLiteDatabase(location: location)
    do { try Self.migrate(database) } catch {
      database.close()
      throw error
    }
    self.database = database
  }

  public func insert(_ attachment: JournalAttachment) async throws -> JournalAttachmentInsertResult {
    if let existing = try storedAttachment(withID: attachment.id) {
      guard existing == attachment else { throw JournalAttachmentStoreError.insertConflict }
      return .alreadyPresent
    }
    let statement = try database.prepare(
      "INSERT INTO journal_attachment_items(attachment_id, entry_id, day_id, created_at, payload) VALUES (?, ?, ?, ?, ?)"
    )
    try statement.bind(Self.uuid(attachment.id.rawValue), at: 1)
    try statement.bind(Self.uuid(attachment.journalEntryID.rawValue), at: 2)
    try statement.bind(Self.uuid(attachment.dayID.rawValue), at: 3)
    try statement.bind(attachment.createdAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(try Self.canonicalPayload(attachment), at: 5)
    do {
      try statement.expectDone()
      return .inserted
    } catch {
      throw JournalAttachmentStoreError.insertConflict
    }
  }

  public func remove(_ attachment: JournalAttachment) async throws {
    let statement = try database.prepare(
      "DELETE FROM journal_attachment_items WHERE attachment_id = ? AND entry_id = ? AND day_id = ? AND payload = ?"
    )
    try statement.bind(Self.uuid(attachment.id.rawValue), at: 1)
    try statement.bind(Self.uuid(attachment.journalEntryID.rawValue), at: 2)
    try statement.bind(Self.uuid(attachment.dayID.rawValue), at: 3)
    try statement.bind(try Self.canonicalPayload(attachment), at: 4)
    try statement.expectDone()
    guard database.changedRowCount == 1 else { throw JournalAttachmentStoreError.insertConflict }
  }

  public func attachments(for dayID: DayID) async throws -> [JournalAttachment] {
    let statement = try database.prepare(
      "SELECT attachment_id, entry_id, day_id, created_at, payload FROM journal_attachment_items WHERE day_id = ? ORDER BY created_at ASC, attachment_id ASC"
    )
    try statement.bind(Self.uuid(dayID.rawValue), at: 1)
    var attachments: [JournalAttachment] = []
    while try statement.stepRow() {
      let attachmentID = try statement.requiredText(at: 0, column: "attachment_id")
      let entryID = try statement.requiredText(at: 1, column: "entry_id")
      let storedDayID = try statement.requiredText(at: 2, column: "day_id")
      let createdAt = try statement.requiredDouble(at: 3, column: "created_at")
      let payload = try statement.requiredText(at: 4, column: "payload")
      guard let attachment = try Self.decode(JournalAttachment.self, payload: payload),
        Self.uuid(attachment.id.rawValue) == attachmentID,
        Self.uuid(attachment.journalEntryID.rawValue) == entryID,
        Self.uuid(attachment.dayID.rawValue) == storedDayID,
        attachment.dayID == dayID,
        attachment.createdAt.timeIntervalSinceReferenceDate == createdAt
      else { throw JournalAttachmentStoreError.invalidStoredPayload }
      attachments.append(attachment)
    }
    return attachments
  }

  public func schemaVersion() async throws -> Int { try Self.metadata(from: database).version }
  public func schemaFingerprint() async throws -> String { try Self.metadata(from: database).fingerprint }

  private func storedAttachment(withID id: JournalAttachmentID) throws -> JournalAttachment? {
    let statement = try database.prepare(
      "SELECT payload FROM journal_attachment_items WHERE attachment_id = ?"
    )
    try statement.bind(Self.uuid(id.rawValue), at: 1)
    guard try statement.stepRow() else { return nil }
    let payload = try statement.requiredText(at: 0, column: "payload")
    guard !(try statement.stepRow()), let attachment = try Self.decode(JournalAttachment.self, payload: payload),
      attachment.id == id
    else { throw JournalAttachmentStoreError.invalidStoredPayload }
    return attachment
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "journal_attachment")
      if names.isEmpty {
        try database.execute(metadataSQL)
        try database.execute(migrationsSQL)
        try database.execute(attachmentsSQL)
        try database.execute(dayIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO journal_attachment_schema_migrations(version, applied_at) VALUES (1, ?)"
        )
        try migration.bind(Date().timeIntervalSince1970, at: 1)
        try migration.expectDone()
        let metadata = try database.prepare(
          "INSERT INTO journal_attachment_schema_metadata(singleton, schema_version, schema_fingerprint) VALUES (1, 1, ?)"
        )
        try metadata.bind(expectedSchemaFingerprint, at: 1)
        try metadata.expectDone()
      }
      let metadata = try Self.metadata(from: database)
      guard metadata.version <= currentSchemaVersion else {
        throw JournalAttachmentStoreError.unsupportedSchemaVersion(
          found: metadata.version, supported: currentSchemaVersion)
      }
      guard metadata.version == currentSchemaVersion,
        metadata.fingerprint == expectedSchemaFingerprint
      else { throw JournalAttachmentStoreError.corruptedSchema("Unexpected schema metadata") }
      let expected = [
        ("table", "journal_attachment_schema_metadata", metadataSQL),
        ("table", "journal_attachment_schema_migrations", migrationsSQL),
        ("table", "journal_attachment_items", attachmentsSQL),
        ("index", "journal_attachment_items_day_created", dayIndexSQL),
      ]
      guard try database.schemaObjectNames(withPrefix: "journal_attachment") == expected.map(\.1).sorted()
      else { throw JournalAttachmentStoreError.corruptedSchema("Unexpected schema objects") }
      for (type, name, sql) in expected {
        guard let found = try database.schemaSQL(type: type, name: name),
          normalizedSQL(found) == normalizedSQL(sql)
        else { throw JournalAttachmentStoreError.corruptedSchema("Unexpected schema object: \(name)") }
      }
      let migration = try database.prepare(
        "SELECT version FROM journal_attachment_schema_migrations ORDER BY version ASC"
      )
      guard try migration.stepRow(), try migration.requiredInt64(at: 0, column: "version") == 1,
        !(try migration.stepRow())
      else { throw JournalAttachmentStoreError.corruptedSchema("Invalid migration journal") }
    }
  }

  private static func metadata(from database: SQLiteDatabase) throws -> (version: Int, fingerprint: String) {
    let statement = try database.prepare(
      "SELECT schema_version, schema_fingerprint FROM journal_attachment_schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow(),
      let version = Int(exactly: try statement.requiredInt64(at: 0, column: "schema_version"))
    else { throw JournalAttachmentStoreError.corruptedSchema("Missing schema metadata") }
    let fingerprint = try statement.requiredText(at: 1, column: "schema_fingerprint")
    guard !(try statement.stepRow()) else {
      throw JournalAttachmentStoreError.corruptedSchema("Duplicate schema metadata")
    }
    return (version, fingerprint)
  }

  private static func canonicalPayload<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let payload = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw JournalAttachmentStoreError.invalidStoredPayload
    }
    return payload
  }
  private static func decode<T: Codable>(_ type: T.Type, payload: String) throws -> T? {
    guard let data = payload.data(using: .utf8), let value = try? JSONDecoder().decode(type, from: data),
      try canonicalPayload(value) == payload
    else { throw JournalAttachmentStoreError.invalidStoredPayload }
    return value
  }
  private static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }
  private static func normalizedSQL(_ sql: String) -> String {
    sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
  private static func fingerprint(of definitions: [String]) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in definitions.map(normalizedSQL).joined(separator: "\n").utf8 {
      value ^= UInt64(byte); value &*= 1_099_511_628_211
    }
    return String(format: "fnv1a64-%016llx", value)
  }
}
