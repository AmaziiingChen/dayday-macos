import DaydayCore
import Foundation
import OSLog

public struct OpenAICompatibleVisionConfiguration: Codable, Equatable, Sendable {
  public enum Detail: String, Codable, CaseIterable, Sendable {
    case low
    case high
    case auto
  }

  public var endpoint: URL
  public var model: String
  public var detail: Detail
  public var thinkingEnabled: Bool

  public init(
    endpoint: URL,
    model: String,
    detail: Detail = .low,
    thinkingEnabled: Bool = false
  ) {
    self.endpoint = endpoint
    self.model = model
    self.detail = detail
    self.thinkingEnabled = thinkingEnabled
  }
}

/// A short-lived, already-redacted image derivative admitted to remote visual inference.
///
/// This type intentionally is not Codable and exposes no file-writing API. The size and dimension
/// ceilings prevent callers from passing an original 4K desktop capture by mistake.
public struct EphemeralVisionImage: Sendable {
  public enum MediaType: String, CaseIterable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case empty
    case exceedsMaximumBytes(Int)
    case invalidDimensions
    case exceedsMaximumDimension(Int)
  }

  public static let maximumBytes = 2_000_000
  public static let maximumDimension = 1_600

  let data: Data
  public let mediaType: MediaType
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(data: Data, mediaType: MediaType, pixelWidth: Int, pixelHeight: Int) throws {
    guard !data.isEmpty else { throw ValidationError.empty }
    guard data.count <= Self.maximumBytes else {
      throw ValidationError.exceedsMaximumBytes(data.count)
    }
    guard pixelWidth > 0, pixelHeight > 0 else { throw ValidationError.invalidDimensions }
    let longest = max(pixelWidth, pixelHeight)
    guard longest <= Self.maximumDimension else {
      throw ValidationError.exceedsMaximumDimension(longest)
    }
    self.data = data
    self.mediaType = mediaType
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

/// Privacy-filtered system facts captured alongside a visual batch. The foreground application
/// label is an operating-system fact; a model may describe an apparent mismatch, but may not
/// replace it with a guessed product name.
public struct ScreenVisualSystemContext: Sendable, Equatable {
  public enum Freshness: String, Sendable, Equatable {
    case current
    case recentlyObserved
    case unavailable
  }

  public let foregroundApplicationLabel: String?
  public let focusedWindowTitle: String?
  public let freshness: Freshness

  public init(
    foregroundApplicationLabel: String? = nil,
    focusedWindowTitle: String? = nil,
    freshness: Freshness? = nil
  ) {
    let application = Self.bounded(foregroundApplicationLabel, maximumBytes: 128)
    self.foregroundApplicationLabel = application
    self.focusedWindowTitle = Self.bounded(focusedWindowTitle, maximumBytes: 256)
    self.freshness = freshness ?? (application == nil ? .unavailable : .current)
  }

  private static func bounded(_ value: String?, maximumBytes: Int) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { return nil }
    var result = ""
    for character in trimmed {
      guard (result + String(character)).utf8.count <= maximumBytes else { break }
      result.append(character)
    }
    return result.isEmpty ? nil : result
  }
}

/// A bounded local summary of immediately preceding visual inferences. It is deliberately marked
/// provisional in the request: it helps the model avoid treating a familiar-looking chat surface
/// as a different application, but is never evidence that may override the current images or the
/// operating-system foreground-app fact.
public struct ScreenVisualPriorSegment: Sendable, Equatable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidSummary
    case invalidForegroundApplication
  }

  public let summary: String
  public let activityKind: ScreenVisualActivityKind
  public let foregroundApplicationLabel: String?

  public init(
    summary: String,
    activityKind: ScreenVisualActivityKind,
    foregroundApplicationLabel: String? = nil
  ) throws {
    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 320,
      !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { throw ValidationError.invalidSummary }
    if let foregroundApplicationLabel {
      let application = foregroundApplicationLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !application.isEmpty, application.utf8.count <= 128,
        !application.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
      else { throw ValidationError.invalidForegroundApplication }
      self.foregroundApplicationLabel = application
    } else {
      self.foregroundApplicationLabel = nil
    }
    self.summary = normalized
    self.activityKind = activityKind
  }
}

public struct ScreenVisualContinuityContext: Sendable, Equatable {
  public enum ValidationError: Error, Equatable, Sendable { case tooManySegments(Int) }
  public static let maximumSegmentCount = 3

  public let recentSegments: [ScreenVisualPriorSegment]

  public init() {
    recentSegments = []
  }

  public init(recentSegments: [ScreenVisualPriorSegment] = []) throws {
    guard recentSegments.count <= Self.maximumSegmentCount else {
      throw ValidationError.tooManySegments(recentSegments.count)
    }
    self.recentSegments = recentSegments
  }
}

/// One chronologically-labelled frame in a short visual understanding window.
/// It is intentionally not Codable and can only reference already-redacted derivatives.
public struct ScreenVisualTimelineFrame: Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidTimestamp
    case invalidDisplayLabel
  }

  public let image: EphemeralVisionImage
  public let observedAt: Date
  public let displayLabel: String
  public let redactedOCRLines: [RedactedOCRLine]

  public init(
    image: EphemeralVisionImage,
    observedAt: Date,
    displayLabel: String,
    redactedOCRLines: [RedactedOCRLine]
  ) throws {
    guard observedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.invalidTimestamp
    }
    let trimmedLabel = displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty, trimmedLabel.utf8.count <= 64,
      !trimmedLabel.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { throw ValidationError.invalidDisplayLabel }
    guard redactedOCRLines.count <= OCRArtifact.maximumLineCount else {
      throw ScreenVisionProviderError.invalidOCRContext
    }
    self.image = image
    self.observedAt = observedAt
    self.displayLabel = trimmedLabel
    self.redactedOCRLines = redactedOCRLines
  }
}

