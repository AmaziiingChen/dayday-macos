import DaydayCore
import DaydayUnderstanding
import Foundation
import Testing

@testable import DaydayApp

@Suite("Today objective timeline presentation")
struct TodayTimelinePresentationAdapterTests {
  @Test("Orders ties deterministically and hides untyped system boundary noise")
  func ordersFactsAndGaps() throws {
    let day = try makeDay()
    let date = day.boundary.startsAt.addingTimeInterval(60)
    let fact = try event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, at: date,
      kind: .applicationContextChanged, disposition: .allowed)
    let gap = try event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, at: date,
      kind: .systemBoundary, disposition: .metadataOnly(.screenLocked))
    let lifecycle = try event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
      at: date.addingTimeInterval(60), kind: .systemBoundary, disposition: .allowed)
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day, events: [lifecycle, fact, gap], now: date, fetchState: .loaded, runtime: .unknown)
    #expect(presentation.state == .populated)
    #expect(
      presentation.items.map(\.kind) == [.lifecycleGap, .objectiveFact, .boundaryStart])
    #expect(presentation.items.allSatisfy { !$0.accessibilityLabel.isEmpty })
    #expect(presentation.items[1].accessibilityLabel.contains("时间：2024-01-01T04:01:00Z"))
    #expect(presentation.items[0].accessibilityLabel.contains("屏幕锁定，记录暂停"))
    #expect(presentation.items[0].accessibilityLabel.contains("来源：applicationWindowContext"))
    #expect(!presentation.items.contains { $0.id == lifecycle.id.rawValue.uuidString })
  }

  @Test("Only pause, permission loss and recovery become collector lifecycle boundaries")
  func filtersCollectorHeartbeatNoise() throws {
    let day = try makeDay()
    let start = day.boundary.startsAt
    let configured = try event(
      id: UUID(), at: start.addingTimeInterval(10), kind: .collectorStateTransition,
      disposition: .allowed)
    let heartbeat = try event(
      id: UUID(), at: start.addingTimeInterval(20), kind: .collectorStateTransition,
      disposition: .allowed)
    let paused = try event(
      id: UUID(), at: start.addingTimeInterval(30), kind: .collectorStateTransition,
      disposition: .allowed)
    let duplicatePause = try event(
      id: UUID(), at: start.addingTimeInterval(40), kind: .collectorStateTransition,
      disposition: .allowed)
    let resumed = try event(
      id: UUID(), at: start.addingTimeInterval(50), kind: .collectorStateTransition,
      disposition: .allowed)
    let revoked = try event(
      id: UUID(), at: start.addingTimeInterval(60), kind: .collectorStateTransition,
      disposition: .allowed)
    let running = try CollectorState(
      kind: .applicationWindowContext, authorization: .authorized, runtime: .running)
    let sleeping = try CollectorState(
      kind: .applicationWindowContext, authorization: .authorized,
      runtime: .paused(reasons: [.systemSleep], resumeState: .running))
    let permissionLost = try CollectorState(
      kind: .applicationWindowContext, authorization: .revoked,
      runtime: .waitingForAuthorization)
    let states = try Dictionary(uniqueKeysWithValues: [
      (configured.id, CollectorStateRecord(eventID: configured.id, state: running)),
      (heartbeat.id, CollectorStateRecord(eventID: heartbeat.id, state: running)),
      (paused.id, CollectorStateRecord(eventID: paused.id, state: sleeping)),
      (duplicatePause.id, CollectorStateRecord(eventID: duplicatePause.id, state: sleeping)),
      (resumed.id, CollectorStateRecord(eventID: resumed.id, state: running)),
      (revoked.id, CollectorStateRecord(eventID: revoked.id, state: permissionLost)),
    ])

    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [configured, heartbeat, paused, duplicatePause, resumed, revoked],
      collectorStates: states,
      now: start.addingTimeInterval(70),
      fetchState: .loaded,
      runtime: .unknown
    )

    let lifecycle = presentation.items.filter { $0.kind == .lifecycleGap }
    #expect(
      lifecycle.map(\.title) == [
        "系统权限丢失，记录暂停", "记录已恢复", "系统睡眠，记录暂停",
      ])
    #expect(!presentation.items.contains { $0.id == configured.id.rawValue.uuidString })
    #expect(!presentation.items.contains { $0.id == heartbeat.id.rawValue.uuidString })
    #expect(!presentation.items.contains { $0.id == duplicatePause.id.rawValue.uuidString })
  }

  @Test("Runtime permission and fetch states are explicit")
  func exposesStatesWithoutSampleData() throws {
    let day = try makeDay()
    #expect(
      TodayTimelinePresentationAdapter.make(
        day: day, events: [], now: day.boundary.startsAt, fetchState: .loaded, runtime: .unknown
      ).state == .empty)
    #expect(
      TodayTimelinePresentationAdapter.make(
        day: day, events: [], now: day.boundary.startsAt, fetchState: .loading, runtime: .unknown
      ).state == .loading)
    #expect(
      TodayTimelinePresentationAdapter.make(
        day: day, events: [], now: day.boundary.startsAt, fetchState: .paused, runtime: .unknown
      ).state == .paused)
    #expect(
      TodayTimelinePresentationAdapter.make(
        day: day, events: [], now: day.boundary.startsAt, fetchState: .failure, runtime: .unknown
      ).state == .failure)
    #expect(
      TodayTimelinePresentationAdapter.make(
        day: day, events: [], now: day.boundary.startsAt, fetchState: .degraded, runtime: .unknown
      ).state == .degraded)
    #expect(
      TodayTimelinePresentationAdapter.make(
        day: day, events: [], now: day.boundary.startsAt, fetchState: .loaded,
        runtime: .previewPermissionRequired
      ).state == .permission)
    #expect(
      TodayTimelinePresentationAdapter.make(
        day: day, events: [], now: day.boundary.startsAt, fetchState: .failure,
        runtime: .previewPermissionRequired
      ).state == .permission)
  }

  @Test("Persisted application facts remain visible after later Accessibility loss")
  func historyOutlivesPermissionRevocation() throws {
    let day = try makeDay()
    let fact = try event(
      id: UUID(), at: day.boundary.startsAt.addingTimeInterval(60),
      kind: .applicationContextChanged, disposition: .allowed)
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day, events: [fact], now: fact.occurredAt, fetchState: .loaded,
      runtime: .previewPermissionRequired)

    #expect(presentation.state == .populated)
    #expect(presentation.items.map(\.kind) == [.objectiveFact, .boundaryStart])
  }

  @Test("Application facts become readable time segments without task inference")
  func groupsApplicationChangesIntoSegments() throws {
    let day = try makeDay()
    let first = try event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      at: day.boundary.startsAt.addingTimeInterval(60),
      kind: .applicationContextChanged, disposition: .allowed)
    let second = try event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
      at: day.boundary.startsAt.addingTimeInterval(15 * 60),
      kind: .applicationContextChanged, disposition: .allowed)
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [second, first],
      applicationContexts: [
        first.id: try applicationContext(for: first, label: "Xcode"),
        second.id: try applicationContext(for: second, label: "Safari"),
      ],
      now: day.boundary.startsAt.addingTimeInterval(32 * 60),
      fetchState: .loaded,
      runtime: .unknown
    )

    let segments = presentation.items.filter { $0.kind == .activitySegment }
    #expect(segments.map(\.title) == ["使用 Safari", "使用 Xcode"])
    #expect(
      segments.map(\.sourceLabel) == [
        "本地应用与窗口记录 · 17分钟", "本地应用与窗口记录 · 14分钟",
      ])
    #expect(segments.allSatisfy { $0.accessibilityLabel.contains("来自本地应用与窗口记录") })
    #expect(presentation.items.allSatisfy { !$0.title.contains("任务") })
  }

  @Test("Empty H2 enrichment falls back to objective application segments")
  func fallsBackWhenUnderstandingHasNoSessions() throws {
    let day = try makeDay()
    let first = try event(
      id: UUID(), at: day.boundary.startsAt.addingTimeInterval(60),
      kind: .applicationContextChanged, disposition: .allowed)
    let second = try event(
      id: UUID(), at: day.boundary.startsAt.addingTimeInterval(15 * 60),
      kind: .applicationContextChanged, disposition: .allowed)

    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [second, first],
      applicationContexts: [
        first.id: try applicationContext(for: first, label: "ChatGPT"),
        second.id: try applicationContext(for: second, label: "Dayday"),
      ],
      understanding: .init(sessions: [], activities: []),
      now: day.boundary.startsAt.addingTimeInterval(30 * 60),
      fetchState: .loaded,
      runtime: .unknown
    )

    #expect(presentation.state == .populated)
    #expect(
      presentation.items.filter { $0.kind == .activitySegment }.map(\.title) == [
        "使用 Dayday", "使用 ChatGPT",
      ])
    #expect(!presentation.items.contains { $0.kind == .sessionSpan })
    #expect(!presentation.items.contains { $0.kind == .activityInference })
  }

  @Test("Privacy and lifecycle boundaries never bridge application segments")
  func boundariesCloseSegmentsWithoutInventingContinuity() throws {
    let day = try makeDay()
    let application = try event(
      id: UUID(), at: day.boundary.startsAt.addingTimeInterval(60),
      kind: .applicationContextChanged, disposition: .allowed)
    let suppression = try event(
      id: UUID(), at: day.boundary.startsAt.addingTimeInterval(5 * 60),
      kind: .applicationContextChanged, disposition: .excluded(.authorizationUnavailable))
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [application, suppression],
      applicationContexts: [
        application.id: try applicationContext(for: application, label: "Xcode")
      ],
      now: day.boundary.startsAt.addingTimeInterval(20 * 60),
      fetchState: .loaded,
      runtime: .unknown
    )

    let segments = presentation.items.filter { $0.kind == .activitySegment }
    #expect(segments.count == 1)
    #expect(segments[0].endedAt == suppression.occurredAt)
    #expect(segments[0].sourceLabel == "本地应用与窗口记录 · 4分钟")
    #expect(!presentation.items.contains { $0.kind == .securityGap })
    #expect(!presentation.items.contains { $0.id == suppression.id.rawValue.uuidString })
  }

  @Test("High-frequency privacy suppressions stay out of the primary timeline")
  func hidesImplementationLevelPrivacySuppressions() throws {
    let day = try makeDay()
    let reasons: [CollectionSuppressionReason] = [
      .uncertainSafetyState, .authenticationContext, .authorizationUnavailable,
    ]
    let events = try reasons.enumerated().map { offset, reason in
      try event(
        id: UUID(), at: day.boundary.startsAt.addingTimeInterval(Double(offset + 1) * 10),
        kind: .applicationContextChanged, disposition: .metadataOnly(reason))
    }

    let presentation = TodayTimelinePresentationAdapter.make(
      day: day, events: events, now: day.boundary.startsAt.addingTimeInterval(60),
      fetchState: .loaded, runtime: .unknown)

    #expect(!presentation.items.contains { $0.kind == .securityGap })
    #expect(presentation.items.map(\.kind) == [.boundaryStart])
    #expect(presentation.state == .empty)
  }

  @Test("An unreadable application projection also breaks continuity")
  func missingApplicationProjectionClosesThePriorSegment() throws {
    let day = try makeDay()
    let first = try event(
      id: UUID(), at: day.boundary.startsAt.addingTimeInterval(60),
      kind: .applicationContextChanged, disposition: .allowed)
    let missingProjection = try event(
      id: UUID(), at: day.boundary.startsAt.addingTimeInterval(5 * 60),
      kind: .applicationContextChanged, disposition: .allowed)
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [first, missingProjection],
      applicationContexts: [first.id: try applicationContext(for: first, label: "Xcode")],
      now: day.boundary.startsAt.addingTimeInterval(20 * 60),
      fetchState: .loaded,
      runtime: .unknown
    )

    let segments = presentation.items.filter { $0.kind == .activitySegment }
    #expect(segments.count == 1)
    #expect(segments[0].endedAt == missingProjection.occurredAt)
  }

  @Test("Out-of-range events do not make a workday populated")
  func excludesOutOfRangeEventsBeforeStateSelection() throws {
    let day = try makeDay()
    let outside = try event(
      id: UUID(), at: day.boundary.endsAt, kind: .applicationContextChanged, disposition: .allowed)
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day, events: [outside], now: day.boundary.startsAt, fetchState: .loaded,
      runtime: .unknown)
    #expect(presentation.state == .empty)
    #expect(presentation.items.map(\.kind) == [.boundaryStart])
  }

  @Test("Latest captured fact appears first and a future workday end stays hidden")
  func presentsActiveWorkdayLatestFirst() throws {
    let day = try makeDay()
    let afternoon = try event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
      at: day.boundary.startsAt.addingTimeInterval(13 * 60 * 60),
      kind: .applicationContextChanged,
      disposition: .allowed
    )
    let afterMidnight = try event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
      at: day.boundary.startsAt.addingTimeInterval(20 * 60 * 60),
      kind: .applicationContextChanged,
      disposition: .allowed
    )
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [afternoon, afterMidnight],
      now: day.boundary.startsAt.addingTimeInterval(21 * 60 * 60),
      fetchState: .loaded,
      runtime: .unknown
    )

    #expect(
      presentation.items.map(\.occurredAt) == [
        afterMidnight.occurredAt, afternoon.occurredAt, day.boundary.startsAt,
      ])
    #expect(presentation.items.first?.id == afterMidnight.id.rawValue.uuidString)
    #expect(!presentation.items.contains { $0.kind == .boundaryEnd })
  }

  @Test("Derived sessions and activities are presented separately from objective facts")
  func presentsUnderstandingWithoutClaimingInferenceAsFact() throws {
    let day = try makeDay()
    let start = day.boundary.startsAt.addingTimeInterval(60)
    let end = start.addingTimeInterval(10 * 60)
    let application = try event(
      id: UUID(), at: start, kind: .applicationContextChanged, disposition: .allowed)
    let display = DisplayID(rawValue: UUID())
    let session = try Session(
      id: SessionID(), displayID: display, startedAt: start, endedAt: end,
      objectiveEventIDs: [application.id]
    )
    let activity = try Activity(
      id: ActivityID(), startedAt: start, endedAt: end, sessionIDs: [session.id],
      title: "Observed Xcode activity", confidence: .low, reviewState: .needsReview,
      interpretation: ActivityInterpretation(
        origin: .deterministicRule, producerVersion: "test-v1",
        rationale: "Derived from objective membership."
      )
    )
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [application],
      applicationContexts: [
        application.id: try applicationContext(for: application, label: "Xcode")
      ],
      understanding: ObjectiveUnderstandingSnapshot(sessions: [session], activities: [activity]),
      now: end,
      fetchState: .loaded,
      runtime: .unknown
    )

    #expect(presentation.items.filter { $0.kind == .activitySegment }.isEmpty)
    #expect(!presentation.items.contains { $0.kind == .sessionSpan })
    let inferred = try #require(presentation.items.first { $0.kind == .activityInference })
    #expect(inferred.title == "使用 Xcode")
    #expect(inferred.sourceLabel == "本地归集 Activity · 1 个 Session")
    #expect(inferred.activity?.eventCount == 1)
  }

  @Test("Activity evidence and its visual narrative coexist without replacing either layer")
  func keepsVisualNarrativeAlongsideDerivedActivity() throws {
    let day = try makeDay()
    let start = day.boundary.startsAt.addingTimeInterval(60)
    let end = start.addingTimeInterval(10 * 60)
    let application = try event(
      id: UUID(), at: start, kind: .applicationContextChanged, disposition: .allowed)
    let session = try Session(
      id: SessionID(), scope: .workspace, startedAt: start, endedAt: end,
      objectiveEventIDs: [application.id]
    )
    let activity = try Activity(
      id: ActivityID(), startedAt: start, endedAt: end, sessionIDs: [session.id],
      title: "使用 Xcode", confidence: .low, reviewState: .needsReview,
      interpretation: ActivityInterpretation(
        origin: .deterministicRule, producerVersion: "test-v1",
        rationale: "Derived from objective membership."
      )
    )
    let visual = try visualInference(
      at: start.addingTimeInterval(2 * 60),
      endedAt: start.addingTimeInterval(7 * 60),
      summary: "在 Xcode 中连续修改时间线归集逻辑"
    )

    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [application],
      applicationContexts: [
        application.id: try applicationContext(for: application, label: "Xcode")
      ],
      visualInferences: [visual],
      understanding: ObjectiveUnderstandingSnapshot(sessions: [session], activities: [activity]),
      now: end,
      fetchState: .loaded,
      runtime: .unknown
    )

    let activities = presentation.items.filter { $0.kind == .activityInference }
    #expect(activities.count == 1)
    #expect(activities[0].inference?.summary == "在 Xcode 中连续修改时间线归集逻辑")
    #expect(activities[0].sourceLabel.contains("AI 观察 1 段"))
    let narratives = presentation.items.filter { $0.kind == .inferredActivity }
    #expect(narratives.count == 1)
    #expect(narratives[0].title == "在 Xcode 中连续修改时间线归集逻辑")
    #expect(TodayTimelineWindow.primaryItems(from: presentation.items) == narratives)
  }

  @Test("DST workday boundary duration is preserved")
  func preservesTwentyThreeHourDSTBoundary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let start = try #require(calendar.date(from: .init(year: 2024, month: 3, day: 9, hour: 4)))
    let end = try #require(calendar.date(from: .init(year: 2024, month: 3, day: 10, hour: 4)))
    let day = try DayDescriptor(
      logicalDate: .init(year: 2024, month: 3, day: 9), timeZoneIdentifier: "America/New_York",
      boundary: .init(hour: 4, startsAt: start, endsAt: end))
    let presentation = TodayTimelinePresentationAdapter.make(
      day: day, events: [], now: day.boundary.startsAt, fetchState: .loaded, runtime: .unknown)
    #expect(day.boundary.endsAt.timeIntervalSince(day.boundary.startsAt) == 82_800)
    #expect(presentation.boundary == day.boundary)
  }

  private func makeDay() throws -> DayDescriptor {
    let start = Date(timeIntervalSince1970: 1_704_081_600)  // 2024-01-01 04:00 UTC
    let end = start.addingTimeInterval(86_400)
    return try DayDescriptor(
      logicalDate: .init(year: 2024, month: 1, day: 1), timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: end))
  }

  private func event(
    id: UUID, at: Date, kind: ObjectiveEventKind, disposition: EventSecurityDisposition,
    collector: CollectorKind = .applicationWindowContext
  ) throws -> ObjectiveEvent {
    try .init(
      id: .init(rawValue: id), kind: kind, occurredAt: at, timeZoneIdentifier: "UTC",
      source: .init(
        collector: collector, collectorVersion: "1.0", payloadSchemaVersion: 1),
      securityDisposition: disposition)
  }

  private func applicationContext(for event: ObjectiveEvent, label: String) throws
    -> ApplicationContextRecord
  {
    try ApplicationContextRecord(
      eventID: event.id,
      applicationIdentifier: .init(rawValue: UUID()),
      displayLabelSnapshot: label
    )
  }

  private func visualInference(
    at start: Date, endedAt: Date, summary: String
  ) throws -> VisibleContentObservation {
    let provenance = try VisibleContentProvenance(
      source: CollectorSource(
        collector: .screenUnderstanding,
        collectorVersion: "byok-screen-vision-v1",
        payloadSchemaVersion: 1
      ),
      observedAt: start,
      endedAt: endedAt,
      timeZoneIdentifier: "UTC",
      display: DisplayContext(id: DisplayID(), topologyRevision: 1)
    )
    return try VisibleContentObservation(
      provenance: provenance,
      kind: .inference,
      redactionState: .noRedactionNeeded,
      text: """
        情境：\(summary)
        可见交互：持续编辑代码
        类型：development
        可见依据：
        - Xcode 编辑器持续可见
        """,
      inferenceOrigin: "byok-screen-vision-v1"
    )
  }
}
