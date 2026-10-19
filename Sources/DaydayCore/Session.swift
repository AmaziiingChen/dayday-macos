import Foundation

/// An opaque identifier for one immutable deterministic Session derivation.
public struct SessionID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public init() {
    self.init(rawValue: UUID())
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "SessionID",
      from: decoder
    )
    self.init(rawValue: try container.decode(UUID.self, forKey: .rawValue))
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }
}

/// The closed durable representation version for a Session.
public enum SessionVersion: UInt8, Codable, CaseIterable, Hashable, Sendable {
  case v1 = 1
  case v2 = 2
}

/// The objective lane on which a Session was observed.
///
/// Accessibility foreground-application facts are system-wide and do not truthfully identify a
/// display. Treating that absence as a fabricated display made production H2 derivation empty.
/// V2 therefore admits an explicit workspace lane while preserving V1 display-local payloads.
public enum SessionScope: Codable, Equatable, Hashable, Sendable {
  case display(DisplayID)
  case workspace

  private enum Kind: String, Codable { case display, workspace }
  private enum CodingKeys: String, CodingKey { case kind, displayID }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self, typeName: "SessionScope", from: decoder)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .display:
      self = .display(try container.decode(DisplayID.self, forKey: .displayID))
    case .workspace:
      guard !container.contains(.displayID) else {
        throw DecodingError.dataCorruptedError(
          forKey: .displayID, in: container,
          debugDescription: "Workspace scope cannot contain a display identifier")
      }
      self = .workspace
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .display(let displayID):
      try container.encode(Kind.display, forKey: .kind)
      try container.encode(displayID, forKey: .displayID)
    case .workspace:
      try container.encode(Kind.workspace, forKey: .kind)
    }
  }
}

/// A persisted hard boundary that ended a Session lane.
public enum SessionHardBoundaryReason: String, Codable, CaseIterable, Hashable, Sendable {
  case screenLocked
  case systemSleep
  case collectionPaused
  case privacySuppressed
  case authorizationLost
  case userSessionLost
  case displayDisconnected
  case shutdown
}

/// Immutable lineage for a deterministic rebuild or correction-derived Session.
///
/// A successor points to its predecessor. Existing Sessions are never updated to point forward.
public struct SessionLineage: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidDerivationRevision(UInt64)
  }

  public let derivationRevision: UInt64
  public let supersedesSessionID: SessionID?

  public init(derivationRevision: UInt64 = 1, supersedesSessionID: SessionID? = nil) throws {
    guard derivationRevision > 0 else {
      throw ValidationError.invalidDerivationRevision(derivationRevision)
    }

    self.derivationRevision = derivationRevision
    self.supersedesSessionID = supersedesSessionID
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "SessionLineage",
      from: decoder
    )
    try self.init(
      derivationRevision: container.decode(UInt64.self, forKey: .derivationRevision),
      supersedesSessionID: container.decodeIfPresent(SessionID.self, forKey: .supersedesSessionID)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case derivationRevision
    case supersedesSessionID
  }
}

/// One objective contiguous context lane on a display or the system foreground workspace.
///
/// Evidence identifiers are deliberately absent: an ID-only membership cannot prove its
/// stable-state-event linkage. A later derivation/read slice may join evidence through the
/// existing closed evidence contract.
public struct Session: Codable, Equatable, Hashable, Sendable {
  /// A defensive serialization ceiling, not a product Session-length or retention policy.
  public static let maximumObjectiveEventMembershipCount = 4_096

  public enum ValidationError: Error, Equatable, Sendable {
    case invalidIntervalTimestamp
    case unorderedInterval
    case emptyObjectiveEventMembership
    case exceedsMaximumObjectiveEventMembershipCount(Int)
    case duplicateObjectiveEventMembership(EventID)
    case lineageCannotSupersedeSelf
  }

  public let id: SessionID
  public let version: SessionVersion
  public let scope: SessionScope
  public var displayID: DisplayID? {
    guard case .display(let displayID) = scope else { return nil }
    return displayID
  }
  public let startedAt: Date
  public let endedAt: Date
  public let endingHardBoundary: SessionHardBoundaryReason?
  public let objectiveEventIDs: [EventID]
  public let lineage: SessionLineage

