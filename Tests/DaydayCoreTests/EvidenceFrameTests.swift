import Foundation
import Testing

@testable import DaydayCore

struct EvidenceFrameTests {
  @Test
  func selectedEvidenceRoundTripsWithClosedObjectiveProvenance() throws {
    let selection = try makeSelection()

    let encoded = try JSONEncoder().encode(selection)
    let decoded = try JSONDecoder().decode(AtomicSelectedEvidence.self, from: encoded)

    #expect(decoded == selection)
    #expect(decoded.evidenceFrame.source.stableStateObservationEventID == decoded.event.id)
    #expect(decoded.ocrArtifact?.evidenceFrameID == decoded.evidenceFrame.id)
  }

  @Test
  func closedEvidenceValuesAreEquatableAndSendable() throws {
    let selection = try makeSelection()

    assertSendable(EvidenceFrame.self)
    assertSendable(OCRArtifact.self)
    assertSendable(AtomicSelectedEvidence.self)
    #expect(selection == selection)
  }

  @Test
  func invalidTemporalTextAndCollectionBoundsAreRejected() throws {
    let source = try makeEvidenceSource()
    #expect(throws: EvidenceFrame.ValidationError.invalidObservedAt) {
      try EvidenceFrame(
        id: EvidenceFrameID(),
        observedAt: Date(timeIntervalSinceReferenceDate: .infinity),
        source: source
      )
    }
    #expect(throws: RedactedOCRLine.ValidationError.empty) {
      try RedactedOCRLine(" \n ")
    }
    #expect(throws: RedactedOCRLine.ValidationError.containsControlCharacter) {
      try RedactedOCRLine("line\u{0000}")
    }
    #expect(throws: RedactedOCRLine.ValidationError.exceedsMaximumUTF8Length(513)) {
      try RedactedOCRLine(String(repeating: "a", count: 513))
    }

    let line = try RedactedOCRLine("redacted text")
    #expect(throws: OCRArtifact.ValidationError.emptyLines) {
      try OCRArtifact(evidenceFrameID: EvidenceFrameID(), lines: [])
    }
    #expect(throws: OCRArtifact.ValidationError.exceedsMaximumLineCount(65)) {
      try OCRArtifact(
        evidenceFrameID: EvidenceFrameID(),
        lines: Array(repeating: line, count: 65)
      )
    }
  }

  @Test
  func eventEvidenceAndOCRLinksMustMatchExactly() throws {
    let selection = try makeSelection()
    let alternateEvent = try makeEvent(id: EventID(), observedAt: selection.event.occurredAt)
    #expect(throws: AtomicSelectedEvidence.ValidationError.eventEvidenceLinkMismatch) {
      try AtomicSelectedEvidence(event: alternateEvent, evidenceFrame: selection.evidenceFrame)
    }

    let alternateOCR = try OCRArtifact(
      evidenceFrameID: EvidenceFrameID(),
      lines: [RedactedOCRLine("redacted text")]
    )
    #expect(throws: AtomicSelectedEvidence.ValidationError.ocrEvidenceLinkMismatch) {
      try AtomicSelectedEvidence(
        event: selection.event,
        evidenceFrame: selection.evidenceFrame,
        ocrArtifact: alternateOCR
      )
    }

    let wrongKind = try ObjectiveEvent(
      id: selection.event.id,
      kind: .applicationContextChanged,
      occurredAt: selection.event.occurredAt,
      timeZoneIdentifier: "UTC",
      source: selection.event.source,
      display: selection.event.display,
      securityDisposition: .allowed
    )
    #expect(throws: AtomicSelectedEvidence.ValidationError.eventIsNotStableStateObservation) {
      try AtomicSelectedEvidence(event: wrongKind, evidenceFrame: selection.evidenceFrame)
    }

    let wrongCollector = try makeEvent(
      id: selection.event.id,
      observedAt: selection.event.occurredAt,
      collector: .weather
    )
    #expect(throws: AtomicSelectedEvidence.ValidationError.eventSourceIsNotScreenUnderstanding) {
      try AtomicSelectedEvidence(event: wrongCollector, evidenceFrame: selection.evidenceFrame)
    }
  }

  @Test
  func serializedEvidenceHasNoRawMediaOrGenericPayloadFields() throws {
    let encoded = try JSONEncoder().encode(makeSelection())
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let frame = try #require(object["evidenceFrame"] as? [String: Any])

    #expect(frame["pixels"] == nil)
    #expect(frame["data"] == nil)
    #expect(frame["fileURL"] == nil)
    #expect(frame["path"] == nil)
    #expect(frame["metadata"] == nil)
    #expect(frame["payload"] == nil)
    #expect(object["vision"] == nil)
  }

  @Test
  func closedEvidenceDecodingRejectsUnknownOuterAndNestedKeys() throws {
    let selection = try makeSelection()

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(to: selection, key: "payload")
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(to: selection, key: "pixels", at: ["evidenceFrame"])
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(
          to: selection,
          key: "fileURL",
          at: ["evidenceFrame", "source"]
        )
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(to: selection, key: "path", at: ["ocrArtifact"])
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(
          to: selection,
          key: "payload",
          at: ["evidenceFrame", "source", "stableStateObservationEventID"]
        )
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(
          to: selection,
          key: "path",
          at: ["evidenceFrame", "source", "displayID"]
        )
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(to: selection, key: "payload", at: ["event"])
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(to: selection, key: "payload", at: ["event", "source"])
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(to: selection, key: "path", at: ["event", "display"])
      )
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AtomicSelectedEvidence.self,
        from: try encodedAddingUnknownKey(
          to: selection,
          key: "payload",
          at: ["event", "securityDisposition"]
        )
      )
    }
  }

  private func makeSelection() throws -> AtomicSelectedEvidence {
    let eventID = EventID(
      rawValue: try #require(
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
      ))
    let evidenceID = EvidenceFrameID(
      rawValue: try #require(
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")
      ))
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let event = try makeEvent(id: eventID, observedAt: observedAt)
    let frame = try EvidenceFrame(
      id: evidenceID,
      observedAt: observedAt,
      source: try makeEvidenceSource(eventID: eventID)
    )
    let artifact = try OCRArtifact(
      evidenceFrameID: evidenceID,
      lines: [RedactedOCRLine("redacted text")]
    )
    return try AtomicSelectedEvidence(event: event, evidenceFrame: frame, ocrArtifact: artifact)
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

  private func makeEvidenceSource(eventID: EventID = EventID()) throws -> EvidenceObjectiveSource {
    EvidenceObjectiveSource(
      stableStateObservationEventID: eventID,
      displayID: DisplayID(
        rawValue: try #require(
          UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")
        )),
      applicationIdentifier: ApplicationIdentifier(
        rawValue: try #require(
          UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")
        ))
    )
  }

  private func makeEvent(
    id: EventID,
    observedAt: Date,
    collector: CollectorKind = .screenUnderstanding
  ) throws -> ObjectiveEvent {
    let source = try CollectorSource(
      collector: collector,
      collectorVersion: "0.1.0",
      payloadSchemaVersion: 1
    )
    return try ObjectiveEvent(
      id: id,
      kind: .stableStateObservation,
      occurredAt: observedAt,
      timeZoneIdentifier: "UTC",
      source: source,
      display: DisplayContext(
        id: DisplayID(
          rawValue: try #require(
            UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")
          )),
        topologyRevision: 1
      ),
      securityDisposition: .allowed
    )
  }

  private func assertSendable<Value: Sendable>(_ type: Value.Type) {}
}
