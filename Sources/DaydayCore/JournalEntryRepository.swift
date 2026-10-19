import Foundation

/// A day's journal as stored: the current exact user-authored original plus the
/// entry that tracks its lineage. The day descriptor and the entry must agree and
/// the current original must be exactly the version the entry points at.
public struct PersistedJournalEntryRecord: Codable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case dayMismatch
    case currentOriginalMismatch
  }

  public let day: DayDescriptor
  public let entry: JournalEntry
  public let currentOriginal: JournalOriginalVersion

  public init(
    day: DayDescriptor,
    entry: JournalEntry,
    currentOriginal: JournalOriginalVersion
  ) throws {
    guard day.id == entry.dayID else { throw ValidationError.dayMismatch }
    guard currentOriginal.journalEntryID == entry.id,
      currentOriginal.id == entry.currentOriginalVersionID,
      currentOriginal.versionNumber == entry.currentOriginalVersionNumber
    else { throw ValidationError.currentOriginalMismatch }
    self.day = day
    self.entry = entry
    self.currentOriginal = currentOriginal
  }

  private enum CodingKeys: String, CodingKey {
    case day, entry, currentOriginal
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      day: values.decode(DayDescriptor.self, forKey: .day),
      entry: values.decode(JournalEntry.self, forKey: .entry),
      currentOriginal: values.decode(JournalOriginalVersion.self, forKey: .currentOriginal)
    )
  }
}

public enum JournalEntrySaveResult: Equatable, Sendable {
  case inserted
  case updated
  case alreadyPresent
}

public enum JournalDerivedVersionSaveResult: Equatable, Sendable {
  case inserted
  case alreadyPresent
}

/// Stores model-produced journal copies separately from the exact user-authored original.
/// A derived copy never becomes the current journal merely because it was generated.
public protocol JournalDerivedVersionRepository: Sendable {
  func saveDerivedVersion(
    _ version: JournalDerivedVersion
  ) async throws -> JournalDerivedVersionSaveResult

  func derivedVersions(
    for entryID: JournalEntryID,
    limit: Int
  ) async throws -> [JournalDerivedVersion]
}

public protocol JournalEntryRepository: Sendable {
  /// Saves the current exact user-authored original for a day. Repeated saves replace that
  /// same original in place; ordinary typing never creates a user-visible revision.
  func save(_ record: PersistedJournalEntryRecord) async throws -> JournalEntrySaveResult

  /// Returns the current persisted journal entry for a logical day, if any.
  func entry(for dayID: DayID) async throws -> PersistedJournalEntryRecord?

  /// Returns retained original records for a day, oldest first. New journal edits keep one
  /// current original; older rows can exist only from a prior data format and are never surfaced
  /// as automatic versions.
  func originals(for dayID: DayID) async throws -> [JournalOriginalVersion]

  /// Returns the most recently updated journal days, newest first.
  func recentEntries(limit: Int) async throws -> [PersistedJournalEntryRecord]

  func schemaVersion() async throws -> Int
  func schemaFingerprint() async throws -> String
}
