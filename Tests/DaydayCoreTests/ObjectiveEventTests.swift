import Foundation
import Testing

@testable import DaydayCore

struct ObjectiveEventTests {
  @Test
  func envelopeRoundTripsOnlySafeObjectiveMetadata() throws {
    let eventID = EventID(
      rawValue: try #require(
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
      ))
    let displayID = DisplayID(
      rawValue: try #require(
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")
      ))
    let source = try CollectorSource(
      collector: .screenUnderstanding,
      collectorVersion: "0.1.0",
      payloadSchemaVersion: 1
    )
    let event = try ObjectiveEvent(
      id: eventID,
      kind: .stableStateObservation,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
      timeZoneIdentifier: "Asia/Shanghai",
      source: source,
      display: DisplayContext(id: displayID, topologyRevision: 7),
      securityDisposition: .allowed
    )

    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(ObjectiveEvent.self, from: data)
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(decoded == event)
    #expect(json["dayID"] == nil)
    #expect(json["ocr"] == nil)
    #expect(json["keystrokes"] == nil)
    #expect(json["mouseEvents"] == nil)
    #expect(json["payload"] == nil)
  }

  @Test
  func suppressedEventStoresOnlyASafeReason() throws {
    let source = try CollectorSource(
      collector: .chromeContext,
      collectorVersion: "0.1.0",
      payloadSchemaVersion: 1
    )
    let event = try ObjectiveEvent(
      kind: .systemBoundary,
      occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
      timeZoneIdentifier: "UTC",
      source: source,
      securityDisposition: .excluded(.incognito)
    )

    #expect(event.securityDisposition == .excluded(.incognito))
    #expect(event.display == nil)
  }

  @Test
  func eventSecurityDispositionRoundTripsEveryClosedCase() throws {
    for (value, expectedJSON) in [
      (EventSecurityDisposition.allowed, #"{"allowed":{}}"#),
      (.metadataOnly(.secureInput), #"{"metadataOnly":{"_0":"secureInput"}}"#),
      (.excluded(.incognito), #"{"excluded":{"_0":"incognito"}}"#),
    ] {
      let data = try JSONEncoder().encode(value)
      #expect(try JSONDecoder().decode(EventSecurityDisposition.self, from: data) == value)
      #expect(String(decoding: data, as: UTF8.self) == expectedJSON)
    }
  }

  @Test
  func invalidTemporalAndSourceMetadataAreRejected() throws {
    #expect(throws: CollectorSource.ValidationError.emptyCollectorVersion) {
      try CollectorSource(
        collector: .weather,
        collectorVersion: "  ",
        payloadSchemaVersion: 1
      )
    }
    #expect(throws: CollectorSource.ValidationError.invalidCollectorVersionFormat) {
      try CollectorSource(
        collector: .weather,
        collectorVersion: "secret value must not fit here",
        payloadSchemaVersion: 1
      )
    }
    #expect(throws: CollectorSource.ValidationError.invalidCollectorVersionFormat) {
      try CollectorSource(
        collector: .weather,
        collectorVersion: String(repeating: "a", count: 65),
        payloadSchemaVersion: 1
      )
    }
    #expect(throws: CollectorSource.ValidationError.invalidPayloadSchemaVersion(0)) {
      try CollectorSource(
        collector: .weather,
        collectorVersion: "0.1.0",
        payloadSchemaVersion: 0
      )
    }

    let source = try CollectorSource(
      collector: .weather,
      collectorVersion: "0.1.0",
      payloadSchemaVersion: 1
    )
    let start = Date(timeIntervalSince1970: 100)
    #expect(throws: ObjectiveEvent.ValidationError.endBeforeStart) {
      try ObjectiveEvent(
        kind: .stableStateObservation,
        occurredAt: start,
        endedAt: start.addingTimeInterval(-1),
        timeZoneIdentifier: "UTC",
        source: source,
        securityDisposition: .allowed
      )
    }
    #expect(throws: ObjectiveEvent.ValidationError.invalidTimeZoneIdentifier("Mars/Olympus")) {
      try ObjectiveEvent(
        kind: .stableStateObservation,
        occurredAt: start,
        timeZoneIdentifier: "Mars/Olympus",
        source: source,
        securityDisposition: .allowed
      )
    }
    #expect(throws: ObjectiveEvent.ValidationError.invalidTimestamp) {
      try ObjectiveEvent(
        kind: .stableStateObservation,
        occurredAt: Date(timeIntervalSinceReferenceDate: .nan),
        timeZoneIdentifier: "UTC",
        source: source,
        securityDisposition: .allowed
      )
    }
    #expect(throws: ObjectiveEvent.ValidationError.invalidTimestamp) {
      try ObjectiveEvent(
        kind: .stableStateObservation,
        occurredAt: start,
        endedAt: Date(timeIntervalSinceReferenceDate: .infinity),
        timeZoneIdentifier: "UTC",
        source: source,
        securityDisposition: .allowed
      )
    }
  }
}
