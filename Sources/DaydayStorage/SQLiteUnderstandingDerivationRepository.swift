import CSQLite
import CryptoKit
import DaydayCore
import Foundation

public enum UnderstandingDerivationStoreError: Error, Equatable, Sendable {
  case corruptedSchema(String)
  case invalidStoredDerivation
}

/// Stores one complete Session/Activity revision in a single SQLite transaction.
public actor SQLiteUnderstandingDerivationRepository: UnderstandingDerivationRepository {
  private static let migrationLock = NSLock()
  private let database: SQLiteDatabase

  init(location: SQLiteDatabaseLocation) throws {
    database = try Self.migrationLock.withLock {
      _ = try SQLiteSessionRepository(location: location)
      _ = try SQLiteActivityRepository(location: location)
      let database = try SQLiteDatabase(location: location)
      return database
    }
  }

  public func saveAtomically(_ derivation: PersistedUnderstandingDerivation) throws
    -> UnderstandingDerivationSaveResult
  {
    guard Int64(exactly: derivation.revision) != nil else { return .conflict }
    do {
      return try database.transaction {
        if let existing = try Self.derivation(
          day: derivation.day, revision: derivation.revision, database: database)
        {
          return existing == derivation ? .alreadyPresent : .conflict
        }
        try Self.insert(derivation, database: database)
        return .inserted
      }
    } catch let error as ObjectiveEventStoreError {
      guard case .database(let code, _) = error, code & 0xFF == SQLITE_CONSTRAINT else {
        throw error
      }
      guard
        let existing = try Self.derivation(
          day: derivation.day, revision: derivation.revision, database: database)
      else { throw error }
      return existing == derivation ? .alreadyPresent : .conflict
    }
  }

  public func latest(for day: DayDescriptor) throws -> PersistedUnderstandingDerivation? {
    let statement = try database.prepare(
      "SELECT revision FROM h2_activity_batches WHERE logical_date=? AND time_zone=? AND boundary_start=? AND boundary_end=? ORDER BY revision DESC LIMIT 1"
    )
    try Self.bind(day, to: statement, startingAt: 1)
    guard try statement.stepRow() else { return nil }
    guard let revision = UInt64(exactly: try statement.requiredInt64(at: 0, column: "revision"))
    else {
      throw UnderstandingDerivationStoreError.invalidStoredDerivation
    }
    return try Self.derivation(day: day, revision: revision, database: database)
  }

  private static func insert(_ value: PersistedUnderstandingDerivation, database: SQLiteDatabase)
    throws
  {
    let sessionBatchID = try sessionIdentity(value)
    let activityBatchID = try activityIdentity(value, sessionBatchID: sessionBatchID)
    let orderedSessions = canonical(value.sessions)
    let orderedActivities = canonical(value.activities)
    let sessionBatch = try database.prepare(
      "INSERT INTO h2_session_batches(batch_id,logical_date,time_zone,boundary_start,boundary_end,revision,session_ids) VALUES(?,?,?,?,?,?,?)"
    )
    try sessionBatch.bind(sessionBatchID, at: 1)
    try bind(value.day, to: sessionBatch)
    try sessionBatch.bind(Int64(value.revision), at: 6)
    try sessionBatch.bind(serialized(orderedSessions.map(\.id)), at: 7)
    try sessionBatch.expectDone()
    for session in orderedSessions {
      try insert(session, batchID: sessionBatchID, database: database)
    }

    let activityBatch = try database.prepare(
      "INSERT INTO h2_activity_batches(batch_id,session_batch_id,logical_date,time_zone,boundary_start,boundary_end,revision,activity_ids) VALUES(?,?,?,?,?,?,?,?)"
    )
    try activityBatch.bind(activityBatchID, at: 1)
    try activityBatch.bind(sessionBatchID, at: 2)
    try bind(value.day, to: activityBatch, startingAt: 3)
    try activityBatch.bind(Int64(value.revision), at: 7)
    try activityBatch.bind(serialized(orderedActivities.map(\.id)), at: 8)
    try activityBatch.expectDone()
    for activity in orderedActivities {
      try insert(activity, batchID: activityBatchID, database: database)
    }
  }

  private static func derivation(
    day: DayDescriptor, revision: UInt64, database: SQLiteDatabase
  ) throws -> PersistedUnderstandingDerivation? {
    guard let storageRevision = Int64(exactly: revision) else { return nil }
    let batch = try database.prepare(
      "SELECT batch_id,session_batch_id,activity_ids FROM h2_activity_batches WHERE logical_date=? AND time_zone=? AND boundary_start=? AND boundary_end=? AND revision=?"
    )
    try bind(day, to: batch, startingAt: 1)
    try batch.bind(storageRevision, at: 5)
    guard try batch.stepRow() else { return nil }
    let activityBatchID = try batch.requiredText(at: 0, column: "batch_id")
    let sessionBatchID = try batch.requiredText(at: 1, column: "session_batch_id")
    let activityIDs = try batch.requiredText(at: 2, column: "activity_ids")
    guard !(try batch.stepRow()) else {
      throw UnderstandingDerivationStoreError.invalidStoredDerivation
    }

    let sessionEnvelope = try database.prepare(
      "SELECT session_ids FROM h2_session_batches WHERE batch_id=? AND logical_date=? AND time_zone=? AND boundary_start=? AND boundary_end=? AND revision=?"
    )
    try sessionEnvelope.bind(sessionBatchID, at: 1)
    try bind(day, to: sessionEnvelope, startingAt: 2)
    try sessionEnvelope.bind(storageRevision, at: 6)
    guard try sessionEnvelope.stepRow() else {
      throw UnderstandingDerivationStoreError.invalidStoredDerivation
    }
    let sessionIDs = try sessionEnvelope.requiredText(at: 0, column: "session_ids")
    guard !(try sessionEnvelope.stepRow()) else {
      throw UnderstandingDerivationStoreError.invalidStoredDerivation
    }

    let sessions = try records(
      query:
        "SELECT session_id FROM h2_sessions WHERE batch_id=? ORDER BY started_at ASC, ended_at ASC, session_id ASC",
      batchID: sessionBatchID,
      database: database,
      decode: session
    )
    let activities = try records(
      query:
        "SELECT activity_id FROM h2_activity_records WHERE batch_id=? ORDER BY started_at ASC, activity_id ASC",
      batchID: activityBatchID,
      database: database,
      decode: activity
    )
    guard !sessions.isEmpty, !activities.isEmpty,
      sessionIDs == serialized(sessions.map(\.id)),
      activityIDs == serialized(activities.map(\.id)),
      activities.allSatisfy({ Set($0.sessionIDs).isSubset(of: Set(sessions.map(\.id))) })
    else { throw UnderstandingDerivationStoreError.invalidStoredDerivation }
    return try PersistedUnderstandingDerivation(
      sessionBatch: SessionDerivationBatch(
        day: day, derivationRevision: revision, sessions: sessions),
      activityBatch: ActivityDerivationBatch(
        day: day, derivationRevision: revision, activities: activities)
    )
  }

  private static func records<T>(
    query: String,
    batchID: String,
    database: SQLiteDatabase,
    decode: (UUID, SQLiteDatabase) throws -> T?
  ) throws -> [T] {
    let statement = try database.prepare(query)
    try statement.bind(batchID, at: 1)
    var values: [T] = []
    while try statement.stepRow() {
      guard let identifier = UUID(uuidString: try statement.requiredText(at: 0, column: "id")),
        let value = try decode(identifier, database)
      else { throw UnderstandingDerivationStoreError.invalidStoredDerivation }
      values.append(value)
    }
    return values
  }

  private static func insert(_ value: Session, batchID: String, database: SQLiteDatabase) throws {
    let statement = try database.prepare(
      "INSERT INTO h2_sessions(session_id,batch_id,started_at,ended_at,display_id,ending_boundary,revision,supersedes_id,payload) VALUES(?,?,?,?,?,?,?,?,?)"
    )
    try statement.bind(value.id.rawValue.uuidString.lowercased(), at: 1)
    try statement.bind(batchID, at: 2)
    try statement.bind(value.startedAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(value.endedAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(Self.storageKey(for: value.scope), at: 5)
    if let boundary = value.endingHardBoundary {
      try statement.bind(boundary.rawValue, at: 6)
    } else {
      try statement.bindNull(at: 6)
    }
    try statement.bind(Int64(value.lineage.derivationRevision), at: 7)
    if let id = value.lineage.supersedesSessionID {
      try statement.bind(id.rawValue.uuidString.lowercased(), at: 8)
    } else {
      try statement.bindNull(at: 8)
    }
    try statement.bind(try payload(value), at: 9)
    try statement.expectDone()
    for (ordinal, eventID) in value.objectiveEventIDs.enumerated() {
      let member = try database.prepare(
        "INSERT INTO h2_session_membership(session_id,ordinal,event_id) VALUES(?,?,?)")
      try member.bind(value.id.rawValue.uuidString.lowercased(), at: 1)
      try member.bind(Int64(ordinal), at: 2)
      try member.bind(eventID.rawValue.uuidString.lowercased(), at: 3)
      try member.expectDone()
    }
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
    for (ordinal, sessionID) in value.sessionIDs.enumerated() {
      let member = try database.prepare(
        "INSERT INTO h2_activity_membership(activity_id,ordinal,session_id) VALUES(?,?,?)")
      try member.bind(value.id.rawValue.uuidString.lowercased(), at: 1)
      try member.bind(Int64(ordinal), at: 2)
      try member.bind(sessionID.rawValue.uuidString.lowercased(), at: 3)
      try member.expectDone()
    }
  }

  private static func session(_ raw: UUID, database: SQLiteDatabase) throws -> Session? {
    let id = SessionID(rawValue: raw)
    let statement = try database.prepare(
      "SELECT started_at,ended_at,display_id,ending_boundary,revision,supersedes_id,payload FROM h2_sessions WHERE session_id=?"
    )
    try statement.bind(raw.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    let started = try statement.requiredDouble(at: 0, column: "started_at")
    let ended = try statement.requiredDouble(at: 1, column: "ended_at")
    let display = try statement.requiredText(at: 2, column: "display_id")
    let boundary =
      statement.isNull(at: 3) ? nil : try statement.requiredText(at: 3, column: "ending_boundary")
    let revision = try statement.requiredInt64(at: 4, column: "revision")
    let supersedes =
      statement.isNull(at: 5) ? nil : try statement.requiredText(at: 5, column: "supersedes_id")
    let value = try decode(Session.self, try statement.requiredText(at: 6, column: "payload"))
    guard value.id == id,
      value.startedAt.timeIntervalSinceReferenceDate == started,
      value.endedAt.timeIntervalSinceReferenceDate == ended,
      Self.storageKey(for: value.scope) == display.lowercased(),
      value.endingHardBoundary?.rawValue == boundary,
      UInt64(exactly: revision) == value.lineage.derivationRevision,
      value.lineage.supersedesSessionID?.rawValue.uuidString.lowercased()
        == supersedes?.lowercased(),
      !(try statement.stepRow())
    else { throw UnderstandingDerivationStoreError.invalidStoredDerivation }
    let membership = try database.prepare(
      "SELECT event_id FROM h2_session_membership WHERE session_id=? ORDER BY ordinal ASC")
    try membership.bind(raw.uuidString.lowercased(), at: 1)
    var ids: [EventID] = []
    while try membership.stepRow() {
      guard let raw = UUID(uuidString: try membership.requiredText(at: 0, column: "event_id"))
      else { throw UnderstandingDerivationStoreError.invalidStoredDerivation }
      ids.append(EventID(rawValue: raw))
    }
    guard ids == value.objectiveEventIDs else {
      throw UnderstandingDerivationStoreError.invalidStoredDerivation
    }
    return value
  }

  private static func activity(_ raw: UUID, database: SQLiteDatabase) throws -> Activity? {
    let id = ActivityID(rawValue: raw)
    let statement = try database.prepare(
      "SELECT started_at,ended_at,payload FROM h2_activity_records WHERE activity_id=?")
    try statement.bind(raw.uuidString.lowercased(), at: 1)
    guard try statement.stepRow() else { return nil }
    let started = try statement.requiredDouble(at: 0, column: "started_at")
    let ended = try statement.requiredDouble(at: 1, column: "ended_at")
    let value = try decode(Activity.self, try statement.requiredText(at: 2, column: "payload"))
    guard value.id == id,
      value.startedAt.timeIntervalSinceReferenceDate == started,
      value.endedAt.timeIntervalSinceReferenceDate == ended,
      !(try statement.stepRow())
    else { throw UnderstandingDerivationStoreError.invalidStoredDerivation }
    let membership = try database.prepare(
      "SELECT session_id FROM h2_activity_membership WHERE activity_id=? ORDER BY ordinal ASC")
    try membership.bind(raw.uuidString.lowercased(), at: 1)
    var ids: [SessionID] = []
    while try membership.stepRow() {
      guard let raw = UUID(uuidString: try membership.requiredText(at: 0, column: "session_id"))
      else { throw UnderstandingDerivationStoreError.invalidStoredDerivation }
      ids.append(SessionID(rawValue: raw))
    }
    guard ids == value.sessionIDs else {
      throw UnderstandingDerivationStoreError.invalidStoredDerivation
    }
    return value
  }

  private static func bind(
    _ day: DayDescriptor, to statement: SQLiteStatement, startingAt: Int32 = 2
  )
    throws
  {
    let date = day.logicalDate
    try statement.bind(
      String(format: "%04d-%02d-%02d", date.year, date.month, date.day), at: startingAt)
    try statement.bind(day.timeZoneIdentifier, at: startingAt + 1)
    try statement.bind(day.boundary.startsAt.timeIntervalSinceReferenceDate, at: startingAt + 2)
    try statement.bind(day.boundary.endsAt.timeIntervalSinceReferenceDate, at: startingAt + 3)
  }

  private static func canonical(_ values: [Session]) -> [Session] {
    values.sorted {
      $0.startedAt == $1.startedAt
        ? ($0.endedAt == $1.endedAt
          ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.endedAt < $1.endedAt)
        : $0.startedAt < $1.startedAt
    }
  }
  private static func storageKey(for scope: SessionScope) -> String {
    switch scope {
    case .workspace: return "workspace"
    case .display(let displayID): return displayID.rawValue.uuidString.lowercased()
    }
  }
  private static func canonical(_ values: [Activity]) -> [Activity] {
    values.sorted {
      $0.startedAt == $1.startedAt
        ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.startedAt < $1.startedAt
    }
  }
  private static func serialized<T: RawRepresentable>(_ ids: [T]) -> String
  where T.RawValue == UUID {
    ids.map { $0.rawValue.uuidString.lowercased() }.joined(separator: "|")
  }
  private static func sessionIdentity(_ value: PersistedUnderstandingDerivation) throws -> String {
    try identity(
      prefix: "h2-session-batch-v2-", day: value.day, revision: value.revision,
      identifiers: canonical(value.sessions).map(\.id))
  }
  private static func activityIdentity(
    _ value: PersistedUnderstandingDerivation, sessionBatchID: String
  ) throws -> String {
    try identity(
      prefix: "h2-activity-batch-v2-", day: value.day, revision: value.revision,
      identifiers: canonical(value.activities).map(\.id), extra: sessionBatchID)
  }
  private static func identity<T: RawRepresentable>(
    prefix: String, day: DayDescriptor, revision: UInt64, identifiers: [T], extra: String = ""
  ) throws -> String where T.RawValue == UUID {
    let payload =
      [
        String(
          format: "%04d-%02d-%02d", day.logicalDate.year, day.logicalDate.month, day.logicalDate.day
        ), day.timeZoneIdentifier, String(day.boundary.startsAt.timeIntervalSinceReferenceDate),
        String(day.boundary.endsAt.timeIntervalSinceReferenceDate), String(revision), extra,
      ] + identifiers.map { $0.rawValue.uuidString.lowercased() }
    return prefix
      + SHA256.hash(data: Data(payload.joined(separator: "\u{1F}").utf8)).map {
        String(format: "%02x", $0)
      }.joined()
  }
  private static func payload<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
  private static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    do { return try JSONDecoder().decode(type, from: Data(value.utf8)) } catch {
      throw UnderstandingDerivationStoreError.invalidStoredDerivation
    }
  }
}