/// The synchronized visible state of every captured display at one moment. A foreground app is a
/// global input-focus fact, never a claim that every display contains that application.
public struct ScreenVisualTimeSlice: Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case empty
    case tooManyDisplays(Int)
    case duplicateDisplayLabel(String)
  }

  public static let maximumDisplayCount = 4

  public let observedAt: Date
  public let frames: [ScreenVisualTimelineFrame]
  public let systemContext: ScreenVisualSystemContext

  public init(
    frames: [ScreenVisualTimelineFrame],
    systemContext: ScreenVisualSystemContext = .init()
  ) throws {
    guard let first = frames.first else { throw ValidationError.empty }
    guard frames.count <= Self.maximumDisplayCount else {
      throw ValidationError.tooManyDisplays(frames.count)
    }
    var labels = Set<String>()
    for frame in frames where !labels.insert(frame.displayLabel).inserted {
      throw ValidationError.duplicateDisplayLabel(frame.displayLabel)
    }
    self.observedAt = first.observedAt
    self.frames = frames.sorted { $0.displayLabel < $1.displayLabel }
    self.systemContext = systemContext
  }
}

/// A bounded chronological window for one visual-model request. The provider receives time slices
/// rather than an ungrounded bag of frames, preserving simultaneous-display relationships and
/// their short-term progression.
public struct ScreenVisualTimelineBatch: Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case empty
    case tooManyTimeSlices(Int)
    case tooManyFrames(Int)
    case unorderedTimeSlices
    case exceedsMaximumBytes(Int)
  }

  public static let maximumTimeSliceCount = 8
  public static let maximumFrameCount = 8
  public static let maximumTotalBytes = 8_000_000

  public let timeSlices: [ScreenVisualTimeSlice]
  public let continuityContext: ScreenVisualContinuityContext
  /// Compatibility view for image construction and legacy test fixtures. New callers must retain
  /// the time-slice boundaries through `timeSlices`.
  public var frames: [ScreenVisualTimelineFrame] { timeSlices.flatMap(\.frames) }
  /// Compatibility view only. Request construction uses each slice's own context.
  public var systemContext: ScreenVisualSystemContext { timeSlices.last!.systemContext }

  public init(
    timeSlices: [ScreenVisualTimeSlice],
    continuityContext: ScreenVisualContinuityContext? = nil
  ) throws {
    guard !timeSlices.isEmpty else { throw ValidationError.empty }
    guard timeSlices.count <= Self.maximumTimeSliceCount else {
      throw ValidationError.tooManyTimeSlices(timeSlices.count)
    }
    guard zip(timeSlices, timeSlices.dropFirst()).allSatisfy({ $0.observedAt <= $1.observedAt })
    else { throw ValidationError.unorderedTimeSlices }
    let frames = timeSlices.flatMap(\.frames)
    guard frames.count <= Self.maximumFrameCount else {
      throw ValidationError.tooManyFrames(frames.count)
    }
    let total = frames.reduce(0) { $0 + $1.image.data.count }
    guard total <= Self.maximumTotalBytes else { throw ValidationError.exceedsMaximumBytes(total) }
    self.timeSlices = timeSlices
    self.continuityContext = continuityContext ?? ScreenVisualContinuityContext()
  }

  public init(
    frames: [ScreenVisualTimelineFrame],
    systemContext: ScreenVisualSystemContext = .init(),
    continuityContext: ScreenVisualContinuityContext? = nil
  ) throws {
    try self.init(
      timeSlices: frames.map {
        try ScreenVisualTimeSlice(frames: [$0], systemContext: systemContext)
      }, continuityContext: continuityContext)
  }
}

public typealias ScreenVisualActivityKind = VisualWorkActivityKind

/// Provider-facing display state. Its label is resolved to Dayday's opaque `DisplayID` only by
/// the runtime that owns the corresponding local frame; a provider never receives that identity.
public struct ScreenVisualDisplayInference: Equatable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidDisplayLabel
    case invalidVisibleState
  }

  public let displayLabel: String
  public let role: VisualDisplayRole
  public let visibleState: String

  public init(displayLabel: String, role: VisualDisplayRole, visibleState: String) throws {
    let label = displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, label.utf8.count <= 64,
      !label.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { throw ValidationError.invalidDisplayLabel }
    guard
      let bounded = try? VisualDisplayState(
        displayID: DisplayID(), role: role, visibleState: visibleState
      ).visibleState
    else { throw ValidationError.invalidVisibleState }
    self.displayLabel = label
    self.role = role
    self.visibleState = bounded
  }
}

