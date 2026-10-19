import DaydayCapture
import DaydayCore
import DaydayStorage
import Foundation

/// Compact input totals for the menu-bar surface. Every value is derived from
/// already-coarsened aggregates; this type contains no input content, order,
/// raw pointer points, or per-application input attribution.
struct MenuBarInputSummaryPresentation: Equatable {
  let keyPressCount: UInt64
  let keyboardCounts: [UInt16: UInt64]
  let clickCount: UInt64
  let scrollActionCount: UInt64
  let scrollMagnitude: UInt64
  let hasLegacyScrollMagnitude: Bool
  let pointerDisplay: PointerHeatmapPresentation?

  static func make(
    aggregates: [InputAggregate],
    pointerDisplays: [PointerHeatmapPresentation]
  ) -> MenuBarInputSummaryPresentation {
    let summary = InputMetricSummary.make(from: aggregates)
    return MenuBarInputSummaryPresentation(
      keyPressCount: summary.keyPressCount,
      keyboardCounts: keyboardCounts(from: aggregates),
      clickCount: summary.clickCount,
      scrollActionCount: summary.scrollActionCount,
      scrollMagnitude: summary.scrollMagnitude,
      hasLegacyScrollMagnitude: summary.hasLegacyScrollMagnitude,
      pointerDisplay: pointerDisplays.first
    )
  }

  private static func keyboardCounts(from aggregates: [InputAggregate]) -> [UInt16: UInt64] {
    aggregates.reduce(into: [:]) { result, aggregate in
      for key in aggregate.physicalKeyCounts {
        let existing = result[key.hardwareKeyCode, default: 0]
        let merged = existing.addingReportingOverflow(key.count)
        result[key.hardwareKeyCode] = merged.overflow ? UInt64.max : merged.partialValue
      }
    }
  }
}

struct MenuBarInsightsPresentation: Equatable {
  enum State: Equatable { case loading, empty, populated, failure }

  let state: State
  let input: MenuBarInputSummaryPresentation
  let applications: [ApplicationUsagePresentation.Summary]
  let applicationSwitchCount: Int
  let hasIncompleteForegroundFacts: Bool

  static let empty = MenuBarInsightsPresentation(
    state: .empty,
    input: .make(aggregates: [], pointerDisplays: []),
    applications: [],
    applicationSwitchCount: 0,
    hasIncompleteForegroundFacts: false
  )

  func replacingInput(
    _ input: MenuBarInputSummaryPresentation,
    inputIsEmpty: Bool
  ) -> MenuBarInsightsPresentation {
    MenuBarInsightsPresentation(
      state: inputIsEmpty && applications.isEmpty ? .empty : .populated,
      input: input,
      applications: applications,
      applicationSwitchCount: applicationSwitchCount,
      hasIncompleteForegroundFacts: hasIncompleteForegroundFacts
    )
  }
}

/// Independent menu-bar read model. It deliberately keeps its selected range
/// and short cache separate from InsightsView, so opening the status popover
/// never changes the main window's filters or reuses a mismatched projection.
@MainActor
final class MenuBarInsightsModel: ObservableObject {
  @Published private(set) var presentation = MenuBarInsightsPresentation.empty
  @Published private(set) var isLoading = false

  private struct CachedPresentation {
    let loadedAt: Date
    let value: MenuBarInsightsPresentation
  }

  private let now: @Sendable () -> Date
  private var inputRepository: SQLiteInputAggregateRepository?
  private var objectiveRepository: SQLiteObjectiveEventRepository?
  private weak var inputRuntime: InputCollectionRuntime?
  private var cache: [MenuBarTimelineRange: CachedPresentation] = [:]
  private var storedInputAggregates: [MenuBarTimelineRange: [InputAggregate]] = [:]
  private var refreshTask: Task<Void, Never>?
  private var generation = 0
  private var visibleRange: MenuBarTimelineRange?
  private var workdayBoundary = WorkdayBoundary.standard

  init(now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
  }

  deinit { refreshTask?.cancel() }

  func configure(
    inputRepository: SQLiteInputAggregateRepository,
    objectiveRepository: SQLiteObjectiveEventRepository,
    inputRuntime: InputCollectionRuntime,
    workdayBoundary: WorkdayBoundary = .standard
  ) {
    self.inputRepository = inputRepository
    self.objectiveRepository = objectiveRepository
    self.inputRuntime = inputRuntime
    self.workdayBoundary = workdayBoundary
  }

  func updateWorkdayBoundary(_ boundary: WorkdayBoundary) {
    guard workdayBoundary != boundary else { return }
    workdayBoundary = boundary
    cache.removeAll()
    storedInputAggregates.removeAll()
  }

