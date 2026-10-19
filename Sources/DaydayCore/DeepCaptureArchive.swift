import Foundation

/// Opaque identity for one durable visible-content observation.
public struct VisibleContentObservationID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

/// Opaque identity for one non-replayable text-production aggregate.
public struct TextProductionAggregateID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

public enum VisibleContentKind: String, Codable, CaseIterable, Hashable, Sendable {
  case objectiveText
  case inference
}

/// Why a record is allowed to retain text. Classification is deliberately not a claim that text
/// is user-authored; that distinction is carried by `VisibleContentKind`.
public enum VisibleContentClassification: String, Codable, CaseIterable, Hashable, Sendable {
  case ordinaryVisibleContent
  case conversation
  case document
  case sourceCode
}

public enum VisibleContentRedactionState: String, Codable, CaseIterable, Hashable, Sendable {
  case redacted
  case noRedactionNeeded
  case excluded
}

/// Source/time/window/display context for a content observation. Application identifiers are
/// opaque; raw bundle IDs and raw accessibility trees never enter this value.
public struct VisibleContentProvenance: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidTimestamp
    case endBeforeStart
    case invalidTimeZoneIdentifier(String)
    case invalidWindowLabel
  }

  public let source: CollectorSource
  public let observedAt: Date
  public let endedAt: Date?
  public let timeZoneIdentifier: String
  public let applicationIdentifier: ApplicationIdentifier?
  public let windowLabel: String?
  public let display: DisplayContext?

  public init(
    source: CollectorSource,
    observedAt: Date,
    endedAt: Date? = nil,
    timeZoneIdentifier: String,
    applicationIdentifier: ApplicationIdentifier? = nil,
    windowLabel: String? = nil,
    display: DisplayContext? = nil
  ) throws {
    guard observedAt.timeIntervalSinceReferenceDate.isFinite,
      endedAt?.timeIntervalSinceReferenceDate.isFinite != false else {
      throw ValidationError.invalidTimestamp
    }
    guard endedAt == nil || endedAt! >= observedAt else { throw ValidationError.endBeforeStart }
    guard TimeZone(identifier: timeZoneIdentifier) != nil else {
      throw ValidationError.invalidTimeZoneIdentifier(timeZoneIdentifier)
    }
    if let windowLabel { try DeepCaptureValidation.text(windowLabel, maximumUTF8Bytes: 256) }
    self.source = source
    self.observedAt = observedAt
    self.endedAt = endedAt
    self.timeZoneIdentifier = timeZoneIdentifier
    self.applicationIdentifier = applicationIdentifier
    self.windowLabel = windowLabel
    self.display = display
  }
}

/// A bounded archive record for text that was visibly rendered in an allowed context, or for a
/// separately derived inference. Excluded records remain auditable but carry no text.
public struct VisibleContentObservation: Codable, Equatable, Hashable, Sendable {
  public static let currentRecordVersion = 1
  public enum ValidationError: Error, Equatable, Sendable {
    case unsupportedRecordVersion(Int)
    case emptyText
    case textTooLong
    case exclusionMustNotContainContent
    case exclusionMustUseSafeProvenance
    case nonExcludedMustContainContent
    case inferenceRequiresInferenceOrigin
    case invalidInferenceOrigin
    case objectiveCannotHaveInferenceOrigin
    case objectiveCannotHaveVisualWorkSegment
  }

  public let id: VisibleContentObservationID
  public let provenance: VisibleContentProvenance
  public let kind: VisibleContentKind
  public let classification: VisibleContentClassification?
  public let redactionState: VisibleContentRedactionState
  public let suppressionReason: CollectionSuppressionReason?
  public let text: String?
  /// A stable local rule/model identifier; it is never a provider credential or prompt.
  public let inferenceOrigin: String?
  /// Typed visual-model output for report assembly. Legacy inference observations may omit it and
  /// retain only their bounded readable text projection.
  public let visualWorkSegment: VisualWorkSegment?
  public let recordVersion: Int

  public init(
    id: VisibleContentObservationID = VisibleContentObservationID(),
    provenance: VisibleContentProvenance,
    kind: VisibleContentKind,
    classification: VisibleContentClassification? = nil,
    redactionState: VisibleContentRedactionState,
    suppressionReason: CollectionSuppressionReason? = nil,
    text: String? = nil,
    inferenceOrigin: String? = nil,
    visualWorkSegment: VisualWorkSegment? = nil,
    recordVersion: Int = currentRecordVersion
  ) throws {
    guard recordVersion == Self.currentRecordVersion else { throw ValidationError.unsupportedRecordVersion(recordVersion) }
    if let text {
      guard !text.isEmpty else { throw ValidationError.emptyText }
      guard text.utf8.count <= 32_768 else { throw ValidationError.textTooLong }
    }
    if redactionState == .excluded {
      guard text == nil, classification == nil, suppressionReason != nil,
        kind == .objectiveText, inferenceOrigin == nil else {
        throw ValidationError.exclusionMustNotContainContent
      }
      guard provenance.windowLabel == nil else {
        throw ValidationError.exclusionMustUseSafeProvenance
      }
    } else {
      guard text != nil, suppressionReason == nil else { throw ValidationError.nonExcludedMustContainContent }
    }
    switch kind {
    case .objectiveText:
      guard inferenceOrigin == nil else { throw ValidationError.objectiveCannotHaveInferenceOrigin }
      guard visualWorkSegment == nil else { throw ValidationError.objectiveCannotHaveVisualWorkSegment }
    case .inference:
      guard let inferenceOrigin else { throw ValidationError.inferenceRequiresInferenceOrigin }
      try DeepCaptureValidation.identifier(inferenceOrigin)
    }
    self.id = id; self.provenance = provenance; self.kind = kind; self.classification = classification
    self.redactionState = redactionState; self.suppressionReason = suppressionReason; self.text = text
    self.inferenceOrigin = inferenceOrigin; self.visualWorkSegment = visualWorkSegment
    self.recordVersion = recordVersion
  }
}

