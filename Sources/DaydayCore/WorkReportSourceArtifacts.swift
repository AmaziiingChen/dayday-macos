import Foundation

/// A durable copy of the explicit work note that was supplied to one report generation.
/// It is intentionally separate from journal storage and can be resolved from revision lineage.
public struct PersistedWorkReportNote: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case nonFiniteCreationDate
    case emptyBody
    case bodyTooLong
  }

  public static let maximumBodyUTF8Length = 16 * 1024

  public let id: WorkNoteID
  public let dayID: DayID
  public let createdAt: Date
  public let body: String
  public let activityID: ActivityID?

  public init(
    id: WorkNoteID = WorkNoteID(),
    dayID: DayID,
    createdAt: Date,
    body: String,
    activityID: ActivityID? = nil
  ) throws {
    guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.nonFiniteCreationDate
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyBody
    }
    guard body.utf8.count <= Self.maximumBodyUTF8Length else {
      throw ValidationError.bodyTooLong
    }
    self.id = id
    self.dayID = dayID
    self.createdAt = createdAt
    self.body = body
    self.activityID = activityID
  }

  public var context: WorkReportNoteContext {
    // All validation required by the context type is a subset of this durable contract.
    try! WorkReportNoteContext(
      id: id,
      createdAt: createdAt,
      body: body,
      activityID: activityID
    )
  }
}

/// Source artifacts written atomically with a generated report revision. Activity and visual
/// lineage stay in their existing repositories; this envelope owns only report-specific copies.
public struct WorkReportGenerationSources: Equatable, Sendable {
  public let workNotes: [PersistedWorkReportNote]
  public let weatherSnapshots: [WeatherSnapshot]

  public init(
    workNotes: [PersistedWorkReportNote] = [],
    weatherSnapshots: [WeatherSnapshot] = []
  ) {
    self.workNotes = workNotes
    self.weatherSnapshots = weatherSnapshots
  }

  public static let empty = WorkReportGenerationSources()
}

/// Production implementations guarantee that source artifacts and the referencing report revision
/// commit in one transaction. Fetches support a future source inspector without retaining prompts.
public protocol WorkReportGenerationRepository: WorkReportRepository {
  func saveGenerated(
    _ record: PersistedWorkReportRecord,
    sources: WorkReportGenerationSources
  ) async throws -> WorkReportSaveResult
  func workNote(id: WorkNoteID) async throws -> PersistedWorkReportNote?
  func weatherSnapshot(id: WeatherSnapshotID) async throws -> WeatherSnapshot?
}
