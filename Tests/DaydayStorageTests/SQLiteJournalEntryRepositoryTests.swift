import CSQLite
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite journal entry repository", .serialized)
struct SQLiteJournalEntryRepositoryTests {
  @Test("initial original and entry are saved atomically and idempotently")
  func initialSaveAndIdempotency() async throws {
    let repository = try SQLiteJournalEntryRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 1, savedAt: date(100), createdAt: date(99))

    #expect(try await repository.save(first) == .inserted)
    #expect(try await repository.save(first) == .alreadyPresent)
    #expect(try await repository.entry(for: first.entry.dayID) == first)
    #expect(try await repository.schemaVersion() == 2)
    #expect(
      try await repository.schemaFingerprint()
        == SQLiteJournalEntryRepository.expectedSchemaFingerprint)
    #expect(try await repository.originals(for: first.entry.dayID).count == 1)
  }

  @Test("AI copies remain independent and are returned newest first")
  func derivedVersionsAreIndependent() async throws {
    let repository = try SQLiteJournalEntryRepository(location: .inMemory)
    let original = try makeInitialRecord(seed: 21, savedAt: date(700))
    _ = try await repository.save(original)
    let provenance = try ModelProvenance(
      provider: "local.test", model: "test-model", promptVersion: "journal-markdown-v1"
    )
    let older = try JournalDerivedVersion(
      journalEntryID: original.entry.id,
      sourceOriginalVersionID: original.currentOriginal.id,
      operation: .proofread,
      body: "校对版本",
      modelProvenance: provenance,
      createdAt: date(701)
    )
    let newer = try JournalDerivedVersion(
      journalEntryID: original.entry.id,
      sourceOriginalVersionID: original.currentOriginal.id,
      operation: .rewrite,
      body: "改写版本",
      modelProvenance: provenance,
      createdAt: date(702)
    )

    #expect(try await repository.saveDerivedVersion(older) == .inserted)
    #expect(try await repository.saveDerivedVersion(older) == .alreadyPresent)
    #expect(try await repository.saveDerivedVersion(newer) == .inserted)
    #expect(try await repository.derivedVersions(for: original.entry.id, limit: 20) == [newer, older])
    #expect(try await repository.derivedVersions(for: original.entry.id, limit: 1) == [newer])
    await #expect(throws: JournalEntryStoreError.invalidLimit) {
      _ = try await repository.derivedVersions(for: original.entry.id, limit: 0)
    }
    await #expect(throws: JournalEntryStoreError.invalidLimit) {
      _ = try await repository.derivedVersions(for: original.entry.id, limit: 201)
    }
    #expect(try await repository.entry(for: original.entry.dayID) == original)
  }

  @Test("realtime saves update one current original without creating automatic versions")
  func realtimeSaveReplacesCurrentOriginal() async throws {
    let repository = try SQLiteJournalEntryRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 2, savedAt: date(200))
    _ = try await repository.save(first)
    let second = try makeReplacement(first, body: "午后补充一句。", at: date(201))

    #expect(try await repository.save(second) == .updated)
    let stored = try #require(await repository.entry(for: first.entry.dayID))
    #expect(stored.entry.currentOriginalVersionNumber == 1)
    #expect(stored.currentOriginal.body == "午后补充一句。")
    let originals = try await repository.originals(for: first.entry.dayID)
    #expect(originals.map(\.versionNumber) == [1])
    #expect(originals.first?.body == "午后补充一句。")
  }

  @Test("invalid lineage rolls back the entire attempted update")
  func invalidLineageRollsBack() async throws {
    let repository = try SQLiteJournalEntryRepository(location: .inMemory)
    let first = try makeInitialRecord(seed: 3, savedAt: date(300))
    _ = try await repository.save(first)

    let unrelated = try makeUnrelatedRecord(
      dayID: first.entry.dayID, seed: 4, savedAt: date(301))
    await #expect(throws: JournalEntryStoreError.invalidVersionLineage) {
      _ = try await repository.save(unrelated)
    }
    #expect(try await repository.entry(for: first.entry.dayID) == first)
  }

  @Test("recent entries are ordered by updated time and limits fail closed")
  func recentOrderingAndLimits() async throws {
    let repository = try SQLiteJournalEntryRepository(location: .inMemory)
    let older = try makeInitialRecord(seed: 5, savedAt: date(400))
    let newer = try makeInitialRecord(seed: 6, savedAt: date(500))
    _ = try await repository.save(older)
    _ = try await repository.save(newer)

    #expect(try await repository.recentEntries(limit: 1) == [newer])
    await #expect(throws: JournalEntryStoreError.invalidLimit) {
      _ = try await repository.recentEntries(limit: 0)
    }
  }

  @Test("file reopen preserves entries and schema tampering fails closed")
  func reopenAndSchemaTampering() async throws {
    let url = URL(fileURLWithPath: "/tmp/dayday-journal-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
    let first = try makeInitialRecord(seed: 7, savedAt: date(600))
    let repository = try SQLiteJournalEntryRepository(location: .file(url))
    _ = try await repository.save(first)

    let reopened = try SQLiteJournalEntryRepository(location: .file(url))
    #expect(try await reopened.entry(for: first.entry.dayID) == first)
    try executeJournalSQL("DROP INDEX journal_artifact_entries_updated_at", at: url)
    #expect(throws: JournalEntryStoreError.corruptedSchema("Unexpected schema objects")) {
      _ = try SQLiteJournalEntryRepository(location: .file(url))
    }
  }

  private func makeInitialRecord(
    seed: UInt8,
    savedAt: Date,
    createdAt: Date? = nil
  ) throws -> PersistedJournalEntryRecord {
    let createdAt = createdAt ?? savedAt.addingTimeInterval(-1)
    let entryID = JournalEntryID(rawValue: uuid(seed, suffix: 1))
    let day = try makeDay(
      id: DayID(rawValue: uuid(seed, suffix: 3)),
      containing: savedAt
    )
    let original = try JournalOriginalVersion(
      id: JournalOriginalVersionID(rawValue: uuid(seed, suffix: 2)),
      journalEntryID: entryID,
      versionNumber: 1,
      previousVersionID: nil,
      body: "日记-\(seed)",
      savedAt: savedAt
    )
    let entry = try JournalEntry(
      id: entryID,
      dayID: day.id,
      initialOriginal: original,
      createdAt: createdAt
    )
    return try PersistedJournalEntryRecord(day: day, entry: entry, currentOriginal: original)
  }

  private func makeUnrelatedRecord(
    dayID: DayID,
    seed: UInt8,
    savedAt: Date
  ) throws -> PersistedJournalEntryRecord {
    let createdAt = savedAt.addingTimeInterval(-1)
    let entryID = JournalEntryID(rawValue: uuid(seed, suffix: 1))
    let day = try makeDay(id: dayID, containing: savedAt)
    let original = try JournalOriginalVersion(
      id: JournalOriginalVersionID(rawValue: uuid(seed, suffix: 2)),
      journalEntryID: entryID,
      versionNumber: 1,
      previousVersionID: nil,
      body: "日记-\(seed)",
      savedAt: savedAt
    )
    let entry = try JournalEntry(
      id: entryID,
      dayID: dayID,
      initialOriginal: original,
      createdAt: createdAt
    )
    return try PersistedJournalEntryRecord(day: day, entry: entry, currentOriginal: original)
  }

  private func makeReplacement(
    _ current: PersistedJournalEntryRecord,
    body: String,
    at date: Date
  ) throws -> PersistedJournalEntryRecord {
    let original = try JournalOriginalVersion(
      id: current.currentOriginal.id,
      journalEntryID: current.entry.id,
      versionNumber: current.currentOriginal.versionNumber,
      previousVersionID: current.currentOriginal.previousVersionID,
      body: body,
      savedAt: date
    )
    let entry = try current.entry.replacingCurrentOriginal(original)
    return try PersistedJournalEntryRecord(
      day: current.day,
      entry: entry,
      currentOriginal: original
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

private enum JournalSQLiteTestError: Error {
  case open(Int32)
  case execute(Int32, String)
}

private func executeJournalSQL(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
  guard openResult == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw JournalSQLiteTestError.open(openResult)
  }
  defer { sqlite3_close_v2(database) }
  var message: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &message)
  guard result == SQLITE_OK else {
    let text = message.map { String(cString: $0) } ?? "SQLite error"
    sqlite3_free(message)
    throw JournalSQLiteTestError.execute(result, text)
  }
}
