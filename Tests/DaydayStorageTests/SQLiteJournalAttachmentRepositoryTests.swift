import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite journal attachment repository", .serialized)
struct SQLiteJournalAttachmentRepositoryTests {
  @Test("image metadata is stored locally, read by day, and idempotent")
  func storesAttachments() async throws {
    let repository = try SQLiteJournalAttachmentRepository(location: .inMemory)
    let dayID = DayID()
    let attachment = try JournalAttachment(
      journalEntryID: JournalEntryID(),
      dayID: dayID,
      payload: .image(
        try JournalImageAttachment(
          relativeFileKey: try JournalRelativeFileKey(rawValue: "images/first.png"),
          mediaType: .png,
          pixelWidth: 1200,
          pixelHeight: 800,
          byteCount: 42_000
        )
      ),
      createdAt: Date(timeIntervalSinceReferenceDate: 900)
    )

    #expect(try await repository.insert(attachment) == .inserted)
    #expect(try await repository.insert(attachment) == .alreadyPresent)
    #expect(try await repository.attachments(for: dayID) == [attachment])
    #expect(try await repository.schemaVersion() == 1)
    #expect(
      try await repository.schemaFingerprint()
        == SQLiteJournalAttachmentRepository.expectedSchemaFingerprint)
  }

  @Test("deleting an attachment removes its local metadata record")
  func removesAttachment() async throws {
    let repository = try SQLiteJournalAttachmentRepository(location: .inMemory)
    let dayID = DayID()
    let attachment = try JournalAttachment(
      journalEntryID: JournalEntryID(),
      dayID: dayID,
      payload: .image(
        try JournalImageAttachment(
          relativeFileKey: try JournalRelativeFileKey(rawValue: "images/remove.png"),
          mediaType: .png,
          pixelWidth: 12,
          pixelHeight: 8,
          byteCount: 420
        )
      ),
      createdAt: Date(timeIntervalSinceReferenceDate: 901)
    )

    _ = try await repository.insert(attachment)
    try await repository.remove(attachment)
    #expect(try await repository.attachments(for: dayID).isEmpty)
  }
}
