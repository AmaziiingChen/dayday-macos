import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@Suite("Historical objective timeline", .serialized)
@MainActor
struct HistoricalTimelineModelTests {
  @Test("Uses the selected logical date's 04:00 boundary and projects newest first")
  func usesLogicalDayAndLatestFirst() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let selected = try #require(calendar.date(from: .init(year: 2024, month: 1, day: 2)))
    let day = try HistoricalTimelineModel.dayDescriptor(
      forCalendarDate: selected, calendar: calendar, boundary: .standard)
    let old = try event(at: day.boundary.startsAt.addingTimeInterval(60))
    let latest = try event(at: day.boundary.endsAt.addingTimeInterval(-60))
    let repository = HistoricalPageRepository(pages: [.init(events: [latest, old], nextCursor: nil)])
    let model = HistoricalTimelineModel(calendar: calendar, now: { day.boundary.endsAt })
    model.selectedCalendarDate = selected
    model.configure(repository: repository)

    #expect(await eventually { !model.isLoading })
    #expect(model.presentation?.boundary == day.boundary)
    #expect(model.presentation?.items.first(where: { $0.kind == .objectiveFact })?.occurredAt == latest.occurredAt)
    #expect(model.presentation?.items.map(\.kind).contains(.inferredActivity) == false)
  }

  @Test("Loads older SQLite-style pages without replacing the first page")
  func loadsOlderPage() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let selected = try #require(calendar.date(from: .init(year: 2024, month: 1, day: 2)))
    let day = try HistoricalTimelineModel.dayDescriptor(
      forCalendarDate: selected, calendar: calendar, boundary: .standard)
    let newer = try event(at: day.boundary.startsAt.addingTimeInterval(2_000))
    let older = try event(at: day.boundary.startsAt.addingTimeInterval(1_000))
    let cursor = ObjectiveEventPageCursor(occurredAt: newer.occurredAt, eventID: newer.id)
    let repository = HistoricalPageRepository(pages: [
      .init(events: [newer], nextCursor: cursor), .init(events: [older], nextCursor: nil),
    ])
    let model = HistoricalTimelineModel(calendar: calendar, now: { day.boundary.endsAt })
    model.selectedCalendarDate = selected
    model.configure(repository: repository)
    #expect(await eventually { !model.isLoading })
    #expect(model.canLoadOlder)

    model.loadOlder()
    #expect(await eventually { !model.isLoadingOlder })
    #expect(!model.canLoadOlder)
    #expect(model.presentation?.items.map(\.occurredAt).contains(older.occurredAt) == true)
  }

  @Test("Replays durable visual inference alongside the selected day's facts")
  func replaysDurableVisualInference() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let selected = try #require(calendar.date(from: .init(year: 2024, month: 1, day: 2)))
    let day = try HistoricalTimelineModel.dayDescriptor(
      forCalendarDate: selected, calendar: calendar, boundary: .standard)
    let repository = HistoricalPageRepository(pages: [.init(events: [], nextCursor: nil)])
    let visualRepository = HistoricalVisualRepository(observations: [
      try visualInference(at: day.boundary.startsAt.addingTimeInterval(60))
    ])
    let model = HistoricalTimelineModel(calendar: calendar, now: { day.boundary.endsAt })
    model.selectedCalendarDate = selected
    model.configure(repository: repository, visualInferenceRepository: visualRepository)

    #expect(await eventually { !model.isLoading })
    #expect(model.presentation?.items.contains(where: { $0.kind == .inferredActivity }) == true)
  }

  @Test("A stale cancelled date request cannot replace the new selection")
  func cancelsStaleSelection() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let first = try #require(calendar.date(from: .init(year: 2024, month: 1, day: 1)))
    let second = try #require(calendar.date(from: .init(year: 2024, month: 1, day: 2)))
    let repository = SuspendingHistoricalRepository()
    let model = HistoricalTimelineModel(calendar: calendar, now: { second })
    model.selectedCalendarDate = first
    model.configure(repository: repository)
    #expect(await eventually { await repository.started == 1 })

    model.selectedCalendarDate = second
    model.refresh()
    #expect(await eventually { await repository.cancelled == 1 })
    #expect(await eventually { !model.isLoading })
    let expectedDay = try HistoricalTimelineModel.dayDescriptor(
      forCalendarDate: second, calendar: calendar, boundary: .standard)
    #expect(model.presentation?.boundary.startsAt == expectedDay.boundary.startsAt)
  }

  @Test("Repository failures have an explicit failure presentation")
  func surfacesRepositoryFailure() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let model = HistoricalTimelineModel(calendar: calendar)
    model.configure(repository: FailingHistoricalRepository())
    #expect(await eventually { !model.isLoading })
    #expect(model.presentation?.state == .failure)
  }

  @Test("Future civil dates clamp to today before reading history")
  func futureSelectionClampsToCurrentCivilDate() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let current = try #require(calendar.date(from: .init(year: 2024, month: 1, day: 2, hour: 12)))
    let future = try #require(calendar.date(from: .init(year: 2024, month: 1, day: 3)))
    let repository = HistoricalPageRepository(pages: [.init(events: [], nextCursor: nil)])
    let model = HistoricalTimelineModel(calendar: calendar, now: { current })
    model.selectedCalendarDate = future
    model.configure(repository: repository)

    #expect(await eventually { !model.isLoading })
    #expect(model.selectedCalendarDate == calendar.startOfDay(for: current))
    let expectedDay = try HistoricalTimelineModel.dayDescriptor(
      forCalendarDate: current, calendar: calendar, boundary: .standard
    )
    #expect(model.presentation?.boundary == expectedDay.boundary)
  }

  @Test("Changing the owner schedule refreshes records with the new logical-day boundary")
  func updatesConfiguredBoundary() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let current = try #require(calendar.date(from: .init(year: 2024, month: 1, day: 2, hour: 12)))
    let repository = HistoricalPageRepository(pages: [
      .init(events: [], nextCursor: nil),
      .init(events: [], nextCursor: nil),
    ])
    let model = HistoricalTimelineModel(calendar: calendar, now: { current })
    model.configure(repository: repository)
    #expect(await eventually { !model.isLoading })

    model.updateWorkdayBoundary(try WorkdayBoundary(hour: 6))
    #expect(await eventually { !model.isLoading })
    #expect(model.presentation?.boundary.hour == 6)
  }

  private func event(at date: Date) throws -> ObjectiveEvent {
    try .init(
      id: .init(), kind: .stableStateObservation, occurredAt: date, timeZoneIdentifier: "UTC",
      source: .init(collector: .applicationWindowContext, collectorVersion: "1.0", payloadSchemaVersion: 1),
      securityDisposition: .allowed
    )
  }

  private func visualInference(at date: Date) throws -> VisibleContentObservation {
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let provenance = try VisibleContentProvenance(
      source: .init(
        collector: .screenUnderstanding,
        collectorVersion: "byok-screen-vision-v1",
        payloadSchemaVersion: 1
      ),
      observedAt: date,
      endedAt: date.addingTimeInterval(30),
      timeZoneIdentifier: "UTC",
      display: display
    )
    return try VisibleContentObservation(
      provenance: provenance,
      kind: .inference,
      redactionState: .noRedactionNeeded,
      text: "情境：查看历史回放\n可见交互：静态浏览\n类型：navigation\n置信度：0.90\n可见依据：\n- 时间线可见",
      inferenceOrigin: "byok-screen-vision-v1"
    )
  }
}