/// Provider inference, never an objective observation.
public struct ScreenVisualInference: Equatable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidSummary
    case invalidInteraction
    case tooManyEvidenceItems(Int)
    case invalidEvidence
    case noDisplayStates
    case duplicateDisplayLabel(String)
    case tooManyDisplayStates(Int)
    case tooManyUncertainties(Int)
    case invalidUncertainty
  }

  public let summary: String
  public let interaction: String
  public let activityKind: ScreenVisualActivityKind
  public let evidence: [String]
  public let displayStates: [ScreenVisualDisplayInference]
  public let relationship: VisualDisplayRelationship
  public let systemContextAgreement: VisualSystemContextAgreement
  public let uncertainties: [String]

  public init(
    summary: String,
    interaction: String,
    activityKind: ScreenVisualActivityKind,
    evidence: [String],
    displayStates: [ScreenVisualDisplayInference],
    relationship: VisualDisplayRelationship,
    systemContextAgreement: VisualSystemContextAgreement = .unavailable,
    uncertainties: [String] = []
  ) throws {
    guard Self.isBoundedText(summary, maximumBytes: 1_024) else {
      throw ValidationError.invalidSummary
    }
    guard Self.isBoundedText(interaction, maximumBytes: 1_024) else {
      throw ValidationError.invalidInteraction
    }
    guard evidence.count <= 8 else {
      throw ValidationError.tooManyEvidenceItems(evidence.count)
    }
    guard evidence.allSatisfy({ Self.isBoundedText($0, maximumBytes: 256) }) else {
      throw ValidationError.invalidEvidence
    }
    guard !displayStates.isEmpty else { throw ValidationError.noDisplayStates }
    guard displayStates.count <= 4 else {
      throw ValidationError.tooManyDisplayStates(displayStates.count)
    }
    var labels = Set<String>()
    for state in displayStates where !labels.insert(state.displayLabel).inserted {
      throw ValidationError.duplicateDisplayLabel(state.displayLabel)
    }
    guard uncertainties.count <= 4 else {
      throw ValidationError.tooManyUncertainties(uncertainties.count)
    }
    guard uncertainties.allSatisfy({ Self.isBoundedText($0, maximumBytes: 256) }) else {
      throw ValidationError.invalidUncertainty
    }
    self.summary = summary
    self.interaction = interaction
    self.activityKind = activityKind
    self.evidence = evidence
    self.displayStates = displayStates
    self.relationship = relationship
    self.systemContextAgreement = systemContextAgreement
    self.uncertainties = uncertainties
  }

  private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
  }
}

public struct ProviderScreenVisionSegment: Equatable, Sendable {
  /// Nil is the compatibility form used by local fixtures and connection tests; it covers the
  /// complete submitted window. Production provider responses always carry an explicit range.
  public let timeSliceRange: ClosedRange<Int>?
  public let inference: ScreenVisualInference

  public init(
    timeSliceRange: ClosedRange<Int>?,
    inference: ScreenVisualInference
  ) {
    self.timeSliceRange = timeSliceRange
    self.inference = inference
  }
}

public struct ProviderScreenVisionResponse: Equatable, Sendable {
  public let requestID: String?
  public let segments: [ProviderScreenVisionSegment]
  public let usage: ProviderReportedTokenUsage?

  /// Compatibility view for callers that only need a connection probe or a single fixture result.
  public var inference: ScreenVisualInference { segments[0].inference }

  public init(
    requestID: String?,
    inference: ScreenVisualInference,
    usage: ProviderReportedTokenUsage?
  ) {
    self.requestID = requestID
    segments = [.init(timeSliceRange: nil, inference: inference)]
    self.usage = usage
  }

  public init(
    requestID: String?,
    segments: [ProviderScreenVisionSegment],
    usage: ProviderReportedTokenUsage?
  ) {
    precondition((1...3).contains(segments.count))
    self.requestID = requestID
    self.segments = segments
    self.usage = usage
  }
}

public enum ScreenVisionProviderError: Error, Equatable, Sendable {
  case invalidEndpoint
  case missingCredential
  case invalidOCRContext
  case cancelled
  case transportUnavailable
  case unauthorized
  case rateLimited
  case serverFailure(statusCode: Int)
  case rejected(statusCode: Int)
  case invalidResponse
}

