import DaydayCore
import Foundation

public enum WorkReportStoreError: Error, Equatable, Sendable {
  case invalidLimit
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case corruptedSchema(String)
  case invalidStoredPayload
  case reportConflict
  case revisionConflict
  case sourceConflict
  case sourceReferenceMismatch
  case invalidRevisionLineage
}

public actor SQLiteWorkReportRepository: WorkReportGenerationRepository {
  public static let currentSchemaVersion = 2

  private static let metadataSQL = """
    CREATE TABLE work_artifact_schema_metadata (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      schema_version INTEGER NOT NULL,
      schema_fingerprint TEXT NOT NULL
    ) STRICT
    """
  private static let migrationsSQL = """
    CREATE TABLE work_artifact_schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at REAL NOT NULL
    ) STRICT
    """
  private static let reportsSQL = """
    CREATE TABLE work_artifact_reports (
      report_id TEXT PRIMARY KEY NOT NULL,
      day_id TEXT UNIQUE NOT NULL,
      updated_at REAL NOT NULL,
      day_payload TEXT NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let revisionsSQL = """
    CREATE TABLE work_artifact_report_revisions (
      revision_id TEXT PRIMARY KEY NOT NULL,
      report_id TEXT NOT NULL REFERENCES work_artifact_reports(report_id) ON DELETE CASCADE,
      revision_number INTEGER NOT NULL CHECK (revision_number > 0),
      created_at REAL NOT NULL,
      payload TEXT NOT NULL,
      UNIQUE (report_id, revision_number)
    ) STRICT
    """
  private static let usageSQL = """
    CREATE TABLE work_artifact_model_usage (
      usage_id TEXT PRIMARY KEY NOT NULL,
      revision_id TEXT UNIQUE NOT NULL REFERENCES work_artifact_report_revisions(revision_id) ON DELETE CASCADE,
      completed_at REAL NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let reportsUpdatedIndexSQL =
    "CREATE INDEX work_artifact_reports_updated_at ON work_artifact_reports(updated_at DESC, report_id ASC)"
  private static let workNotesSQL = """
    CREATE TABLE work_artifact_work_notes (
      note_id TEXT PRIMARY KEY NOT NULL,
      day_id TEXT NOT NULL,
      created_at REAL NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let weatherSnapshotsSQL = """
    CREATE TABLE work_artifact_weather_snapshots (
      snapshot_id TEXT PRIMARY KEY NOT NULL,
      day_id TEXT NOT NULL,
      observed_at REAL NOT NULL,
      payload TEXT NOT NULL
    ) STRICT
    """
  private static let workNotesDayIndexSQL =
    "CREATE INDEX work_artifact_work_notes_day ON work_artifact_work_notes(day_id, created_at ASC, note_id ASC)"
  private static let weatherSnapshotsDayIndexSQL =
    "CREATE INDEX work_artifact_weather_snapshots_day ON work_artifact_weather_snapshots(day_id, observed_at ASC, snapshot_id ASC)"

  static let schemaV1Fingerprint = fingerprint(of: [
    metadataSQL, migrationsSQL, reportsSQL, revisionsSQL, usageSQL, reportsUpdatedIndexSQL,
  ])

  public static let expectedSchemaFingerprint = fingerprint(of: [
    metadataSQL, migrationsSQL, reportsSQL, revisionsSQL, usageSQL, reportsUpdatedIndexSQL,
    workNotesSQL, weatherSnapshotsSQL, workNotesDayIndexSQL, weatherSnapshotsDayIndexSQL,
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

  public func save(_ record: PersistedWorkReportRecord) throws -> WorkReportSaveResult {
    try database.transaction {
      try Self.saveRecord(record, into: database)
    }
  }

  public func saveGenerated(
    _ record: PersistedWorkReportRecord,
    sources: WorkReportGenerationSources
  ) throws -> WorkReportSaveResult {
    try Self.validate(sources: sources, for: record)
    return try database.transaction {
      try Self.validateObjectiveEventReferences(
        record.currentRevision.sourceReferences.objectiveEventIDs,
        in: database
      )
      for note in sources.workNotes { try Self.insert(note: note, into: database) }
      for snapshot in sources.weatherSnapshots {
        try Self.insert(weatherSnapshot: snapshot, into: database)
      }
      return try Self.saveRecord(record, into: database)
    }
  }

  public func workNote(id: WorkNoteID) throws -> PersistedWorkReportNote? {
    try Self.workNote(id: id, from: database)
  }

  public func weatherSnapshot(id: WeatherSnapshotID) throws -> WeatherSnapshot? {
    try Self.weatherSnapshot(id: id, from: database)
  }

  public func report(for dayID: DayID) throws -> PersistedWorkReportRecord? {
    try Self.record(for: dayID, from: database)
  }

  public func finalize(_ record: PersistedWorkReportRecord) throws -> WorkReportSaveResult {
    guard record.report.status == .final else {
      throw WorkReportStoreError.invalidRevisionLineage
    }
    try database.transaction {
      guard let current = try Self.record(for: record.report.dayID, from: database) else {
        throw WorkReportFinalizeError.notFound
      }
      guard record.report.id == current.report.id,
        record.report.dayID == current.report.dayID,
        record.report.currentRevisionID == current.report.currentRevisionID,
        record.report.currentRevisionNumber == current.report.currentRevisionNumber,
        record.currentRevision.id == current.currentRevision.id,
        record.day == current.day
      else { throw WorkReportFinalizeError.recordMismatch }
      guard current.report.status == .draft else {
        throw WorkReportFinalizeError.alreadyFinalized
      }
      guard record.report.finalizedAt != nil,
        let finalizedAt = record.report.finalizedAt,
        finalizedAt >= current.report.updatedAt
      else { throw WorkReportFinalizeError.invalidFinalization }

      let statement = try database.prepare(
        "UPDATE work_artifact_reports SET updated_at = ?, payload = ? WHERE report_id = ? AND day_id = ?"
      )
      try statement.bind(record.report.updatedAt.timeIntervalSinceReferenceDate, at: 1)
      try statement.bind(try Self.canonicalPayload(record.report), at: 2)
      try statement.bind(Self.uuid(record.report.id.rawValue), at: 3)
      try statement.bind(Self.uuid(record.report.dayID.rawValue), at: 4)
      try statement.expectDone()
      guard database.changedRowCount == 1 else { throw WorkReportStoreError.reportConflict }
    }
    return .updated
  }

  public func tokenUsage(in interval: Range<Date>) throws -> WorkReportTokenSummary {
    let statement = try database.prepare(
      """
      SELECT
        COALESCE(SUM(CAST(JSON_EXTRACT(payload, '$.inputTokens') AS INTEGER)), 0),
        COALESCE(SUM(CAST(JSON_EXTRACT(payload, '$.outputTokens') AS INTEGER)), 0),
        COALESCE(SUM(CAST(JSON_EXTRACT(payload, '$.cachedInputTokens') AS INTEGER)), 0),
        COALESCE(SUM(CAST(JSON_EXTRACT(payload, '$.totalTokens') AS INTEGER)), 0),
        COUNT(*)
      FROM work_artifact_model_usage
      WHERE completed_at >= ? AND completed_at < ?
      """
    )
    try statement.bind(interval.lowerBound.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(interval.upperBound.timeIntervalSinceReferenceDate, at: 2)
    guard try statement.stepRow() else { return .empty }
    let inputTokens = try statement.requiredInt64(at: 0, column: "input")
    let outputTokens = try statement.requiredInt64(at: 1, column: "output")
    let cachedInputTokens = try statement.requiredInt64(at: 2, column: "cached")
    let totalTokens = try statement.requiredInt64(at: 3, column: "total")
    let attemptCount = try statement.requiredInt64(at: 4, column: "attempts")
    return WorkReportTokenSummary(
      inputTokens: Int(inputTokens),
      outputTokens: Int(outputTokens),
      cachedInputTokens: Int(cachedInputTokens),
      totalTokens: Int(totalTokens),
      attemptCount: Int(attemptCount)
    )
  }

  public func revisions(for dayID: DayID) throws -> [WorkReportRevision] {
    let report = try Self.record(for: dayID, from: database)?.report
    guard let report else { return [] }
    let statement = try database.prepare(
      "SELECT report_id, revision_number FROM work_artifact_report_revisions WHERE report_id = ? ORDER BY revision_number ASC"
    )
    try statement.bind(Self.uuid(report.id.rawValue), at: 1)
    var revisions: [WorkReportRevision] = []
    while try statement.stepRow() {
      let reportID = try statement.requiredText(at: 0, column: "report_id")
      let revisionNumber = try statement.requiredInt64(at: 1, column: "revision_number")
      let revision = try Self.revision(
        for: report.id, revisionNumber: Int(revisionNumber), from: database
      )
      guard let revision, Self.uuid(revision.reportID.rawValue) == reportID else {
        throw WorkReportStoreError.invalidStoredPayload
      }
      revisions.append(revision)
    }
    return revisions
  }

  private static func revision(
    for reportID: WorkReportID,
    revisionNumber: Int,
    from database: SQLiteDatabase
  ) throws -> WorkReportRevision? {
    let statement = try database.prepare(
      "SELECT revision_id, report_id, revision_number, created_at, payload FROM work_artifact_report_revisions WHERE report_id = ? AND revision_number = ?"
    )
    try statement.bind(Self.uuid(reportID.rawValue), at: 1)
    try statement.bind(Int64(revisionNumber), at: 2)
    guard try statement.stepRow() else { return nil }
    let revisionID = try statement.requiredText(at: 0, column: "revision_id")
    let revisionReportID = try statement.requiredText(at: 1, column: "report_id")
    let storedNumber = try statement.requiredInt64(at: 2, column: "revision_number")
    let revisionCreatedAt = try statement.requiredDouble(at: 3, column: "created_at")
    let payload = try statement.requiredText(at: 4, column: "payload")
    guard !(try statement.stepRow()),
      let revision = try? decode(WorkReportRevision.self, payload: payload),
      Self.uuid(revision.id.rawValue) == revisionID,
      Self.uuid(revision.reportID.rawValue) == revisionReportID,
      revision.revisionNumber == revisionNumber,
      Int(revisionNumber) == Int(storedNumber),
      revision.createdAt.timeIntervalSinceReferenceDate == revisionCreatedAt
    else { throw WorkReportStoreError.invalidStoredPayload }
    return revision
  }

  public func recentReports(limit: Int) throws -> [PersistedWorkReportRecord] {
    guard (1...500).contains(limit) else { throw WorkReportStoreError.invalidLimit }
    let statement = try database.prepare(
      "SELECT day_id FROM work_artifact_reports ORDER BY updated_at DESC, report_id ASC LIMIT ?"
    )
    try statement.bind(Int64(limit), at: 1)
    var records: [PersistedWorkReportRecord] = []
    while try statement.stepRow() {
      let raw = try statement.requiredText(at: 0, column: "day_id")
      guard let id = UUID(uuidString: raw),
        let record = try Self.record(for: DayID(rawValue: id), from: database)
      else { throw WorkReportStoreError.invalidStoredPayload }
      records.append(record)
    }
    return records
  }

  public func schemaVersion() throws -> Int { try Self.metadata(from: database).version }
  public func schemaFingerprint() throws -> String { try Self.metadata(from: database).fingerprint }

  private static func validateSuccessor(
    _ next: PersistedWorkReportRecord,
    after current: PersistedWorkReportRecord
  ) throws {
    let report = next.report
    guard report.id == current.report.id,
      report.dayID == current.report.dayID,
      next.day == current.day,
      report.createdAt == current.report.createdAt,
      report.currentRevisionNumber == current.report.currentRevisionNumber + 1,
      next.currentRevision.previousRevisionID == current.report.currentRevisionID,
      report.updatedAt >= current.report.updatedAt
    else { throw WorkReportStoreError.invalidRevisionLineage }
  }

  private static func saveRecord(
    _ record: PersistedWorkReportRecord,
    into database: SQLiteDatabase
  ) throws -> WorkReportSaveResult {
    if let existing = try Self.record(for: record.report.dayID, from: database) {
      if existing == record { return .alreadyPresent }
      try Self.validateSuccessor(record, after: existing)
      try Self.insertRevision(record.currentRevision, into: database)
      if let usage = record.modelUsage { try Self.insertUsage(usage, into: database) }
      let statement = try database.prepare(
        "UPDATE work_artifact_reports SET updated_at = ?, day_payload = ?, payload = ? WHERE report_id = ? AND day_id = ?"
      )
      try statement.bind(record.report.updatedAt.timeIntervalSinceReferenceDate, at: 1)
      try statement.bind(try Self.canonicalPayload(record.day), at: 2)
      try statement.bind(try Self.canonicalPayload(record.report), at: 3)
      try statement.bind(Self.uuid(record.report.id.rawValue), at: 4)
      try statement.bind(Self.uuid(record.report.dayID.rawValue), at: 5)
      try statement.expectDone()
      guard database.changedRowCount == 1 else { throw WorkReportStoreError.reportConflict }
      return .updated
    }

    guard record.report.currentRevisionNumber == 1,
      record.currentRevision.revisionNumber == 1,
      record.currentRevision.previousRevisionID == nil
    else { throw WorkReportStoreError.invalidRevisionLineage }
    try Self.insertReport(record, into: database)
    try Self.insertRevision(record.currentRevision, into: database)
    if let usage = record.modelUsage { try Self.insertUsage(usage, into: database) }
    return .inserted
  }

  private static func validate(
    sources: WorkReportGenerationSources,
    for record: PersistedWorkReportRecord
  ) throws {
    let references = record.currentRevision.sourceReferences
    let sourceWorkNoteIDs = sources.workNotes.map(\.id)
    let sourceWeatherSnapshotIDs = sources.weatherSnapshots.map(\.id)
    guard Set(references.workNoteIDs).count == references.workNoteIDs.count,
      Set(references.objectiveEventIDs).count == references.objectiveEventIDs.count,
      Set(references.weatherSnapshotIDs).count == references.weatherSnapshotIDs.count,
      Set(sourceWorkNoteIDs).count == sourceWorkNoteIDs.count,
      Set(sourceWeatherSnapshotIDs).count == sourceWeatherSnapshotIDs.count,
      Set(references.workNoteIDs) == Set(sourceWorkNoteIDs),
      references.workNoteIDs.count == sources.workNotes.count,
      Set(references.weatherSnapshotIDs) == Set(sourceWeatherSnapshotIDs),
      references.weatherSnapshotIDs.count == sources.weatherSnapshots.count,
      sources.workNotes.allSatisfy({ $0.dayID == record.day.id }),
      sources.weatherSnapshots.allSatisfy({ $0.dayID == record.day.id })
    else { throw WorkReportStoreError.sourceReferenceMismatch }
  }

  private static func validateObjectiveEventReferences(
    _ eventIDs: [EventID],
    in database: SQLiteDatabase
  ) throws {
    guard !eventIDs.isEmpty else { return }
    let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
    do {
      let statement = try database.prepare(
        """
        SELECT COUNT(*)
        FROM objective_events event
        JOIN objective_application_contexts context ON context.event_id = event.id
        WHERE event.id IN (\(placeholders))
          AND event.kind = 'applicationContextChanged'
          AND event.security_disposition = 'allowed'
        """
      )
      for (index, eventID) in eventIDs.enumerated() {
        try statement.bind(uuid(eventID.rawValue), at: Int32(index + 1))
      }
      guard try statement.stepRow(),
        try statement.requiredInt64(at: 0, column: "objective_event_count") == Int64(eventIDs.count)
      else { throw WorkReportStoreError.sourceReferenceMismatch }
    } catch let error as WorkReportStoreError {
      throw error
    } catch {
      throw WorkReportStoreError.sourceReferenceMismatch
    }
  }

  private static func insert(
    note: PersistedWorkReportNote,
    into database: SQLiteDatabase
  ) throws {
    if let existing = try workNote(id: note.id, from: database) {
      guard existing == note else { throw WorkReportStoreError.sourceConflict }
      return
    }
    let statement = try database.prepare(
      "INSERT INTO work_artifact_work_notes(note_id, day_id, created_at, payload) VALUES (?, ?, ?, ?)"
    )
    try statement.bind(uuid(note.id.rawValue), at: 1)
    try statement.bind(uuid(note.dayID.rawValue), at: 2)
    try statement.bind(note.createdAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(try canonicalPayload(note), at: 4)
    do {
      try statement.expectDone()
    } catch {
      throw WorkReportStoreError.sourceConflict
    }
  }

  private static func insert(
    weatherSnapshot: WeatherSnapshot,
    into database: SQLiteDatabase
  ) throws {
    if let existing = try Self.weatherSnapshot(id: weatherSnapshot.id, from: database) {
      guard existing == weatherSnapshot else { throw WorkReportStoreError.sourceConflict }
      return
    }
    let statement = try database.prepare(
      "INSERT INTO work_artifact_weather_snapshots(snapshot_id, day_id, observed_at, payload) VALUES (?, ?, ?, ?)"
    )
    try statement.bind(uuid(weatherSnapshot.id.rawValue), at: 1)
    try statement.bind(uuid(weatherSnapshot.dayID.rawValue), at: 2)
    try statement.bind(weatherSnapshot.observedAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(try canonicalPayload(weatherSnapshot), at: 4)
    do {
      try statement.expectDone()
    } catch {
      throw WorkReportStoreError.sourceConflict
    }
  }

  private static func workNote(
    id: WorkNoteID,
    from database: SQLiteDatabase
  ) throws -> PersistedWorkReportNote? {
    let statement = try database.prepare(
      "SELECT note_id, day_id, created_at, payload FROM work_artifact_work_notes WHERE note_id = ?"
    )
    try statement.bind(uuid(id.rawValue), at: 1)
    guard try statement.stepRow() else { return nil }
    let noteID = try statement.requiredText(at: 0, column: "note_id")
    let dayID = try statement.requiredText(at: 1, column: "day_id")
    let createdAt = try statement.requiredDouble(at: 2, column: "created_at")
    let payload = try statement.requiredText(at: 3, column: "payload")
    guard !(try statement.stepRow()),
      let note = try? decode(PersistedWorkReportNote.self, payload: payload),
      uuid(note.id.rawValue) == noteID,
      uuid(note.dayID.rawValue) == dayID,
      note.createdAt.timeIntervalSinceReferenceDate == createdAt
    else { throw WorkReportStoreError.invalidStoredPayload }
    return note
  }

  private static func weatherSnapshot(
    id: WeatherSnapshotID,
    from database: SQLiteDatabase
  ) throws -> WeatherSnapshot? {
    let statement = try database.prepare(
      "SELECT snapshot_id, day_id, observed_at, payload FROM work_artifact_weather_snapshots WHERE snapshot_id = ?"
    )
    try statement.bind(uuid(id.rawValue), at: 1)
    guard try statement.stepRow() else { return nil }
    let snapshotID = try statement.requiredText(at: 0, column: "snapshot_id")
    let dayID = try statement.requiredText(at: 1, column: "day_id")
    let observedAt = try statement.requiredDouble(at: 2, column: "observed_at")
    let payload = try statement.requiredText(at: 3, column: "payload")
    guard !(try statement.stepRow()),
      let snapshot = try? decode(WeatherSnapshot.self, payload: payload),
      uuid(snapshot.id.rawValue) == snapshotID,
      uuid(snapshot.dayID.rawValue) == dayID,
      snapshot.observedAt.timeIntervalSinceReferenceDate == observedAt
    else { throw WorkReportStoreError.invalidStoredPayload }
    return snapshot
  }

  private static func insertReport(
    _ record: PersistedWorkReportRecord,
    into database: SQLiteDatabase
  ) throws {
    let report = record.report
    let statement = try database.prepare(
      "INSERT INTO work_artifact_reports(report_id, day_id, updated_at, day_payload, payload) VALUES (?, ?, ?, ?, ?)"
    )
    try statement.bind(uuid(report.id.rawValue), at: 1)
    try statement.bind(uuid(report.dayID.rawValue), at: 2)
    try statement.bind(report.updatedAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(try canonicalPayload(record.day), at: 4)
    try statement.bind(try canonicalPayload(report), at: 5)
    do {
      try statement.expectDone()
    } catch {
      throw WorkReportStoreError.reportConflict
    }
  }

  private static func insertRevision(
    _ revision: WorkReportRevision,
    into database: SQLiteDatabase
  ) throws {
    let statement = try database.prepare(
      "INSERT INTO work_artifact_report_revisions(revision_id, report_id, revision_number, created_at, payload) VALUES (?, ?, ?, ?, ?)"
    )
    try statement.bind(uuid(revision.id.rawValue), at: 1)
    try statement.bind(uuid(revision.reportID.rawValue), at: 2)
    try statement.bind(Int64(revision.revisionNumber), at: 3)
    try statement.bind(revision.createdAt.timeIntervalSinceReferenceDate, at: 4)
    try statement.bind(try canonicalPayload(revision), at: 5)
    do {
      try statement.expectDone()
    } catch {
      throw WorkReportStoreError.revisionConflict
    }
  }

  private static func insertUsage(_ usage: ModelUsage, into database: SQLiteDatabase) throws {
    guard let revisionID = usage.revisionID else {
      throw WorkReportStoreError.invalidRevisionLineage
    }
    let statement = try database.prepare(
      "INSERT INTO work_artifact_model_usage(usage_id, revision_id, completed_at, payload) VALUES (?, ?, ?, ?)"
    )
    try statement.bind(uuid(usage.id.rawValue), at: 1)
    try statement.bind(uuid(revisionID.rawValue), at: 2)
    try statement.bind(usage.completedAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(try canonicalPayload(usage), at: 4)
    do {
      try statement.expectDone()
    } catch {
      throw WorkReportStoreError.revisionConflict
    }
  }

  private static func record(
    for dayID: DayID,
    from database: SQLiteDatabase
  ) throws -> PersistedWorkReportRecord? {
    let reportStatement = try database.prepare(
      "SELECT report_id, day_id, updated_at, day_payload, payload FROM work_artifact_reports WHERE day_id = ?"
    )
    try reportStatement.bind(uuid(dayID.rawValue), at: 1)
    guard try reportStatement.stepRow() else { return nil }
    let reportID = try reportStatement.requiredText(at: 0, column: "report_id")
    let storedDayID = try reportStatement.requiredText(at: 1, column: "day_id")
    let updatedAt = try reportStatement.requiredDouble(at: 2, column: "updated_at")
    let dayPayload = try reportStatement.requiredText(at: 3, column: "day_payload")
    let reportPayload = try reportStatement.requiredText(at: 4, column: "payload")
    guard !(try reportStatement.stepRow()),
      let day = try? decode(DayDescriptor.self, payload: dayPayload),
      let report = try? decode(WorkReport.self, payload: reportPayload),
      day.id == report.dayID,
      uuid(report.id.rawValue) == reportID,
      uuid(report.dayID.rawValue) == storedDayID,
      report.updatedAt.timeIntervalSinceReferenceDate == updatedAt
    else { throw WorkReportStoreError.invalidStoredPayload }

    let revisionStatement = try database.prepare(
      "SELECT revision_id, report_id, revision_number, created_at, payload FROM work_artifact_report_revisions WHERE revision_id = ?"
    )
    try revisionStatement.bind(uuid(report.currentRevisionID.rawValue), at: 1)
    guard try revisionStatement.stepRow() else {
      throw WorkReportStoreError.invalidStoredPayload
    }
    let revisionID = try revisionStatement.requiredText(at: 0, column: "revision_id")
    let revisionReportID = try revisionStatement.requiredText(at: 1, column: "report_id")
    let revisionNumber = try revisionStatement.requiredInt64(at: 2, column: "revision_number")
    let revisionCreatedAt = try revisionStatement.requiredDouble(at: 3, column: "created_at")
    let revisionPayload = try revisionStatement.requiredText(at: 4, column: "payload")
    guard !(try revisionStatement.stepRow()),
      let revision = try? decode(WorkReportRevision.self, payload: revisionPayload),
      uuid(revision.id.rawValue) == revisionID,
      uuid(revision.reportID.rawValue) == revisionReportID,
      revision.revisionNumber == revisionNumber,
      revision.createdAt.timeIntervalSinceReferenceDate == revisionCreatedAt
    else { throw WorkReportStoreError.invalidStoredPayload }

    let usageStatement = try database.prepare(
      "SELECT usage_id, revision_id, completed_at, payload FROM work_artifact_model_usage WHERE revision_id = ?"
    )
    try usageStatement.bind(revisionID, at: 1)
    var usage: ModelUsage?
    if try usageStatement.stepRow() {
      let usageID = try usageStatement.requiredText(at: 0, column: "usage_id")
      let usageRevisionID = try usageStatement.requiredText(at: 1, column: "revision_id")
      let completedAt = try usageStatement.requiredDouble(at: 2, column: "completed_at")
      let payload = try usageStatement.requiredText(at: 3, column: "payload")
      guard let decoded = try? decode(ModelUsage.self, payload: payload),
        uuid(decoded.id.rawValue) == usageID,
        decoded.revisionID.map({ uuid($0.rawValue) }) == usageRevisionID,
        decoded.completedAt.timeIntervalSinceReferenceDate == completedAt
      else { throw WorkReportStoreError.invalidStoredPayload }
      usage = decoded
      guard !(try usageStatement.stepRow()) else {
        throw WorkReportStoreError.invalidStoredPayload
      }
    }
    return try PersistedWorkReportRecord(
      day: day,
      report: report,
      currentRevision: revision,
      modelUsage: usage
    )
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.transaction {
      let names = try database.schemaObjectNames(withPrefix: "work_artifact")
      if names.isEmpty {
        try database.execute(metadataSQL)
        try database.execute(migrationsSQL)
        try database.execute(reportsSQL)
        try database.execute(revisionsSQL)
        try database.execute(usageSQL)
        try database.execute(reportsUpdatedIndexSQL)
        try database.execute(workNotesSQL)
        try database.execute(weatherSnapshotsSQL)
        try database.execute(workNotesDayIndexSQL)
        try database.execute(weatherSnapshotsDayIndexSQL)
        let migration1 = try database.prepare(
          "INSERT INTO work_artifact_schema_migrations(version, applied_at) VALUES (1, ?)"
        )
        try migration1.bind(Date().timeIntervalSince1970, at: 1)
        try migration1.expectDone()
        let migration2 = try database.prepare(
          "INSERT INTO work_artifact_schema_migrations(version, applied_at) VALUES (2, ?)"
        )
        try migration2.bind(Date().timeIntervalSince1970, at: 1)
        try migration2.expectDone()
        let metadata = try database.prepare(
          "INSERT INTO work_artifact_schema_metadata(singleton, schema_version, schema_fingerprint) VALUES (1, 2, ?)"
        )
        try metadata.bind(expectedSchemaFingerprint, at: 1)
        try metadata.expectDone()
      }

      var metadata = try Self.metadata(from: database)
      guard metadata.version <= currentSchemaVersion else {
        throw WorkReportStoreError.unsupportedSchemaVersion(
          found: metadata.version,
          supported: currentSchemaVersion
        )
      }

      if metadata.version == 1 {
        guard metadata.fingerprint == schemaV1Fingerprint else {
          throw WorkReportStoreError.corruptedSchema("Unexpected version 1 fingerprint")
        }
        let versionOneExpected = [
          ("table", "work_artifact_schema_metadata", metadataSQL),
          ("table", "work_artifact_schema_migrations", migrationsSQL),
          ("table", "work_artifact_reports", reportsSQL),
          ("table", "work_artifact_report_revisions", revisionsSQL),
          ("table", "work_artifact_model_usage", usageSQL),
          ("index", "work_artifact_reports_updated_at", reportsUpdatedIndexSQL),
        ]
        guard names == versionOneExpected.map(\.1).sorted() else {
          throw WorkReportStoreError.corruptedSchema("Unexpected version 1 schema objects")
        }
        for (type, name, sql) in versionOneExpected {
          guard let found = try database.schemaSQL(type: type, name: name),
            normalizedSQL(found) == normalizedSQL(sql)
          else { throw WorkReportStoreError.corruptedSchema("Unexpected schema object: \(name)") }
        }
        let versionOneJournal = try database.prepare(
          "SELECT version FROM work_artifact_schema_migrations ORDER BY version ASC"
        )
        guard try versionOneJournal.stepRow(),
          try versionOneJournal.requiredInt64(at: 0, column: "version") == 1,
          !(try versionOneJournal.stepRow())
        else { throw WorkReportStoreError.corruptedSchema("Invalid version 1 migration journal") }

        try database.execute(workNotesSQL)
        try database.execute(weatherSnapshotsSQL)
        try database.execute(workNotesDayIndexSQL)
        try database.execute(weatherSnapshotsDayIndexSQL)
        let migration = try database.prepare(
          "INSERT INTO work_artifact_schema_migrations(version, applied_at) VALUES (2, ?)"
        )
        try migration.bind(Date().timeIntervalSince1970, at: 1)
        try migration.expectDone()
        let update = try database.prepare(
          "UPDATE work_artifact_schema_metadata SET schema_version = 2, schema_fingerprint = ? WHERE singleton = 1"
        )
        try update.bind(expectedSchemaFingerprint, at: 1)
        try update.expectDone()
        guard database.changedRowCount == 1 else {
          throw WorkReportStoreError.corruptedSchema("Unable to update schema metadata")
        }
        metadata = try Self.metadata(from: database)
      }

      guard metadata.version == currentSchemaVersion,
        metadata.fingerprint == expectedSchemaFingerprint
      else { throw WorkReportStoreError.corruptedSchema("Unexpected schema metadata") }

      let expected = [
        ("table", "work_artifact_schema_metadata", metadataSQL),
        ("table", "work_artifact_schema_migrations", migrationsSQL),
        ("table", "work_artifact_reports", reportsSQL),
        ("table", "work_artifact_report_revisions", revisionsSQL),
        ("table", "work_artifact_model_usage", usageSQL),
        ("table", "work_artifact_work_notes", workNotesSQL),
        ("table", "work_artifact_weather_snapshots", weatherSnapshotsSQL),
        ("index", "work_artifact_reports_updated_at", reportsUpdatedIndexSQL),
        ("index", "work_artifact_work_notes_day", workNotesDayIndexSQL),
        ("index", "work_artifact_weather_snapshots_day", weatherSnapshotsDayIndexSQL),
      ]
      guard
        try database.schemaObjectNames(withPrefix: "work_artifact")
          == expected.map(\.1).sorted()
      else { throw WorkReportStoreError.corruptedSchema("Unexpected schema objects") }
      for (type, name, sql) in expected {
        guard let found = try database.schemaSQL(type: type, name: name),
          normalizedSQL(found) == normalizedSQL(sql)
        else { throw WorkReportStoreError.corruptedSchema("Unexpected schema object: \(name)") }
      }
      let journal = try database.prepare(
        "SELECT version FROM work_artifact_schema_migrations ORDER BY version ASC"
      )
      guard try journal.stepRow(),
        try journal.requiredInt64(at: 0, column: "version") == 1,
        try journal.stepRow(),
        try journal.requiredInt64(at: 0, column: "version") == 2,
        !(try journal.stepRow())
      else { throw WorkReportStoreError.corruptedSchema("Invalid migration journal") }
    }
  }

  private static func metadata(
    from database: SQLiteDatabase
  ) throws -> (version: Int, fingerprint: String) {
    let statement = try database.prepare(
      "SELECT schema_version, schema_fingerprint FROM work_artifact_schema_metadata WHERE singleton = 1"
    )
    guard try statement.stepRow(),
      let version = Int(exactly: try statement.requiredInt64(at: 0, column: "schema_version"))
    else { throw WorkReportStoreError.corruptedSchema("Missing schema metadata") }
    let fingerprint = try statement.requiredText(at: 1, column: "schema_fingerprint")
    guard !(try statement.stepRow()) else {
      throw WorkReportStoreError.corruptedSchema("Duplicate schema metadata")
    }
    return (version, fingerprint)
  }

  private static func canonicalPayload<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw WorkReportStoreError.invalidStoredPayload
    }
    return string
  }

  private static func decode<T: Codable>(_ type: T.Type, payload: String) throws -> T {
    guard let data = payload.data(using: .utf8) else {
      throw WorkReportStoreError.invalidStoredPayload
    }
    let decoded = try JSONDecoder().decode(type, from: data)
    guard try canonicalPayload(decoded) == payload else {
      throw WorkReportStoreError.invalidStoredPayload
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
