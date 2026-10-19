import Foundation
import Testing

@testable import DaydayCore

struct ActivityTests {
  @Test func deterministicActivityBatchRejectsNonProvisionalMembers() throws {
    let activity = try makeActivity(
      evidenceReferences: [],
      confidence: .low,
      reviewState: .needsReview,
      interpretation: try ActivityInterpretation(
        origin: .deterministicRule, producerVersion: "rule-v1")
    )
    let day = try DayDescriptor(
      logicalDate: .init(year: 2027, month: 1, day: 15), timeZoneIdentifier: "UTC",
      boundary: .init(
        hour: 4, startsAt: Date(timeIntervalSince1970: 1_799_985_600),
        endsAt: Date(timeIntervalSince1970: 1_800_072_000))
    )
    #expect(
      try ActivityDerivationBatch(day: day, derivationRevision: 1, activities: [activity])
        .activities == [activity])
    let inferred = try makeActivity(
      interpretation: try ActivityInterpretation(
        origin: .modelInference, producerVersion: "model-v1", rationale: "review"))
    #expect(
      throws: ActivityDerivationBatch.ValidationError.notDeterministicProvisional(inferred.id)
    ) {
      try ActivityDerivationBatch(day: day, derivationRevision: 1, activities: [inferred])
    }
  }
  @Test func roundTripIsInferredReviewMetadataWithRebuildLineage() throws {
    let activity = try makeActivity(
      confidence: .high, reviewState: .needsReview,
      interpretation: try ActivityInterpretation(
        origin: .modelInference, producerVersion: "v1", rationale: "review"),
      lineage: try ActivityLineage(
        revision: 2, supersedesDeterministicRebuildActivityID: ActivityID()))
    #expect(
      try JSONDecoder().decode(Activity.self, from: JSONEncoder().encode(activity)) == activity)
    assertSendable(Activity.self)
    #expect(activity.reviewState == .needsReview)
  }

  @Test func validationRejectsIntervalsMembershipEvidenceAndText() throws {
    let activity = try makeActivity()
    let session = activity.sessionIDs[0]
    let evidence = activity.evidenceReferences[0]
    #expect(throws: Activity.ValidationError.unorderedInterval) {
      try makeActivity(startedAt: activity.endedAt, endedAt: activity.startedAt)
    }
    #expect(throws: Activity.ValidationError.invalidTimestamp) {
      try makeActivity(startedAt: Date(timeIntervalSinceReferenceDate: .nan))
    }
    #expect(throws: Activity.ValidationError.invalidTimestamp) {
      try makeActivity(endedAt: Date(timeIntervalSinceReferenceDate: .infinity))
    }
    #expect(throws: Activity.ValidationError.emptySessionMembership) {
      try makeActivity(sessionIDs: [])
    }
    #expect(throws: Activity.ValidationError.duplicateSessionID(session)) {
      try makeActivity(sessionIDs: [session, session])
    }
    #expect(throws: Activity.ValidationError.tooManySessions(4_097)) {
      try makeActivity(sessionIDs: Array(repeating: SessionID(), count: 4_097))
    }
    #expect(throws: Activity.ValidationError.duplicateEvidenceFrameID(evidence.evidenceFrameID)) {
      try makeActivity(evidenceReferences: [evidence, evidence])
    }
    #expect(throws: Activity.ValidationError.tooManyEvidenceReferences(4_097)) {
      try makeActivity(
        evidenceReferences: (0..<4_097).map { _ in
          ActivityEvidenceReference(
            role: .supporting, evidenceFrameID: EvidenceFrameID(),
            stableStateObservationEventID: EventID())
        })
    }
    #expect(throws: Activity.ValidationError.emptyTitle) { try makeActivity(title: " ") }
    #expect(throws: Activity.ValidationError.textTooLong(257)) {
      try makeActivity(title: String(repeating: "a", count: 257))
    }
    #expect(throws: Activity.ValidationError.controlCharacter) {
      try makeActivity(title: "a\u{0000}")
    }
    #expect(throws: Activity.ValidationError.emptySummary) { try makeActivity(summary: " ") }
    #expect(throws: Activity.ValidationError.textTooLong(2_049)) {
      try makeActivity(summary: String(repeating: "a", count: 2_049))
    }
    #expect(throws: Activity.ValidationError.controlCharacter) {
      try makeActivity(summary: "a\u{0000}")
    }
    #expect(throws: ActivityLineage.ValidationError.invalidRevision(0)) {
      try ActivityLineage(revision: 0)
    }
    #expect(throws: ActivityLineage.ValidationError.originalHasPredecessor) {
      try ActivityLineage(revision: 1, supersedesDeterministicRebuildActivityID: ActivityID())
    }
    #expect(try ActivityLineage(revision: 2).supersedesDeterministicRebuildActivityID == nil)
    let id = ActivityID()
    #expect(throws: Activity.ValidationError.lineageCannotSupersedeSelf) {
      try makeActivity(
        id: id,
        lineage: try ActivityLineage(revision: 2, supersedesDeterministicRebuildActivityID: id))
    }
  }

  @Test func exactMaximumBoundsAreAccepted() throws {
    let maximumSessions = try makeActivity(sessionIDs: (0..<4_096).map { _ in SessionID() })
    #expect(maximumSessions.sessionIDs.count == 4_096)
    let maximumEvidence = try makeActivity(
      evidenceReferences: (0..<4_096).map { _ in
        ActivityEvidenceReference(
          role: .supporting, evidenceFrameID: EvidenceFrameID(),
          stableStateObservationEventID: EventID())
      })
    #expect(maximumEvidence.evidenceReferences.count == 4_096)
    let maximumText = try makeActivity(
      title: String(repeating: "a", count: 256), summary: String(repeating: "b", count: 2_048))
    #expect(maximumText.title.utf8.count == 256)
    #expect(maximumText.summary?.utf8.count == 2_048)
  }

  @Test func decodingIsClosedAtEveryComposedBoundary() throws {
    let data = try JSONEncoder().encode(makeActivity())
    let base = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["payload", "path", "media", "bundleIdentifier"] {
      var x = base
      x[key] = "x"
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
      }
    }
    for field in ["id", "sessionIDs"] {
      var x = base
      if field == "id" {
        var id = try #require(x[field] as? [String: Any])
        id["payload"] = "x"
        x[field] = id
      } else {
        var ids = try #require(x[field] as? [[String: Any]])
        ids[0]["path"] = "x"
        x[field] = ids
      }
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
      }
    }
    var x = base
    var refs = try #require(x["evidenceReferences"] as? [[String: Any]])
    refs[0]["payload"] = "x"
    x["evidenceReferences"] = refs
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
    }
    x = base
    refs = try #require(x["evidenceReferences"] as? [[String: Any]])
    var frame = try #require(refs[0]["evidenceFrameID"] as? [String: Any])
    frame["media"] = "x"
    refs[0]["evidenceFrameID"] = frame
    var event = try #require(refs[0]["stableStateObservationEventID"] as? [String: Any])
    event["path"] = "x"
    refs[0]["stableStateObservationEventID"] = event
    x["evidenceReferences"] = refs
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
    }
    x = base
    var lineage = try #require(x["lineage"] as? [String: Any])
    lineage["payload"] = "x"
    x["lineage"] = lineage
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
    }
    x = base
    var interpretation = try #require(x["interpretation"] as? [String: Any])
    interpretation["payload"] = "x"
    x["interpretation"] = interpretation
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
    }
    let rebuilt = try makeActivity(
      lineage: try ActivityLineage(
        revision: 2, supersedesDeterministicRebuildActivityID: ActivityID()))
    x = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(rebuilt)) as? [String: Any])
    lineage = try #require(x["lineage"] as? [String: Any])
    var predecessor = try #require(
      lineage["supersedesDeterministicRebuildActivityID"] as? [String: Any])
    predecessor["payload"] = "x"
    lineage["supersedesDeterministicRebuildActivityID"] = predecessor
    x["lineage"] = lineage
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
    }
  }

  @Test func versionAndSerializationAuditAreClosed() throws {
    let data = try JSONEncoder().encode(makeActivity())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["version"] = 99
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: object))
    }
    object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(!containsForbiddenKey(in: object))
  }

  @Test func enumValuesAndOrderedProvenanceRoundTrip() throws {
    let first = ActivityEvidenceReference(
      role: .supporting, evidenceFrameID: EvidenceFrameID(),
      stableStateObservationEventID: EventID())
    let second = ActivityEvidenceReference(
      role: .conflicting, evidenceFrameID: EvidenceFrameID(),
      stableStateObservationEventID: EventID())
    let activity = try makeActivity(evidenceReferences: [first, second])
    let decoded = try JSONDecoder().decode(Activity.self, from: JSONEncoder().encode(activity))
    #expect(decoded.evidenceReferences == [first, second])

    let base = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(activity)) as? [String: Any])
    for (key, value) in [("confidence", "unknown"), ("reviewState", "unknown")] {
      var x = base
      x[key] = value
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
      }
    }
    var x = base
    var interpretation = try #require(x["interpretation"] as? [String: Any])
    interpretation["origin"] = "unknown"
    x["interpretation"] = interpretation
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
    }
    x = base
    var references = try #require(x["evidenceReferences"] as? [[String: Any]])
    references[0]["role"] = "unknown"
    x["evidenceReferences"] = references
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: x))
    }
  }

  @Test func interpretationOriginsRolesAndBoundsAreClosed() throws {
    #expect(
      try ActivityInterpretation(origin: .deterministicRule, producerVersion: "v1").origin
        == .deterministicRule)
    #expect(
      try ActivityInterpretation(origin: .modelInference, producerVersion: "v1", rationale: "r")
        .origin == .modelInference)
    #expect(
      try ActivityInterpretation(origin: .mixed, producerVersion: "v1", rationale: "r").origin
        == .mixed)
    #expect(throws: ActivityInterpretation.ValidationError.missingRequiredRationale) {
      try ActivityInterpretation(origin: .modelInference, producerVersion: "v1")
    }
    #expect(throws: ActivityInterpretation.ValidationError.missingRequiredRationale) {
      try ActivityInterpretation(origin: .mixed, producerVersion: "v1")
    }
    #expect(ActivityEvidenceRole.supporting != .conflicting)
    #expect(throws: ActivityInterpretation.ValidationError.emptyProducerVersion) {
      try ActivityInterpretation(origin: .modelInference, producerVersion: " ")
    }
    #expect(throws: ActivityInterpretation.ValidationError.oversizedProducerVersion(65)) {
      try ActivityInterpretation(
        origin: .modelInference, producerVersion: String(repeating: "a", count: 65))
    }
    #expect(throws: ActivityInterpretation.ValidationError.invalidProducerVersionFormat) {
      try ActivityInterpretation(origin: .modelInference, producerVersion: "https://secret")
    }
    #expect(throws: ActivityInterpretation.ValidationError.invalidProducerVersionFormat) {
      try ActivityInterpretation(origin: .modelInference, producerVersion: "v 1")
    }
    #expect(throws: ActivityInterpretation.ValidationError.controlCharacter) {
      try ActivityInterpretation(origin: .modelInference, producerVersion: "v\u{0000}")
    }
    #expect(throws: ActivityInterpretation.ValidationError.emptyRationale) {
      try ActivityInterpretation(origin: .modelInference, producerVersion: "v1", rationale: " ")
    }
    #expect(throws: ActivityInterpretation.ValidationError.controlCharacter) {
      try ActivityInterpretation(
        origin: .modelInference, producerVersion: "v1", rationale: "a\u{0000}")
    }
    #expect(throws: ActivityInterpretation.ValidationError.oversizedRationale(2_049)) {
      try ActivityInterpretation(
        origin: .modelInference, producerVersion: "v1",
        rationale: String(repeating: "a", count: 2_049))
    }
    #expect(
      try ActivityInterpretation(
        origin: .modelInference, producerVersion: String(repeating: "a", count: 64),
        rationale: String(repeating: "a", count: 2_048)
      ).rationale?.utf8.count == 2_048)
  }

  private func makeActivity(
    id: ActivityID = ActivityID(), startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    endedAt: Date = Date(timeIntervalSince1970: 1_800_000_300), sessionIDs: [SessionID]? = nil,
    evidenceReferences: [ActivityEvidenceReference]? = nil, title: String = "Draft",
    summary: String? = "Redacted", confidence: ActivityConfidenceBand = .medium,
    reviewState: ActivityReviewState = .ready,
    interpretation: ActivityInterpretation? = nil,
    lineage: ActivityLineage? = nil
  ) throws -> Activity {
    let resolvedInterpretation =
      try interpretation
      ?? ActivityInterpretation(
        origin: .deterministicRule, producerVersion: "v1")
    return try Activity(
      id: id, startedAt: startedAt, endedAt: endedAt, sessionIDs: sessionIDs ?? [SessionID()],
      evidenceReferences: evidenceReferences ?? [
        ActivityEvidenceReference(
          role: .supporting, evidenceFrameID: EvidenceFrameID(),
          stableStateObservationEventID: EventID())
      ], title: title, summary: summary, confidence: confidence, reviewState: reviewState,
      interpretation: resolvedInterpretation, lineage: lineage)
  }
  private func assertSendable<Value: Sendable>(_ type: Value.Type) {}

  private func containsForbiddenKey(in value: Any) -> Bool {
    let forbidden = Set([
      "payload", "path", "media", "bundleIdentifier", "pixels", "data", "fileURL", "metadata",
      "score", "productivity", "focus",
    ])
    if let object = value as? [String: Any] {
      return object.keys.contains(where: forbidden.contains)
        || object.values.contains(where: containsForbiddenKey)
    }
    if let array = value as? [Any] { return array.contains(where: containsForbiddenKey) }
    return false
  }
}
