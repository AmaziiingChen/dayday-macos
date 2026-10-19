import Foundation

/// Stable source-version markers for typed application-context facts.
///
/// The event kind remains `applicationContextChanged`; the source marker keeps
/// foreground-duration facts separate from richer window-context updates.
public enum ApplicationContextObservationVersion {
  public static let foregroundApplication = "foreground-application-v1"
  public static let windowContext = "0.1.0"
}

/// Latest admitted presentation label for one opaque application identity.
public struct ApplicationCatalogEntry: Codable, Equatable, Hashable, Sendable {
  public static let currentRecordVersion = 1

  public let identifier: ApplicationIdentifier
  public let displayLabel: String
  public let recordVersion: Int

  public init(
    identifier: ApplicationIdentifier, displayLabel: String,
    recordVersion: Int = currentRecordVersion
  ) throws {
    try ObjectiveLinkedRecordValidation.recordVersion(recordVersion)
    try ObjectiveLinkedRecordValidation.displayLabel(displayLabel)
    self.identifier = identifier
    self.displayLabel = displayLabel
    self.recordVersion = recordVersion
  }

  public init(from decoder: Decoder) throws {
    let values = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "ApplicationCatalogEntry",
      from: decoder
    )
    try self.init(
      identifier: values.decode(ApplicationIdentifier.self, forKey: .identifier),
      displayLabel: values.decode(String.self, forKey: .displayLabel),
      recordVersion: values.decode(Int.self, forKey: .recordVersion)
    )
  }
}

/// Immutable historical window context linked to one application-context event.
public struct ApplicationContextRecord: Codable, Equatable, Hashable, Sendable {
  public static let currentRecordVersion = 1

  public let eventID: EventID
  public let applicationIdentifier: ApplicationIdentifier
  public let displayLabelSnapshot: String
  public let windowTitleSnapshot: String?
  public let documentFilenameHint: String?
  public let recordVersion: Int

  public init(
    eventID: EventID,
    applicationIdentifier: ApplicationIdentifier,
    displayLabelSnapshot: String,
    windowTitleSnapshot: String? = nil,
    documentFilenameHint: String? = nil,
    recordVersion: Int = currentRecordVersion
  ) throws {
    try ObjectiveLinkedRecordValidation.recordVersion(recordVersion)
    try ObjectiveLinkedRecordValidation.displayLabel(displayLabelSnapshot)
    if let windowTitleSnapshot {
      try ObjectiveLinkedRecordValidation.windowTitle(windowTitleSnapshot)
    }
    if let documentFilenameHint {
      try ObjectiveLinkedRecordValidation.filenameHint(documentFilenameHint)
    }
    self.eventID = eventID
    self.applicationIdentifier = applicationIdentifier
    self.displayLabelSnapshot = displayLabelSnapshot
    self.windowTitleSnapshot = windowTitleSnapshot
    self.documentFilenameHint = documentFilenameHint
    self.recordVersion = recordVersion
  }

  public init(from decoder: Decoder) throws {
    let values = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "ApplicationContextRecord",
      from: decoder
    )
    try self.init(
      eventID: values.decode(EventID.self, forKey: .eventID),
      applicationIdentifier: values.decode(
        ApplicationIdentifier.self, forKey: .applicationIdentifier),
      displayLabelSnapshot: values.decode(String.self, forKey: .displayLabelSnapshot),
      windowTitleSnapshot: values.decodeIfPresent(String.self, forKey: .windowTitleSnapshot),
      documentFilenameHint: values.decodeIfPresent(String.self, forKey: .documentFilenameHint),
      recordVersion: values.decode(Int.self, forKey: .recordVersion)
    )
  }
}

/// Immutable, typed collector-state projection linked to one transition event.
public struct CollectorStateRecord: Codable, Equatable, Hashable, Sendable {
  public static let currentRecordVersion = 1

  public let eventID: EventID
  public let state: CollectorState
  public let recordVersion: Int

  public init(eventID: EventID, state: CollectorState, recordVersion: Int = currentRecordVersion)
    throws
  {
    try ObjectiveLinkedRecordValidation.recordVersion(recordVersion)
    self.eventID = eventID
    self.state = state
    self.recordVersion = recordVersion
  }

  public init(from decoder: Decoder) throws {
    let values = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "CollectorStateRecord",
      from: decoder
    )
    try self.init(
      eventID: values.decode(EventID.self, forKey: .eventID),
      state: values.decode(CollectorState.self, forKey: .state),
      recordVersion: values.decode(Int.self, forKey: .recordVersion)
    )
  }
}

/// Content-free durable proof that collection was suppressed for one event.
public struct CollectionSuppressionRecord: Codable, Equatable, Hashable, Sendable {
  public static let currentRecordVersion = 1

  public let eventID: EventID
  public let reason: CollectionSuppressionReason
  public let recordVersion: Int

  public init(
    eventID: EventID,
    reason: CollectionSuppressionReason,
    recordVersion: Int = currentRecordVersion
  ) throws {
    try ObjectiveLinkedRecordValidation.recordVersion(recordVersion)
    self.eventID = eventID
    self.reason = reason
    self.recordVersion = recordVersion
  }

