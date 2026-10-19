import DaydayCore
import Foundation

public enum DeepCaptureArchiveStoreError: Error, Equatable, Sendable {
  case invalidDateRange
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case corruptedSchema(String)
  case invalidStoredPayload
  case identifierConflict(String)
}

/// A separate SQLite namespace for the sensitive Owner Deep Capture archive. It intentionally
/// does not conform to any work-report context interface, so report assembly cannot acquire it
/// merely by opening ordinary objective storage.
public actor SQLiteDeepCaptureArchiveRepository: VisibleContentArchiveRepository,
  TextProductionAggregateRepository, ScreenVisionUsageRepository, ScreenVisionPendingEvidenceRepository
{
  public static let currentSchemaVersion = 3
  private static let maximumPendingVisualEvidence = 64

  private static let metadataSQL = """
    CREATE TABLE deep_capture_schema_metadata (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL,
      schema_fingerprint TEXT NOT NULL
    ) STRICT
    """
  private static let migrationsSQL = """
    CREATE TABLE deep_capture_schema_migrations (
      version INTEGER PRIMARY KEY, applied_at REAL NOT NULL
    ) STRICT
    """
  private static let visibleSQL = """
    CREATE TABLE deep_capture_visible_content (
      id TEXT PRIMARY KEY NOT NULL, observed_at REAL NOT NULL, ended_at REAL,
      record_version INTEGER NOT NULL CHECK (record_version = 1), payload TEXT NOT NULL
    ) STRICT
    """
  private static let textProductionSQL = """
    CREATE TABLE deep_capture_text_production (
      id TEXT PRIMARY KEY NOT NULL, observed_at REAL NOT NULL, ended_at REAL,
      record_version INTEGER NOT NULL CHECK (record_version = 1), payload TEXT NOT NULL
    ) STRICT
    """
  private static let visibleIndexSQL =
    "CREATE INDEX deep_capture_visible_content_observed_at ON deep_capture_visible_content(observed_at, id)"
  private static let textProductionIndexSQL =
    "CREATE INDEX deep_capture_text_production_observed_at ON deep_capture_text_production(observed_at, id)"
  private static let visionUsageSQL = """
    CREATE TABLE deep_capture_screen_vision_usage (
      id TEXT PRIMARY KEY NOT NULL, started_at REAL NOT NULL, completed_at REAL NOT NULL,
      outcome TEXT NOT NULL CHECK (outcome IN ('success','failure')),
      error_category TEXT, record_version INTEGER NOT NULL CHECK (record_version = 1),
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let visionUsageIndexSQL =
    "CREATE INDEX deep_capture_screen_vision_usage_started_at ON deep_capture_screen_vision_usage(started_at, id)"
  private static let visionPendingEvidenceSQL = """
    CREATE TABLE deep_capture_screen_vision_pending_evidence (
      id TEXT PRIMARY KEY NOT NULL, observed_at REAL NOT NULL,
      record_version INTEGER NOT NULL CHECK (record_version = 1), payload TEXT NOT NULL
    ) STRICT
    """
  private static let visionPendingEvidenceIndexSQL =
    "CREATE INDEX deep_capture_screen_vision_pending_evidence_observed_at ON deep_capture_screen_vision_pending_evidence(observed_at, id)"
  private static let v1Definitions = [
    metadataSQL, migrationsSQL, visibleSQL, textProductionSQL, visibleIndexSQL,
    textProductionIndexSQL,
  ]
  private static let v2Definitions = v1Definitions + [visionUsageSQL, visionUsageIndexSQL]
  private static let v3Definitions = v2Definitions + [visionPendingEvidenceSQL, visionPendingEvidenceIndexSQL]
  // Internal so migration tests can construct an exact legacy namespace without
  // duplicating the schema fingerprint algorithm or freezing its output in tests.
  static let legacyV1SchemaFingerprint = fingerprint(of: v1Definitions)
  public static let expectedSchemaFingerprint = fingerprint(of: v3Definitions)

  private let database: SQLiteDatabase

  init(location: SQLiteDatabaseLocation) throws {
    let database = try SQLiteDatabase(location: location)
    do { try Self.migrate(database) } catch {
      database.close()
      throw error
    }
    self.database = database
  }

  public func insert(_ observation: VisibleContentObservation) throws -> DeepCaptureInsertResult {
    try database.transaction {
      let id = observation.id.rawValue.uuidString.lowercased()
      let payload = try Self.canonicalPayload(observation)
      let existing = try Self.visible(id: id, from: database)
      if let existing {
        guard existing == observation else {
          throw DeepCaptureArchiveStoreError.identifierConflict(id)
        }
        return .alreadyPresent
      }
      let statement = try database.prepare(
        "INSERT INTO deep_capture_visible_content (id, observed_at, ended_at, record_version, payload) VALUES (?, ?, ?, ?, ?)"
      )
      try statement.bind(id, at: 1)
      try statement.bind(observation.provenance.observedAt.timeIntervalSinceReferenceDate, at: 2)
      if let end = observation.provenance.endedAt {
        try statement.bind(end.timeIntervalSinceReferenceDate, at: 3)
      } else {
        try statement.bindNull(at: 3)
      }
      try statement.bind(Int64(observation.recordVersion), at: 4)
      try statement.bind(payload, at: 5)
      try statement.expectDone()
      return .inserted
    }
  }

  public func fetchVisibleContent(observedIn range: Range<Date>) throws
    -> [VisibleContentObservation]
  {
    try Self.validate(range)
    let statement = try database.prepare(
      "SELECT id, observed_at, ended_at, record_version, payload FROM deep_capture_visible_content WHERE observed_at >= ? AND observed_at < ? ORDER BY observed_at ASC, id ASC"
    )
    try statement.bind(range.lowerBound.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(range.upperBound.timeIntervalSinceReferenceDate, at: 2)
    var records: [VisibleContentObservation] = []
    while try statement.stepRow() { records.append(try Self.decodeVisible(statement)) }
    return records
  }

  public func insert(_ aggregate: TextProductionAggregate) throws -> DeepCaptureInsertResult {
    try database.transaction {
      let id = aggregate.id.rawValue.uuidString.lowercased()
      let payload = try Self.canonicalPayload(aggregate)
      let existing = try Self.textProduction(id: id, from: database)
      if let existing {
        guard existing == aggregate else {
          throw DeepCaptureArchiveStoreError.identifierConflict(id)
        }
        return .alreadyPresent
      }
      let statement = try database.prepare(
        "INSERT INTO deep_capture_text_production (id, observed_at, ended_at, record_version, payload) VALUES (?, ?, ?, ?, ?)"
      )
      try statement.bind(id, at: 1)
      try statement.bind(aggregate.provenance.observedAt.timeIntervalSinceReferenceDate, at: 2)
      if let end = aggregate.provenance.endedAt {
        try statement.bind(end.timeIntervalSinceReferenceDate, at: 3)
      } else {
        try statement.bindNull(at: 3)
      }
      try statement.bind(Int64(aggregate.recordVersion), at: 4)
      try statement.bind(payload, at: 5)
      try statement.expectDone()
      return .inserted
    }
  }

  public func fetchTextProduction(observedIn range: Range<Date>) throws -> [TextProductionAggregate]
  {
    try Self.validate(range)
    let statement = try database.prepare(
      "SELECT id, observed_at, ended_at, record_version, payload FROM deep_capture_text_production WHERE observed_at >= ? AND observed_at < ? ORDER BY observed_at ASC, id ASC"
    )
    try statement.bind(range.lowerBound.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(range.upperBound.timeIntervalSinceReferenceDate, at: 2)
    var records: [TextProductionAggregate] = []
    while try statement.stepRow() { records.append(try Self.decodeTextProduction(statement)) }
    return records
  }

  public func insert(_ record: ScreenVisionUsageRecord) throws -> DeepCaptureInsertResult {
    try database.transaction {
      let id = record.id.uuidString.lowercased()
      let payload = try Self.canonicalPayload(record)
      let existing = try Self.visionUsage(id: id, from: database)
      if let existing {
        guard existing == record else {
          throw DeepCaptureArchiveStoreError.identifierConflict(id)
        }
        return .alreadyPresent
      }
      let statement = try database.prepare(
        "INSERT INTO deep_capture_screen_vision_usage (id, started_at, completed_at, outcome, error_category, record_version, payload) VALUES (?, ?, ?, ?, ?, ?, ?)"
      )
      try statement.bind(id, at: 1)
      try statement.bind(record.startedAt.timeIntervalSinceReferenceDate, at: 2)
      try statement.bind(record.completedAt.timeIntervalSinceReferenceDate, at: 3)
      try statement.bind(record.outcome.rawValue, at: 4)
      if let error = record.errorCategory {
        try statement.bind(error.rawValue, at: 5)
      } else {
        try statement.bindNull(at: 5)
      }
      try statement.bind(Int64(1), at: 6)
      try statement.bind(payload, at: 7)
      try statement.expectDone()
      return .inserted
    }
  }

  public func screenVisionUsage(in range: Range<Date>) throws -> ScreenVisionUsageSummary {
    try Self.validate(range)
    let statement = try database.prepare(
      "SELECT payload FROM deep_capture_screen_vision_usage WHERE started_at >= ? AND started_at < ? ORDER BY started_at ASC, id ASC"
    )
    try statement.bind(range.lowerBound.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(range.upperBound.timeIntervalSinceReferenceDate, at: 2)
    var records: [ScreenVisionUsageRecord] = []
    while try statement.stepRow() {
      let payload = try statement.requiredText(at: 0, column: "payload")
      guard let data = payload.data(using: .utf8),
        let record = try? JSONDecoder().decode(ScreenVisionUsageRecord.self, from: data),
        try Self.canonicalPayload(record) == payload
      else { throw DeepCaptureArchiveStoreError.invalidStoredPayload }
      records.append(record)
    }
    var failures: [ScreenVisionErrorCategory: Int] = [:]
    var failureStages: [ScreenVisionFailureStage: Int] = [:]
    for record in records where record.outcome == .failure {
      if let category = record.errorCategory { failures[category, default: 0] += 1 }
      if let stage = record.failureStage { failureStages[stage, default: 0] += 1 }
    }
    return ScreenVisionUsageSummary(
      callCount: records.count,
      successCount: records.filter({ $0.outcome == .success }).count,
      inputTokens: records.compactMap(\.inputTokens).reduce(0, +),
      outputTokens: records.compactMap(\.outputTokens).reduce(0, +),
      cachedInputTokens: records.compactMap(\.cachedInputTokens).reduce(0, +),
      totalTokens: records.compactMap(\.totalTokens).reduce(0, +),
      failuresByCategory: failures,
      failuresByStage: failureStages
    )
  }

  public func insert(_ evidence: ScreenVisionPendingEvidence) throws -> DeepCaptureInsertResult {
    try database.transaction {
      let id = evidence.id.rawValue.uuidString.lowercased()
      let payload = try Self.canonicalPayload(evidence)
      let existing = try Self.pendingEvidence(id: id, from: database)
      if let existing {
        guard existing == evidence else {
          throw DeepCaptureArchiveStoreError.identifierConflict(id)
        }
        return .alreadyPresent
      }
      let capacity = try database.prepare(
        "SELECT COUNT(*) FROM deep_capture_screen_vision_pending_evidence"
      )
      guard try capacity.stepRow() else {
        throw DeepCaptureArchiveStoreError.corruptedSchema("Missing pending evidence count")
      }
      let count = try capacity.requiredInt64(at: 0, column: "count")
      guard !(try capacity.stepRow()) else {
        throw DeepCaptureArchiveStoreError.corruptedSchema("Invalid pending evidence count")
      }
      if count >= Int64(Self.maximumPendingVisualEvidence) {
        let trim = try database.prepare(
          "DELETE FROM deep_capture_screen_vision_pending_evidence WHERE id IN (SELECT id FROM deep_capture_screen_vision_pending_evidence ORDER BY observed_at ASC, id ASC LIMIT 1)"
        )
        try trim.expectDone()
      }
      let statement = try database.prepare(
        "INSERT INTO deep_capture_screen_vision_pending_evidence (id, observed_at, record_version, payload) VALUES (?, ?, ?, ?)"
      )
      try statement.bind(id, at: 1)
      try statement.bind(evidence.observedAt.timeIntervalSinceReferenceDate, at: 2)
      try statement.bind(Int64(evidence.recordVersion), at: 3)
      try statement.bind(payload, at: 4)
      try statement.expectDone()
      return .inserted
    }
  }

  public func pendingScreenVisionEvidence(limit: Int) throws -> [ScreenVisionPendingEvidence] {
    guard (1...64).contains(limit) else { throw DeepCaptureArchiveStoreError.invalidDateRange }
    let statement = try database.prepare(
      "SELECT id, observed_at, record_version, payload FROM deep_capture_screen_vision_pending_evidence ORDER BY observed_at ASC, id ASC LIMIT ?"
    )
    try statement.bind(Int64(limit), at: 1)
    var records: [ScreenVisionPendingEvidence] = []
    while try statement.stepRow() { records.append(try Self.decodePendingEvidence(statement)) }
    return records
  }

  public func removePendingScreenVisionEvidence(ids: [ScreenVisionPendingEvidenceID]) throws {
    guard ids.count <= Self.maximumPendingVisualEvidence else {
      throw DeepCaptureArchiveStoreError.invalidDateRange
    }
    try database.transaction {
      for id in ids {
        let statement = try database.prepare(
          "DELETE FROM deep_capture_screen_vision_pending_evidence WHERE id = ?"
        )
        try statement.bind(id.rawValue.uuidString.lowercased(), at: 1)
        try statement.expectDone()
      }
    }
  }

  public func schemaVersion() throws -> Int { try Self.metadata(from: database).version }
  public func schemaFingerprint() throws -> String { try Self.metadata(from: database).fingerprint }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "deep_capture")
      if names.isEmpty {
        try database.execute(metadataSQL)
        try database.execute(migrationsSQL)
        try database.execute(visibleSQL)
        try database.execute(textProductionSQL)
        try database.execute(visibleIndexSQL)
        try database.execute(textProductionIndexSQL)
        try database.execute(visionUsageSQL)
        try database.execute(visionUsageIndexSQL)
        try database.execute(visionPendingEvidenceSQL)
        try database.execute(visionPendingEvidenceIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO deep_capture_schema_migrations(version, applied_at) VALUES (1, ?)")
        try migration.bind(Date().timeIntervalSince1970, at: 1)
        try migration.expectDone()
        let second = try database.prepare(
          "INSERT INTO deep_capture_schema_migrations(version, applied_at) VALUES (2, ?)")
        try second.bind(Date().timeIntervalSince1970, at: 1)
        try second.expectDone()
        let third = try database.prepare(
          "INSERT INTO deep_capture_schema_migrations(version, applied_at) VALUES (3, ?)")
        try third.bind(Date().timeIntervalSince1970, at: 1)
        try third.expectDone()
        let metadata = try database.prepare(
          "INSERT INTO deep_capture_schema_metadata(singleton, schema_version, schema_fingerprint) VALUES (1, 3, ?)"
        )
        try metadata.bind(expectedSchemaFingerprint, at: 1)
        try metadata.expectDone()
      }
      var metadata = try Self.metadata(from: database)
      guard metadata.version <= currentSchemaVersion else {
        throw DeepCaptureArchiveStoreError.unsupportedSchemaVersion(
          found: metadata.version, supported: currentSchemaVersion)
      }
      if metadata.version == 1 {
        guard metadata.fingerprint == legacyV1SchemaFingerprint else {
          throw DeepCaptureArchiveStoreError.corruptedSchema("Unexpected v1 schema metadata")
        }
        try Self.validateObjects(database, definitions: v1Definitions)
        try database.execute(visionUsageSQL)
        try database.execute(visionUsageIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO deep_capture_schema_migrations(version, applied_at) VALUES (2, ?)")
        try migration.bind(Date().timeIntervalSince1970, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE deep_capture_schema_metadata SET schema_version=2, schema_fingerprint=? WHERE singleton=1 AND schema_version=1"
        )
        try update.bind(fingerprint(of: v2Definitions), at: 1)
        try update.expectDone()
        metadata = try Self.metadata(from: database)
      }
      if metadata.version == 2 {
        guard metadata.fingerprint == fingerprint(of: v2Definitions) else {
          throw DeepCaptureArchiveStoreError.corruptedSchema("Unexpected v2 schema metadata")
        }
        try Self.validateObjects(database, definitions: v2Definitions)
        try database.execute(visionPendingEvidenceSQL)
        try database.execute(visionPendingEvidenceIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO deep_capture_schema_migrations(version, applied_at) VALUES (3, ?)")
        try migration.bind(Date().timeIntervalSince1970, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE deep_capture_schema_metadata SET schema_version=3, schema_fingerprint=? WHERE singleton=1 AND schema_version=2"
        )
        try update.bind(expectedSchemaFingerprint, at: 1)
        try update.expectDone()
        metadata = try Self.metadata(from: database)
      }
      guard metadata.version == currentSchemaVersion,
        metadata.fingerprint == expectedSchemaFingerprint
      else { throw DeepCaptureArchiveStoreError.corruptedSchema("Unexpected schema metadata") }
      let journal = try database.prepare(
        "SELECT version FROM deep_capture_schema_migrations ORDER BY version ASC")
      guard try journal.stepRow(), try journal.requiredInt64(at: 0, column: "version") == 1,
        try journal.stepRow(), try journal.requiredInt64(at: 0, column: "version") == 2,
        try journal.stepRow(), try journal.requiredInt64(at: 0, column: "version") == 3,
        !(try journal.stepRow())
      else { throw DeepCaptureArchiveStoreError.corruptedSchema("Invalid migration journal") }
      try Self.validateObjects(database, definitions: v3Definitions)
    }
  }

  private static func metadata(from database: SQLiteDatabase) throws -> (
    version: Int, fingerprint: String
  ) {
    let statement = try database.prepare(
      "SELECT schema_version, schema_fingerprint FROM deep_capture_schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow(),
      let version = Int(exactly: try statement.requiredInt64(at: 0, column: "schema_version"))
    else { throw DeepCaptureArchiveStoreError.corruptedSchema("Missing schema metadata") }
    let fingerprint = try statement.requiredText(at: 1, column: "schema_fingerprint")
    guard !(try statement.stepRow()) else {
      throw DeepCaptureArchiveStoreError.corruptedSchema("Duplicate schema metadata")
    }
    return (version, fingerprint)
  }

  private static func visible(id: String, from database: SQLiteDatabase) throws
    -> VisibleContentObservation?
  {
    let statement = try database.prepare(
      "SELECT id, observed_at, ended_at, record_version, payload FROM deep_capture_visible_content WHERE id = ?"
    )
    try statement.bind(id, at: 1)
    guard try statement.stepRow() else { return nil }
    let result = try decodeVisible(statement)
    guard !(try statement.stepRow()) else {
      throw DeepCaptureArchiveStoreError.corruptedSchema("Duplicate visible ID")
    }
    return result
  }
  private static func textProduction(id: String, from database: SQLiteDatabase) throws
    -> TextProductionAggregate?
  {
    let statement = try database.prepare(
      "SELECT id, observed_at, ended_at, record_version, payload FROM deep_capture_text_production WHERE id = ?"
    )
    try statement.bind(id, at: 1)
    guard try statement.stepRow() else { return nil }
    let result = try decodeTextProduction(statement)
    guard !(try statement.stepRow()) else {
      throw DeepCaptureArchiveStoreError.corruptedSchema("Duplicate text production ID")
    }
    return result
  }
  private static func visionUsage(id: String, from database: SQLiteDatabase) throws
    -> ScreenVisionUsageRecord?
  {
    let statement = try database.prepare(
      "SELECT payload FROM deep_capture_screen_vision_usage WHERE id = ?")
    try statement.bind(id, at: 1)
    guard try statement.stepRow() else { return nil }
    let payload = try statement.requiredText(at: 0, column: "payload")
    guard !(try statement.stepRow()), let data = payload.data(using: .utf8),
      let value = try? JSONDecoder().decode(ScreenVisionUsageRecord.self, from: data),
      value.id.uuidString.lowercased() == id,
      try canonicalPayload(value) == payload
    else { throw DeepCaptureArchiveStoreError.invalidStoredPayload }
    return value
  }
  private static func pendingEvidence(id: String, from database: SQLiteDatabase) throws
    -> ScreenVisionPendingEvidence?
  {
    let statement = try database.prepare(
      "SELECT id, observed_at, record_version, payload FROM deep_capture_screen_vision_pending_evidence WHERE id = ?"
    )
    try statement.bind(id, at: 1)
    guard try statement.stepRow() else { return nil }
    let result = try decodePendingEvidence(statement)
    guard !(try statement.stepRow()) else {
      throw DeepCaptureArchiveStoreError.corruptedSchema("Duplicate pending visual evidence ID")
    }
    return result
  }
  private static func decodeVisible(_ statement: SQLiteStatement) throws
    -> VisibleContentObservation
  {
    let id = try statement.requiredText(at: 0, column: "id")
    let observed = try statement.requiredDouble(at: 1, column: "observed_at")
    let version = try statement.requiredInt64(at: 3, column: "record_version")
    let payload = try statement.requiredText(at: 4, column: "payload")
    let ended =
      statement.isNull(at: 2) ? nil : try statement.requiredDouble(at: 2, column: "ended_at")
    guard let data = payload.data(using: .utf8),
      let value = try? JSONDecoder().decode(VisibleContentObservation.self, from: data),
      value.id.rawValue.uuidString.lowercased() == id,
      value.provenance.observedAt.timeIntervalSinceReferenceDate == observed,
      value.provenance.endedAt?.timeIntervalSinceReferenceDate == ended,
      value.recordVersion == Int(version), try matchesStoredVisiblePayload(value, payload: payload)
    else { throw DeepCaptureArchiveStoreError.invalidStoredPayload }
    return value
  }

  /// `confidence` was removed from `VisualWorkSegment` after visual records had already been
  /// stored. Keep the archive immutable, but accept precisely that legacy additive field when
  /// the remainder of the canonical payload still matches the decoded record.
  private static func matchesStoredVisiblePayload(
    _ value: VisibleContentObservation,
    payload: String
  ) throws -> Bool {
    let canonical = try canonicalPayload(value)
    guard canonical != payload,
      value.kind == .inference,
      let payloadData = payload.data(using: .utf8),
      var root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
      var segment = root["visualWorkSegment"] as? [String: Any],
      segment.removeValue(forKey: "confidence") != nil
    else { return canonical == payload }
    root["visualWorkSegment"] = segment
    guard let canonicalData = canonical.data(using: .utf8),
      let canonicalObject = try? JSONSerialization.jsonObject(with: canonicalData)
    else { return false }
    // JSONEncoder's byte-level spelling can legitimately differ across the two historic Swift
    // encoders (notably for escaped Unicode). Compare the complete parsed structure instead;
    // the only removed member is still the explicitly checked legacy confidence field above.
    return (root as NSDictionary).isEqual(canonicalObject)
  }
  private static func decodeTextProduction(_ statement: SQLiteStatement) throws
    -> TextProductionAggregate
  {
    let id = try statement.requiredText(at: 0, column: "id")
    let observed = try statement.requiredDouble(at: 1, column: "observed_at")
    let version = try statement.requiredInt64(at: 3, column: "record_version")
    let payload = try statement.requiredText(at: 4, column: "payload")
    let ended =
      statement.isNull(at: 2) ? nil : try statement.requiredDouble(at: 2, column: "ended_at")
    guard let data = payload.data(using: .utf8),
      let value = try? JSONDecoder().decode(TextProductionAggregate.self, from: data),
      value.id.rawValue.uuidString.lowercased() == id,
      value.provenance.observedAt.timeIntervalSinceReferenceDate == observed,
      value.provenance.endedAt?.timeIntervalSinceReferenceDate == ended,
      value.recordVersion == Int(version), try canonicalPayload(value) == payload
    else { throw DeepCaptureArchiveStoreError.invalidStoredPayload }
    return value
  }
  private static func decodePendingEvidence(_ statement: SQLiteStatement) throws
    -> ScreenVisionPendingEvidence
  {
    let id = try statement.requiredText(at: 0, column: "id")
    let observed = try statement.requiredDouble(at: 1, column: "observed_at")
    let version = try statement.requiredInt64(at: 2, column: "record_version")
    let payload = try statement.requiredText(at: 3, column: "payload")
    guard let data = payload.data(using: .utf8),
      let value = try? JSONDecoder().decode(ScreenVisionPendingEvidence.self, from: data),
      value.id.rawValue.uuidString.lowercased() == id,
      value.observedAt.timeIntervalSinceReferenceDate == observed,
      value.recordVersion == Int(version), try canonicalPayload(value) == payload
    else { throw DeepCaptureArchiveStoreError.invalidStoredPayload }
    return value
  }
  private static func canonicalPayload<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw DeepCaptureArchiveStoreError.invalidStoredPayload
    }
    return result
  }
  private static func validate(_ range: Range<Date>) throws {
    guard range.lowerBound.timeIntervalSinceReferenceDate.isFinite,
      range.upperBound.timeIntervalSinceReferenceDate.isFinite, range.lowerBound < range.upperBound
    else { throw DeepCaptureArchiveStoreError.invalidDateRange }
  }
  private static func normalizedSQL(_ sql: String) -> String {
    sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
  private static func validateObjects(_ database: SQLiteDatabase, definitions: [String]) throws {
    let objects: [(String, String, String)] = [
      ("table", "deep_capture_schema_metadata", metadataSQL),
      ("table", "deep_capture_schema_migrations", migrationsSQL),
      ("table", "deep_capture_visible_content", visibleSQL),
      ("table", "deep_capture_text_production", textProductionSQL),
      ("index", "deep_capture_visible_content_observed_at", visibleIndexSQL),
      ("index", "deep_capture_text_production_observed_at", textProductionIndexSQL),
      ("table", "deep_capture_screen_vision_usage", visionUsageSQL),
      ("index", "deep_capture_screen_vision_usage_started_at", visionUsageIndexSQL),
      ("table", "deep_capture_screen_vision_pending_evidence", visionPendingEvidenceSQL),
      ("index", "deep_capture_screen_vision_pending_evidence_observed_at", visionPendingEvidenceIndexSQL),
    ].filter { definition in
      definitions.contains(where: { normalizedSQL($0) == normalizedSQL(definition.2) })
    }
    guard try database.schemaObjectNames(withPrefix: "deep_capture") == objects.map(\.1).sorted()
    else { throw DeepCaptureArchiveStoreError.corruptedSchema("Unexpected schema objects") }
    for (type, name, sql) in objects {
      guard let found = try database.schemaSQL(type: type, name: name),
        normalizedSQL(found) == normalizedSQL(sql)
      else {
        throw DeepCaptureArchiveStoreError.corruptedSchema("Unexpected schema object: \(name)")
      }
    }
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
