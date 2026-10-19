import Foundation
import Testing

@testable import DaydayCore

struct SessionTests {
  @Test
  func derivationBatchRequiresOneNonemptyRevisionAndUniqueSessionIDs() throws {
    let session = try makeSession()
    let day = try DayDescriptor(
      logicalDate: .init(year: 2027, month: 1, day: 15), timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: Date(timeIntervalSince1970: 1_799_985_600), endsAt: Date(timeIntervalSince1970: 1_800_072_000))
    )
    #expect(throws: SessionDerivationBatch.ValidationError.empty) {
      try SessionDerivationBatch(day: day, derivationRevision: 1, sessions: [])
    }
    #expect(throws: SessionDerivationBatch.ValidationError.duplicateID(session.id)) {
      try SessionDerivationBatch(day: day, derivationRevision: 1, sessions: [session, session])
    }
  }
  @Test
  func sessionRoundTripsOneDisplayOrderedFactsAndImmutableLineage() throws {
    let session = try makeSession(
      endingHardBoundary: .displayDisconnected,
      lineage: try SessionLineage(derivationRevision: 2, supersedesSessionID: SessionID())
    )

    let encoded = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(Session.self, from: encoded)

    assertSendable(SessionID.self)
    assertSendable(Session.self)
    #expect(decoded == session)
    #expect(decoded.displayID == session.displayID)
    #expect(decoded.objectiveEventIDs == session.objectiveEventIDs)
    #expect(decoded.endingHardBoundary == .displayDisconnected)
    #expect(decoded.lineage.supersedesSessionID != nil)
  }

  @Test
  func workspaceSessionV2RoundTripsWithoutFabricatedDisplay() throws {
    let baseline = try makeSession()
    let session = try Session(
      id: SessionID(), scope: .workspace,
      startedAt: baseline.startedAt, endedAt: baseline.endedAt,
      objectiveEventIDs: baseline.objectiveEventIDs)

    let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))

    #expect(decoded.version == .v2)
    #expect(decoded.scope == .workspace)
    #expect(decoded.displayID == nil)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
    #expect(object["displayID"] == nil)
    #expect(object["scope"] != nil)
  }

  @Test
  func intervalMembershipAndLineageInvariantsAreFailClosed() throws {
    let session = try makeSession()
    let eventID = try #require(session.objectiveEventIDs.first)
    #expect(throws: Session.ValidationError.invalidIntervalTimestamp) {
      try makeSession(startedAt: Date(timeIntervalSinceReferenceDate: .nan))
    }
    #expect(throws: Session.ValidationError.unorderedInterval) {
      try makeSession(startedAt: session.endedAt, endedAt: session.startedAt)
    }
    #expect(throws: Session.ValidationError.emptyObjectiveEventMembership) {
      try makeSession(objectiveEventIDs: [])
    }
    #expect(throws: Session.ValidationError.duplicateObjectiveEventMembership(eventID)) {
      try makeSession(objectiveEventIDs: [eventID, eventID])
    }
    #expect(throws: Session.ValidationError.exceedsMaximumObjectiveEventMembershipCount(4_097)) {
      try makeSession(objectiveEventIDs: Array(repeating: eventID, count: 4_097))
    }
    #expect(throws: SessionLineage.ValidationError.invalidDerivationRevision(0)) {
      try SessionLineage(derivationRevision: 0)
    }
    #expect(throws: Session.ValidationError.lineageCannotSupersedeSelf) {
      let id = SessionID()
      return try Session(
        id: id,
        displayID: DisplayID(),
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        objectiveEventIDs: [eventID],
        lineage: try SessionLineage(supersedesSessionID: id)
      )
    }
  }

  @Test
  func everyHardBoundaryReasonIsClosedAndExplicit() {
    #expect(
      SessionHardBoundaryReason.allCases == [
        .screenLocked,
        .systemSleep,
        .collectionPaused,
        .privacySuppressed,
        .authorizationLost,
        .userSessionLost,
        .displayDisconnected,
        .shutdown,
      ])
  }

  @Test
  func decodingRejectsForgedSessionInvariantsAndUnknownVersion() throws {
    let session = try makeSession()
    let encoded = try JSONEncoder().encode(session)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    object["objectiveEventIDs"] = []
    let emptyMembership = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: Session.ValidationError.emptyObjectiveEventMembership) {
      try JSONDecoder().decode(Session.self, from: emptyMembership)
    }

    object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["version"] = 99
    let unknownVersion = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Session.self, from: unknownVersion)
    }
  }

  @Test
  func decodingRejectsUnknownSessionAndLineageFields() throws {
    let encoded = try JSONEncoder().encode(makeSession())
    let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    for unknownKey in ["payload", "path", "media", "bundleIdentifier"] {
      var forged = original
      forged[unknownKey] = "adversarial"
      let data = try JSONSerialization.data(withJSONObject: forged)
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Session.self, from: data)
      }
    }

    var forgedLineage = original
    var lineage = try #require(forgedLineage["lineage"] as? [String: Any])
    lineage["payload"] = "adversarial"
    forgedLineage["lineage"] = lineage
    let lineageData = try JSONSerialization.data(withJSONObject: forgedLineage)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Session.self, from: lineageData)
    }
  }

  @Test
  func decodingRejectsUnknownNestedIdentifierFields() throws {
    let encoded = try JSONEncoder().encode(makeSession())
    let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    for (field, unknownKey) in [("id", "payload"), ("displayID", "path")] {
      var forged = original
      var identifier = try #require(forged[field] as? [String: Any])
      identifier[unknownKey] = "adversarial"
      forged[field] = identifier
      let data = try JSONSerialization.data(withJSONObject: forged)
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Session.self, from: data)
      }
    }

    var forgedEvent = original
    var eventIDs = try #require(forgedEvent["objectiveEventIDs"] as? [[String: Any]])
    eventIDs[0]["payload"] = "adversarial"
    forgedEvent["objectiveEventIDs"] = eventIDs
    let eventData = try JSONSerialization.data(withJSONObject: forgedEvent)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Session.self, from: eventData)
    }
  }

  @Test
  func serializedSessionHasNoEvidenceMediaOrGenericPayloadFields() throws {
    let encoded = try JSONEncoder().encode(makeSession())
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(object["evidenceFrameIDs"] == nil)
    #expect(object["pixels"] == nil)
    #expect(object["data"] == nil)
    #expect(object["fileURL"] == nil)
    #expect(object["metadata"] == nil)
    #expect(object["payload"] == nil)
  }

  private func makeSession(
    startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    endedAt: Date = Date(timeIntervalSince1970: 1_800_000_300),
    endingHardBoundary: SessionHardBoundaryReason? = nil,
    objectiveEventIDs: [EventID]? = nil,
    lineage: SessionLineage? = nil
  ) throws -> Session {
    try Session(
      id: SessionID(
        rawValue: try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
      ),
      displayID: DisplayID(
        rawValue: try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
      ),
      startedAt: startedAt,
      endedAt: endedAt,
      endingHardBoundary: endingHardBoundary,
      objectiveEventIDs: objectiveEventIDs ?? [
        EventID(rawValue: try #require(UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA"))),
        EventID(rawValue: try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"))),
      ],
      lineage: lineage
    )
  }

  private func assertSendable<Value: Sendable>(_ type: Value.Type) {}
}
