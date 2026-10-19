import DaydayCore
import Foundation

/// A compact, objective-only time distribution for the menu-bar popover. It
/// counts saved observations; a taller column never claims more focus,
/// productivity, or elapsed work time.
enum MenuBarTimelineRange: String, CaseIterable, Identifiable {
  case recentNinetyMinutes
  case today
  case week
  case month

  var id: Self { self }

  var title: String {
    switch self {
    case .recentNinetyMinutes: "90 分钟"
    case .today: "今日"
    case .week: "本周"
    case .month: "本月"
    }
  }

  var chartTitle: String {
    switch self {
    case .recentNinetyMinutes: "最近 90 分钟"
    case .today: "今日记录分布"
    case .week: "最近 7 个工作日"
    case .month: "最近 30 个工作日"
    }
  }

  var chartHeight: CGFloat {
    96
  }

  var popoverSize: CGSize {
    .init(width: 420, height: 620)
  }

  func axisLabel(for date: Date, calendar: Calendar) -> String {
    switch self {
    case .recentNinetyMinutes, .today:
      return date.formatted(date: .omitted, time: .shortened)
    case .week:
      let weekday = calendar.component(.weekday, from: date)
      return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][weekday - 1]
    case .month:
      return date.formatted(.dateTime.month().day())
    }
  }

  func requestRange(
    now: Date,
    calendar: Calendar,
    boundary: WorkdayBoundary = .standard
  ) -> Range<Date> {
    switch self {
    case .recentNinetyMinutes:
      return now.addingTimeInterval(-90 * 60)..<now
    case .today, .week, .month:
      let dayStart = (try? boundary.start(containing: now, calendar: calendar))
        ?? calendar.startOfDay(for: now)
      let precedingDays: Int
      switch self {
      case .today: precedingDays = 0
      case .week: precedingDays = 6
      case .month: precedingDays = 29
      case .recentNinetyMinutes: precedingDays = 0
      }
      let start = calendar.date(byAdding: .day, value: -precedingDays, to: dayStart) ?? dayStart
      return start..<now
    }
  }

  fileprivate func bucketStarts(in range: Range<Date>, calendar: Calendar) -> [Date] {
    let interval: TimeInterval
    let count: Int
    switch self {
    case .recentNinetyMinutes:
      interval = 5 * 60
      count = 18
    case .today:
      interval = 60 * 60
      count = max(1, Int(ceil(range.upperBound.timeIntervalSince(range.lowerBound) / interval)))
    case .week:
      interval = 24 * 60 * 60
      count = 7
    case .month:
      interval = 24 * 60 * 60
      count = 30
    }
    return (0..<count).compactMap { index in
      switch self {
      case .week, .month:
        calendar.date(byAdding: .day, value: index, to: range.lowerBound)
      case .recentNinetyMinutes, .today:
        range.lowerBound.addingTimeInterval(Double(index) * interval)
      }
    }
  }
}

struct MenuBarTimelineBucket: Identifiable, Equatable {
  let startedAt: Date
  let endedAt: Date
  let screenObservationCount: Int
  let applicationObservationCount: Int
  let otherObservationCount: Int

  var id: Date { startedAt }
  var objectiveObservationCount: Int {
    screenObservationCount + applicationObservationCount + otherObservationCount
  }
}

struct MenuBarTimelinePresentation: Equatable {
  enum State: Equatable { case loading, empty, populated, failure }

  let state: State
  let range: MenuBarTimelineRange
  let buckets: [MenuBarTimelineBucket]
  let rangeStart: Date
  let rangeEnd: Date

  var totalObservationCount: Int {
    buckets.reduce(0) { $0 + $1.objectiveObservationCount }
  }

  var maximumBucketCount: Int {
    max(1, buckets.map(\.objectiveObservationCount).max() ?? 0)
  }

  var screenObservationCount: Int {
    buckets.reduce(0) { $0 + $1.screenObservationCount }
  }

  var applicationObservationCount: Int {
    buckets.reduce(0) { $0 + $1.applicationObservationCount }
  }

  var otherObservationCount: Int {
    buckets.reduce(0) { $0 + $1.otherObservationCount }
  }
}

