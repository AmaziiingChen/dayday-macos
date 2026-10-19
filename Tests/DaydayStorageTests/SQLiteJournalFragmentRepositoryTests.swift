import CSQLite
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite journal fragment repository", .serialized)
struct SQLiteJournalFragmentRepositoryTests {
  @Test("fragments are inserted idempotently and returned oldest first")
  func insertAndRead() async throws {
    let repository = try SQLiteJournalFragmentRepository(location: .inMemory)
    let dayID = DayID()
    let first = try makeFragment(dayID: dayID, body: "想法一", seed: 1, at: date(100))
    let second = try makeFragment(dayID: dayID, body: "想法二", seed: 2, at: date(110))

    #expect(try await repository.insert(first) == .inserted)
    #expect(try await repository.insert(first) == .alreadyPresent)
    #expect(try await repository.insert(second) == .inserted)
    #expect(try await repository.fragments(for: dayID).map(\.body) == ["想法一", "想法二"])
    #expect(try await repository.schemaVersion() == 1)
    #expect(
      try await repository.schemaFingerprint()
        == SQLiteJournalFragmentRepository.expectedSchemaFingerprint)
  }

  @Test("different days are isolated by day id")
  func dayIsolation() async throws {
    let repository = try SQLiteJournalFragmentRepository(location: .inMemory)
    let dayA = DayID()
    let dayB = DayID()
    _ = try await repository.insert(
      try makeFragment(dayID: dayA, body: "a", seed: 3, at: date(200)))
    _ = try await repository.insert(
      try makeFragment(dayID: dayB, body: "b", seed: 4, at: date(210)))

    #expect(try await repository.fragments(for: dayA).map(\.body) == ["a"])
    #expect(try await repository.fragments(for: dayB).map(\.body) == ["b"])
  }

  @Test("recent fragments are newest-first and limits fail closed")
  func recentOrderingAndLimits() async throws {
    let repository = try SQLiteJournalFragmentRepository(location: .inMemory)
    let dayA = DayID()
    let dayB = DayID()
    _ = try await repository.insert(
      try makeFragment(dayID: dayA, body: "early", seed: 5, at: date(300)))
    _ = try await repository.insert(
      try makeFragment(dayID: dayB, body: "late", seed: 6, at: date(400)))

    let recent = try await repository.recentFragments(limit: 2)
    #expect(recent.map(\.body) == ["late", "early"])
    #expect(try await repository.recentFragments(limit: 1).map(\.body) == ["late"])
    await #expect(throws: JournalFragmentStoreError.invalidLimit) {
      _ = try await repository.recentFragments(limit: 0)
    }
  }

  @Test("file reopen preserves fragments and schema tampering fails closed")
  func reopenAndSchemaTampering() async throws {
    let url = URL(fileURLWithPath: "/tmp/dayday-journal-fragment-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
    let dayID = DayID()
    let fragment = try makeFragment(dayID: dayID, body: "persisted", seed: 7, at: date(500))
    let repository = try SQLiteJournalFragmentRepository(location: .file(url))
    _ = try await repository.insert(fragment)

    let reopened = try SQLiteJournalFragmentRepository(location: .file(url))
    #expect(try await reopened.fragments(for: dayID).map(\.body) == ["persisted"])
    try executeFragmentSQL("DROP INDEX journal_fragment_items_created_at", at: url)
    #expect(throws: JournalFragmentStoreError.corruptedSchema("Unexpected schema objects")) {
      _ = try SQLiteJournalFragmentRepository(location: .file(url))
    }
  }

  private func makeFragment(
    dayID: DayID,
    body: String,
    seed: UInt8,
    at date: Date
  ) throws -> JournalFragment {
    try JournalFragment(
      id: JournalFragmentID(rawValue: uuid(seed, suffix: 1)),
      dayID: dayID,
      body: body,
      createdAt: date
    )
  }

  private func date(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
  }

  private func uuid(_ seed: UInt8, suffix: UInt8) -> UUID {
    UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
  }
}

private enum JournalFragmentSQLiteTestError: Error {
  case open(Int32)
  case execute(Int32, String)
}

private func executeFragmentSQL(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
  guard openResult == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw JournalFragmentSQLiteTestError.open(openResult)
  }
  defer { sqlite3_close_v2(database) }
  var message: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &message)
  guard result == SQLITE_OK else {
    let text = message.map { String(cString: $0) } ?? "SQLite error"
    sqlite3_free(message)
    throw JournalFragmentSQLiteTestError.execute(result, text)
  }
}