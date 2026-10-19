import DaydayCore
import Foundation

/// Reads a bounded historical replay. It never consults current display state,
/// journals, or reports; durable visual inferences are admitted only from the
/// selected workday so their evidence relationship stays intact.
@MainActor
final class HistoricalTimelineModel: ObservableObject {
  @Published private(set) var presentation: TodayTimelinePresentation?
  @Published var selectedCalendarDate: Date
  @Published private(set) var isLoading = false
  @Published private(set) var isLoadingOlder = false
  @Published private(set) var canLoadOlder = false
  @Published private(set) var loadOlderFailed = false

  private let calendar: Calendar
  private var boundary: WorkdayBoundary
  private let now: @Sendable () -> Date
  private var repository: (any ObjectiveEventPageRepository)?
  private var linkedRepository: (any ObjectiveLinkedRecordRepository)?
  private var visualInferenceRepository: (any VisibleContentArchiveRepository)?
  private var loadTask: Task<Void, Never>?
  private var generation = 0
  private var day: DayDescriptor?
  private var events: [ObjectiveEvent] = []
  private var contexts: [EventID: ApplicationContextRecord] = [:]
  private var collectorStates: [EventID: CollectorStateRecord] = [:]
  private var visualInferences: [VisibleContentObservation] = []
  private var cursor: ObjectiveEventPageCursor?

  private static let pageSize = 60

  init(
    calendar: Calendar = .autoupdatingCurrent,
    boundary: WorkdayBoundary = .standard,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.calendar = calendar
    self.boundary = boundary
    self.now = now
    selectedCalendarDate = now()
  }

  deinit { loadTask?.cancel() }

  var latestSelectableCalendarDate: Date {
    calendar.startOfDay(for: now())
  }

  func configure(
    repository: any ObjectiveEventPageRepository,
    linkedRepository: (any ObjectiveLinkedRecordRepository)? = nil,
    visualInferenceRepository: (any VisibleContentArchiveRepository)? = nil,
    boundary: WorkdayBoundary = .standard
  ) {
    self.repository = repository
    self.linkedRepository = linkedRepository ?? (repository as? any ObjectiveLinkedRecordRepository)
    self.visualInferenceRepository = visualInferenceRepository
    self.boundary = boundary
    refresh()
  }

  func updateWorkdayBoundary(_ boundary: WorkdayBoundary) {
    guard self.boundary != boundary else { return }
    self.boundary = boundary
    refresh()
  }

  func showCurrentDay() {
    let current = latestSelectableCalendarDate
    if selectedCalendarDate != current {
      selectedCalendarDate = current
    } else {
      refresh()
    }
  }

  func refresh() {
    guard let repository else { return }
    generation &+= 1
    let requestGeneration = generation
    loadTask?.cancel()
    isLoading = true
    isLoadingOlder = false
    canLoadOlder = false
    loadOlderFailed = false
    events = []
    contexts = [:]
    collectorStates = [:]
    visualInferences = []
    cursor = nil
    presentation = nil
    let selectedDate = min(selectedCalendarDate, latestSelectableCalendarDate)
    if selectedCalendarDate != selectedDate {
      selectedCalendarDate = selectedDate
    }
    let linkedRepository = linkedRepository
    let visualInferenceRepository = visualInferenceRepository
    let now = now()
    loadTask = Task { [weak self] in
      defer {
        if self?.generation == requestGeneration {
          self?.isLoading = false
          self?.loadTask = nil
        }
      }
      do {
        let day = try Self.dayDescriptor(
          forCalendarDate: selectedDate, calendar: self?.calendar ?? .autoupdatingCurrent,
          boundary: self?.boundary ?? .standard
        )
        async let page = repository.fetchPage(
          occurredIn: day.boundary.startsAt..<day.boundary.endsAt,
          before: nil,
          limit: Self.pageSize
        )
        let visualInferences: [VisibleContentObservation]
        if let visualInferenceRepository {
          visualInferences = (try? await visualInferenceRepository.fetchVisibleContent(
            observedIn: day.boundary.startsAt..<day.boundary.endsAt
          )) ?? []
        } else {
          visualInferences = []
        }
        let loadedPage = try await page
        let contexts = try await Self.fetchContexts(for: loadedPage.events, from: linkedRepository)
        let collectorStates = try await Self.fetchCollectorStates(
          for: loadedPage.events, from: linkedRepository)
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        self?.day = day
        self?.events = loadedPage.events
        self?.contexts = contexts
        self?.collectorStates = collectorStates
        self?.visualInferences = visualInferences
        self?.cursor = loadedPage.nextCursor
        self?.canLoadOlder = loadedPage.nextCursor != nil
        self?.publish(day: day, now: now)
      } catch {
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        if let day = try? Self.dayDescriptor(
          forCalendarDate: selectedDate, calendar: self?.calendar ?? .autoupdatingCurrent,
          boundary: self?.boundary ?? .standard
        ) {
          self?.presentation = TodayTimelinePresentationAdapter.make(
            day: day, events: [], now: now, fetchState: .failure, runtime: .unknown
          )
        }
      }
    }
  }