public protocol ScreenVisionInferring: Sendable {
  func infer(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws -> ProviderScreenVisionResponse
}

public protocol ScreenVisionConnectionTesting: Sendable {
  func testConnection(
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws
}

public struct OpenAICompatibleScreenVisionClient:
  ScreenVisionInferring, ScreenVisionConnectionTesting, Sendable
{
  private static let validationLogger = Logger(
    subsystem: "app.dayday.local",
    category: "screen-vision-response"
  )
  private let transport: any ProviderHTTPTransport
  private let timeout: TimeInterval

  public init(
    transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(),
    timeout: TimeInterval = 90
  ) {
    self.transport = transport
    self.timeout = timeout
  }

  public func infer(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws -> ProviderScreenVisionResponse {
    guard !credential.isEmpty else { throw ScreenVisionProviderError.missingCredential }
    let request = try Self.request(
      batch: batch,
      configuration: configuration,
      credential: credential,
      timeout: timeout
    )
    do {
      let (data, response) = try await transport.data(for: request)
      let envelope = try Self.decode(data: data, response: response)
      let normalizedSegments = Self.repairSingleSegmentCoverage(
        envelope.segments,
        submittedTimeSliceCount: batch.timeSlices.count
      )
      let explicitRanges = normalizedSegments.compactMap(\.timeSliceRange)
      if !explicitRanges.isEmpty {
        guard explicitRanges.count == normalizedSegments.count,
          explicitRanges.first?.lowerBound == 0,
          explicitRanges.last?.upperBound == batch.timeSlices.count - 1
        else { throw Self.invalidResponse(stage: "segment-window-coverage") }
      }
      let segments = try normalizedSegments.map { result in
        try Self.reconciledSegment(from: result, batch: batch)
      }
      guard !segments.isEmpty, segments.count <= 3 else {
        throw Self.invalidResponse(stage: "segment-count")
      }
      return ProviderScreenVisionResponse(
        requestID: envelope.requestID,
        segments: segments,
        usage: envelope.usage
      )
    } catch is CancellationError {
      throw ScreenVisionProviderError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw ScreenVisionProviderError.cancelled
    } catch let error as ScreenVisionProviderError {
      throw error
    } catch {
      throw ScreenVisionProviderError.transportUnavailable
    }
  }

  /// A sole segment already gives one unified visible situation. When a provider accidentally
  /// narrows its declared range, expanding that sole description to the submitted window keeps
  /// the evidence boundary local and avoids a needless retry. Multi-segment gaps remain rejected.
  private static func repairSingleSegmentCoverage(
    _ segments: [NormalizedVisionSegment],
    submittedTimeSliceCount: Int
  ) -> [NormalizedVisionSegment] {
    guard segments.count == 1, let suppliedRange = segments[0].timeSliceRange else { return segments }
    let completeRange = 0...(submittedTimeSliceCount - 1)
    guard suppliedRange != completeRange,
      suppliedRange.lowerBound >= 0,
      suppliedRange.upperBound < submittedTimeSliceCount
    else { return segments }
    let segment = segments[0]
    validationLogger.notice("Visual response repaired from a narrowed single-segment range")
    return [
      NormalizedVisionSegment(
        timeSliceRange: completeRange,
        summary: segment.summary,
        interaction: segment.interaction,
        activityKind: segment.activityKind,
        evidence: segment.evidence,
        displayStates: segment.displayStates,
        relationship: segment.relationship,
        systemContextAgreement: segment.systemContextAgreement,
        uncertainties: segment.uncertainties
      )
    ]
  }

  private static func reconciledSegment(
    from result: NormalizedVisionSegment,
    batch: ScreenVisualTimelineBatch
  ) throws -> ProviderScreenVisionSegment {
    let timeSliceRange = result.timeSliceRange ?? (0...(batch.timeSlices.count - 1))
    guard timeSliceRange.lowerBound >= 0,
      timeSliceRange.upperBound < batch.timeSlices.count
    else { throw Self.invalidResponse(stage: "segment-time-slice-range") }
    let segmentFrames = timeSliceRange.flatMap { batch.timeSlices[$0].frames }
    guard !segmentFrames.isEmpty else {
      throw Self.invalidResponse(stage: "segment-frames-empty")
    }
    var seenExpectedLabels = Set<String>()
    let expectedLabels = segmentFrames.compactMap { frame in
      seenExpectedLabels.insert(frame.displayLabel).inserted ? frame.displayLabel : nil
    }
    let providerStates = result.displayStates
    if providerStates.count == expectedLabels.count,
      Set(providerStates.map(\.displayLabel)) == Set(expectedLabels)
    {
      let stateByLabel = Dictionary(
        uniqueKeysWithValues: providerStates.map {
          ($0.displayLabel, $0)
        })
      let displayStates = try expectedLabels.map { label in
        guard let state = stateByLabel[label] else {
          throw Self.invalidResponse(stage: "display-label-missing-from-exact-set")
        }
        return try ScreenVisualDisplayInference(
          displayLabel: label,
          role: state.role,
          visibleState: state.visibleState
        )
      }
      return try Self.segment(
        from: result,
        timeSliceRange: timeSliceRange,
        displayStates: displayStates
      )
    }
    if providerStates.count < expectedLabels.count {
      do {
        guard
          let combinedVisibleState = Self.normalizedProviderText(
            providerStates.map(\.visibleState).joined(separator: "；"),
            maximumUTF8Bytes: 600
          )
        else { throw Self.invalidResponse(stage: "partial-display-state-empty") }
        let displayStates = try expectedLabels.map { label in
          try ScreenVisualDisplayInference(
            displayLabel: label,
            role: .unknown,
            visibleState: combinedVisibleState
          )
        }
        let uncertainty = "视觉模型未完整逐屏返回状态；各显示器暂时共用同一跨屏合并描述。"
        let uncertainties = Array(result.uncertainties.prefix(3)) + [uncertainty]
        let response = try Self.segment(
          from: result,
          timeSliceRange: timeSliceRange,
          displayStates: displayStates,
          relationship: .uncertain,
          uncertainties: uncertainties
        )
        Self.validationLogger.notice(
          "Visual response recovered as an explicitly uncertain combined-display state"
        )
        return response
      } catch {
        if let providerError = error as? ScreenVisionProviderError { throw providerError }
        throw Self.invalidResponse(stage: "combined-display-reconciliation")
      }
    }
    if expectedLabels.count == 1, let primaryState = providerStates.first {
      do {
        let state = try ScreenVisualDisplayInference(
          displayLabel: expectedLabels[0],
          role: primaryState.role,
          visibleState: primaryState.visibleState
        )
        let uncertainty = "视觉模型返回了多余屏幕状态；已仅保留本地已知屏幕的首项描述。"
        let response = try Self.segment(
          from: result,
          timeSliceRange: timeSliceRange,
          displayStates: [state],
          relationship: .uncertain,
          uncertainties: Array(result.uncertainties.prefix(3)) + [uncertainty]
        )
        Self.validationLogger.notice("Visual response recovered by discarding extra single-display states")
        return response
      } catch {
        if let providerError = error as? ScreenVisionProviderError { throw providerError }
        throw Self.invalidResponse(stage: "extra-single-display-reconciliation")
      }
    }
    // Some compatible multimodal models preserve the display-state array order but translate
    // Dayday's opaque labels, or return one state per chronological input frame instead of one
    // state per unique display. Recover only for those two exact cardinalities. Missing,
    // unrelated extra, or otherwise ambiguous states still fail closed.
    let reconciliationLabels: [String]
    if providerStates.count == expectedLabels.count {
      reconciliationLabels = expectedLabels
    } else if providerStates.count == segmentFrames.count {
      reconciliationLabels = segmentFrames.map(\.displayLabel)
    } else {
      throw Self.invalidResponse(
        stage:
          "display-label-cardinality-expected-\(expectedLabels.count)-frames-\(segmentFrames.count)-actual-\(providerStates.count)"
      )
    }
    do {
      let relabeledStates = try zip(providerStates, reconciliationLabels).map {
        state, expectedLabel in
        try ScreenVisualDisplayInference(
          displayLabel: expectedLabel,
          role: state.role,
          visibleState: state.visibleState
        )
      }
      var latestByDisplay = [String: ScreenVisualDisplayInference]()
      for state in relabeledStates { latestByDisplay[state.displayLabel] = state }
      let displayStates = try expectedLabels.map { label in
        guard let state = latestByDisplay[label] else {
          throw Self.invalidResponse(stage: "display-label-missing-after-reconciliation")
        }
        return state
      }
      let response = try Self.segment(
        from: result,
        timeSliceRange: timeSliceRange,
        displayStates: displayStates
      )
      Self.validationLogger.notice(
        "Visual response recovered by ordered display-label reconciliation"
      )
      return response
    } catch {
      if let providerError = error as? ScreenVisionProviderError { throw providerError }
      throw Self.invalidResponse(stage: "display-label-reconciliation")
    }
  }

  public func testConnection(
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws {
    // A tiny valid PNG proves authentication, model availability, image input and strict JSON in
    // one bounded request. Qwen VL rejects dimensions of 10 px or less, so the neutral fixture is
    // deliberately 16×16. It contains no user data and is never persisted.
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAI0lEQVR4nGP8//8/AymAiSTVDKMaiANMRKqDg1ENxACSQwkAVW0DHeN02ZEAAAAASUVORK5CYII="
    )!
    let image = try EphemeralVisionImage(
      data: png, mediaType: .png, pixelWidth: 16, pixelHeight: 16)
    _ = try await infer(
      batch: try ScreenVisualTimelineBatch(
        frames: [
          .init(
            image: image, observedAt: .now, displayLabel: "connection-test", redactedOCRLines: [])
        ]
      ),
      configuration: configuration,
      credential: credential
    )
  }

  static func request(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String,
    timeout: TimeInterval
  ) throws -> URLRequest {
    guard let endpoint = Self.chatCompletionsURL(from: configuration.endpoint),
      timeout.isFinite, timeout > 0,
      !credential.isEmpty,
      !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ScreenVisionProviderError.invalidEndpoint }

    let timeSliceContext = batch.timeSlices.enumerated().map { sliceIndex, slice in
      let systemContext = [
        Self.systemContextPrefix(slice.systemContext),
        slice.systemContext.foregroundApplicationLabel.map { "应用标签：\($0)" },
        slice.systemContext.focusedWindowTitle.map { "已过滤窗口标题：\($0)" },
      ].compactMap { $0 }.joined(separator: "；")
      let displays = slice.frames.map { frame in
        let ocr = frame.redactedOCRLines.map(\.value).joined(separator: " | ")
        return "- \(frame.displayLabel)：本地 OCR（可能为空，仅作辅助）：\(ocr)"
      }.joined(separator: "\n")
      return
        "时间片 \(sliceIndex + 1)：\(Self.timestamp(slice.observedAt))；\(systemContext.isEmpty ? "系统上下文：不可用" : systemContext)\n\(displays)"
    }.joined(separator: "\n")
    let continuityContext = batch.continuityContext.recentSegments.enumerated().map {
      index, segment in
      let application = segment.foregroundApplicationLabel.map { "；系统前台应用：\($0)" } ?? ""
      return "- 既往片段 \(index + 1)：\(segment.activityKind.rawValue)；\(segment.summary)\(application)"
    }.joined(separator: "\n")
    let prompt = """
      分析按时间顺序提供的工作桌面截图。不要猜测屏幕外行为，不要评价效率或专注度。
      只有标为“当前”的系统上下文才是前台应用的确定事实；不得仅凭相似界面把应用改称为其他产品。标为“最近观测”的上下文可能已过期，只能辅助消歧，不能当作当前应用事实。
      system_context_agreement 必须且只能为 matches、conflicts、unavailable：存在任一“当前”系统上下文时，画面与其应用身份一致写 matches，识别到不同应用界面写 conflicts；没有“当前”系统上下文时必须写 unavailable。conflicts 时必须在 uncertainties 说明冲突，不可自行改写系统应用名。
      下方“既往片段”只是本地模型的暂定连续性提示，不是当前截图的证据；它不能覆盖当前图像、当前时间片系统上下文或其中的不确定性。若当前画面发生变化，优先如实描述变化。
      将整个候选窗口按“连续、同一工作主题”归纳为 1 至 3 个时段。短暂切换、查看参考资料或少于约 5 分钟的插曲应并入主要时段；只有可见工作主题确实改变时才切段。
      segments 必须按时间顺序排列、互不重叠并覆盖全部时间片。start_time_slice 和 end_time_slice 使用下方从 1 开始的时间片编号，且包含首尾。
      每个时段的 summary：一句话概括该连续画面的可见工作情境，并可根据连续画面与可见交互推断紧邻的工作意图（例如“在准备日报素材”）；意图必须有画面依据，不得断言屏幕外动机、未展示的结果或后续计划，证据不足时只描述画面。interaction：描述跨帧可见的交互或状态变化，无法判断则明确不确定；
      activity_kind 只能是 reading、writing、navigation、development、communication、media、meeting、other、uncertain；
      display_states：为该时段内每个出现的 display label 只返回一项，包含 display_label、role、visible_state；display_label 必须逐字复制下方的 display-xxxxxxxx，不得翻译、改名、新增或遗漏。
      role 只能是 primary、reference、communication、monitoring、independent、unknown；relationship 只能是 coordinated、independent、uncertain。
      evidence 最多 8 条，只写图中可见依据；uncertainties 最多 4 条，写清无法从画面确认的点。
      summary 和 interaction 各不超过 300 个汉字；每项 visible_state 不超过 180 个汉字；每项 evidence 和 uncertainty 不超过 80 个汉字。所有文字字段使用单行纯文本，不要在字符串中换行。
      只返回 JSON 对象，最外层键必须且只能为 segments。segments 中每项必须包含 start_time_slice、end_time_slice、summary、interaction、activity_kind、evidence、display_states、relationship、system_context_agreement、uncertainties；不要输出其他语义字段。
      时间片上下文（同一时间片中的多块屏幕必须联合判断，不得把全局前台应用错误套用到每块屏幕）：
      \(timeSliceContext)
      既往片段（可能为空）：
      \(continuityContext.isEmpty ? "无" : continuityContext)
      """
    let imageParts: [VisionRequestBody.Content] = batch.frames.map { frame in
      .imageURL(
        url:
          "data:\(frame.image.mediaType.rawValue);base64,\(frame.image.data.base64EncodedString())",
        detail: configuration.detail.rawValue
      )
    }
    let body = VisionRequestBody(
      model: configuration.model,
      messages: [
        .init(
          role: "user",
          content: [
            .text(prompt)
          ] + imageParts
        )
      ],
      responseFormat: .init(type: "json_object"),
      enableThinking: configuration.thinkingEnabled,
      maxTokens: 2_400,
      stream: false
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func systemContextPrefix(_ context: ScreenVisualSystemContext) -> String {
    switch context.freshness {
    case .current: return "系统上下文：当前"
    case .recentlyObserved: return "系统上下文：最近观测（非当前事实）"
    case .unavailable: return "系统上下文：不可用"
    }
  }

  private static func decode(data: Data, response: URLResponse) throws -> NormalizedVisionEnvelope {
    guard let http = response as? HTTPURLResponse else {
      throw Self.invalidResponse(stage: "non-http-response")
    }
    try validate(statusCode: http.statusCode)

    let responseBody: VisionResponseBody
    do {
      responseBody = try JSONDecoder().decode(VisionResponseBody.self, from: data)
    } catch {
      throw Self.invalidResponse(stage: "response-envelope")
    }
    guard let content = responseBody.choices.first?.message.content,
      let contentData = content.data(using: .utf8)
    else { throw Self.invalidResponse(stage: "missing-message-content") }

    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: contentData)
    } catch {
      throw Self.invalidResponse(stage: "message-content-json")
    }
    guard let dictionary = object as? [String: Any] else {
      throw Self.invalidResponse(stage: "message-content-object")
    }
    let segmentPayloads: [(payload: VisionInferencePayload, range: ClosedRange<Int>?)]
    if let rawSegments = dictionary["segments"] as? [[String: Any]], !rawSegments.isEmpty {
      let payload: VisionWindowPayload
      do {
        payload = try JSONDecoder().decode(VisionWindowPayload.self, from: contentData)
      } catch {
        throw Self.invalidResponse(stage: "segment-field-decode")
      }
      guard (1...3).contains(payload.segments.count) else {
        throw Self.invalidResponse(stage: "segment-count")
      }
      segmentPayloads = try payload.segments.map { segment in
        guard segment.startTimeSlice > 0, segment.endTimeSlice >= segment.startTimeSlice else {
          throw Self.invalidResponse(stage: "segment-range")
        }
        return (segment.inference, (segment.startTimeSlice - 1)...(segment.endTimeSlice - 1))
      }
      for pair in zip(segmentPayloads, segmentPayloads.dropFirst()) {
        guard let left = pair.0.range, let right = pair.1.range,
          left.upperBound + 1 == right.lowerBound
        else { throw Self.invalidResponse(stage: "segment-order-or-coverage") }
      }
    } else if VisionInferencePayload.expectedKeys.isSubset(of: Set(dictionary.keys)) {
      // Compatibility keeps connection tests and previously configured local providers working
      // while production prompts move to the explicit multi-segment envelope.
      let payload: VisionInferencePayload
      do {
        payload = try JSONDecoder().decode(VisionInferencePayload.self, from: contentData)
      } catch {
        throw Self.invalidResponse(stage: "inference-field-decode")
      }
      segmentPayloads = [(payload, nil)]
    } else {
      throw Self.invalidResponse(stage: "message-content-keys")
    }

    let segments = try segmentPayloads.map { item in
      try normalizedSegment(from: item.payload, timeSliceRange: item.range)
    }
    return NormalizedVisionEnvelope(
      requestID: responseBody.id,
      segments: segments,
      usage: responseBody.usage.map {
        ProviderReportedTokenUsage(
          promptTokens: $0.promptTokens,
          completionTokens: $0.completionTokens,
          totalTokens: $0.totalTokens,
          cachedTokens: $0.promptTokensDetails?.cachedTokens
        )
      }
    )
  }

  private static func normalizedSegment(
    from payload: VisionInferencePayload,
    timeSliceRange: ClosedRange<Int>?
  ) throws -> NormalizedVisionSegment {
    guard
      let summary = normalizedProviderText(payload.summary, maximumUTF8Bytes: 1_024),
      let interaction = normalizedProviderText(payload.interaction, maximumUTF8Bytes: 1_024)
    else { throw Self.invalidResponse(stage: "summary-or-interaction") }
    var seenDisplayLabels = Set<String>()
    let displayStates: [NormalizedVisionDisplayState] = try payload.displayStates.enumerated().map {
      index, state in
      guard
        let visibleState = normalizedProviderText(
          state.visibleState,
          maximumUTF8Bytes: 600
        )
      else { throw Self.invalidResponse(stage: "display-visible-state") }
      let normalizedLabel =
        normalizedProviderText(state.displayLabel, maximumUTF8Bytes: 64)
        ?? "provider-invalid-\(index)"
      let displayLabel =
        seenDisplayLabels.insert(normalizedLabel).inserted
        ? normalizedLabel
        : "provider-duplicate-\(index)"
      return NormalizedVisionDisplayState(
        displayLabel: displayLabel,
        role: state.role,
        visibleState: visibleState
      )
    }
    guard !displayStates.isEmpty else {
      throw Self.invalidResponse(stage: "display-states-empty")
    }
    return NormalizedVisionSegment(
      timeSliceRange: timeSliceRange,
      summary: summary,
      interaction: interaction,
      activityKind: payload.activityKind,
      evidence: payload.evidence.prefix(8).compactMap {
        normalizedProviderText($0, maximumUTF8Bytes: 256)
      },
      displayStates: displayStates,
      relationship: payload.relationship,
      systemContextAgreement: payload.systemContextAgreement,
      uncertainties: payload.uncertainties.prefix(4).compactMap {
        normalizedProviderText($0, maximumUTF8Bytes: 256)
      }
    )
  }

  private static func segment(
    from result: NormalizedVisionSegment,
    timeSliceRange: ClosedRange<Int>,
    displayStates: [ScreenVisualDisplayInference],
    relationship: VisualDisplayRelationship? = nil,
    uncertainties: [String]? = nil
  ) throws -> ProviderScreenVisionSegment {
    let inference: ScreenVisualInference
    do {
      inference = try ScreenVisualInference(
        summary: result.summary,
        interaction: result.interaction,
        activityKind: result.activityKind,
        evidence: result.evidence,
        displayStates: displayStates,
        relationship: relationship ?? result.relationship,
        systemContextAgreement: result.systemContextAgreement,
        uncertainties: uncertainties ?? result.uncertainties
      )
    } catch let error as ScreenVisualInference.ValidationError {
      let stage: String
      switch error {
      case .invalidSummary: stage = "domain-summary"
      case .invalidInteraction: stage = "domain-interaction"
      case .tooManyEvidenceItems: stage = "domain-evidence-count"
      case .invalidEvidence: stage = "domain-evidence"
      case .noDisplayStates: stage = "domain-display-empty"
      case .duplicateDisplayLabel: stage = "domain-display-duplicate"
      case .tooManyDisplayStates: stage = "domain-display-count"
      case .tooManyUncertainties: stage = "domain-uncertainty-count"
      case .invalidUncertainty: stage = "domain-uncertainty"
      }
      throw Self.invalidResponse(stage: stage)
    }
    return ProviderScreenVisionSegment(timeSliceRange: timeSliceRange, inference: inference)
  }

  private static func chatCompletionsURL(from base: URL) -> URL? {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      scheme == "https" || (scheme == "http" && Self.isLoopback(host))
    else { return nil }

    var path = components.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/chat/completions") {
      components.path = path
    } else if path.hasSuffix("/v1") {
      components.path = path + "/chat/completions"
    } else if path.isEmpty || path == "/" {
      components.path = "/v1/chat/completions"
    } else {
      components.path = path + "/v1/chat/completions"
    }
    return components.url
  }

