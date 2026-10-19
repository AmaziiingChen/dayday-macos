import Foundation

public enum ModelTask: String, Codable, Hashable, Sendable {
  case workReport
}

public enum ModelUsageOutcome: String, Codable, Hashable, Sendable {
  case success
  case failure
}

public struct ModelUsage: Codable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidProvider
    case invalidModel
    case invalidRequestID
    case invalidTimeRange
    case invalidTokenCount
    case successfulAttemptRequiresRevision
    case successfulAttemptHasError
    case failedAttemptRequiresError
  }

  public let id: ModelUsageID
  public let revisionID: WorkReportRevisionID?
  public let requestID: String?
  public let provider: String
  public let model: String
  public let task: ModelTask
  public let startedAt: Date
  public let completedAt: Date
  public let outcome: ModelUsageOutcome
  public let errorClass: String?
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let cachedInputTokens: Int?
  public let totalTokens: Int?

  public init(
    id: ModelUsageID = ModelUsageID(),
    revisionID: WorkReportRevisionID?,
    requestID: String?,
    provider: String,
    model: String,
    task: ModelTask,
    startedAt: Date,
    completedAt: Date,
    outcome: ModelUsageOutcome,
    errorClass: String? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cachedInputTokens: Int? = nil,
    totalTokens: Int? = nil
  ) throws {
    guard Self.isBoundedText(provider, maximumBytes: 96) else {
      throw ValidationError.invalidProvider
    }
    guard Self.isBoundedText(model, maximumBytes: 160) else {
      throw ValidationError.invalidModel
    }
    if let requestID, !Self.isBoundedText(requestID, maximumBytes: 256) {
      throw ValidationError.invalidRequestID
    }
    guard startedAt.timeIntervalSinceReferenceDate.isFinite,
      completedAt.timeIntervalSinceReferenceDate.isFinite,
      completedAt >= startedAt
    else { throw ValidationError.invalidTimeRange }
    guard
      [inputTokens, outputTokens, cachedInputTokens, totalTokens]
        .compactMap({ $0 }).allSatisfy({ $0 >= 0 })
    else { throw ValidationError.invalidTokenCount }
    switch outcome {
    case .success:
      guard revisionID != nil else { throw ValidationError.successfulAttemptRequiresRevision }
      guard errorClass == nil else { throw ValidationError.successfulAttemptHasError }
    case .failure:
      guard let errorClass, Self.isBoundedText(errorClass, maximumBytes: 96) else {
        throw ValidationError.failedAttemptRequiresError
      }
    }

    self.id = id
    self.revisionID = revisionID
    self.requestID = requestID
    self.provider = provider
    self.model = model
    self.task = task
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.outcome = outcome
    self.errorClass = errorClass
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedInputTokens = cachedInputTokens
    self.totalTokens = totalTokens
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(ModelUsageID.self, forKey: .id),
      revisionID: values.decodeIfPresent(WorkReportRevisionID.self, forKey: .revisionID),
      requestID: values.decodeIfPresent(String.self, forKey: .requestID),
      provider: values.decode(String.self, forKey: .provider),
      model: values.decode(String.self, forKey: .model),
      task: values.decode(ModelTask.self, forKey: .task),
      startedAt: values.decode(Date.self, forKey: .startedAt),
      completedAt: values.decode(Date.self, forKey: .completedAt),
      outcome: values.decode(ModelUsageOutcome.self, forKey: .outcome),
      errorClass: values.decodeIfPresent(String.self, forKey: .errorClass),
      inputTokens: values.decodeIfPresent(Int.self, forKey: .inputTokens),
      outputTokens: values.decodeIfPresent(Int.self, forKey: .outputTokens),
      cachedInputTokens: values.decodeIfPresent(Int.self, forKey: .cachedInputTokens),
      totalTokens: values.decodeIfPresent(Int.self, forKey: .totalTokens)
    )
  }

  private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
  }
}