/// A coarse writing interval. It provides duration only, never per-event timing or enough samples
/// to reconstruct a character stream.
public struct TextProductionInterval: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable { case invalidTimestamp; case endNotAfterStart }
  public let start: Date
  public let end: Date
  public init(start: Date, end: Date) throws {
    guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite else { throw ValidationError.invalidTimestamp }
    guard end > start else { throw ValidationError.endNotAfterStart }
    self.start = start; self.end = end
  }
}

/// Totals-only text production. It has no character, key, clipboard, snapshot, or event-order
/// field and its intervals are limited to 16 per aggregate to avoid a sparse replayable timeline.
public struct TextProductionAggregate: Codable, Equatable, Hashable, Sendable {
  public static let currentRecordVersion = 1
  public enum ValidationError: Error, Equatable, Sendable {
    case unsupportedRecordVersion(Int); case invalidTimestamp; case endBeforeStart
    case invalidTimeZoneIdentifier(String); case excludedMustBeZero; case allowedMustHaveNoSuppression
    case excludedMustUseSafeProvenance; case tooManyIntervals; case intervalsOverlap; case intervalOutsideAggregate
  }
  public let id: TextProductionAggregateID
  public let provenance: VisibleContentProvenance
  public let insertedGraphemeCount: UInt64
  public let deletedGraphemeCount: UInt64
  public let insertedUnicodeScalarCount: UInt64
  public let estimatedWordCount: UInt64
  public let correctionCount: UInt64
  public let intervals: [TextProductionInterval]
  public let suppressionReason: CollectionSuppressionReason?
  public let recordVersion: Int

  public init(
    id: TextProductionAggregateID = TextProductionAggregateID(), provenance: VisibleContentProvenance,
    insertedGraphemeCount: UInt64 = 0, deletedGraphemeCount: UInt64 = 0,
    insertedUnicodeScalarCount: UInt64 = 0, estimatedWordCount: UInt64 = 0,
    correctionCount: UInt64 = 0, intervals: [TextProductionInterval] = [],
    suppressionReason: CollectionSuppressionReason? = nil, recordVersion: Int = currentRecordVersion
  ) throws {
    guard recordVersion == Self.currentRecordVersion else { throw ValidationError.unsupportedRecordVersion(recordVersion) }
    guard intervals.count <= 16 else { throw ValidationError.tooManyIntervals }
    for (index, interval) in intervals.enumerated() {
      guard interval.start >= provenance.observedAt, provenance.endedAt.map({ interval.end <= $0 }) ?? true else { throw ValidationError.intervalOutsideAggregate }
      if index > 0, intervals[index - 1].end > interval.start { throw ValidationError.intervalsOverlap }
    }
    let isZero = insertedGraphemeCount == 0 && deletedGraphemeCount == 0 && insertedUnicodeScalarCount == 0 && estimatedWordCount == 0 && correctionCount == 0 && intervals.isEmpty
    if suppressionReason != nil {
      guard isZero else { throw ValidationError.excludedMustBeZero }
      guard provenance.windowLabel == nil else { throw ValidationError.excludedMustUseSafeProvenance }
    }
    else { guard !isZero else { throw ValidationError.allowedMustHaveNoSuppression } }
    self.id = id; self.provenance = provenance; self.insertedGraphemeCount = insertedGraphemeCount
    self.deletedGraphemeCount = deletedGraphemeCount; self.insertedUnicodeScalarCount = insertedUnicodeScalarCount
    self.estimatedWordCount = estimatedWordCount; self.correctionCount = correctionCount; self.intervals = intervals
    self.suppressionReason = suppressionReason; self.recordVersion = recordVersion
  }
}

public enum DeepCaptureInsertResult: Equatable, Sendable { case inserted, alreadyPresent }

public protocol VisibleContentArchiveRepository: Sendable {
  func insert(_ observation: VisibleContentObservation) async throws -> DeepCaptureInsertResult
  func fetchVisibleContent(observedIn range: Range<Date>) async throws -> [VisibleContentObservation]
}

public protocol TextProductionAggregateRepository: Sendable {
  func insert(_ aggregate: TextProductionAggregate) async throws -> DeepCaptureInsertResult
  func fetchTextProduction(observedIn range: Range<Date>) async throws -> [TextProductionAggregate]
}

private enum DeepCaptureValidation {
  static func text(_ value: String, maximumUTF8Bytes: Int) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      throw VisibleContentProvenance.ValidationError.invalidWindowLabel
    }
    guard value.utf8.count <= maximumUTF8Bytes else { throw VisibleContentProvenance.ValidationError.invalidWindowLabel }
  }
  static func identifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128,
      value.utf8.allSatisfy({ $0.isASCIIAlphaNumeric || $0 == 46 || $0 == 45 || $0 == 95 }) else {
      throw VisibleContentObservation.ValidationError.invalidInferenceOrigin
    }
  }
}

private extension UInt8 {
  var isASCIIAlphaNumeric: Bool { (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self) }
}
