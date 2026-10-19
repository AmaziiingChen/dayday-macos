import Foundation

/// The closed durable representation version for an inferred Activity interpretation.
public enum ActivityVersion: UInt8, Codable, CaseIterable, Hashable, Sendable { case v1 = 1 }

/// Coarse review/debug evidence quality, never a score or model self-report.
public enum ActivityConfidenceBand: String, Codable, CaseIterable, Hashable, Sendable {
  case low, medium, high
}
public enum ActivityReviewState: String, Codable, CaseIterable, Hashable, Sendable {
  case ready, needsReview
}

public enum ActivityEvidenceRole: String, Codable, CaseIterable, Hashable, Sendable {
  case supporting, conflicting
}

public enum ActivityInterpretationOrigin: String, Codable, CaseIterable, Hashable, Sendable {
  case deterministicRule, modelInference, mixed
}

/// Derived review/debug attribution; never an objective fact or provider configuration.
public struct ActivityInterpretation: Codable, Equatable, Hashable, Sendable {
  public static let maximumProducerVersionUTF8Length = 64
  public static let maximumRationaleUTF8Length = 2_048
  public enum ValidationError: Error, Equatable, Sendable {
    case emptyProducerVersion
    case oversizedProducerVersion(Int)
    case invalidProducerVersionFormat
    case emptyRationale
    case missingRequiredRationale
    case oversizedRationale(Int)
    case controlCharacter
  }
  public let origin: ActivityInterpretationOrigin
  public let producerVersion: String
  public let rationale: String?
  public init(
    origin: ActivityInterpretationOrigin, producerVersion: String, rationale: String? = nil
  ) throws {
    try validateInterpretationText(
      producerVersion, empty: .emptyProducerVersion, oversized: { .oversizedProducerVersion($0) },
      maximum: Self.maximumProducerVersionUTF8Length)
    guard
      producerVersion.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46
          || $0 == 43 || $0 == 45 || $0 == 95
      })
    else { throw ValidationError.invalidProducerVersionFormat }
    if (origin == .modelInference || origin == .mixed) && rationale == nil {
      throw ValidationError.missingRequiredRationale
    }
    if let rationale {
      try validateInterpretationText(
        rationale, empty: .emptyRationale, oversized: { .oversizedRationale($0) },
        maximum: Self.maximumRationaleUTF8Length)
    }
    self.origin = origin
    self.producerVersion = producerVersion
    self.rationale = rationale
  }
  public init(from decoder: Decoder) throws {
    let c = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self, typeName: "ActivityInterpretation", from: decoder)
    try self.init(
      origin: c.decode(ActivityInterpretationOrigin.self, forKey: .origin),
      producerVersion: c.decode(String.self, forKey: .producerVersion),
      rationale: c.decodeIfPresent(String.self, forKey: .rationale))
  }
  private enum CodingKeys: String, CodingKey { case origin, producerVersion, rationale }
}

/// Explicit redacted-evidence provenance for an Activity interpretation.
public struct ActivityEvidenceReference: Codable, Equatable, Hashable, Sendable {
  public let role: ActivityEvidenceRole
  public let evidenceFrameID: EvidenceFrameID
  public let stableStateObservationEventID: EventID

  public init(
    role: ActivityEvidenceRole, evidenceFrameID: EvidenceFrameID,
    stableStateObservationEventID: EventID
  ) {
    self.role = role
    self.evidenceFrameID = evidenceFrameID
    self.stableStateObservationEventID = stableStateObservationEventID
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self, typeName: "ActivityEvidenceReference", from: decoder
    )
    self.init(
      role: try container.decode(ActivityEvidenceRole.self, forKey: .role),
      evidenceFrameID: try decodeEvidenceFrameID(from: container, forKey: .evidenceFrameID),
      stableStateObservationEventID: try container.decode(
        EventID.self, forKey: .stableStateObservationEventID)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case role, evidenceFrameID, stableStateObservationEventID
  }
}

