import Foundation

public enum ScreenVisionUsageOutcome: String, Codable, Hashable, Sendable {
  case success
  case failure
}

public enum ScreenVisionErrorCategory: String, Codable, CaseIterable, Hashable, Sendable {
  case missingConfiguration
  case invalidEndpoint
  case missingCredential
  case invalidInput
  case cancelled
  case network
  case unauthorized
  case rateLimited
  case providerServer
  case providerRejected
  case invalidResponse
  case archiveFailure
  case unknown
}

/// Content-free point at which a visual-provider attempt stopped. This is diagnostic metadata,
/// never provider prose or captured-screen content.
public enum ScreenVisionFailureStage: String, Codable, CaseIterable, Hashable, Sendable {
  case configuration
  case providerRequest
  case responseValidation
  case localAcceptance
}

/// Content-free accounting for one visual-provider attempt.
public struct ScreenVisionUsageRecord: Codable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidProvider
    case invalidModel
    case invalidRequestID
    case invalidTimeRange
    case invalidTokenCount
    case successHasError
    case failureMissingError
  }

  public let id: UUID
  public let provider: String
  public let model: String
  public let requestID: String?
  public let startedAt: Date
  public let completedAt: Date
  public let outcome: ScreenVisionUsageOutcome
  public let errorCategory: ScreenVisionErrorCategory?
  public let failureStage: ScreenVisionFailureStage?
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let cachedInputTokens: Int?
  public let totalTokens: Int?

  public init(
    id: UUID = UUID(),
    provider: String,
    model: String,
    requestID: String? = nil,
    startedAt: Date,
    completedAt: Date,
    outcome: ScreenVisionUsageOutcome,
    errorCategory: ScreenVisionErrorCategory? = nil,
    failureStage: ScreenVisionFailureStage? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cachedInputTokens: Int? = nil,
    totalTokens: Int? = nil
  ) throws {
    guard Self.valid(provider, maximumBytes: 128) else { throw ValidationError.invalidProvider }
    guard Self.valid(model, maximumBytes: 160) else { throw ValidationError.invalidModel }
    if let requestID, !Self.valid(requestID, maximumBytes: 256) {
      throw ValidationError.invalidRequestID
    }
    guard completedAt >= startedAt,
      startedAt.timeIntervalSinceReferenceDate.isFinite,
      completedAt.timeIntervalSinceReferenceDate.isFinite
    else { throw ValidationError.invalidTimeRange }
    guard
      [inputTokens, outputTokens, cachedInputTokens, totalTokens]
        .compactMap({ $0 }).allSatisfy({ $0 >= 0 })
    else { throw ValidationError.invalidTokenCount }
    switch outcome {
    case .success where errorCategory != nil || failureStage != nil: throw ValidationError.successHasError
    case .failure where errorCategory == nil: throw ValidationError.failureMissingError
    default: break
    }
    self.id = id
    self.provider = provider
    self.model = model
    self.requestID = requestID
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.outcome = outcome
    self.errorCategory = errorCategory
    self.failureStage = failureStage
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedInputTokens = cachedInputTokens
    self.totalTokens = totalTokens
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(UUID.self, forKey: .id),
      provider: values.decode(String.self, forKey: .provider),
      model: values.decode(String.self, forKey: .model),
      requestID: values.decodeIfPresent(String.self, forKey: .requestID),
      startedAt: values.decode(Date.self, forKey: .startedAt),
      completedAt: values.decode(Date.self, forKey: .completedAt),
      outcome: values.decode(ScreenVisionUsageOutcome.self, forKey: .outcome),
      errorCategory: values.decodeIfPresent(ScreenVisionErrorCategory.self, forKey: .errorCategory),
      failureStage: values.decodeIfPresent(ScreenVisionFailureStage.self, forKey: .failureStage),
      inputTokens: values.decodeIfPresent(Int.self, forKey: .inputTokens),
      outputTokens: values.decodeIfPresent(Int.self, forKey: .outputTokens),
      cachedInputTokens: values.decodeIfPresent(Int.self, forKey: .cachedInputTokens),
      totalTokens: values.decodeIfPresent(Int.self, forKey: .totalTokens)
    )
  }

  private static func valid(_ value: String, maximumBytes: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
  }
}

public struct ScreenVisionUsageSummary: Equatable, Sendable {
  public let callCount: Int
  public let successCount: Int
  public let inputTokens: Int
  public let outputTokens: Int
  public let cachedInputTokens: Int
  public let totalTokens: Int
  public let failuresByCategory: [ScreenVisionErrorCategory: Int]
  public let failuresByStage: [ScreenVisionFailureStage: Int]

  public init(
    callCount: Int,
    successCount: Int,
    inputTokens: Int,
    outputTokens: Int,
    cachedInputTokens: Int,
    totalTokens: Int,
    failuresByCategory: [ScreenVisionErrorCategory: Int],
    failuresByStage: [ScreenVisionFailureStage: Int] = [:]
  ) {
    self.callCount = callCount
    self.successCount = successCount
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedInputTokens = cachedInputTokens
    self.totalTokens = totalTokens
    self.failuresByCategory = failuresByCategory
    self.failuresByStage = failuresByStage
  }
}

public protocol ScreenVisionUsageRepository: Sendable {
  func insert(_ record: ScreenVisionUsageRecord) async throws -> DeepCaptureInsertResult
  func screenVisionUsage(in range: Range<Date>) async throws -> ScreenVisionUsageSummary
}
