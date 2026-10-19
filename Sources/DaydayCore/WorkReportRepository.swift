import Foundation

public struct PersistedWorkReportRecord: Codable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case dayMismatch
    case currentRevisionMismatch
    case usageRevisionMismatch
    case usageMustBeSuccessfulWorkReport
  }

  public let day: DayDescriptor
  public let report: WorkReport
  public let currentRevision: WorkReportRevision
  public let modelUsage: ModelUsage?

  public init(
    day: DayDescriptor,
    report: WorkReport,
    currentRevision: WorkReportRevision,
    modelUsage: ModelUsage?
  ) throws {
    guard day.id == report.dayID else { throw ValidationError.dayMismatch }
    guard currentRevision.reportID == report.id,
      currentRevision.id == report.currentRevisionID,
      currentRevision.revisionNumber == report.currentRevisionNumber
    else { throw ValidationError.currentRevisionMismatch }
    if let modelUsage {
      guard modelUsage.revisionID == currentRevision.id else {
        throw ValidationError.usageRevisionMismatch
      }
      guard modelUsage.outcome == .success, modelUsage.task == .workReport else {
        throw ValidationError.usageMustBeSuccessfulWorkReport
      }
    }
    self.day = day
    self.report = report
    self.currentRevision = currentRevision
    self.modelUsage = modelUsage
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      day: values.decode(DayDescriptor.self, forKey: .day),
      report: values.decode(WorkReport.self, forKey: .report),
      currentRevision: values.decode(WorkReportRevision.self, forKey: .currentRevision),
      modelUsage: values.decodeIfPresent(ModelUsage.self, forKey: .modelUsage)
    )
  }
}

public enum WorkReportSaveResult: Equatable, Sendable {
  case inserted
  case updated
  case alreadyPresent
}

public enum WorkReportFinalizeError: Error, Equatable, Sendable {
  case notFound
  case recordMismatch
  case alreadyFinalized
  case invalidFinalization
}

public protocol WorkReportRepository: Sendable {
  func save(_ record: PersistedWorkReportRecord) async throws -> WorkReportSaveResult
  func report(for dayID: DayID) async throws -> PersistedWorkReportRecord?

  /// Persists a status-only transition of an existing draft to `.final` without appending a new
  /// revision. The passed record must reference the same current revision as the stored draft and
  /// carry `.status == .final`.
  func finalize(_ record: PersistedWorkReportRecord) async throws -> WorkReportSaveResult
  func recentReports(limit: Int) async throws -> [PersistedWorkReportRecord]

  /// Returns the immutable revision lineage for a report, oldest first.
  func revisions(for dayID: DayID) async throws -> [WorkReportRevision]

  /// Aggregates successful provider-reported tokens across all usage rows whose completion time
  /// falls in the interval. Used for budget gates and usage statistics; never any content.
  func tokenUsage(in interval: Range<Date>) async throws -> WorkReportTokenSummary
}

public struct WorkReportTokenSummary: Codable, Hashable, Sendable {
  public let inputTokens: Int
  public let outputTokens: Int
  public let	cachedInputTokens: Int
  public let totalTokens: Int
  public let attemptCount: Int

  public init(
    inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, totalTokens: Int = 0,
    attemptCount: Int = 0
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedInputTokens = cachedInputTokens
    self.totalTokens = totalTokens
    self.attemptCount = attemptCount
  }

  public static let empty = WorkReportTokenSummary()
}