/// Immutable deterministic-rebuild lineage, not user-correction lineage.
public struct ActivityLineage: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidRevision(UInt64)
    case originalHasPredecessor
  }
  public let revision: UInt64
  public let supersedesDeterministicRebuildActivityID: ActivityID?

  public init(revision: UInt64 = 1, supersedesDeterministicRebuildActivityID: ActivityID? = nil)
    throws
  {
    guard revision > 0 else { throw ValidationError.invalidRevision(revision) }
    if revision == 1, supersedesDeterministicRebuildActivityID != nil {
      throw ValidationError.originalHasPredecessor
    }
    self.revision = revision
    self.supersedesDeterministicRebuildActivityID = supersedesDeterministicRebuildActivityID
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self, typeName: "ActivityLineage", from: decoder
    )
    try self.init(
      revision: container.decode(UInt64.self, forKey: .revision),
      supersedesDeterministicRebuildActivityID: decodeOptionalActivityID(
        from: container, forKey: .supersedesDeterministicRebuildActivityID)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case revision, supersedesDeterministicRebuildActivityID
  }
}

/// A revisable inferred interpretation of one or more independently-derived Session lanes.
///
/// It is not an objective event and never represents focus, productivity, or a user-facing score.
public struct Activity: Codable, Equatable, Hashable, Sendable {
  public static let maximumSessionCount = 4_096
  public static let maximumEvidenceReferenceCount = 4_096
  public static let maximumTitleUTF8Length = 256
  public static let maximumSummaryUTF8Length = 2_048

  public enum ValidationError: Error, Equatable, Sendable {
    case invalidTimestamp
    case unorderedInterval
    case emptySessionMembership
    case tooManySessions(Int)
    case duplicateSessionID(SessionID)
    case tooManyEvidenceReferences(Int)
    case duplicateEvidenceFrameID(EvidenceFrameID)
    case emptyTitle
    case emptySummary
    case textTooLong(Int)
    case controlCharacter
    case lineageCannotSupersedeSelf
  }

  public let id: ActivityID
  public let version: ActivityVersion
  public let startedAt: Date
  public let endedAt: Date
  /// Ordered membership may span displays but never changes or stitches the member Session lanes.
  public let sessionIDs: [SessionID]
  public let evidenceReferences: [ActivityEvidenceReference]
  public let title: String
  public let summary: String?
  public let confidence: ActivityConfidenceBand
  public let reviewState: ActivityReviewState
  public let interpretation: ActivityInterpretation
  public let lineage: ActivityLineage

