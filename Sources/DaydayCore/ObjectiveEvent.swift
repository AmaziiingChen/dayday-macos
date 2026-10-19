import Foundation

/// A coarse objective event category. Category-specific detail belongs in a
/// separate privacy-reviewed record linked by `EventID`.
public enum ObjectiveEventKind: String, Codable, CaseIterable, Hashable, Sendable {
  case collectorStateTransition
  case stableStateObservation
  case displayTopologyChanged
  case applicationContextChanged
  case browserContextChanged
  case aggregateSnapshot
  case systemBoundary
}

public struct CollectorSource: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case emptyCollectorVersion
    case invalidCollectorVersionFormat
    case invalidPayloadSchemaVersion(Int)
  }

  public let collector: CollectorKind
  public let collectorVersion: String
  public let payloadSchemaVersion: Int

  public init(
    collector: CollectorKind,
    collectorVersion: String,
    payloadSchemaVersion: Int
  ) throws {
    guard !collectorVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyCollectorVersion
    }
    let allowedVersionBytes = collectorVersion.utf8.allSatisfy { byte in
      byte.isASCIIAlphaNumeric || byte == 46 || byte == 43 || byte == 45 || byte == 95
    }
    guard collectorVersion.utf8.count <= 64, allowedVersionBytes else {
      throw ValidationError.invalidCollectorVersionFormat
    }
    guard payloadSchemaVersion >= 1 else {
      throw ValidationError.invalidPayloadSchemaVersion(payloadSchemaVersion)
    }

    self.collector = collector
    self.collectorVersion = collectorVersion
    self.payloadSchemaVersion = payloadSchemaVersion
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "CollectorSource",
      from: decoder
    )
    try self.init(
      collector: container.decode(CollectorKind.self, forKey: .collector),
      collectorVersion: container.decode(String.self, forKey: .collectorVersion),
      payloadSchemaVersion: container.decode(Int.self, forKey: .payloadSchemaVersion)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case collector
    case collectorVersion
    case payloadSchemaVersion
  }
}

public struct DisplayContext: Codable, Equatable, Hashable, Sendable {
  public let id: DisplayID
  public let topologyRevision: UInt64

  public init(id: DisplayID, topologyRevision: UInt64) {
    self.id = id
    self.topologyRevision = topologyRevision
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "DisplayContext",
      from: decoder
    )
    self.init(
      id: try container.decode(DisplayID.self, forKey: .id),
      topologyRevision: try container.decode(UInt64.self, forKey: .topologyRevision)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case topologyRevision
  }
}

/// A safe reason why content processing was suppressed.
public enum CollectionSuppressionReason: String, Codable, CaseIterable, Hashable, Sendable {
  case globalPause
  case screenLocked
  case systemSleep
  case secureInput
  case incognito
  case authenticationContext
  case passwordManager
  case userExclusion
  case mandatoryExclusion
  case authorizationUnavailable
  case uncertainSafetyState
}

