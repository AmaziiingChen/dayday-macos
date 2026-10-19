import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite journal location snapshot repository", .serialized)
struct SQLiteJournalLocationSnapshotRepositoryTests {
  @Test("one-time coordinates are stored with their system-reported precision")
  func storesSnapshot() async throws {
    let repository = try SQLiteJournalLocationSnapshotRepository(location: .inMemory)
    let dayID = DayID()
    let snapshot = try JournalLocationSnapshot(
      journalEntryID: JournalEntryID(),
      dayID: dayID,
      latitude: 31.230416,
      longitude: 121.473701,
      altitude: nil,
      horizontalAccuracy: 3.2,
      verticalAccuracy: nil,
      capturedAt: Date(timeIntervalSinceReferenceDate: 1_000),
      placeName: "上海市黄浦区中山东一路"
    )

    #expect(try await repository.insert(snapshot) == .inserted)
    #expect(try await repository.insert(snapshot) == .alreadyPresent)
    #expect(try await repository.snapshots(for: dayID) == [snapshot])
    #expect(try await repository.snapshots(for: dayID).first?.placeName == "上海市黄浦区中山东一路")
    #expect(try await repository.schemaVersion() == 1)
    #expect(
      try await repository.schemaFingerprint()
        == SQLiteJournalLocationSnapshotRepository.expectedSchemaFingerprint)
  }
}