  /// Provider prose is untrusted, variable-length inference output. Preserve its visible meaning
  /// while converging whitespace and the domain's existing UTF-8 storage ceilings so one verbose
  /// response cannot permanently pin the crash-safe retry queue.
  private static func normalizedProviderText(
    _ value: String,
    maximumUTF8Bytes: Int
  ) -> String? {
    precondition(maximumUTF8Bytes > 0)
    let singleLine = value.unicodeScalars.map { scalar in
      scalar.value < 0x20 || scalar.value == 0x7F ? " " : String(scalar)
    }.joined()
    let normalized = singleLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    guard normalized.utf8.count > maximumUTF8Bytes else { return normalized }
    var result = ""
    for character in normalized {
      let candidate = result + String(character)
      guard candidate.utf8.count <= maximumUTF8Bytes else { break }
      result = candidate
    }
    return result.isEmpty ? nil : result
  }

  private static func invalidResponse(stage: String) -> ScreenVisionProviderError {
    validationLogger.error(
      "Visual response rejected at stage: \(stage, privacy: .public)"
    )
    return .invalidResponse
  }

  private static func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  private static func validate(statusCode: Int) throws {
    switch statusCode {
    case 200...299: return
    case 401, 403: throw ScreenVisionProviderError.unauthorized
    case 429: throw ScreenVisionProviderError.rateLimited
    case 500...599: throw ScreenVisionProviderError.serverFailure(statusCode: statusCode)
    default: throw ScreenVisionProviderError.rejected(statusCode: statusCode)
    }
  }
}

private struct VisionRequestBody: Encodable {
  struct Message: Encodable {
    let role: String
    let content: [Content]
  }