  func refresh(range: MenuBarTimelineRange) {
    visibleRange = range
    // A cache hit is still a new selection. Invalidate any outstanding read
    // before returning cached content; otherwise an older range can finish
    // later and overwrite the popover while its segmented control already
    // shows the newly selected range.
    generation &+= 1
    let requestGeneration = generation
    refreshTask?.cancel()
    let capturedNow = now()
    if let cached = cache[range], capturedNow.timeIntervalSince(cached.loadedAt) < 45 {
      presentation = cached.value
      isLoading = false
      return
    }
    guard let inputRepository, let objectiveRepository else {
      presentation = .empty
      isLoading = false
      return
    }

    isLoading = true
    presentation = .init(
      state: .loading,
      input: .make(aggregates: [], pointerDisplays: []),
      applications: [],
      applicationSwitchCount: 0,
      hasIncompleteForegroundFacts: false
    )
    let calendar = Calendar.autoupdatingCurrent
    let requestedRange = range.requestRange(
      now: capturedNow,
      calendar: calendar,
      boundary: workdayBoundary
    )
    let runtime = inputRuntime

    refreshTask = Task { [weak self] in
      defer {
        if self?.generation == requestGeneration {
          self?.isLoading = false
          self?.refreshTask = nil
        }
      }
      do {
        async let finalized = inputRepository.fetch(startingIn: requestedRange)
        async let checkpoints = inputRepository.openCheckpoints()
        async let events = objectiveRepository.fetch(occurredIn: requestedRange)
        let stored = try await finalized + checkpoints.map(\.aggregate)
        let eventValues = try await events
        let contexts = try await ApplicationUsageInsightsModel.fetchContexts(
          for: eventValues, repository: objectiveRepository)
        let liveValues: [InputAggregate]
        if let runtime {
          liveValues = try await runtime.liveAggregates()
        } else {
          liveValues = []
        }
        let live = liveValues.filter {
          $0.period.end > requestedRange.lowerBound && $0.period.start <= capturedNow
        }
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        let inputSnapshot = await Task.detached(priority: .utility) {
          InputInsightsPresentationBuilder.makeRangeSnapshot(stored: stored, live: live)
        }.value
        let application = ApplicationUsagePresentationAdapter.make(
          events: eventValues,
          applicationContexts: contexts,
          range: requestedRange,
          now: capturedNow
        )
        let value = MenuBarInsightsPresentation(
          state: Self.presentationState(inputSnapshot: inputSnapshot, application: application),
          input: MenuBarInputSummaryPresentation.make(
            aggregates: inputSnapshot.aggregates, pointerDisplays: inputSnapshot.pointerDisplays),
          applications: Array(application.summaries.prefix(10)),
          applicationSwitchCount: application.applicationSwitchCount,
          hasIncompleteForegroundFacts: application.hasIncompleteForegroundFacts
        )
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        self?.storedInputAggregates[range] = stored
        self?.cache[range] = .init(loadedAt: capturedNow, value: value)
        self?.presentation = value
      } catch {
        guard !Task.isCancelled, self?.generation == requestGeneration else { return }
        self?.presentation = .init(
          state: .failure,
          input: .make(aggregates: [], pointerDisplays: []),
          applications: [],
          applicationSwitchCount: 0,
          hasIncompleteForegroundFacts: false
        )
      }
    }
  }

  /// A durable system foreground switch arrived. The normal 45-second cache is
  /// intentionally bypassed for the currently visible popover range only.
  func foregroundFactsDidChange() {
    guard let visibleRange else { return }
    cache[visibleRange] = nil
    refresh(range: visibleRange)
  }

  /// Keeps the visible menu-bar key/mouse summary live without repeating the
  /// application-context or objective-event queries. Capture has already
  /// coalesced raw callbacks before this content-free invalidation arrives.
  func presentLiveInput(range: MenuBarTimelineRange) async {
    guard let runtime = inputRuntime else { return }
    var isInitialSnapshot = true
    for await _ in runtime.statusUpdates() {
      guard !Task.isCancelled else { return }
      if isInitialSnapshot {
        isInitialSnapshot = false
      } else {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
      }
      await refreshLiveInput(range: range, runtime: runtime)
    }
  }

  private func refreshLiveInput(
    range: MenuBarTimelineRange,
    runtime: InputCollectionRuntime
  ) async {
    // A cancelled SwiftUI task may already be between awaits when the user
    // changes the segmented control. It must never publish its old range into
    // the newly selected popover.
    guard visibleRange == range, let stored = storedInputAggregates[range] else { return }
    let capturedNow = now()
    let requestedRange = range.requestRange(
      now: capturedNow,
      calendar: .autoupdatingCurrent,
      boundary: workdayBoundary
    )
    do {
      let live = try await runtime.liveAggregates().filter {
        $0.period.end > requestedRange.lowerBound
          && $0.period.start < requestedRange.upperBound
      }
      guard !Task.isCancelled, visibleRange == range else { return }
      let snapshot = await Task.detached(priority: .utility) {
        InputInsightsPresentationBuilder.makeRangeSnapshot(stored: stored, live: live)
      }.value
      guard !Task.isCancelled, visibleRange == range else { return }
      let input = MenuBarInputSummaryPresentation.make(
        aggregates: snapshot.aggregates,
        pointerDisplays: snapshot.pointerDisplays
      )
      let value = presentation.replacingInput(
        input,
        inputIsEmpty: snapshot.aggregates.isEmpty
      )
      if let cached = cache[range] {
        cache[range] = .init(loadedAt: cached.loadedAt, value: value)
      }
      guard visibleRange == range else { return }
      presentation = value
    } catch {
      // A live read is best-effort. Keep the last complete presentation; the
      // ordinary refresh remains responsible for exposing repository failure.
    }
  }

  private static func presentationState(
    inputSnapshot: InputRangePresentationSnapshot,
    application: ApplicationUsagePresentation
  ) -> MenuBarInsightsPresentation.State {
    if !inputSnapshot.aggregates.isEmpty || !application.summaries.isEmpty { return .populated }
    return .empty
  }
}