  public init(
    id: ActivityID,
    version: ActivityVersion = .v1,
    startedAt: Date,
    endedAt: Date,
    sessionIDs: [SessionID],
    evidenceReferences: [ActivityEvidenceReference] = [],
    title: String,
    summary: String? = nil,
    confidence: ActivityConfidenceBand,
    reviewState: ActivityReviewState,
    interpretation: ActivityInterpretation,
    lineage: ActivityLineage? = nil
  ) throws {
    guard startedAt.timeIntervalSinceReferenceDate.isFinite,
      endedAt.timeIntervalSinceReferenceDate.isFinite
    else { throw ValidationError.invalidTimestamp }
    guard startedAt < endedAt else { throw ValidationError.unorderedInterval }
    guard !sessionIDs.isEmpty else { throw ValidationError.emptySessionMembership }
    guard sessionIDs.count <= Self.maximumSessionCount else {
      throw ValidationError.tooManySessions(sessionIDs.count)
    }
    if let duplicate = firstDuplicate(sessionIDs) {
      throw ValidationError.duplicateSessionID(duplicate)
    }
    guard evidenceReferences.count <= Self.maximumEvidenceReferenceCount else {
      throw ValidationError.tooManyEvidenceReferences(evidenceReferences.count)
    }
    if let duplicate = firstDuplicate(evidenceReferences.map(\.evidenceFrameID)) {
      throw ValidationError.duplicateEvidenceFrameID(duplicate)
    }
    try validate(title, empty: .emptyTitle, maximum: Self.maximumTitleUTF8Length)
    if let summary {
      try validate(summary, empty: .emptySummary, maximum: Self.maximumSummaryUTF8Length)
    }
    let resolvedLineage = try lineage ?? ActivityLineage()
    guard resolvedLineage.supersedesDeterministicRebuildActivityID != id else {
      throw ValidationError.lineageCannotSupersedeSelf
    }
    self.id = id
    self.version = version
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.sessionIDs = sessionIDs
    self.evidenceReferences = evidenceReferences
    self.title = title
    self.summary = summary
    self.confidence = confidence
    self.reviewState = reviewState
    self.interpretation = interpretation
    self.lineage = resolvedLineage
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self, typeName: "Activity", from: decoder)
    try self.init(
      id: decodeActivityID(from: container, forKey: .id),
      version: container.decode(ActivityVersion.self, forKey: .version),
      startedAt: container.decode(Date.self, forKey: .startedAt),
      endedAt: container.decode(Date.self, forKey: .endedAt),
      sessionIDs: container.decode([SessionID].self, forKey: .sessionIDs),
      evidenceReferences: container.decode(
        [ActivityEvidenceReference].self, forKey: .evidenceReferences),
      title: container.decode(String.self, forKey: .title),
      summary: container.decodeIfPresent(String.self, forKey: .summary),
      confidence: container.decode(ActivityConfidenceBand.self, forKey: .confidence),
      reviewState: container.decode(ActivityReviewState.self, forKey: .reviewState),
      interpretation: container.decode(ActivityInterpretation.self, forKey: .interpretation),
      lineage: container.decode(ActivityLineage.self, forKey: .lineage)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, version, startedAt, endedAt, sessionIDs, evidenceReferences, title,
      summary, confidence, reviewState, interpretation, lineage
  }
}

private enum IdentifierCodingKeys: String, CodingKey { case rawValue }
private func decodeActivityID<Key: CodingKey>(
  from container: KeyedDecodingContainer<Key>, forKey key: Key
) throws -> ActivityID {
  let nested = try ClosedWorldDecoding.nestedContainer(
    from: container, forKey: key, keyedBy: IdentifierCodingKeys.self, typeName: "ActivityID")
  return ActivityID(rawValue: try nested.decode(UUID.self, forKey: .rawValue))
}
private func decodeOptionalActivityID<Key: CodingKey>(
  from container: KeyedDecodingContainer<Key>, forKey key: Key
) throws -> ActivityID? {
  guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
  return try decodeActivityID(from: container, forKey: key)
}
private func decodeEvidenceFrameID<Key: CodingKey>(
  from container: KeyedDecodingContainer<Key>, forKey key: Key
) throws -> EvidenceFrameID {
  let nested = try ClosedWorldDecoding.nestedContainer(
    from: container, forKey: key, keyedBy: IdentifierCodingKeys.self, typeName: "EvidenceFrameID")
  return EvidenceFrameID(rawValue: try nested.decode(UUID.self, forKey: .rawValue))
}
private func firstDuplicate<Value: Hashable>(_ values: [Value]) -> Value? {
  var seen = Set<Value>()
  return values.first { !seen.insert($0).inserted }
}
private func validate(_ text: String, empty: Activity.ValidationError, maximum: Int) throws {
  guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw empty }
  guard text.utf8.count <= maximum else {
    throw Activity.ValidationError.textTooLong(text.utf8.count)
  }
  guard !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
    throw Activity.ValidationError.controlCharacter
  }
}
private func validateInterpretationText(
  _ value: String, empty: ActivityInterpretation.ValidationError,
  oversized: (Int) -> ActivityInterpretation.ValidationError, maximum: Int
) throws {
  guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw empty }
  guard value.utf8.count <= maximum else { throw oversized(value.utf8.count) }
  guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
    throw ActivityInterpretation.ValidationError.controlCharacter
  }
}