  public init(
    id: SessionID,
    version: SessionVersion = .v1,
    displayID: DisplayID,
    startedAt: Date,
    endedAt: Date,
    endingHardBoundary: SessionHardBoundaryReason? = nil,
    objectiveEventIDs: [EventID],
    lineage: SessionLineage? = nil
  ) throws {
    try self.init(
      id: id,
      version: version,
      scope: .display(displayID),
      startedAt: startedAt,
      endedAt: endedAt,
      endingHardBoundary: endingHardBoundary,
      objectiveEventIDs: objectiveEventIDs,
      lineage: lineage
    )
  }

  public init(
    id: SessionID,
    version: SessionVersion = .v2,
    scope: SessionScope,
    startedAt: Date,
    endedAt: Date,
    endingHardBoundary: SessionHardBoundaryReason? = nil,
    objectiveEventIDs: [EventID],
    lineage: SessionLineage? = nil
  ) throws {
    guard startedAt.timeIntervalSinceReferenceDate.isFinite,
      endedAt.timeIntervalSinceReferenceDate.isFinite
    else {
      throw ValidationError.invalidIntervalTimestamp
    }
    guard startedAt < endedAt else {
      throw ValidationError.unorderedInterval
    }
    guard !objectiveEventIDs.isEmpty else {
      throw ValidationError.emptyObjectiveEventMembership
    }
    guard objectiveEventIDs.count <= Self.maximumObjectiveEventMembershipCount else {
      throw ValidationError.exceedsMaximumObjectiveEventMembershipCount(objectiveEventIDs.count)
    }
    if let duplicate = Self.firstDuplicate(in: objectiveEventIDs) {
      throw ValidationError.duplicateObjectiveEventMembership(duplicate)
    }
    let resolvedLineage = try lineage ?? SessionLineage()
    guard resolvedLineage.supersedesSessionID != id else {
      throw ValidationError.lineageCannotSupersedeSelf
    }

    self.id = id
    self.version = version
    guard version == .v2 || {
      if case .display = scope { return true }
      return false
    }() else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "V1 Session must remain display-local"))
    }
    self.scope = scope
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.endingHardBoundary = endingHardBoundary
    self.objectiveEventIDs = objectiveEventIDs
    self.lineage = resolvedLineage
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "Session",
      from: decoder
    )
    let version = try container.decode(SessionVersion.self, forKey: .version)
    let scope: SessionScope
    switch version {
    case .v1:
      scope = .display(try container.decode(DisplayID.self, forKey: .displayID))
      guard !container.contains(.scope) else {
        throw DecodingError.dataCorruptedError(
          forKey: .scope, in: container, debugDescription: "V1 Session cannot contain scope")
      }
    case .v2:
      scope = try container.decode(SessionScope.self, forKey: .scope)
      guard !container.contains(.displayID) else {
        throw DecodingError.dataCorruptedError(
          forKey: .displayID, in: container,
          debugDescription: "V2 Session stores its lane in scope")
      }
    }
    try self.init(
      id: container.decode(SessionID.self, forKey: .id), version: version, scope: scope,
      startedAt: container.decode(Date.self, forKey: .startedAt),
      endedAt: container.decode(Date.self, forKey: .endedAt),
      endingHardBoundary: container.decodeIfPresent(SessionHardBoundaryReason.self, forKey: .endingHardBoundary),
      objectiveEventIDs: container.decode([EventID].self, forKey: .objectiveEventIDs),
      lineage: container.decode(SessionLineage.self, forKey: .lineage))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(version, forKey: .version)
    switch version {
    case .v1:
      guard case .display(let displayID) = scope else {
        throw EncodingError.invalidValue(
          scope, .init(codingPath: encoder.codingPath, debugDescription: "V1 Session must be display-local"))
      }
      try container.encode(displayID, forKey: .displayID)
    case .v2:
      try container.encode(scope, forKey: .scope)
    }
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(endedAt, forKey: .endedAt)
    try container.encodeIfPresent(endingHardBoundary, forKey: .endingHardBoundary)
    try container.encode(objectiveEventIDs, forKey: .objectiveEventIDs)
    try container.encode(lineage, forKey: .lineage)
  }

  private static func firstDuplicate(in identifiers: [EventID]) -> EventID? {
    var seen = Set<EventID>()
    for identifier in identifiers where !seen.insert(identifier).inserted {
      return identifier
    }
    return nil
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case version
    case displayID, scope
    case startedAt
    case endedAt
    case endingHardBoundary
    case objectiveEventIDs
    case lineage
  }
}
