import CSQLite
import DaydayCore
import Foundation

public enum CollectionConsentStoreError: Error, Equatable, Sendable {
  case database(code: Int32, message: String)
  case corruptedSchema(String)
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case invalidStoredValue(String)
  case revisionConflict
  case invalidTransition
  case revisionOutOfRange
}

/// Independently versioned, explicit-column durable consent/control store.
public actor SQLiteCollectionConsentRepository: CollectionConsentRepository {
  public static let currentSchemaVersion = 1
  private let database: SQLiteDatabase

  init(location: SQLiteDatabaseLocation) throws {
    database = try SQLiteDatabase(location: location)
    do { try Self.migrate(database) } catch {
      database.close()
      throw error
    }
  }

  public func consent(for collector: CollectorKind) throws -> PersistedCollectorConsent {
    guard let row = try Self.row(for: collector, database: database) else {
      return PersistedCollectorConsent(
        consent: CollectorConsent(collector: collector), lastAction: nil, revision: 0)
    }
    return row
  }

  public func transition(_ action: CollectorConsentAction, expectedRevision: UInt64) throws
    -> PersistedCollectorConsent
  {
    try database.transaction {
      let collector = Self.collector(of: action)
      guard expectedRevision < UInt64(Int64.max) else {
        throw CollectionConsentStoreError.revisionOutOfRange
      }
      let previous =
        try Self.row(for: collector, database: database)
        ?? PersistedCollectorConsent(
          consent: CollectorConsent(collector: collector), lastAction: nil, revision: 0)
      guard previous.revision == expectedRevision else {
        throw CollectionConsentStoreError.revisionConflict
      }
      let next: CollectorConsent
      do {
        next = try CollectorConsentStateMachine.transition(action, from: previous.consent)
      } catch { throw CollectionConsentStoreError.invalidTransition }
      let revision = expectedRevision + 1
      let confirmation = next.confirmation!
      let statement = try database.prepare(
        """
        INSERT INTO collection_consents (collector, status, confirmed_at, disclosure_version, last_action, revision)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(collector) DO UPDATE SET status=excluded.status, confirmed_at=excluded.confirmed_at,
        disclosure_version=excluded.disclosure_version, last_action=excluded.last_action, revision=excluded.revision
        WHERE collection_consents.revision = ?
        """)
      try statement.bind(collector.rawValue, at: 1)
      try statement.bind(next.status.rawValue, at: 2)
      try statement.bind(confirmation.confirmedAt.timeIntervalSinceReferenceDate, at: 3)
      try statement.bind(confirmation.disclosureVersion, at: 4)
      try statement.bind(CollectorConsentActionKind(action).rawValue, at: 5)
      try statement.bind(Int64(revision), at: 6)
      try statement.bind(Int64(expectedRevision), at: 7)
      try statement.expectDone()
      guard database.changedRowCount == 1 else {
        throw CollectionConsentStoreError.revisionConflict
      }
      return PersistedCollectorConsent(
        consent: next, lastAction: action, revision: revision,
        renewalRequired: confirmation.disclosureVersion
          != Self.currentDisclosureVersion(for: collector))
    }
  }

  public func globalControl() throws -> GlobalCollectionControl { try Self.global(database) }

  public func setGlobalPaused(_ isPaused: Bool, expectedRevision: UInt64) throws
    -> GlobalCollectionControl
  {
    try database.transaction {
      guard expectedRevision < UInt64(Int64.max) else {
        throw CollectionConsentStoreError.revisionOutOfRange
      }
      let current = try Self.global(database)
      guard current.revision == expectedRevision else {
        throw CollectionConsentStoreError.revisionConflict
      }
      let statement = try database.prepare(
        "UPDATE collection_global_control SET is_paused=?, revision=? WHERE singleton=1 AND revision=?"
      )
      try statement.bind(isPaused ? Int64(1) : Int64(0), at: 1)
      try statement.bind(Int64(expectedRevision + 1), at: 2)
      try statement.bind(Int64(expectedRevision), at: 3)
      try statement.expectDone()
      guard database.changedRowCount == 1 else {
        throw CollectionConsentStoreError.revisionConflict
      }
      return GlobalCollectionControl(isPaused: isPaused, revision: expectedRevision + 1)
    }
  }

  public func schemaVersion() throws -> Int { try Self.version(database) }

  private static let metadata =
    "CREATE TABLE collection_consent_schema_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL) STRICT"
  private static let migrations =
    "CREATE TABLE collection_consent_schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL) STRICT"
  private static let consents =
    "CREATE TABLE collection_consents (collector TEXT PRIMARY KEY NOT NULL, status TEXT NOT NULL CHECK (status IN ('enabled','disabled','paused')), confirmed_at REAL NOT NULL, disclosure_version TEXT NOT NULL, last_action TEXT NOT NULL CHECK (last_action IN ('enable','disable','pause','resume')), revision INTEGER NOT NULL CHECK (revision > 0)) STRICT"
  private static let global =
    "CREATE TABLE collection_global_control (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), is_paused INTEGER NOT NULL CHECK (is_paused IN (0,1)), revision INTEGER NOT NULL CHECK (revision >= 0)) STRICT"

  private static func migrate(_ db: SQLiteDatabase) throws {
    try db.transaction {
      let hasMetadata = try db.tableExists("collection_consent_schema_metadata")
      let hasMigrations = try db.tableExists("collection_consent_schema_migrations")
      guard hasMetadata == hasMigrations else {
        throw CollectionConsentStoreError.corruptedSchema("partial namespace")
      }
      if !hasMetadata {
        try db.execute(metadata)
        try db.execute(migrations)
        try db.execute(consents)
        try db.execute(global)
        try db.execute(
          "INSERT INTO collection_consent_schema_migrations(version, applied_at) VALUES (1, \(Date().timeIntervalSinceReferenceDate))"
        )
        try db.execute(
          "INSERT INTO collection_consent_schema_metadata(singleton, schema_version) VALUES (1, 1)")
        try db.execute(
          "INSERT INTO collection_global_control(singleton, is_paused, revision) VALUES (1, 0, 0)")
        return
      }
      let foundVersion = try version(db)
      guard foundVersion == currentSchemaVersion else {
        throw CollectionConsentStoreError.unsupportedSchemaVersion(
          found: foundVersion, supported: currentSchemaVersion)
      }
      guard try db.tableExists("collection_consents"),
        try db.tableExists("collection_global_control")
      else { throw CollectionConsentStoreError.corruptedSchema("missing table") }
      try validateDefinitions(db)
      let migration = try db.prepare("SELECT version FROM collection_consent_schema_migrations")
      guard try migration.stepRow(), try migration.requiredInt64(at: 0, column: "version") == 1,
        !(try migration.stepRow())
      else {
        throw CollectionConsentStoreError.corruptedSchema("migration journal")
      }
      _ = try global(db)
      try validateStoredConsents(db)
    }
  }

  private static func validateDefinitions(_ db: SQLiteDatabase) throws {
    for (name, definition) in [
      ("collection_consent_schema_metadata", metadata),
      ("collection_consent_schema_migrations", migrations),
      ("collection_consents", consents),
      ("collection_global_control", global),
    ] {
      let statement = try db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name=?")
      try statement.bind(name, at: 1)
      guard try statement.stepRow(),
        let actual = try? statement.requiredText(at: 0, column: "sql"),
        normalized(actual) == normalized(definition)
      else {
        throw CollectionConsentStoreError.corruptedSchema("definition")
      }
    }
  }

  private static func validateStoredConsents(_ db: SQLiteDatabase) throws {
    let statement = try db.prepare("SELECT collector FROM collection_consents")
    while try statement.stepRow() {
      guard let raw = try? statement.requiredText(at: 0, column: "collector"),
        let collector = CollectorKind(rawValue: raw)
      else {
        throw CollectionConsentStoreError.invalidStoredValue("collector")
      }
      _ = try row(for: collector, database: db)
    }
  }

  private static func normalized(_ sql: String) -> String {
    sql.lowercased().filter { !$0.isWhitespace }
  }

  private static func version(_ db: SQLiteDatabase) throws -> Int {
    let s = try db.prepare(
      "SELECT schema_version FROM collection_consent_schema_metadata WHERE singleton=1")
    guard try s.stepRow() else { throw CollectionConsentStoreError.corruptedSchema("metadata") }
    let value = try s.requiredInt64(at: 0, column: "schema_version")
    guard !(try s.stepRow()), let version = Int(exactly: value) else {
      throw CollectionConsentStoreError.corruptedSchema("metadata")
    }
    return version
  }

  private static func global(_ db: SQLiteDatabase) throws -> GlobalCollectionControl {
    let s = try db.prepare(
      "SELECT is_paused, revision FROM collection_global_control WHERE singleton=1")
    guard try s.stepRow() else { throw CollectionConsentStoreError.corruptedSchema("global") }
    let paused = try s.requiredInt64(at: 0, column: "is_paused")
    let revision = try s.requiredInt64(at: 1, column: "revision")
    guard !(try s.stepRow()), paused == 0 || paused == 1, revision >= 0 else {
      throw CollectionConsentStoreError.invalidStoredValue("global")
    }
    return GlobalCollectionControl(isPaused: paused == 1, revision: UInt64(revision))
  }

  private static func row(for collector: CollectorKind, database: SQLiteDatabase) throws
    -> PersistedCollectorConsent?
  {
    let s = try database.prepare(
      "SELECT status, confirmed_at, disclosure_version, last_action, revision FROM collection_consents WHERE collector=?"
    )
    try s.bind(collector.rawValue, at: 1)
    guard try s.stepRow() else { return nil }
    let statusText = try s.requiredText(at: 0, column: "status")
    let timestamp = try s.requiredDouble(at: 1, column: "confirmed_at")
    let disclosure = try s.requiredText(at: 2, column: "disclosure_version")
    let actionText = try s.requiredText(at: 3, column: "last_action")
    let revision = try s.requiredInt64(at: 4, column: "revision")
    guard let status = CollectorConsentStatus(rawValue: statusText), status != .unconfirmed,
      let action = CollectorConsentActionKind(rawValue: actionText), revision > 0
    else { throw CollectionConsentStoreError.invalidStoredValue("consent") }
    let confirmation: UserConsentConfirmation
    do {
      confirmation = try UserConsentConfirmation(
        collector: collector, confirmedAt: Date(timeIntervalSinceReferenceDate: timestamp),
        disclosureVersion: disclosure)
    } catch { throw CollectionConsentStoreError.invalidStoredValue("confirmation") }
    // Build with the accepted state machine instead of exposing a second initializer.
    let rebuilt = try rebuild(
      collector: collector, status: status, confirmation: confirmation, action: action)
    return PersistedCollectorConsent(
      consent: rebuilt, lastAction: actionToAction(action, confirmation),
      revision: UInt64(revision),
      renewalRequired: disclosure != currentDisclosureVersion(for: collector))
  }

  private static func rebuild(
    collector: CollectorKind, status: CollectorConsentStatus, confirmation: UserConsentConfirmation,
    action: CollectorConsentActionKind
  ) throws -> CollectorConsent {
    let initial = CollectorConsent(collector: collector)
    switch (status, action) {
    case (.enabled, .enable):
      return try CollectorConsentStateMachine.transition(.enable(confirmation), from: initial)
    case (.enabled, .resume):
      let enabled = try CollectorConsentStateMachine.transition(
        .enable(confirmation), from: initial)
      let paused = try CollectorConsentStateMachine.transition(.pause(confirmation), from: enabled)
      return try CollectorConsentStateMachine.transition(.resume(confirmation), from: paused)
    case (.disabled, .disable):
      return try CollectorConsentStateMachine.transition(.disable(confirmation), from: initial)
    case (.paused, .pause):
      let enabled = try CollectorConsentStateMachine.transition(
        .enable(confirmation), from: initial)
      return try CollectorConsentStateMachine.transition(.pause(confirmation), from: enabled)
    default:
      throw CollectionConsentStoreError.invalidStoredValue("action-state")
    }
  }
  private static func actionToAction(
    _ kind: CollectorConsentActionKind, _ c: UserConsentConfirmation
  ) -> CollectorConsentAction {
    switch kind {
    case .enable: .enable(c)
    case .disable: .disable(c)
    case .pause: .pause(c)
    case .resume: .resume(c)
    }
  }
  private static func collector(of action: CollectorConsentAction) -> CollectorKind {
    switch action {
    case .enable(let c), .disable(let c), .pause(let c), .resume(let c): c.collector
    }
  }
  private static func currentDisclosureVersion(for collector: CollectorKind) -> String {
    "dayday-consent-v1"
  }
}
