import Foundation

/// The closed durable representation version for one privacy-admitted evidence frame.
public enum EvidenceFrameVersion: UInt8, Codable, CaseIterable, Hashable, Sendable {
  case v1 = 1
}

/// The only derivative shape H2 may retain in this contract.
///
/// Storage locates a derivative by `EvidenceFrameID`; this value deliberately carries no
/// bytes, file location, or encoding-quality setting.
public enum EvidenceDerivativeKind: String, Codable, CaseIterable, Hashable, Sendable {
  case redactedCompressedImage
}

/// Closed objective provenance for one selected evidence frame.
public struct EvidenceObjectiveSource: Codable, Equatable, Hashable, Sendable {
  public let stableStateObservationEventID: EventID
  public let displayID: DisplayID
  public let applicationIdentifier: ApplicationIdentifier

  public init(
    stableStateObservationEventID: EventID,
    displayID: DisplayID,
    applicationIdentifier: ApplicationIdentifier
  ) {
    self.stableStateObservationEventID = stableStateObservationEventID
    self.displayID = displayID
    self.applicationIdentifier = applicationIdentifier
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "EvidenceObjectiveSource",
      from: decoder
    )
    self.init(
      stableStateObservationEventID: try container.decode(
        EventID.self, forKey: .stableStateObservationEventID),
      displayID: try container.decode(DisplayID.self, forKey: .displayID),
      applicationIdentifier: try container.decode(
        ApplicationIdentifier.self, forKey: .applicationIdentifier)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case stableStateObservationEventID
    case displayID
    case applicationIdentifier
  }
}

/// A persisted redacted derivative, addressed only by its existing opaque identifier.
public struct EvidenceFrame: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidObservedAt
  }

  public let id: EvidenceFrameID
  public let version: EvidenceFrameVersion
  public let derivativeKind: EvidenceDerivativeKind
  public let observedAt: Date
  public let source: EvidenceObjectiveSource

  public init(
    id: EvidenceFrameID,
    version: EvidenceFrameVersion = .v1,
    derivativeKind: EvidenceDerivativeKind = .redactedCompressedImage,
    observedAt: Date,
    source: EvidenceObjectiveSource
  ) throws {
    guard observedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.invalidObservedAt
    }

    self.id = id
    self.version = version
    self.derivativeKind = derivativeKind
    self.observedAt = observedAt
    self.source = source
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "EvidenceFrame",
      from: decoder
    )
    try self.init(
      id: container.decode(EvidenceFrameID.self, forKey: .id),
      version: container.decode(EvidenceFrameVersion.self, forKey: .version),
      derivativeKind: container.decode(EvidenceDerivativeKind.self, forKey: .derivativeKind),
      observedAt: container.decode(Date.self, forKey: .observedAt),
      source: container.decode(EvidenceObjectiveSource.self, forKey: .source)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case version
    case derivativeKind
    case observedAt
    case source
  }
}

/// A bounded, redaction-passed OCR line. It is not a raw Vision response.
public struct RedactedOCRLine: Codable, Equatable, Hashable, Sendable {
  /// A defensive serialization ceiling, not an OCR selection or retention product default.
  public static let maximumUTF8Length = 512

  public enum ValidationError: Error, Equatable, Sendable {
    case empty
    case exceedsMaximumUTF8Length(Int)
    case containsControlCharacter
  }

  public let value: String

  public init(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.empty
    }
    guard value.utf8.count <= Self.maximumUTF8Length else {
      throw ValidationError.exceedsMaximumUTF8Length(value.utf8.count)
    }
    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw ValidationError.containsControlCharacter
    }

    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

/// The closed durable representation version for a bounded OCR child artifact.
public enum OCRArtifactVersion: UInt8, Codable, CaseIterable, Hashable, Sendable {
  case v1 = 1
}

/// Bounded redaction-passed OCR owned by exactly one evidence frame.
public struct OCRArtifact: Codable, Equatable, Hashable, Sendable {
  /// A defensive serialization ceiling, not an OCR selection or retention product default.
  public static let maximumLineCount = 64

  public enum ValidationError: Error, Equatable, Sendable {
    case emptyLines
    case exceedsMaximumLineCount(Int)
  }

  public let version: OCRArtifactVersion
  public let evidenceFrameID: EvidenceFrameID
  public let lines: [RedactedOCRLine]

  public init(
    version: OCRArtifactVersion = .v1,
    evidenceFrameID: EvidenceFrameID,
    lines: [RedactedOCRLine]
  ) throws {
    guard !lines.isEmpty else {
      throw ValidationError.emptyLines
    }
    guard lines.count <= Self.maximumLineCount else {
      throw ValidationError.exceedsMaximumLineCount(lines.count)
    }

    self.version = version
    self.evidenceFrameID = evidenceFrameID
    self.lines = lines
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "OCRArtifact",
      from: decoder
    )
    try self.init(
      version: container.decode(OCRArtifactVersion.self, forKey: .version),
      evidenceFrameID: container.decode(EvidenceFrameID.self, forKey: .evidenceFrameID),
      lines: container.decode([RedactedOCRLine].self, forKey: .lines)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case evidenceFrameID
    case lines
  }
}
