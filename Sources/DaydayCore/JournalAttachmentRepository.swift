import Foundation

public enum JournalAttachmentInsertResult: Equatable, Sendable {
  case inserted
  case alreadyPresent
}

/// Private journal attachments have a dedicated repository so neither their
/// bytes nor their metadata can be reached by a work-report projection.
public protocol JournalAttachmentRepository: Sendable {
  func insert(_ attachment: JournalAttachment) async throws -> JournalAttachmentInsertResult
  func remove(_ attachment: JournalAttachment) async throws
  func attachments(for dayID: DayID) async throws -> [JournalAttachment]
  func schemaVersion() async throws -> Int
  func schemaFingerprint() async throws -> String
}
