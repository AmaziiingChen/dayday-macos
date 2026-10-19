import DaydayCore
import Foundation

/// A recoverable editor working copy. It is deliberately not a `WorkReportRevision`: ordinary
/// typing must survive navigation and relaunch without turning every pause into report history.
struct WorkReportWorkingDraftSnapshot: Codable, Equatable {
  enum ValidationError: Error, Equatable {
    case unsupportedVersion
    case oversizedBody
    case invalidUpdatedAt
  }

  static let currentVersion = 1
  static let maximumBodyUTF8ByteCount = 384 * 1024

  let version: Int
  let dayID: DayID
  let baseRevisionID: WorkReportRevisionID?
  let body: String
  let updatedAt: Date

  init(
    dayID: DayID,
    baseRevisionID: WorkReportRevisionID?,
    body: String,
    updatedAt: Date
  ) throws {
    guard body.utf8.count <= Self.maximumBodyUTF8ByteCount else {
      throw ValidationError.oversizedBody
    }
    guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.invalidUpdatedAt
    }
    version = Self.currentVersion
    self.dayID = dayID
    self.baseRevisionID = baseRevisionID
    self.body = body
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .version) == Self.currentVersion else {
      throw ValidationError.unsupportedVersion
    }
    try self.init(
      dayID: values.decode(DayID.self, forKey: .dayID),
      baseRevisionID: values.decodeIfPresent(WorkReportRevisionID.self, forKey: .baseRevisionID),
      body: values.decode(String.self, forKey: .body),
      updatedAt: values.decode(Date.self, forKey: .updatedAt)
    )
  }
}

@MainActor
protocol WorkReportWorkingDraftPersisting {
  func load() throws -> WorkReportWorkingDraftSnapshot?
  func save(_ snapshot: WorkReportWorkingDraftSnapshot?) throws
}

enum WorkReportWorkingDraftPersistenceError: Error, Equatable {
  case unreadable
  case corrupted
  case writeFailed
}

@MainActor
final class VolatileWorkReportWorkingDraftStore: WorkReportWorkingDraftPersisting {
  private var snapshot: WorkReportWorkingDraftSnapshot?

  func load() throws -> WorkReportWorkingDraftSnapshot? { snapshot }
  func save(_ snapshot: WorkReportWorkingDraftSnapshot?) throws { self.snapshot = snapshot }
}

/// Uses the same owner-only, no-symlink atomic file discipline as the work-note store, but a
/// separate filename and payload. The report draft never enters preferences or journal storage.
@MainActor
final class WorkReportWorkingDraftFileStore: WorkReportWorkingDraftPersisting {
  private static let maximumEncodedUTF8ByteCount = 512 * 1024
  private let textStore: WorkNoteFileStore

  init(directoryURL: URL, fileManager: FileManager = .default) {
    textStore = WorkNoteFileStore(
      directoryURL: directoryURL,
      fileManager: fileManager,
      fileName: "work-report-working-draft.json",
      maximumUTF8ByteCount: Self.maximumEncodedUTF8ByteCount
    )
  }

  private init(textStore: WorkNoteFileStore) {
    self.textStore = textStore
  }

  static func applicationSupportStore(
    fileManager: FileManager = .default
  ) -> WorkReportWorkingDraftFileStore {
    WorkReportWorkingDraftFileStore(
      textStore: WorkNoteFileStore.applicationSupportStore(
        fileManager: fileManager,
        fileName: "work-report-working-draft.json",
        maximumUTF8ByteCount: maximumEncodedUTF8ByteCount
      )
    )
  }

  func load() throws -> WorkReportWorkingDraftSnapshot? {
    let value: String
    do {
      value = try textStore.load()
    } catch WorkNotePersistenceError.corrupted {
      throw WorkReportWorkingDraftPersistenceError.corrupted
    } catch {
      throw WorkReportWorkingDraftPersistenceError.unreadable
    }
    guard !value.isEmpty else { return nil }
    guard let data = value.data(using: .utf8),
      data.count <= Self.maximumEncodedUTF8ByteCount
    else { throw WorkReportWorkingDraftPersistenceError.corrupted }
    do {
      return try JSONDecoder().decode(WorkReportWorkingDraftSnapshot.self, from: data)
    } catch {
      throw WorkReportWorkingDraftPersistenceError.corrupted
    }
  }

  func save(_ snapshot: WorkReportWorkingDraftSnapshot?) throws {
    let value: String
    do {
      if let snapshot {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumEncodedUTF8ByteCount,
          let encoded = String(data: data, encoding: .utf8)
        else { throw WorkReportWorkingDraftPersistenceError.writeFailed }
        value = encoded
      } else {
        value = ""
      }
      try textStore.save(value)
    } catch let error as WorkReportWorkingDraftPersistenceError {
      throw error
    } catch {
      throw WorkReportWorkingDraftPersistenceError.writeFailed
    }
  }
}
