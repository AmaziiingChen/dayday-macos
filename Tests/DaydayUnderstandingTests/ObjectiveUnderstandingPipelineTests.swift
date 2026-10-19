import DaydayCore
import Foundation
import Testing

@testable import DaydayUnderstanding

struct ObjectiveUnderstandingPipelineTests {
  @Test("derives deterministic display-local sessions and reviewable activities")
  func derivesSessionsActivitiesAndWorkReportContext() async throws {
    let day = try makeDay()
    let displayOne = DisplayID(rawValue: uuid("00000000-0000-0000-0000-000000000001"))
    let displayTwo = DisplayID(rawValue: uuid("00000000-0000-0000-0000-000000000002"))
    let first = try applicationEvent(
      "00000000-0000-0000-0000-000000000010", at: 60, display: displayOne)
    let second = try applicationEvent(
      "00000000-0000-0000-0000-000000000011", at: 60, display: displayTwo)
    let firstStable = try event(
      "00000000-0000-0000-0000-000000000012", kind: .stableStateObservation, at: 120,
      display: displayOne)
    let secondStable = try event(
      "00000000-0000-0000-0000-000000000013", kind: .stableStateObservation, at: 120,
      display: displayTwo)
    let privateGap = try event(
      "00000000-0000-0000-0000-000000000014", kind: .applicationContextChanged, at: 180,
      display: displayOne, disposition: .metadataOnly(.secureInput))
    let afterGap = try applicationEvent(
      "00000000-0000-0000-0000-000000000015", at: 240, display: displayOne)
    let afterGapStable = try event(
      "00000000-0000-0000-0000-000000000016", kind: .stableStateObservation, at: 300,
      display: displayOne)
    let repository = FixtureRepository(
      events: [afterGapStable, first, secondStable, privateGap, firstStable, afterGap, second],
      contexts: [
        first.id: try context(first, label: "Editor"),
        second.id: try context(second, label: "Browser"),
        afterGap.id: try context(afterGap, label: "Terminal"),
      ]
    )
    let pipeline = ObjectiveUnderstandingPipeline(repository: repository)

    let snapshot = try await pipeline.derive(day: day, asOf: offset(day, 360))
    let repeated = try await pipeline.derive(day: day, asOf: offset(day, 360))

    #expect(snapshot == repeated)
    #expect(snapshot.sessions.count == 3)
    #expect(snapshot.sessions.map(\.scope) == [
      .display(displayOne), .display(displayTwo), .display(displayOne),
    ])
    #expect(
      snapshot.sessions.map(\.objectiveEventIDs) == [
        [first.id, firstStable.id], [second.id, secondStable.id], [afterGap.id, afterGapStable.id],
      ])
    #expect(snapshot.sessions.map(\.endingHardBoundary) == [.privacySuppressed, nil, nil])
    #expect(
      snapshot.activities.allSatisfy {
        $0.confidence == .low && $0.reviewState == .needsReview
          && $0.interpretation.origin == .deterministicRule
      })
    #expect(
      snapshot.activities.map(\.title) == [
        "使用 Editor", "使用 Browser", "使用 Terminal",
      ])
    let activityBatch = try #require(try pipeline.activityBatch(day: day, snapshot: snapshot))
    #expect(activityBatch.activities == snapshot.activities)
    #expect(
      activityBatch.activities.allSatisfy {
        $0.confidence == .low && $0.reviewState == .needsReview
      })

    let context = try pipeline.workReportContext(day: day, snapshot: snapshot)
    #expect(context.activities.map(\.id) == snapshot.activities.map(\.id))
    #expect(context.activities.allSatisfy { $0.detectedInteractionSeconds == 0 })
    let encoded = try JSONEncoder().encode(context)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["journal"] == nil)
    #expect(object["mood"] == nil)
    #expect((object["workNotes"] as? [Any])?.isEmpty == true)
  }

  @Test("displayless foreground facts derive an honest workspace lane")
  func derivesWorkspaceSessionsForDisplaylessApplicationFacts() async throws {
    let day = try makeDay()
    let first = try event(
      "00000000-0000-0000-0000-000000000017",
      kind: .applicationContextChanged,
      at: 60
    )
    let second = try event(
      "00000000-0000-0000-0000-000000000018",
      kind: .applicationContextChanged,
      at: 120
    )
    let repository = FixtureRepository(
      events: [first, second],
      contexts: [
        first.id: try ApplicationContextRecord(
          eventID: first.id,
          applicationIdentifier: ApplicationIdentifier(rawValue: UUID()),
          displayLabelSnapshot: "WeChat",
          windowTitleSnapshot: "产品研发群 · 陈工"
        ),
        second.id: try context(second, label: "Xcode"),
      ]
    )
    let pipeline = ObjectiveUnderstandingPipeline(repository: repository)

    let snapshot = try await pipeline.derive(day: day, asOf: offset(day, 180))
    let segments = try await pipeline.objectiveApplicationSegments(
      day: day,
      asOf: offset(day, 180)
    )

    #expect(snapshot.sessions.count == 2)
    #expect(snapshot.sessions.allSatisfy { $0.scope == .workspace })
    #expect(snapshot.activities.map(\.title) == ["使用 WeChat", "使用 Xcode"])
    #expect(segments.count == 2)
    #expect(segments.map(\.applicationLabel) == ["WeChat", "Xcode"])
    #expect(segments[0].windowTitle == "产品研发群 · 陈工")
    #expect(segments.map(\.objectiveEventIDs) == [[first.id], [second.id]])
    #expect(segments.map(\.endedAt) == [second.occurredAt, offset(day, 180)])
  }

  @Test("same application window changes remain separate Sessions but one readable Activity")
  func coalescesAdjacentSameApplicationSessionsIntoOneActivity() async throws {
    let day = try makeDay()
    let first = try event(
      "00000000-0000-0000-0000-000000000019",
      kind: .applicationContextChanged,
      at: 60
    )
    let second = try event(
      "00000000-0000-0000-0000-00000000001a",
      kind: .applicationContextChanged,
      at: 120
    )
    let applicationIdentifier = ApplicationIdentifier(rawValue: UUID())
    let repository = FixtureRepository(
      events: [first, second],
      contexts: [
        first.id: try ApplicationContextRecord(
          eventID: first.id,
          applicationIdentifier: applicationIdentifier,
          displayLabelSnapshot: "Xcode",
          windowTitleSnapshot: "Session.swift"
        ),
        second.id: try ApplicationContextRecord(
          eventID: second.id,
          applicationIdentifier: applicationIdentifier,
          displayLabelSnapshot: "Xcode",
          windowTitleSnapshot: "DaydayUnderstanding.swift"
        ),
      ]
    )

    let snapshot = try await ObjectiveUnderstandingPipeline(repository: repository)
      .derive(day: day, asOf: offset(day, 180))

    #expect(snapshot.sessions.count == 2)
    #expect(snapshot.activities.count == 1)
    #expect(snapshot.activities[0].title == "使用 Xcode")
    #expect(snapshot.activities[0].sessionIDs == snapshot.sessions.map(\.id))
    #expect(snapshot.activities[0].startedAt == first.occurredAt)
    #expect(snapshot.activities[0].endedAt == offset(day, 180))
  }

  @Test("global lifecycle boundary ends every active lane without bridging")
  func lifecycleBoundaryEndsAllLanes() async throws {
    let day = try makeDay()
    let one = DisplayID()
    let two = DisplayID()
    let first = try applicationEvent("00000000-0000-0000-0000-000000000020", at: 60, display: one)
    let second = try applicationEvent("00000000-0000-0000-0000-000000000021", at: 60, display: two)
    let boundary = try event("00000000-0000-0000-0000-000000000022", kind: .systemBoundary, at: 120)
    let repository = FixtureRepository(
      events: [first, second, boundary],
      contexts: [
        first.id: try context(first, label: "Editor"),
        second.id: try context(second, label: "Docs"),
      ]
    )

    let snapshot = try await ObjectiveUnderstandingPipeline(repository: repository)
      .derive(day: day, asOf: offset(day, 180))

    #expect(snapshot.sessions.count == 2)
    #expect(snapshot.sessions.allSatisfy { $0.endedAt == boundary.occurredAt })
    #expect(snapshot.sessions.allSatisfy { $0.endingHardBoundary == nil })
  }

  @Test("collector state projections retain concrete security lifecycle reasons")
  func collectorStateReasonEndsLane() async throws {
    let day = try makeDay()
    let display = DisplayID()
    let application = try applicationEvent(
      "00000000-0000-0000-0000-000000000030", at: 60, display: display)
    let stateEvent = try event(
      "00000000-0000-0000-0000-000000000031", kind: .collectorStateTransition, at: 120)
    let paused = try CollectorState(
      kind: .applicationWindowContext, authorization: .authorized,
      runtime: .paused(reasons: [.screenLocked], resumeState: .running)
    )
    let repository = FixtureRepository(
      events: [application, stateEvent],
      contexts: [application.id: try context(application, label: "Editor")],
      states: [stateEvent.id: try CollectorStateRecord(eventID: stateEvent.id, state: paused)]
    )

    let snapshot = try await ObjectiveUnderstandingPipeline(repository: repository)
      .derive(day: day, asOf: offset(day, 180))

    #expect(snapshot.sessions.map(\.endingHardBoundary) == [.screenLocked])
  }

  @Test("future facts and boundaries cannot alter an earlier snapshot")
  func excludesFutureEventsAtEffectiveUpperBound() async throws {
    let day = try makeDay()
    let display = DisplayID()
    let present = try applicationEvent(
      "00000000-0000-0000-0000-000000000040", at: 60, display: display)
    let futureApplication = try applicationEvent(
      "00000000-0000-0000-0000-000000000041", at: 180, display: display)
    let futureBoundary = try event(
      "00000000-0000-0000-0000-000000000042", kind: .systemBoundary, at: 240)
    let repository = FixtureRepository(
      events: [futureBoundary, futureApplication, present],
      contexts: [
        present.id: try context(present, label: "Editor"),
        futureApplication.id: try context(futureApplication, label: "Terminal"),
      ]
    )
    let pipeline = ObjectiveUnderstandingPipeline(repository: repository)

    let early = try await pipeline.derive(day: day, asOf: offset(day, 120))
    let fullDay = try await pipeline.derive(day: day, asOf: day.boundary.endsAt)
    let beforeStart = try await pipeline.derive(day: day, asOf: offset(day, -1))
    let atStart = try await pipeline.derive(day: day, asOf: day.boundary.startsAt)

    #expect(early.sessions.map(\.objectiveEventIDs) == [[present.id]])
    #expect(early.sessions.map(\.endedAt) == [offset(day, 120)])
    #expect(early.activities.map(\.title) == ["使用 Editor"])
    #expect(fullDay.sessions.flatMap(\.objectiveEventIDs) == [present.id, futureApplication.id])
    #expect(beforeStart == ObjectiveUnderstandingSnapshot(sessions: [], activities: []))
    #expect(atStart == ObjectiveUnderstandingSnapshot(sessions: [], activities: []))
  }

  @Test("later same-day revision extends an open lane with conservative lineage")
  func laterRevisionExtendsOpenSessionAndIsDeterministic() async throws {
    let day = try makeDay()
    let display = DisplayID(rawValue: uuid("00000000-0000-0000-0000-000000000050"))
    let application = try applicationEvent(
      "00000000-0000-0000-0000-000000000051", at: 60, display: display)
    let repository = FixtureRepository(
      events: [application], contexts: [application.id: try context(application, label: "Editor")])
    let pipeline = ObjectiveUnderstandingPipeline(repository: repository)

    let first = try await pipeline.derive(day: day, asOf: offset(day, 120))
    let second = try await pipeline.derive(
      day: day, asOf: offset(day, 240), derivationRevision: 2, previousSnapshot: first)
    let repeated = try await pipeline.derive(
      day: day, asOf: offset(day, 240), derivationRevision: 2, previousSnapshot: first)

    let firstSession = try #require(first.sessions.first)
    let secondSession = try #require(second.sessions.first)
    let firstActivity = try #require(first.activities.first)
    let secondActivity = try #require(second.activities.first)
    #expect(firstSession.lineage.derivationRevision == 1)
    #expect(firstSession.lineage.supersedesSessionID == nil)
    #expect(firstActivity.lineage.revision == 1)
    #expect(firstActivity.lineage.supersedesDeterministicRebuildActivityID == nil)
    #expect(secondSession.id != firstSession.id)
    #expect(secondSession.endedAt > firstSession.endedAt)
    #expect(secondSession.lineage.derivationRevision == 2)
    #expect(secondSession.lineage.supersedesSessionID == firstSession.id)
    #expect(secondActivity.id != firstActivity.id)
    #expect(secondActivity.lineage.revision == 2)
    #expect(secondActivity.lineage.supersedesDeterministicRebuildActivityID == firstActivity.id)
    #expect(second == repeated)
  }

  @Test("a lane first observed in a later revision has no guessed predecessor")
  func newlyAppearingRevisionTwoLaneHasNoPredecessor() async throws {
    let day = try makeDay()
    let existingDisplay = DisplayID(rawValue: uuid("00000000-0000-0000-0000-000000000060"))
    let newDisplay = DisplayID(rawValue: uuid("00000000-0000-0000-0000-000000000061"))
    let existing = try applicationEvent(
      "00000000-0000-0000-0000-000000000062", at: 60, display: existingDisplay)
    let new = try applicationEvent(
      "00000000-0000-0000-0000-000000000063", at: 180, display: newDisplay)
    let repository = FixtureRepository(
      events: [existing, new],
      contexts: [
        existing.id: try context(existing, label: "Editor"),
        new.id: try context(new, label: "Terminal"),
      ]
    )
    let pipeline = ObjectiveUnderstandingPipeline(repository: repository)

    let first = try await pipeline.derive(day: day, asOf: offset(day, 120))
    let second = try await pipeline.derive(
      day: day, asOf: offset(day, 240), derivationRevision: 2, previousSnapshot: first)
    let newSession = try #require(second.sessions.first { $0.scope == .display(newDisplay) })
    let newActivity = try #require(second.activities.first { $0.sessionIDs == [newSession.id] })

    #expect(newSession.lineage.derivationRevision == 2)
    #expect(newSession.lineage.supersedesSessionID == nil)
    #expect(newActivity.lineage.revision == 2)
    #expect(newActivity.lineage.supersedesDeterministicRebuildActivityID == nil)
  }

  @Test("later revisions require the immediately preceding nonempty complete snapshot")
  func revisionSnapshotsAreClosedAndImmediate() async throws {
    let day = try makeDay()
    let display = DisplayID(rawValue: uuid("00000000-0000-0000-0000-000000000070"))
    let application = try applicationEvent(
      "00000000-0000-0000-0000-000000000071", at: 60, display: display)
    let pipeline = ObjectiveUnderstandingPipeline(
      repository: FixtureRepository(
        events: [application], contexts: [application.id: try context(application, label: "Editor")]
      ))
    let first = try await pipeline.derive(day: day, asOf: offset(day, 120))

    await #expect(throws: ObjectiveUnderstandingPipeline.DerivationError.invalidPreviousSnapshot) {
      try await pipeline.derive(
        day: day, asOf: offset(day, 180), derivationRevision: 1, previousSnapshot: first)
    }
    await #expect(throws: ObjectiveUnderstandingPipeline.DerivationError.invalidPreviousSnapshot) {
      try await pipeline.derive(day: day, asOf: offset(day, 180), derivationRevision: 2)
    }
    await #expect(throws: ObjectiveUnderstandingPipeline.DerivationError.invalidPreviousSnapshot) {
      try await pipeline.derive(
        day: day, asOf: offset(day, 180), derivationRevision: 3, previousSnapshot: first)
    }
    await #expect(throws: ObjectiveUnderstandingPipeline.DerivationError.invalidPreviousSnapshot) {
      try await pipeline.derive(
        day: day,
        asOf: offset(day, 180),
        derivationRevision: 2,
        previousSnapshot: ObjectiveUnderstandingSnapshot(sessions: [], activities: [])
      )
    }
  }

  @Test("revision validation and civil DST workday bounds remain explicit")
  func revisionValidationAndDSTBounds() async throws {
    let utcDay = try makeDay()
    let pipeline = ObjectiveUnderstandingPipeline(
      repository: FixtureRepository(events: [], contexts: [:]))
    await #expect(throws: ObjectiveUnderstandingPipeline.DerivationError.invalidDerivationRevision)
    {
      try await pipeline.derive(day: utcDay, asOf: offset(utcDay, 60), derivationRevision: 0)
    }

    for (year, month, dayNumber, expectedSeconds) in [
      (2027, 3, 13, 23 * 60 * 60),
      (2027, 11, 6, 25 * 60 * 60),
    ] {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
      let noon = try #require(
        calendar.date(from: DateComponents(year: year, month: month, day: dayNumber, hour: 12)))
      let start = try WorkdayBoundary.standard.start(containing: noon, calendar: calendar)
      let nextCivilDay = try #require(calendar.date(byAdding: .day, value: 1, to: start))
      let end = try WorkdayBoundary.standard.start(containing: nextCivilDay, calendar: calendar)
      let descriptor = try DayDescriptor(
        logicalDate: .init(year: year, month: month, day: dayNumber),
        timeZoneIdentifier: calendar.timeZone.identifier,
        boundary: .init(hour: 4, startsAt: start, endsAt: end)
      )

      let snapshot = try await pipeline.derive(day: descriptor, asOf: end)
      #expect(descriptor.boundary.startsAt < descriptor.boundary.endsAt)
      #expect(
        descriptor.boundary.endsAt.timeIntervalSince(descriptor.boundary.startsAt)
          == TimeInterval(expectedSeconds))
      #expect(snapshot == ObjectiveUnderstandingSnapshot(sessions: [], activities: []))
    }
  }

  private func makeDay() throws -> DayDescriptor {
    let start = Date(timeIntervalSince1970: 1_799_985_600)
    return try DayDescriptor(
      id: DayID(rawValue: uuid("00000000-0000-0000-0000-000000000100")),
      logicalDate: LogicalDayDate(year: 2027, month: 1, day: 15),
      timeZoneIdentifier: "UTC",
      boundary: WorkdayBoundarySnapshot(
        hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400))
    )
  }

  private func offset(_ day: DayDescriptor, _ seconds: TimeInterval) -> Date {
    day.boundary.startsAt.addingTimeInterval(seconds)
  }

  private func event(
    _ id: String, kind: ObjectiveEventKind, at seconds: TimeInterval, display: DisplayID? = nil,
    disposition: EventSecurityDisposition = .allowed
  ) throws -> ObjectiveEvent {
    try ObjectiveEvent(
      id: EventID(rawValue: uuid(id)), kind: kind, occurredAt: offset(try makeDay(), seconds),
      timeZoneIdentifier: "UTC", source: source(),
      display: display.map { DisplayContext(id: $0, topologyRevision: 1) },
      securityDisposition: disposition
    )
  }

  private func applicationEvent(_ id: String, at offset: TimeInterval, display: DisplayID) throws
    -> ObjectiveEvent
  {
    try event(id, kind: .applicationContextChanged, at: offset, display: display)
  }

  private func context(_ event: ObjectiveEvent, label: String) throws -> ApplicationContextRecord {
    try ApplicationContextRecord(
      eventID: event.id, applicationIdentifier: ApplicationIdentifier(rawValue: UUID()),
      displayLabelSnapshot: label
    )
  }

  private func source() throws -> CollectorSource {
    try CollectorSource(
      collector: .applicationWindowContext, collectorVersion: "test-v1", payloadSchemaVersion: 1)
  }

  private func uuid(_ value: String) -> UUID { UUID(uuidString: value)! }
}

private actor FixtureRepository: ObjectiveLinkedRecordRepository {
  let events: [ObjectiveEvent]
  let contexts: [EventID: ApplicationContextRecord]
  let states: [EventID: CollectorStateRecord]

  init(
    events: [ObjectiveEvent], contexts: [EventID: ApplicationContextRecord],
    states: [EventID: CollectorStateRecord] = [:]
  ) {
    self.events = events
    self.contexts = contexts
    self.states = states
  }

  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult {
    .alreadyPresent
  }
  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] {
    events.filter { range.contains($0.occurredAt) }
  }
  func insertApplicationContext(_ write: ApplicationContextWrite) async throws
    -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func insertCollectorState(_ write: CollectorStateWrite) async throws -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func insertCollectionSuppression(_ write: CollectionSuppressionWrite) async throws
    -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func fetchApplicationContext(for eventID: EventID) async throws -> ApplicationContextRecord? {
    contexts[eventID]
  }
  func fetchCollectorState(for eventID: EventID) async throws -> CollectorStateRecord? {
    states[eventID]
  }
  func fetchCollectionSuppression(for eventID: EventID) async throws -> CollectionSuppressionRecord?
  { nil }
}