  enum Content: Encodable {
    case text(String)
    case imageURL(url: String, detail: String)

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .text(let text):
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
      case .imageURL(let url, let detail):
        try container.encode("image_url", forKey: .type)
        try container.encode(ImageURL(url: url, detail: detail), forKey: .imageURL)
      }
    }

    private struct ImageURL: Encodable {
      let url: String
      let detail: String
    }

    private enum CodingKeys: String, CodingKey {
      case type, text
      case imageURL = "image_url"
    }
  }

  struct ResponseFormat: Encodable { let type: String }
  let model: String
  let messages: [Message]
  let responseFormat: ResponseFormat
  let enableThinking: Bool
  let maxTokens: Int
  let stream: Bool

  enum CodingKeys: String, CodingKey {
    case model, messages, stream
    case responseFormat = "response_format"
    case enableThinking = "enable_thinking"
    case maxTokens = "max_tokens"
  }
}

private struct VisionInferencePayload: Decodable {
  static let expectedKeys: Set<String> = [
    "summary", "interaction", "activity_kind", "evidence", "display_states",
    "relationship", "system_context_agreement", "uncertainties",
  ]

  let summary: String
  let interaction: String
  let activityKind: ScreenVisualActivityKind
  let evidence: [String]
  let displayStates: [DisplayState]
  let relationship: VisualDisplayRelationship
  let systemContextAgreement: VisualSystemContextAgreement
  let uncertainties: [String]

