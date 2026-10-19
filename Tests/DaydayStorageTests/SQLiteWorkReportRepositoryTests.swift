import CSQLite
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite work report repository", .serialized)
struct SQLiteWorkReportRepositoryTests {
  @Test("initial report, revision and usage are saved atomically and idempotently")
  func initialSaveAndIdempotency() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 1, createdAt: date(100))

    #expect(try await repository.save(first) == .inserted)
    #expect(try await repository.save(first) == .alreadyPresent)
    #expect(try await repository.report(for: first.report.dayID) == first)
    #expect(try await repository.schemaVersion() == 2)
    #expect(
      try await repository.schemaFingerprint()
        == SQLiteWorkReportRepository.expectedSchemaFingerprint)
  }

  @Test("generated report commits resolvable note and weather sources atomically")
  func generatedSourcesAreResolvable() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let base = try makeInitialRecord(seed: 40, createdAt: date(1_400))
    let note = try PersistedWorkReportNote(
      id: WorkNoteID(rawValue: uuid(40, suffix: 5)),
      dayID: base.day.id,
      createdAt: date(1_400),
      body: "完成日报来源闭环。"
    )
    let weather = try makeWeather(
      id: WeatherSnapshotID(rawValue: uuid(40, suffix: 6)),
      dayID: base.day.id,
      observedAt: date(1_400)
    )
    let references = WorkReportSourceReferences(
      workNoteIDs: [note.id],
      weatherSnapshotIDs: [weather.id]
    )
    let record = try makeInitialRecord(
      seed: 41,
      createdAt: date(1_400),
      dayID: base.day.id,
      sourceReferences: references
    )

    #expect(
      try await repository.saveGenerated(
        record,
        sources: WorkReportGenerationSources(
          workNotes: [note],
          weatherSnapshots: [weather]
        )
      ) == .inserted
    )
    #expect(try await repository.workNote(id: note.id) == note)
    #expect(try await repository.weatherSnapshot(id: weather.id) == weather)
    #expect(
      try await repository.report(for: record.day.id)?.currentRevision.sourceReferences
        == references
    )
  }

  @Test("generated report objective-event references must resolve to admitted application facts")
  func objectiveEventSourcesAreResolvable() async throws {
    let url = URL(fileURLWithPath: "/tmp/dayday-report-objective-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
    let location = SQLiteDatabaseLocation.file(url)
    let objective = try SQLiteObjectiveEventRepository(location: location)
    let reports = try SQLiteWorkReportRepository(location: location)
    let application = try await objective.resolveApplication(
      bundleIdentifier: "com.tencent.xinWeChat",
      displayLabel: "WeChat"
    )
    let eventID = EventID(rawValue: uuid(45, suffix: 8))
    let event = try ObjectiveEvent(
      id: eventID,
      kind: .applicationContextChanged,
      occurredAt: date(1_700),
      timeZoneIdentifier: "UTC",
      source: CollectorSource(
        collector: .applicationWindowContext,
        collectorVersion: "test-v1",
        payloadSchemaVersion: 1
      ),
      securityDisposition: .allowed
    )
    let context = try ApplicationContextRecord(
      eventID: eventID,
      applicationIdentifier: application.identifier,
      displayLabelSnapshot: "WeChat",
      windowTitleSnapshot: "产品研发群 · 陈工"
    )
    _ = try await objective.insertApplicationContext(
      ApplicationContextWrite(event: event, record: context)
    )
    let record = try makeInitialRecord(
      seed: 45,
      createdAt: date(1_700),
      sourceReferences: WorkReportSourceReferences(objectiveEventIDs: [eventID])
    )

    #expect(try await reports.saveGenerated(record, sources: .empty) == .inserted)
    #expect(
      try await reports.report(for: record.day.id)?.currentRevision.sourceReferences
        .objectiveEventIDs == [eventID]
    )

    let unresolved = try makeInitialRecord(
      seed: 46,
      createdAt: date(1_800),
      sourceReferences: WorkReportSourceReferences(objectiveEventIDs: [EventID()])
    )
    await #expect(throws: WorkReportStoreError.sourceReferenceMismatch) {
      _ = try await reports.saveGenerated(unresolved, sources: .empty)
    }
  }

  @Test("source mismatch fails before writing either report or source artifacts")
  func sourceMismatchRollsBack() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let record = try makeInitialRecord(
      seed: 42,
      createdAt: date(1_500),
      sourceReferences: WorkReportSourceReferences(
        workNoteIDs: [WorkNoteID(rawValue: uuid(42, suffix: 5))]
      )
    )

    await #expect(throws: WorkReportStoreError.sourceReferenceMismatch) {
      _ = try await repository.saveGenerated(record, sources: .empty)
    }
    #expect(try await repository.report(for: record.day.id) == nil)
  }

  @Test("version one database migrates source tables without losing reports")
  func versionOneMigration() async throws {
    let url = URL(fileURLWithPath: "/tmp/dayday-work-report-v1-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
    let record = try makeInitialRecord(seed: 43, createdAt: date(1_600))
    do {
      let repository = try SQLiteWorkReportRepository(location: .file(url))
      _ = try await repository.save(record)
    }
    try executeWorkReportSQL(
      """
      DROP INDEX work_artifact_work_notes_day;
      DROP INDEX work_artifact_weather_snapshots_day;
      DROP TABLE work_artifact_work_notes;
      DROP TABLE work_artifact_weather_snapshots;
      DELETE FROM work_artifact_schema_migrations WHERE version = 2;
      UPDATE work_artifact_schema_metadata
      SET schema_version = 1,
          schema_fingerprint = '\(SQLiteWorkReportRepository.schemaV1Fingerprint)'
      WHERE singleton = 1;
      """,
      at: url
    )

    let migrated = try SQLiteWorkReportRepository(location: .file(url))
    #expect(try await migrated.schemaVersion() == 2)
    #expect(try await migrated.report(for: record.day.id) == record)
  }

  @Test("a successor revision updates the same day without forking history")
  func successorUpdate() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 2, createdAt: date(200))
    _ = try await repository.save(first)
    let second = try makeSuccessor(first, body: "第二版日报", at: date(201), seed: 21)

    #expect(try await repository.save(second) == .updated)
    #expect(try await repository.report(for: first.report.dayID) == second)
    #expect(try await repository.recentReports(limit: 10) == [second])
  }

  @Test("invalid lineage rolls back the entire attempted update")
  func invalidLineageRollsBack() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 3, createdAt: date(300))
    _ = try await repository.save(first)

    let unrelated = try makeInitialRecord(
      seed: 4,
      createdAt: date(301),
      dayID: first.report.dayID
    )
    await #expect(throws: WorkReportStoreError.invalidRevisionLineage) {
      _ = try await repository.save(unrelated)
    }
    #expect(try await repository.report(for: first.report.dayID) == first)
  }

  @Test("recent reports are ordered by updated time and limits fail closed")
  func recentOrderingAndLimits() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let older = try makeInitialRecord(seed: 5, createdAt: date(400))
    let newer = try makeInitialRecord(seed: 6, createdAt: date(500))
    _ = try await repository.save(older)
    _ = try await repository.save(newer)

    #expect(try await repository.recentReports(limit: 1) == [newer])
    await #expect(throws: WorkReportStoreError.invalidLimit) {
      _ = try await repository.recentReports(limit: 0)
    }
  }

  @Test("file reopen preserves records and schema tampering fails closed")
  func reopenAndSchemaTampering() async throws {
    let url = URL(fileURLWithPath: "/tmp/dayday-work-report-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
    let first = try makeInitialRecord(seed: 7, createdAt: date(600))
    let repository = try SQLiteWorkReportRepository(location: .file(url))
    _ = try await repository.save(first)

    let reopened = try SQLiteWorkReportRepository(location: .file(url))
    #expect(try await reopened.report(for: first.report.dayID) == first)
    try executeWorkReportSQL("DROP INDEX work_artifact_reports_updated_at", at: url)
    #expect(throws: WorkReportStoreError.corruptedSchema("Unexpected schema objects")) {
      _ = try SQLiteWorkReportRepository(location: .file(url))
    }
  }

  @Test("finalize transitions a draft to final without appending a revision")
  func finalizeDraft() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 8, createdAt: date(700))
    _ = try await repository.save(first)

    let finalRecord = try makeFinalizedRecord(first, at: date(701))
    #expect(try await repository.finalize(finalRecord) == .updated)
    let stored = try #require(await repository.report(for: first.report.dayID))
    #expect(stored.report.status == .final)
    #expect(stored.report.currentRevisionID == first.currentRevision.id)
    #expect(stored.report.finalizedAt == date(701))
    #expect(try await repository.revisions(for: first.report.dayID).count == 1)
  }

  @Test("finalizing an already finalized report fails closed")
  func finalizeAlreadyFinalized() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 10, createdAt: date(800))
    _ = try await repository.save(first)
    let finalRecord = try makeFinalizedRecord(first, at: date(801))
    _ = try await repository.finalize(finalRecord)

    let againRecord = try makeFinalizedRecord(first, at: date(802))
    await #expect(throws: WorkReportFinalizeError.alreadyFinalized) {
      _ = try await repository.finalize(againRecord)
    }
  }

  @Test("finalizing a record that mismatches the stored lineage fails closed")
  func finalizeMismatchRollsBack() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 11, createdAt: date(900))
    _ = try await repository.save(first)
    let successor = try makeSuccessor(first, body: "第二版", at: date(901), seed: 22)
    _ = try await repository.save(successor)

    // Attempt to finalize against a stale (earlier) revision, which must not overwrite the new one.
    let staleReport = try first.report.finalizedByUser(at: date(902))
    let staleRecord = try PersistedWorkReportRecord(
      day: first.day,
      report: staleReport,
      currentRevision: first.currentRevision,
      modelUsage: nil
    )
    await #expect(throws: WorkReportFinalizeError.recordMismatch) {
      _ = try await repository.finalize(staleRecord)
    }
    let stored = try await repository.report(for: first.report.dayID)
    #expect(stored == successor)
  }

  @Test("finalize on a missing day fails closed")
  func finalizeMissingDay() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let record = try makeInitialRecord(seed: 12, createdAt: date(1000))
    let finalRecord = try makeFinalizedRecord(record, at: date(1001))
    await #expect(throws: WorkReportFinalizeError.notFound) {
      _ = try await repository.finalize(finalRecord)
    }
  }

  @Test("token usage aggregates only completed attempts within the interval")
  func tokenUsageAggregation() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 30, createdAt: date(1200))
    _ = try await repository.save(first)
    let second = try makeSuccessor(first, body: "第二版", at: date(1201), seed: 31)
    _ = try await repository.save(second)

    // The usage rows complete at the revision creation date; both land inside this range.
    let summary = try await repository.tokenUsage(
      in: date(1199)..<date(1202))
    #expect(summary.attemptCount == 2)
    #expect(summary.inputTokens == 30 + 31)
    #expect(summary.outputTokens == 4)
    #expect(summary.totalTokens == (30 + 2) + (31 + 2))

    // Outside the interval nothing is counted.
    let empty = try await repository.tokenUsage(in: date(1199)..<date(1200))
    #expect(empty == .empty)
  }

  @Test("revisions returns the oldest-first immutable lineage")
  func revisionHistory() async throws {
    let repository = try SQLiteWorkReportRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 20, createdAt: date(1100))
    _ = try await repository.save(first)
    let second = try makeSuccessor(first, body: "第二版", at: date(1101), seed: 23)
    _ = try await repository.save(second)
    let third = try makeSuccessor(second, body: "第三版", at: date(1102), seed: 24)
    _ = try await repository.save(third)
    let revisions = try await repository.revisions(for: first.report.dayID)
    #expect(revisions.map(\.revisionNumber) == [1, 2, 3])
    #expect(revisions.last?.body == "第三版")
    #expect(revisions.first?.body == "日报-20")
  }

  private func makeInitialRecord(
    seed: UInt8,
    createdAt: Date,
    dayID: DayID? = nil,
    sourceReferences: WorkReportSourceReferences = .empty
  ) throws -> PersistedWorkReportRecord {
    let reportID = WorkReportID(rawValue: uuid(seed, suffix: 1))
    let day = try makeDay(
      id: dayID ?? DayID(rawValue: uuid(seed, suffix: 3)),
      containing: createdAt
    )
    let revision = try WorkReportRevision(
      id: WorkReportRevisionID(rawValue: uuid(seed, suffix: 2)),
      reportID: reportID,
      revisionNumber: 1,
      previousRevisionID: nil,
      body: "日报-\(seed)",
      origin: .model,
      modelProvenance: try provenance(),
      sourceReferences: sourceReferences,
      createdAt: createdAt
    )
    let report = try WorkReport(
      id: reportID,
      dayID: day.id,
      initialRevision: revision,
      createdAt: createdAt
    )
    let usage = try usage(for: revision, seed: seed, at: createdAt)
    return try PersistedWorkReportRecord(
      day: day,
      report: report,
      currentRevision: revision,
      modelUsage: usage
    )
  }

  private func makeWeather(
    id: WeatherSnapshotID,
    dayID: DayID,
    observedAt: Date
  ) throws -> WeatherSnapshot {
    let location = try CityWeatherLocation(
      id: CityWeatherLocationID(rawValue: uuid(44, suffix: 7)),
      displayName: "深圳南山区",
      timeZoneIdentifier: "Asia/Shanghai",
      providerLocationKey: WeatherProviderLocationKey(rawValue: "district-nanshan")
    )
    return try WeatherSnapshot(
      id: id,
      dayID: dayID,
      location: location,
      provider: "Open-Meteo",
      providerSchemaVersion: "current-v1",
      observedAt: observedAt,
      retrievedAt: observedAt,
      condition: "多云",
      temperatureCelsius: 30,
      humidityPercent: 70,
      attribution: "Open-Meteo"
    )
  }

  private func makeSuccessor(
    _ current: PersistedWorkReportRecord,
    body: String,
    at date: Date,
    seed: UInt8
  ) throws -> PersistedWorkReportRecord {
    let revision = try WorkReportRevision(
      id: WorkReportRevisionID(rawValue: uuid(seed, suffix: 2)),
      reportID: current.report.id,
      revisionNumber: current.report.currentRevisionNumber + 1,
      previousRevisionID: current.currentRevision.id,
      body: body,
      origin: .model,
      modelProvenance: try provenance(),
      createdAt: date
    )
    let report = try current.report.accepting(revision, initiatedBy: .automatic, at: date)
    return try PersistedWorkReportRecord(
      day: current.day,
      report: report,
      currentRevision: revision,
      modelUsage: try usage(for: revision, seed: seed, at: date)
    )
  }

  private func makeFinalizedRecord(
    _ current: PersistedWorkReportRecord,
    at date: Date
  ) throws -> PersistedWorkReportRecord {
    let report = try current.report.finalizedByUser(at: date)
    return try PersistedWorkReportRecord(
      day: current.day,
      report: report,
      currentRevision: current.currentRevision,
      modelUsage: current.modelUsage
    )
  }

  private func provenance() throws -> ModelProvenance {
    try ModelProvenance(
      provider: "deepseek",
      model: "deepseek-v4-flash",
      promptVersion: "work-report-v1"
    )
  }

  private func usage(
    for revision: WorkReportRevision,
    seed: UInt8,
    at date: Date
  ) throws -> ModelUsage {
    try ModelUsage(
      id: ModelUsageID(rawValue: uuid(seed, suffix: 4)),
      revisionID: revision.id,
      requestID: "request-\(seed)",
      provider: "deepseek",
      model: "deepseek-v4-flash",
      task: .workReport,
      startedAt: date,
      completedAt: date,
      outcome: .success,
      inputTokens: Int(seed),
      outputTokens: 2,
      totalTokens: Int(seed) + 2
    )
  }

  private func date(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
  }

  private func makeDay(id: DayID, containing date: Date) throws -> DayDescriptor {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let policy = WorkdayBoundary.standard
    let start = try policy.start(containing: date, calendar: calendar)
    let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
    let components = calendar.dateComponents([.year, .month, .day], from: start)
    return try DayDescriptor(
      id: id,
      logicalDate: .init(
        year: try #require(components.year),
        month: try #require(components.month),
        day: try #require(components.day)
      ),
      timeZoneIdentifier: "UTC",
      boundary: .init(hour: policy.hour, startsAt: start, endsAt: end)
    )
  }

  private func uuid(_ seed: UInt8, suffix: UInt8) -> UUID {
    UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
  }
}

private enum WorkReportSQLiteTestError: Error {
  case open(Int32)
  case execute(Int32, String)
}

private func executeWorkReportSQL(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
  guard openResult == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw WorkReportSQLiteTestError.open(openResult)
  }
  defer { sqlite3_close_v2(database) }
  var message: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &message)
  guard result == SQLITE_OK else {
    let text = message.map { String(cString: $0) } ?? "SQLite error"
    sqlite3_free(message)
    throw WorkReportSQLiteTestError.execute(result, text)
  }
}