enum MenuBarTimelinePresentationAdapter {
  static func make(
    events: [ObjectiveEvent],
    range: MenuBarTimelineRange,
    now: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> MenuBarTimelinePresentation {
    let requestedRange = range.requestRange(now: now, calendar: calendar)
    let starts = range.bucketStarts(in: requestedRange, calendar: calendar)
    guard !starts.isEmpty else {
      return .init(
        state: .empty, range: range, buckets: [], rangeStart: requestedRange.lowerBound,
        rangeEnd: requestedRange.upperBound)
    }

    var counts = Array(repeating: (screen: 0, application: 0, other: 0), count: starts.count)
    for event in events where isVisibleObservation(event) && requestedRange.contains(event.occurredAt) {
      guard let index = bucketIndex(for: event.occurredAt, starts: starts) else {
        continue
      }
      switch event.source.collector {
      case .screenUnderstanding:
        counts[index].screen += 1
      case .applicationWindowContext, .chromeContext:
        counts[index].application += 1
      default:
        counts[index].other += 1
      }
    }

    let buckets = starts.enumerated().map { index, start in
      let next = index + 1 < starts.count ? starts[index + 1] : requestedRange.upperBound
      return MenuBarTimelineBucket(
        startedAt: start,
        endedAt: max(start, next),
        screenObservationCount: counts[index].screen,
        applicationObservationCount: counts[index].application,
        otherObservationCount: counts[index].other
      )
    }
    return .init(
      state: buckets.contains(where: { $0.objectiveObservationCount > 0 }) ? .populated : .empty,
      range: range,
      buckets: buckets,
      rangeStart: requestedRange.lowerBound,
      rangeEnd: requestedRange.upperBound
    )
  }

  private static func isVisibleObservation(_ event: ObjectiveEvent) -> Bool {
    guard event.securityDisposition == .allowed else { return false }
    return event.kind != .collectorStateTransition && event.kind != .systemBoundary
  }

  private static func bucketIndex(for date: Date, starts: [Date]) -> Int? {
    guard let first = starts.first, date >= first else { return nil }
    for index in starts.indices.reversed() where date >= starts[index] {
      return index
    }
    return nil
  }
}

@MainActor
final class MenuBarTimelineModel: ObservableObject {
  @Published private(set) var presentation = MenuBarTimelinePresentation(
    state: .empty,
    range: .recentNinetyMinutes,
    buckets: [],
    rangeStart: .now,
    rangeEnd: .now
  )
  @Published private(set) var isLoading = false

  private struct CachedEvents {
    let loadedAt: Date
    let events: [ObjectiveEvent]
  }

  private let now: @Sendable () -> Date
  private var repository: (any ObjectiveEventRepository)?
  private var cache: [MenuBarTimelineRange: CachedEvents] = [:]
  private var refreshTask: Task<Void, Never>?
  private var generation = 0
  private var workdayBoundary = WorkdayBoundary.standard

  init(now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
  }

  deinit { refreshTask?.cancel() }

  func configure(
    repository: any ObjectiveEventRepository,
    workdayBoundary: WorkdayBoundary = .standard
  ) {
    self.repository = repository
    self.workdayBoundary = workdayBoundary
  }

  func updateWorkdayBoundary(_ boundary: WorkdayBoundary) {
    guard workdayBoundary != boundary else { return }
    workdayBoundary = boundary
    cache.removeAll()
  }

  func refresh(range: MenuBarTimelineRange) {
    // Treat selecting a cached range as a new request too. An old disk read
    // must not be allowed to publish after the user has selected another
    // range, even when that new range was immediately available from cache.
    generation &+= 1
    let requestGeneration = generation
    refreshTask?.cancel()
    let capturedNow = now()
    let calendar = Calendar.autoupdatingCurrent
    if let cached = cache[range], capturedNow.timeIntervalSince(cached.loadedAt) < 45 {
      presentation = MenuBarTimelinePresentationAdapter.make(
        events: cached.events, range: range, now: capturedNow, calendar: calendar)
      isLoading = false
      return
    }
    guard let repository else {
      presentation = .init(
        state: .empty, range: range, buckets: [], rangeStart: capturedNow, rangeEnd: capturedNow)
      isLoading = false
      return
    }

    isLoading = true
    let requestedRange = range.requestRange(
      now: capturedNow,
      calendar: calendar,
      boundary: workdayBoundary
    )
    refreshTask = Task { [weak self] in
      defer {
        if self?.generation == requestGeneration {
          self?.isLoading = false
          self?.refreshTask = nil
        }
      }
      do {
        let events = try await repository.fetch(occurredIn: requestedRange)
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        self?.cache[range] = .init(loadedAt: capturedNow, events: events)
        self?.presentation = MenuBarTimelinePresentationAdapter.make(
          events: events, range: range, now: capturedNow, calendar: calendar)
      } catch {
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        self?.presentation = .init(
          state: .failure, range: range, buckets: [], rangeStart: requestedRange.lowerBound,
          rangeEnd: requestedRange.upperBound)
      }
    }
  }
}