  struct DisplayState: Decodable {
    let displayLabel: String
    let role: VisualDisplayRole
    let visibleState: String

    enum CodingKeys: String, CodingKey {
      case role
      case displayLabel = "display_label"
      case visibleState = "visible_state"
    }
  }

  enum CodingKeys: String, CodingKey {
    case summary, interaction, evidence, relationship, uncertainties
    case activityKind = "activity_kind"
    case displayStates = "display_states"
    case systemContextAgreement = "system_context_agreement"
  }
}

private struct VisionWindowPayload: Decodable {
  let segments: [VisionSegmentPayload]
}

private struct VisionSegmentPayload: Decodable {
  static let expectedKeys = VisionInferencePayload.expectedKeys.union([
    "start_time_slice", "end_time_slice",
  ])

  let startTimeSlice: Int
  let endTimeSlice: Int
  let summary: String
  let interaction: String
  let activityKind: ScreenVisualActivityKind
  let evidence: [String]
  let displayStates: [VisionInferencePayload.DisplayState]
  let relationship: VisualDisplayRelationship
  let systemContextAgreement: VisualSystemContextAgreement
  let uncertainties: [String]

  var inference: VisionInferencePayload {
    VisionInferencePayload(
      summary: summary,
      interaction: interaction,
      activityKind: activityKind,
      evidence: evidence,
      displayStates: displayStates,
      relationship: relationship,
      systemContextAgreement: systemContextAgreement,
      uncertainties: uncertainties
    )
  }