  func loadOlder() {
    guard let repository, let day, let cursor, loadTask == nil, canLoadOlder else { return }
    let requestGeneration = generation
    let linkedRepository = linkedRepository
    let now = now()
    isLoadingOlder = true
    loadOlderFailed = false
    loadTask = Task { [weak self] in
      defer {
        if self?.generation == requestGeneration {
          self?.isLoadingOlder = false
          self?.loadTask = nil
        }
      }
      do {
        let page = try await repository.fetchPage(
          occurredIn: day.boundary.startsAt..<day.boundary.endsAt,
          before: cursor,
          limit: Self.pageSize
        )
        let contexts = try await Self.fetchContexts(for: page.events, from: linkedRepository)
        let collectorStates = try await Self.fetchCollectorStates(
          for: page.events, from: linkedRepository)
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        self?.events.append(contentsOf: page.events)
        self?.contexts.merge(contexts) { _, newer in newer }
        self?.collectorStates.merge(collectorStates) { _, newer in newer }
        self?.cursor = page.nextCursor
        self?.canLoadOlder = page.nextCursor != nil
        self?.publish(day: day, now: now)
      } catch {
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        self?.loadOlderFailed = true
      }
    }
  }

  private func publish(day: DayDescriptor, now: Date) {
    presentation = TodayTimelinePresentationAdapter.make(
      day: day, events: events, applicationContexts: contexts,
      collectorStates: collectorStates, visualInferences: visualInferences, now: now,
      fetchState: .loaded, runtime: .unknown
    )
  }

  private static func fetchContexts(
    for events: [ObjectiveEvent], from repository: (any ObjectiveLinkedRecordRepository)?
  ) async throws -> [EventID: ApplicationContextRecord] {
    guard let repository else { return [:] }
    var results: [EventID: ApplicationContextRecord] = [:]
    for event in events
    where event.kind == .applicationContextChanged && event.securityDisposition == .allowed {
      if let context = try await repository.fetchApplicationContext(for: event.id) {
        results[event.id] = context
      }
    }
    return results
  }

  private static func fetchCollectorStates(
    for events: [ObjectiveEvent], from repository: (any ObjectiveLinkedRecordRepository)?
  ) async throws -> [EventID: CollectorStateRecord] {
    guard let repository else { return [:] }
    var results: [EventID: CollectorStateRecord] = [:]
    for event in events
    where event.kind == .collectorStateTransition && event.securityDisposition == .allowed {
      if let state = try await repository.fetchCollectorState(for: event.id) {
        results[event.id] = state
      }
    }
    return results
  }

  static func dayDescriptor(
    forCalendarDate date: Date, calendar: Calendar, boundary: WorkdayBoundary
  ) throws -> DayDescriptor {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day,
      let midnight = calendar.date(from: DateComponents(year: year, month: month, day: day)),
      let probe = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: midnight),
      let start = try? boundary.start(containing: probe, calendar: calendar),
      let nextDate = calendar.date(byAdding: .day, value: 1, to: midnight),
      let nextProbe = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: nextDate),
      let end = try? boundary.start(containing: nextProbe, calendar: calendar)
    else { throw HistoricalTimelineError.invalidDay }
    return try DayDescriptor(
      logicalDate: .init(year: year, month: month, day: day),
      timeZoneIdentifier: calendar.timeZone.identifier,
      boundary: .init(hour: boundary.hour, startsAt: start, endsAt: end)
    )
  }
}

enum HistoricalTimelineError: Error { case invalidDay }