  public init(from decoder: Decoder) throws {
    let values = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "CollectionSuppressionRecord",
      from: decoder
    )
    try self.init(
      eventID: values.decode(EventID.self, forKey: .eventID),
      reason: values.decode(CollectionSuppressionReason.self, forKey: .reason),
      recordVersion: values.decode(Int.self, forKey: .recordVersion)
    )
  }
}

/// Closed atomic write request; it proves the linked event's identity and kind.
public struct ApplicationContextWrite: Equatable, Hashable, Sendable {
  public let event: ObjectiveEvent
  public let record: ApplicationContextRecord

  public init(event: ObjectiveEvent, record: ApplicationContextRecord) throws {
    guard event.kind == .applicationContextChanged,
      event.id == record.eventID,
      event.source.collector == .applicationWindowContext,
      event.securityDisposition == .allowed
    else {
      throw ObjectiveLinkedRecordValidationError.eventLinkMismatch
    }
    self.event = event
    self.record = record
  }
}

/// Closed atomic write request; it proves the linked event's identity and kind.
public struct CollectorStateWrite: Equatable, Hashable, Sendable {
  public let event: ObjectiveEvent
  public let record: CollectorStateRecord

  public init(event: ObjectiveEvent, record: CollectorStateRecord) throws {
    guard event.kind == .collectorStateTransition,
      event.id == record.eventID,
      event.source.collector == record.state.kind
    else {
      throw ObjectiveLinkedRecordValidationError.eventLinkMismatch
    }
    self.event = event
    self.record = record
  }
}

/// Closed atomic write request for a content-free suppression observation.
public struct CollectionSuppressionWrite: Equatable, Hashable, Sendable {
  public let event: ObjectiveEvent
  public let record: CollectionSuppressionRecord

  public init(event: ObjectiveEvent, record: CollectionSuppressionRecord) throws {
    guard event.id == record.eventID,
      event.kind == .applicationContextChanged,
      event.source.collector == .applicationWindowContext,
      Self.reason(from: event.securityDisposition) == record.reason
    else {
      throw ObjectiveLinkedRecordValidationError.eventLinkMismatch
    }
    self.event = event
    self.record = record
  }

  private static func reason(
    from disposition: EventSecurityDisposition
  ) -> CollectionSuppressionReason? {
    switch disposition {
    case .allowed:
      return nil
    case .metadataOnly(let reason), .excluded(let reason):
      return reason
    }
  }
}

/// Specialized future storage boundary for all-or-nothing event/projection writes.
/// `.alreadyPresent` is valid only when both the complete event and complete
/// linked record exactly match. Implementations must reject event-only,
/// record-only, or mismatched-projection states as conflicts.
public protocol ObjectiveLinkedRecordRepository: ObjectiveEventRepository {
  func insertApplicationContext(_ write: ApplicationContextWrite) async throws
    -> ObjectiveEventInsertResult
  func insertCollectorState(_ write: CollectorStateWrite) async throws -> ObjectiveEventInsertResult
  func insertCollectionSuppression(_ write: CollectionSuppressionWrite) async throws
    -> ObjectiveEventInsertResult
  func fetchApplicationContext(for eventID: EventID) async throws -> ApplicationContextRecord?
  func fetchCollectorState(for eventID: EventID) async throws -> CollectorStateRecord?
  func fetchCollectionSuppression(for eventID: EventID) async throws
    -> CollectionSuppressionRecord?
}

/// Optional read optimization for consumers that need a complete day of application projections.
/// The scalar protocol remains the compatibility baseline for small or test repositories.
public protocol ObjectiveApplicationContextBatchFetching: Sendable {
  func fetchApplicationContexts(for eventIDs: [EventID]) async throws
    -> [EventID: ApplicationContextRecord]
}

public enum ObjectiveLinkedRecordValidationError: Error, Equatable, Sendable {
  case unsupportedRecordVersion(Int)
  case invalidText
  case textTooLong
  case unsafeFilenameHint
  case eventLinkMismatch
}

private enum ObjectiveLinkedRecordValidation {
  static func recordVersion(_ value: Int) throws {
    guard value == 1 else {
      throw ObjectiveLinkedRecordValidationError.unsupportedRecordVersion(value)
    }
  }

  static func displayLabel(_ value: String) throws { try text(value, maximumUTF8Bytes: 96) }
  static func windowTitle(_ value: String) throws { try text(value, maximumUTF8Bytes: 256) }

  static func filenameHint(_ value: String) throws {
    try text(value, maximumUTF8Bytes: 128)
    guard !value.contains("/"), !value.contains("\\"), !value.contains(":"),
      !value.contains("?"), !value.contains("#"), !value.contains("%"),
      !value.contains("..")
    else { throw ObjectiveLinkedRecordValidationError.unsafeFilenameHint }
  }

  static func text(_ value: String, maximumUTF8Bytes: Int) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else {
      throw ObjectiveLinkedRecordValidationError.invalidText
    }
    guard value.utf8.count <= maximumUTF8Bytes else {
      throw ObjectiveLinkedRecordValidationError.textTooLong
    }
  }
}
