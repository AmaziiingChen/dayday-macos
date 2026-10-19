import DaydayCore
import Foundation
import Testing

struct ObjectiveLinkedRecordsTests {
  @Test
  func applicationRecordsEnforceAdmittedUTF8BoundsAndSafeFilenameHints() throws {
    let id = ApplicationIdentifier(
      rawValue: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!)
    _ = try ApplicationCatalogEntry(identifier: id, displayLabel: String(repeating: "a", count: 96))
    _ = try ApplicationContextRecord(
      eventID: EventID(), applicationIdentifier: id, displayLabelSnapshot: "Editor",
      windowTitleSnapshot: String(repeating: "é", count: 128), documentFilenameHint: "notes.txt")

    #expect(throws: ObjectiveLinkedRecordValidationError.textTooLong) {
      _ = try ApplicationCatalogEntry(
        identifier: id, displayLabel: String(repeating: "a", count: 97))
    }
    #expect(throws: ObjectiveLinkedRecordValidationError.invalidText) {
      _ = try ApplicationContextRecord(
        eventID: EventID(), applicationIdentifier: id, displayLabelSnapshot: "Editor\n")
    }
    #expect(throws: ObjectiveLinkedRecordValidationError.invalidText) {
      _ = try ApplicationCatalogEntry(identifier: id, displayLabel: "\u{00A0}\u{2003}")
    }
    #expect(throws: ObjectiveLinkedRecordValidationError.unsafeFilenameHint) {
      _ = try ApplicationContextRecord(
        eventID: EventID(), applicationIdentifier: id, displayLabelSnapshot: "Editor",
        documentFilenameHint: "file:///private/a")
    }
    #expect(throws: ObjectiveLinkedRecordValidationError.unsafeFilenameHint) {
      _ = try ApplicationContextRecord(
        eventID: EventID(), applicationIdentifier: id, displayLabelSnapshot: "Editor",
        documentFilenameHint: "draft:final.txt")
    }
  }

  @Test
  func recordsRoundTripWithoutRawIdentityOrPathFields() throws {
    let id = ApplicationIdentifier(
      rawValue: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!)
    let record = try ApplicationContextRecord(
      eventID: EventID(), applicationIdentifier: id, displayLabelSnapshot: "Editor",
      windowTitleSnapshot: "Draft", documentFilenameHint: "draft.md")
    let data = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(ApplicationContextRecord.self, from: data) == record)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("bundle"))
    #expect(!text.contains("path"))
    #expect(!text.contains("url"))

    let suppression = try CollectionSuppressionRecord(
      eventID: EventID(), reason: .userExclusion)
    let suppressionData = try JSONEncoder().encode(suppression)
    #expect(
      try JSONDecoder().decode(CollectionSuppressionRecord.self, from: suppressionData)
        == suppression)
    let suppressionText = try #require(String(data: suppressionData, encoding: .utf8))
    for forbidden in ["content", "source", "platform", "payload", "path", "url"] {
      #expect(!suppressionText.localizedCaseInsensitiveContains(forbidden))
    }
  }

  @Test
  func atomicWriteRequestsRequireExactEventLinkAndKind() throws {
    let identifier = ApplicationIdentifier(rawValue: UUID())
    let applicationEvent = try event(kind: .applicationContextChanged)
    let context = try ApplicationContextRecord(
      eventID: applicationEvent.id, applicationIdentifier: identifier,
      displayLabelSnapshot: "Editor")
    _ = try ApplicationContextWrite(event: applicationEvent, record: context)
    let wrongKind = try event(kind: .collectorStateTransition)
    #expect(throws: ObjectiveLinkedRecordValidationError.eventLinkMismatch) {
      _ = try ApplicationContextWrite(event: wrongKind, record: context)
    }
    let wrongApplicationSource = try event(
      kind: .applicationContextChanged, collector: .screenUnderstanding)
    #expect(throws: ObjectiveLinkedRecordValidationError.eventLinkMismatch) {
      _ = try ApplicationContextWrite(
        event: wrongApplicationSource,
        record: try ApplicationContextRecord(
          eventID: wrongApplicationSource.id,
          applicationIdentifier: identifier,
          displayLabelSnapshot: "Editor"))
    }
    let suppressedApplicationEvent = try event(
      kind: .applicationContextChanged,
      securityDisposition: .metadataOnly(.secureInput))
    #expect(throws: ObjectiveLinkedRecordValidationError.eventLinkMismatch) {
      _ = try ApplicationContextWrite(
        event: suppressedApplicationEvent,
        record: try ApplicationContextRecord(
          eventID: suppressedApplicationEvent.id,
          applicationIdentifier: identifier,
          displayLabelSnapshot: "Editor"))
    }

    let state = CollectorState(kind: .weather)
    let collectorEvent = try event(kind: .collectorStateTransition, collector: .weather)
    let stateRecord = try CollectorStateRecord(eventID: collectorEvent.id, state: state)
    _ = try CollectorStateWrite(event: collectorEvent, record: stateRecord)
    #expect(throws: ObjectiveLinkedRecordValidationError.eventLinkMismatch) {
      _ = try CollectorStateWrite(event: applicationEvent, record: stateRecord)
    }
    let wrongCollectorSource = try event(
      kind: .collectorStateTransition, collector: .screenUnderstanding)
    #expect(throws: ObjectiveLinkedRecordValidationError.eventLinkMismatch) {
      _ = try CollectorStateWrite(
        event: wrongCollectorSource,
        record: try CollectorStateRecord(eventID: wrongCollectorSource.id, state: state))
    }
  }

  @Test
  func suppressionWritesRequireExactReasonAndClosedEventAdmission() throws {
    let eventID = EventID()
    let metadataEvent = try event(
      id: eventID,
      kind: .applicationContextChanged,
      collector: .applicationWindowContext,
      securityDisposition: .metadataOnly(.secureInput))
    let record = try CollectionSuppressionRecord(eventID: eventID, reason: .secureInput)
    _ = try CollectionSuppressionWrite(event: metadataEvent, record: record)

    let excludedEvent = try event(
      kind: .applicationContextChanged,
      collector: .applicationWindowContext,
      securityDisposition: .excluded(.userExclusion))
    _ = try CollectionSuppressionWrite(
      event: excludedEvent,
      record: try CollectionSuppressionRecord(
        eventID: excludedEvent.id, reason: .userExclusion))

    var invalidWrites = [
      (
        try event(
          id: eventID,
          kind: .applicationContextChanged,
          collector: .applicationWindowContext),
        record
      ),
      (
        metadataEvent,
        try CollectionSuppressionRecord(eventID: EventID(), reason: .secureInput)
      ),
      (
        metadataEvent,
        try CollectionSuppressionRecord(eventID: eventID, reason: .incognito)
      ),
      (
        try event(
          id: eventID,
          kind: .applicationContextChanged,
          collector: .screenUnderstanding,
          securityDisposition: .metadataOnly(.secureInput)),
        record
      ),
    ]
    invalidWrites.append(
      contentsOf: try ObjectiveEventKind.allCases
        .filter { $0 != .applicationContextChanged }
        .map { kind in
          (
            try event(
              id: eventID,
              kind: kind,
              collector: .applicationWindowContext,
              securityDisposition: .metadataOnly(.secureInput)),
            record
          )
        })
    for (event, invalidRecord) in invalidWrites {
      #expect(throws: ObjectiveLinkedRecordValidationError.eventLinkMismatch) {
        _ = try CollectionSuppressionWrite(event: event, record: invalidRecord)
      }
    }
  }

  @Test
  func unsupportedRecordVersionsFailDuringConstructionAndDecoding() throws {
    let id = ApplicationIdentifier(rawValue: UUID())
    #expect(throws: ObjectiveLinkedRecordValidationError.unsupportedRecordVersion(2)) {
      _ = try ApplicationCatalogEntry(identifier: id, displayLabel: "Editor", recordVersion: 2)
    }
    let data = Data(
      #"{"identifier":"01234567-89AB-CDEF-0123-456789ABCDEF","displayLabel":"Editor","recordVersion":2}"#
        .utf8)
    #expect(throws: ObjectiveLinkedRecordValidationError.unsupportedRecordVersion(2)) {
      _ = try JSONDecoder().decode(ApplicationCatalogEntry.self, from: data)
    }
    #expect(throws: ObjectiveLinkedRecordValidationError.unsupportedRecordVersion(2)) {
      _ = try CollectionSuppressionRecord(
        eventID: EventID(), reason: .uncertainSafetyState, recordVersion: 2)
    }
  }

  @Test
  func closedObjectiveRecordDecodingRejectsUnknownKeys() throws {
    let identifier = ApplicationIdentifier(rawValue: UUID())
    let catalog = try ApplicationCatalogEntry(identifier: identifier, displayLabel: "Editor")
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        ApplicationCatalogEntry.self,
        from: try encodedAddingUnknownKey(to: catalog, key: "bundleIdentifier")
      )
    }

    let context = try ApplicationContextRecord(
      eventID: EventID(), applicationIdentifier: identifier, displayLabelSnapshot: "Editor")
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        ApplicationContextRecord.self,
        from: try encodedAddingUnknownKey(to: context, key: "path")
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        ApplicationContextRecord.self,
        from: try encodedAddingUnknownKey(to: context, key: "payload", at: ["eventID"])
      )
    }

    let state = try CollectorStateRecord(eventID: EventID(), state: CollectorState(kind: .weather))
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        CollectorStateRecord.self,
        from: try encodedAddingUnknownKey(to: state, key: "payload")
      )
    }

    let suppression = try CollectionSuppressionRecord(
      eventID: EventID(), reason: .mandatoryExclusion)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        CollectionSuppressionRecord.self,
        from: try encodedAddingUnknownKey(to: suppression, key: "content")
      )
    }
  }

  private func encodedAddingUnknownKey<Value: Encodable>(
    to value: Value,
    key: String,
    at path: [String] = []
  ) throws -> Data {
    let encoded = try JSONEncoder().encode(value)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    try addUnknownKey(key, at: path[...], to: &object)
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func addUnknownKey(
    _ key: String,
    at path: ArraySlice<String>,
    to object: inout [String: Any]
  ) throws {
    guard let component = path.first else {
      object[key] = true
      return
    }
    var nested = try #require(object[component] as? [String: Any])
    try addUnknownKey(key, at: path.dropFirst(), to: &nested)
    object[component] = nested
  }

  private func event(
    id: EventID = EventID(),
    kind: ObjectiveEventKind,
    collector: CollectorKind = .applicationWindowContext,
    securityDisposition: EventSecurityDisposition = .allowed
  ) throws -> ObjectiveEvent {
    try ObjectiveEvent(
      id: id,
      kind: kind,
      occurredAt: Date(timeIntervalSince1970: 100),
      timeZoneIdentifier: "UTC",
      source: try CollectorSource(
        collector: collector, collectorVersion: "1", payloadSchemaVersion: 1),
      securityDisposition: securityDisposition
    )
  }
}