private actor HistoricalPageRepository: ObjectiveEventPageRepository {
  private var pages: [ObjectiveEventPage]
  init(pages: [ObjectiveEventPage]) { self.pages = pages }
  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult { .inserted }
  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] { [] }
  func fetchPage(occurredIn range: Range<Date>, before cursor: ObjectiveEventPageCursor?, limit: Int) async throws -> ObjectiveEventPage {
    pages.removeFirst()
  }
}

private actor SuspendingHistoricalRepository: ObjectiveEventPageRepository {
  var started = 0
  var cancelled = 0
  private var continuation: CheckedContinuation<Void, Never>?
  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult { .inserted }
  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] { [] }
  func fetchPage(occurredIn range: Range<Date>, before cursor: ObjectiveEventPageCursor?, limit: Int) async throws -> ObjectiveEventPage {
    started += 1
    guard started == 1 else { return .init(events: [], nextCursor: nil) }
    do {
      try await Task.sleep(for: .seconds(60))
    } catch {
      cancelled += 1
      return .init(events: [], nextCursor: nil)
    }
    return .init(events: [], nextCursor: nil)
  }
}

private actor FailingHistoricalRepository: ObjectiveEventPageRepository {
  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult { .inserted }
  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] { [] }
  func fetchPage(occurredIn range: Range<Date>, before cursor: ObjectiveEventPageCursor?, limit: Int) async throws -> ObjectiveEventPage { throw HistoricalTimelineError.invalidDay }
}

private actor HistoricalVisualRepository: VisibleContentArchiveRepository {
  let observations: [VisibleContentObservation]

  init(observations: [VisibleContentObservation]) { self.observations = observations }

  func insert(_ observation: VisibleContentObservation) async throws -> DeepCaptureInsertResult {
    .alreadyPresent
  }

  func fetchVisibleContent(observedIn range: Range<Date>) async throws
    -> [VisibleContentObservation]
  {
    observations.filter { range.contains($0.provenance.observedAt) }
  }
}

@MainActor
private func eventually(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
  for _ in 0..<500 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return false
}