/// The outcome of the privacy gate, without the pixels or text that caused it.
public enum EventSecurityDisposition: Codable, Equatable, Hashable, Sendable {
  case allowed
  case metadataOnly(CollectionSuppressionReason)
  case excluded(CollectionSuppressionReason)

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "EventSecurityDisposition",
      from: decoder
    )
    guard container.allKeys.count == 1 else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "EventSecurityDisposition requires exactly one case"
        ))
    }

    if container.contains(.allowed) {
      _ = try ClosedWorldDecoding.nestedContainer(
        from: container,
        forKey: .allowed,
        keyedBy: EmptyCodingKeys.self,
        typeName: "EventSecurityDisposition.allowed"
      )
      self = .allowed
    } else if container.contains(.metadataOnly) {
      let values = try ClosedWorldDecoding.nestedContainer(
        from: container,
        forKey: .metadataOnly,
        keyedBy: AssociatedValueCodingKeys.self,
        typeName: "EventSecurityDisposition.metadataOnly"
      )
      self = .metadataOnly(try values.decode(CollectionSuppressionReason.self, forKey: .value))
    } else {
      let values = try ClosedWorldDecoding.nestedContainer(
        from: container,
        forKey: .excluded,
        keyedBy: AssociatedValueCodingKeys.self,
        typeName: "EventSecurityDisposition.excluded"
      )
      self = .excluded(try values.decode(CollectionSuppressionReason.self, forKey: .value))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .allowed:
      _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .allowed)
    case .metadataOnly(let reason):
      var values = container.nestedContainer(
        keyedBy: AssociatedValueCodingKeys.self,
        forKey: .metadataOnly
      )
      try values.encode(reason, forKey: .value)
    case .excluded(let reason):
      var values = container.nestedContainer(
        keyedBy: AssociatedValueCodingKeys.self,
        forKey: .excluded
      )
      try values.encode(reason, forKey: .value)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case allowed
    case metadataOnly
    case excluded
  }

  private enum AssociatedValueCodingKeys: String, CodingKey {
    case value = "_0"
  }

  private struct EmptyCodingKeys: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) { nil }
    init?(intValue: Int) { nil }
  }
}

/// Minimal persistable envelope for an objective collector observation.
///
/// It intentionally has no generic payload field. OCR text, raw key presses,
/// individual pointer coordinates, and screen pixels cannot be placed in this
/// type; privacy-reviewed aggregate or evidence types must be modeled
/// separately and linked using `id`.
public struct ObjectiveEvent: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case endBeforeStart
    case invalidTimestamp
    case invalidTimeZoneIdentifier(String)
  }

  public let id: EventID
  public let kind: ObjectiveEventKind
  public let occurredAt: Date
  public let endedAt: Date?
  public let timeZoneIdentifier: String
  public let source: CollectorSource
  public let display: DisplayContext?
  public let securityDisposition: EventSecurityDisposition

  public init(
    id: EventID = EventID(),
    kind: ObjectiveEventKind,
    occurredAt: Date,
    endedAt: Date? = nil,
    timeZoneIdentifier: String,
    source: CollectorSource,
    display: DisplayContext? = nil,
    securityDisposition: EventSecurityDisposition
  ) throws {
    guard occurredAt.timeIntervalSinceReferenceDate.isFinite,
      endedAt?.timeIntervalSinceReferenceDate.isFinite != false
    else {
      throw ValidationError.invalidTimestamp
    }
    if let endedAt, endedAt < occurredAt {
      throw ValidationError.endBeforeStart
    }
    guard TimeZone(identifier: timeZoneIdentifier) != nil else {
      throw ValidationError.invalidTimeZoneIdentifier(timeZoneIdentifier)
    }

    self.id = id
    self.kind = kind
    self.occurredAt = occurredAt
    self.endedAt = endedAt
    self.timeZoneIdentifier = timeZoneIdentifier
    self.source = source
    self.display = display
    self.securityDisposition = securityDisposition
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "ObjectiveEvent",
      from: decoder
    )
    try self.init(
      id: container.decode(EventID.self, forKey: .id),
      kind: container.decode(ObjectiveEventKind.self, forKey: .kind),
      occurredAt: container.decode(Date.self, forKey: .occurredAt),
      endedAt: container.decodeIfPresent(Date.self, forKey: .endedAt),
      timeZoneIdentifier: container.decode(String.self, forKey: .timeZoneIdentifier),
      source: container.decode(CollectorSource.self, forKey: .source),
      display: container.decodeIfPresent(DisplayContext.self, forKey: .display),
      securityDisposition: container.decode(
        EventSecurityDisposition.self,
        forKey: .securityDisposition
      )
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case occurredAt
    case endedAt
    case timeZoneIdentifier
    case source
    case display
    case securityDisposition
  }
}

extension UInt8 {
  fileprivate var isASCIIAlphaNumeric: Bool {
    (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
  }
}