  enum CodingKeys: String, CodingKey {
    case summary, interaction, evidence, relationship, uncertainties
    case startTimeSlice = "start_time_slice"
    case endTimeSlice = "end_time_slice"
    case activityKind = "activity_kind"
    case displayStates = "display_states"
    case systemContextAgreement = "system_context_agreement"
  }
}

private struct NormalizedVisionDisplayState {
  let displayLabel: String
  let role: VisualDisplayRole
  let visibleState: String
}

private struct NormalizedVisionSegment {
  let timeSliceRange: ClosedRange<Int>?
  let summary: String
  let interaction: String
  let activityKind: ScreenVisualActivityKind
  let evidence: [String]
  let displayStates: [NormalizedVisionDisplayState]
  let relationship: VisualDisplayRelationship
  let systemContextAgreement: VisualSystemContextAgreement
  let uncertainties: [String]
}

private struct NormalizedVisionEnvelope {
  let requestID: String?
  let segments: [NormalizedVisionSegment]
  let usage: ProviderReportedTokenUsage?
}

private struct VisionResponseBody: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message
  }

  struct Usage: Decodable {
    struct PromptTokensDetails: Decodable {
      let cachedTokens: Int?
      enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
    }
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptTokensDetails: PromptTokensDetails?

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
      case promptTokensDetails = "prompt_tokens_details"
    }
  }

  let id: String?
  let choices: [Choice]
  let usage: Usage?
}
