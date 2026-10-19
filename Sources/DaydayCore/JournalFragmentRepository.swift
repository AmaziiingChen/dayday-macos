import Foundation

public enum JournalFragmentInsertResult: Equatable, Sendable {
  case inserted
  case alreadyPresent
}

/// Durable store for user-authored journal fragments. A fragment is immutable once
/// created and belongs to a logical day. Like journal originals, fragments are
/// private personal artifacts: nothing in the work-report allowlist reads them.
public protocol JournalFragmentRepository: Sendable {
  func insert(_ fragment: JournalFragment) async throws -> JournalFragmentInsertResult

  /// Returns the immutable fragments for a day, oldest first.
  func fragments(for dayID: DayID) async throws -> [JournalFragment]

  /// Returns the most recently created fragments across all days, newest first.
  func recentFragments(limit: Int) async throws -> [JournalFragment]

  func schemaVersion() async throws -> Int
  func schemaFingerprint() async throws -> String
}