import Combine
import DaydayCapture
import DaydayCore
import DaydayUnderstanding
import Foundation

enum AppRuntimePermissionState: String, Sendable, Equatable {
  case unknown
  case authorized
  case notAuthorized

  init(_ state: CaptureAuthorizationPreflightState) {
    switch state {
    case .authorized:
      self = .authorized
    case .notAuthorized:
      self = .notAuthorized
    }
  }
}

enum AppRuntimeDisplayInventoryState: Sendable, Equatable {
  case unknown
  case available
  case unavailable
}

struct AppRuntimeDisplay: Identifiable, Sendable, Equatable {
  let id: UInt32
  let logicalWidth: Double
  let logicalHeight: Double
  let pixelWidth: Int?
  let pixelHeight: Int?
  let rotationDegrees: Double
  let isMain: Bool
  let isBuiltIn: Bool
  let isMirrored: Bool

  init(_ descriptor: DisplayDescriptor) {
    id = descriptor.runtimeID
    logicalWidth = descriptor.bounds.width
    logicalHeight = descriptor.bounds.height
    pixelWidth = descriptor.pixelSize?.width
    pixelHeight = descriptor.pixelSize?.height
    rotationDegrees = descriptor.rotationDegrees
    isMain = descriptor.isMain
    isBuiltIn = descriptor.isBuiltIn
    isMirrored = descriptor.mirrorSourceRuntimeID != nil
  }
}

struct AppRuntimeSnapshot: Sendable, Equatable {
  let screenRecording: AppRuntimePermissionState
  let accessibility: AppRuntimePermissionState
  let displayInventoryState: AppRuntimeDisplayInventoryState
  let displays: [AppRuntimeDisplay]
  let checkedAt: Date?

  static let unknown = AppRuntimeSnapshot(
    screenRecording: .unknown,
    accessibility: .unknown,
    displayInventoryState: .unknown,
    displays: [],
    checkedAt: nil
  )

  static let previewAuthorized = AppRuntimeSnapshot(
    screenRecording: .authorized,
    accessibility: .authorized,
    displayInventoryState: .available,
    displays: [
      AppRuntimeDisplay(
        id: 1,
        logicalWidth: 1_920,
        logicalHeight: 1_080,
        pixelWidth: 3_840,
        pixelHeight: 2_160,
        rotationDegrees: 0,
        isMain: true,
        isBuiltIn: false,
        isMirrored: false
      ),
      AppRuntimeDisplay(
        id: 2,
        logicalWidth: 1_512,
        logicalHeight: 982,
        pixelWidth: 3_024,
        pixelHeight: 1_964,
        rotationDegrees: 0,
        isMain: false,
        isBuiltIn: true,
        isMirrored: false
      ),
    ],
    checkedAt: Date(timeIntervalSinceReferenceDate: 0)
  )

  static let previewPermissionRequired = AppRuntimeSnapshot(
    screenRecording: .notAuthorized,
    accessibility: .notAuthorized,
    displayInventoryState: .available,
    displays: [],
    checkedAt: Date(timeIntervalSinceReferenceDate: 0)
  )
}

extension AppRuntimeDisplay {
  init(
    id: UInt32,
    logicalWidth: Double,
    logicalHeight: Double,
    pixelWidth: Int?,
    pixelHeight: Int?,
    rotationDegrees: Double,
    isMain: Bool,
    isBuiltIn: Bool,
    isMirrored: Bool
  ) {
    self.id = id
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.rotationDegrees = rotationDegrees
    self.isMain = isMain
    self.isBuiltIn = isBuiltIn
    self.isMirrored = isMirrored
  }
}

protocol AppRuntimeSnapshotProviding: Sendable {
  func snapshot(at date: Date) async -> AppRuntimeSnapshot
}

struct AppRuntimeSchedule: Sendable {
  let now: @Sendable () -> Date
  let sleep: @Sendable (Duration) async throws -> Void

  static let live = AppRuntimeSchedule(
    now: Date.init,
    sleep: { duration in
      try await Task.sleep(for: duration)
    }
  )
}

struct LiveAppRuntimeSnapshotProvider: AppRuntimeSnapshotProviding {
  private let authorizationPreflight: any CaptureAuthorizationPreflighting
  private let displayInventory: any DisplayInventoryProviding

  init(
    authorizationPreflight: any CaptureAuthorizationPreflighting =
      MacOSCaptureAuthorizationPreflight(),
    displayInventory: any DisplayInventoryProviding = CoreGraphicsDisplayInventory()
  ) {
    self.authorizationPreflight = authorizationPreflight
    self.displayInventory = displayInventory
  }

  /// This async, nonisolated boundary keeps synchronous platform metadata reads off MainActor.
  func snapshot(at date: Date) async -> AppRuntimeSnapshot {
    let authorization = authorizationPreflight.snapshot(at: date)

    do {
      let displays = try displayInventory.onlineDisplays()
        .map(AppRuntimeDisplay.init)
        .sorted { lhs, rhs in
          if lhs.isMain != rhs.isMain { return lhs.isMain }
          return lhs.id < rhs.id
        }

      return AppRuntimeSnapshot(
        screenRecording: AppRuntimePermissionState(authorization.screenRecording),
        accessibility: AppRuntimePermissionState(authorization.accessibility),
        displayInventoryState: .available,
        displays: displays,
        checkedAt: authorization.checkedAt
      )
    } catch {
      return AppRuntimeSnapshot(
        screenRecording: AppRuntimePermissionState(authorization.screenRecording),
        accessibility: AppRuntimePermissionState(authorization.accessibility),
        displayInventoryState: .unavailable,
        displays: [],
        checkedAt: authorization.checkedAt
      )
    }
  }
}

struct PreviewAppRuntimeSnapshotProvider: AppRuntimeSnapshotProviding {
  let value: AppRuntimeSnapshot

  func snapshot(at date: Date) async -> AppRuntimeSnapshot {
    AppRuntimeSnapshot(
      screenRecording: value.screenRecording,
      accessibility: value.accessibility,
      displayInventoryState: value.displayInventoryState,
      displays: value.displays,
      checkedAt: date
    )
  }
}

@MainActor
final class AppRuntimeModel: ObservableObject {
  enum CollectionStatus: Equatable {
    case checking
    case notConfigured
    case starting
    case running
    case paused
    case permissionRequired
    case disabled
    case degraded
    case failed
  }

  @Published private(set) var snapshot: AppRuntimeSnapshot
  @Published private(set) var isRefreshing = false
  @Published private(set) var h1Snapshot: H1CollectionRuntimeSnapshot?
  @Published private(set) var todayTimeline: TodayTimelinePresentation?
  @Published private(set) var isRefreshingTodayTimeline = false
  @Published private(set) var isLoadingOlderTodayTimeline = false
  @Published private(set) var canLoadOlderTodayTimeline = false
  @Published private(set) var todayTimelineLoadMoreFailed = false

  private let provider: any AppRuntimeSnapshotProviding
  private let schedule: AppRuntimeSchedule
  private let refreshInterval: Duration
  private var logicalDayBoundary = WorkdayBoundary.standard
  private var collectionGateRefresher: (@Sendable () async -> Void)?
  private var monitoringTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var todayRepository: (any ObjectiveEventRepository)?
  private var todayPageRepository: (any ObjectiveEventPageRepository)?
  private var todayVisualInferenceRepository: (any VisibleContentArchiveRepository)?
  private var todayUnderstandingPipeline: ObjectiveUnderstandingPipeline?
  private var applicationContextFetcher:
    (@Sendable (EventID) async throws -> ApplicationContextRecord?)?
  private var collectorStateFetcher: (@Sendable (EventID) async throws -> CollectorStateRecord?)?
  private var todayTimelineTask: Task<Void, Never>?
  private var todayTimelineVisible = true
  private var todayTimelineGeneration = 0
  private var pendingTodayTimelineRefresh = false
  private var loadedTodayTimelineEvents: [ObjectiveEvent] = []
  private var loadedTodayApplicationContexts: [EventID: ApplicationContextRecord] = [:]
  private var loadedTodayCollectorStates: [EventID: CollectorStateRecord] = [:]
  private var loadedTodayVisualInferences: [VisibleContentObservation] = []
  private var loadedTodayUnderstanding: ObjectiveUnderstandingSnapshot?
  private var loadedTodayUnderstandingRevision: UInt64?
  private var todayTimelineDay: DayDescriptor?
  private var olderTimelineCursor: ObjectiveEventPageCursor?
  /// Fetch a small objective-event buffer so presentation can skip collector noise and still
  /// render its compact latest-first window. `TodayTimelineWindow` retains the 10-item UI limit.
  private static let todayTimelinePageSize = 60

  init(
    provider: any AppRuntimeSnapshotProviding = LiveAppRuntimeSnapshotProvider(),
    initialSnapshot: AppRuntimeSnapshot = .unknown,
    schedule: AppRuntimeSchedule = .live,
    refreshInterval: Duration = .seconds(30)
  ) {
    self.provider = provider
    snapshot = initialSnapshot
    self.schedule = schedule
    self.refreshInterval = refreshInterval
  }

  deinit {
    monitoringTask?.cancel()
    refreshTask?.cancel()
    todayTimelineTask?.cancel()
  }

  var collectionStatus: CollectionStatus {
    if let h1Snapshot {
      switch h1Snapshot.status {
      case .idle, .stopped:
        return .notConfigured
      case .starting, .holdingNegativeControl:
        return .starting
      case .running:
        return .running
      case .waitingForAuthorization:
        // The platform snapshot is newer than the H1 status while a gate
        // refresh is in flight. Never render a permission warning beside two
        // currently authorized permission badges.
        if snapshot.screenRecording == .authorized,
          snapshot.accessibility == .authorized
        {
          return .starting
        }
        return .permissionRequired
      case .disabled:
        return .disabled
      case .pausedByUser, .paused:
        return .paused
      case .degraded:
        return .degraded
      case .failed:
        return .failed
      }
    }
    guard snapshot.screenRecording != .unknown,
      snapshot.accessibility != .unknown
    else {
      return .checking
    }

    guard snapshot.screenRecording == .authorized,
      snapshot.accessibility == .authorized
    else {
      return .permissionRequired
    }

    // Authorization is only a prerequisite. No collector has been started in this slice.
    return .notConfigured
  }

  func applyH1Snapshot(_ snapshot: H1CollectionRuntimeSnapshot) {
    let shouldRefresh = h1Snapshot?.historyRevision != snapshot.historyRevision
    h1Snapshot = snapshot
    if shouldRefresh { refreshTodayTimeline() }
  }

  func setCollectionGateRefresher(
    _ refresher: (@Sendable () async -> Void)?
  ) {
    collectionGateRefresher = refresher
  }

  func reportProductionBootstrapFailure() {
    h1Snapshot = H1CollectionRuntimeSnapshot(
      status: .failed(.storageUnavailable),
      historyRevision: 0
    )
  }

  func configureToday(
    repository: any ObjectiveEventRepository,
    visualInferenceRepository: (any VisibleContentArchiveRepository)? = nil
  ) {
    todayRepository = repository
    todayPageRepository = repository as? any ObjectiveEventPageRepository
    todayVisualInferenceRepository = visualInferenceRepository
    if let linkedRepository = repository as? any ObjectiveLinkedRecordRepository {
      todayUnderstandingPipeline = ObjectiveUnderstandingPipeline(repository: linkedRepository)
      applicationContextFetcher = { eventID in
        try await linkedRepository.fetchApplicationContext(for: eventID)
      }
      collectorStateFetcher = { eventID in
        try await linkedRepository.fetchCollectorState(for: eventID)
      }
    } else {
      todayUnderstandingPipeline = nil
      applicationContextFetcher = nil
      collectorStateFetcher = nil
    }
    resetTodayTimelinePaging()
    refreshTodayTimeline()
  }

  func updateLogicalDayBoundary(_ boundary: WorkdayBoundary) {
    guard logicalDayBoundary != boundary else { return }
    logicalDayBoundary = boundary
    resetTodayTimelinePaging()
    refreshTodayTimeline()
  }

  func refreshTodayTimeline() {
    guard todayTimelineVisible, let todayRepository else {
      pendingTodayTimelineRefresh = true
      return
    }
    guard todayTimelineTask == nil else {
      pendingTodayTimelineRefresh = true
      return
    }
    let generation = todayTimelineGeneration
    isRefreshingTodayTimeline = true
    todayTimelineLoadMoreFailed = false
    let now = schedule.now()
    let runtimeSnapshot = snapshot
    let pageRepository = todayPageRepository
    let applicationContextFetcher = applicationContextFetcher
    let collectorStateFetcher = collectorStateFetcher
    let visualInferenceRepository = todayVisualInferenceRepository
    let understandingPipeline = todayUnderstandingPipeline
    let cachedUnderstanding = loadedTodayUnderstanding
    let cachedUnderstandingDay = todayTimelineDay
    let cachedUnderstandingRevision = loadedTodayUnderstandingRevision
    let currentHistoryRevision = h1Snapshot?.historyRevision
    let logicalDayBoundary = logicalDayBoundary
    todayTimelineTask = Task { [weak self] in
      defer {
        if self?.todayTimelineGeneration == generation {
          self?.isRefreshingTodayTimeline = false
          self?.todayTimelineTask = nil
          if self?.pendingTodayTimelineRefresh == true {
            self?.pendingTodayTimelineRefresh = false
            self?.refreshTodayTimeline()
          }
        }
      }
      do {
        let day = try Self.currentDay(at: now, boundary: logicalDayBoundary)
        let page = try await Self.fetchTimelinePage(
          from: todayRepository,
          paging: pageRepository,
          in: day.boundary.startsAt..<day.boundary.endsAt,
          before: nil
        )
        guard !Task.isCancelled else { return }
        let applicationContexts = try await Self.fetchApplicationContexts(
          for: page.events, using: applicationContextFetcher
        )
        let collectorStates = try await Self.fetchCollectorStates(
          for: page.events, using: collectorStateFetcher
        )
        let visualInferences = await Self.fetchVisualInferences(
          from: visualInferenceRepository,
          in: day.boundary.startsAt..<day.boundary.endsAt
        )
        let understanding: ObjectiveUnderstandingSnapshot?
        if cachedUnderstandingDay?.id == day.id,
          let currentHistoryRevision,
          cachedUnderstandingRevision == currentHistoryRevision,
          let cachedUnderstanding
        {
          understanding = cachedUnderstanding
        } else {
          understanding = try await understandingPipeline?.derive(day: day, asOf: now)
        }
        guard !Task.isCancelled, self?.todayTimelineGeneration == generation,
          self?.todayTimelineVisible == true
        else { return }
        self?.loadedTodayTimelineEvents = page.events
        self?.loadedTodayApplicationContexts = applicationContexts
        self?.loadedTodayCollectorStates = collectorStates
        self?.loadedTodayVisualInferences = visualInferences
        self?.loadedTodayUnderstanding = understanding
        self?.loadedTodayUnderstandingRevision = currentHistoryRevision
        self?.todayTimelineDay = day
        self?.olderTimelineCursor = page.nextCursor
        self?.canLoadOlderTodayTimeline = page.nextCursor != nil
        self?.publishTodayTimeline(day: day, now: now, runtime: runtimeSnapshot)
      } catch {
        guard !Task.isCancelled else { return }
        if self?.todayTimelineGeneration == generation,
          self?.todayTimelineVisible == true,
          let day = try? Self.currentDay(at: now, boundary: logicalDayBoundary)
        {
          self?.todayTimeline = TodayTimelinePresentationAdapter.make(
            day: day, events: [], now: now, fetchState: .failure, runtime: runtimeSnapshot
          )
        }
      }
    }
  }

  /// Called after a derived visual observation is durably archived. This avoids polling the
  /// complete deep-capture archive on every permission/status refresh while keeping Today fresh.
  func visualInferenceArchiveChanged() {
    refreshTodayTimeline()
  }

  func loadOlderTodayTimeline() {
    guard todayTimelineVisible,
      canLoadOlderTodayTimeline,
      todayTimelineTask == nil,
      let todayRepository,
      let day = todayTimelineDay,
      let cursor = olderTimelineCursor
    else { return }

    let generation = todayTimelineGeneration
    let now = schedule.now()
    let runtimeSnapshot = snapshot
    let pageRepository = todayPageRepository
    let applicationContextFetcher = applicationContextFetcher
    let collectorStateFetcher = collectorStateFetcher
    isLoadingOlderTodayTimeline = true
    todayTimelineLoadMoreFailed = false
    todayTimelineTask = Task { [weak self] in
      defer {
        if self?.todayTimelineGeneration == generation {
          self?.isLoadingOlderTodayTimeline = false
          self?.todayTimelineTask = nil
          if self?.pendingTodayTimelineRefresh == true {
            self?.pendingTodayTimelineRefresh = false
            self?.refreshTodayTimeline()
          }
        }
      }
      do {
        let page = try await Self.fetchTimelinePage(
          from: todayRepository,
          paging: pageRepository,
          in: day.boundary.startsAt..<day.boundary.endsAt,
          before: cursor
        )
        guard !Task.isCancelled else { return }
        let applicationContexts = try await Self.fetchApplicationContexts(
          for: page.events, using: applicationContextFetcher
        )
        let collectorStates = try await Self.fetchCollectorStates(
          for: page.events, using: collectorStateFetcher
        )
        guard !Task.isCancelled, self?.todayTimelineGeneration == generation,
          self?.todayTimelineVisible == true
        else { return }
        self?.loadedTodayTimelineEvents.append(contentsOf: page.events)
        self?.loadedTodayApplicationContexts.merge(applicationContexts) { _, newer in newer }
        self?.loadedTodayCollectorStates.merge(collectorStates) { _, newer in newer }
        self?.olderTimelineCursor = page.nextCursor
        self?.canLoadOlderTodayTimeline = page.nextCursor != nil
        self?.publishTodayTimeline(day: day, now: now, runtime: runtimeSnapshot)
      } catch {
        guard !Task.isCancelled, self?.todayTimelineGeneration == generation else { return }
        self?.todayTimelineLoadMoreFailed = true
      }
    }
  }

  func setTodayTimelineVisible(_ isVisible: Bool) {
    guard todayTimelineVisible != isVisible else { return }
    todayTimelineVisible = isVisible
    todayTimelineGeneration &+= 1
    todayTimelineTask?.cancel()
    todayTimelineTask = nil
    isRefreshingTodayTimeline = false
    isLoadingOlderTodayTimeline = false
    if isVisible {
      pendingTodayTimelineRefresh = false
      refreshTodayTimeline()
    }
  }

  private func resetTodayTimelinePaging() {
    todayTimelineGeneration &+= 1
    todayTimelineTask?.cancel()
    todayTimelineTask = nil
    isRefreshingTodayTimeline = false
    isLoadingOlderTodayTimeline = false
    loadedTodayTimelineEvents = []
    loadedTodayApplicationContexts = [:]
    loadedTodayCollectorStates = [:]
    loadedTodayVisualInferences = []
    loadedTodayUnderstanding = nil
    loadedTodayUnderstandingRevision = nil
    todayTimelineDay = nil
    olderTimelineCursor = nil
    canLoadOlderTodayTimeline = false
    todayTimelineLoadMoreFailed = false
    pendingTodayTimelineRefresh = false
  }

  private func publishTodayTimeline(
    day: DayDescriptor,
    now: Date,
    runtime: AppRuntimeSnapshot
  ) {
    todayTimeline = TodayTimelinePresentationAdapter.make(
      day: day,
      events: loadedTodayTimelineEvents,
      applicationContexts: loadedTodayApplicationContexts,
      collectorStates: loadedTodayCollectorStates,
      visualInferences: loadedTodayVisualInferences,
      understanding: loadedTodayUnderstanding,
      now: now,
      fetchState: .loaded,
      runtime: runtime
    )
  }

  private static func fetchTimelinePage(
    from repository: any ObjectiveEventRepository,
    paging: (any ObjectiveEventPageRepository)?,
    in range: Range<Date>,
    before cursor: ObjectiveEventPageCursor?
  ) async throws -> ObjectiveEventPage {
    if let paging {
      return try await paging.fetchPage(
        occurredIn: range,
        before: cursor,
        limit: todayTimelinePageSize
      )
    }
    guard cursor == nil else { return .init(events: [], nextCursor: nil) }
    return .init(events: try await repository.fetch(occurredIn: range), nextCursor: nil)
  }

  private static func fetchApplicationContexts(
    for events: [ObjectiveEvent],
    using fetcher: (@Sendable (EventID) async throws -> ApplicationContextRecord?)?
  ) async throws -> [EventID: ApplicationContextRecord] {
    guard let fetcher else { return [:] }
    var contexts: [EventID: ApplicationContextRecord] = [:]
    for event in events
    where event.kind == .applicationContextChanged && event.securityDisposition == .allowed {
      if let context = try await fetcher(event.id) {
        contexts[event.id] = context
      }
    }
    return contexts
  }

  private static func fetchCollectorStates(
    for events: [ObjectiveEvent],
    using fetcher: (@Sendable (EventID) async throws -> CollectorStateRecord?)?
  ) async throws -> [EventID: CollectorStateRecord] {
    guard let fetcher else { return [:] }
    var states: [EventID: CollectorStateRecord] = [:]
    for event in events
    where event.kind == .collectorStateTransition && event.securityDisposition == .allowed {
      if let state = try await fetcher(event.id) {
        states[event.id] = state
      }
    }
    return states
  }

  private static func fetchVisualInferences(
    from repository: (any VisibleContentArchiveRepository)?,
    in range: Range<Date>
  ) async -> [VisibleContentObservation] {
    guard let repository else { return [] }
    return
      (try? await repository.fetchVisibleContent(observedIn: range).filter {
        $0.kind == .inference
      }) ?? []
  }

  private static func currentDay(
    at date: Date,
    boundary: WorkdayBoundary
  ) throws -> DayDescriptor {
    let timeZone = TimeZone.autoupdatingCurrent
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = try boundary.start(containing: date, calendar: calendar)
    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
      throw TodayDayDescriptorError.nextDayUnavailable
    }
    let end = try boundary.start(containing: nextDay, calendar: calendar)
    let components = calendar.dateComponents([.year, .month, .day], from: start)
    guard let year = components.year, let month = components.month, let day = components.day else {
      throw TodayDayDescriptorError.invalidDate
    }
    return try DayDescriptor(
      logicalDate: .init(year: year, month: month, day: day),
      timeZoneIdentifier: timeZone.identifier,
      boundary: .init(hour: boundary.hour, startsAt: start, endsAt: end)
    )
  }

  func startMonitoring() {
    guard monitoringTask == nil else { return }

    let schedule = schedule
    let refreshInterval = refreshInterval
    monitoringTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.requestRefresh()

        do {
          try await schedule.sleep(refreshInterval)
        } catch {
          return
        }
      }
    }
  }

  func stopMonitoring() {
    monitoringTask?.cancel()
    monitoringTask = nil
    refreshTask?.cancel()
  }

  func requestRefresh() {
    // Repeated triggers share the in-flight refresh. Platform preflights are snapshots, so a
    // parallel or queued duplicate would add work without improving freshness.
    guard refreshTask == nil else { return }

    isRefreshing = true
    let checkedAt = schedule.now()
    let provider = provider
    let collectionGateRefresher = collectionGateRefresher
    refreshTask = Task { [weak self] in
      guard !Task.isCancelled else {
        self?.finishRefresh(with: nil)
        return
      }
      let refreshedSnapshot = await provider.snapshot(at: checkedAt)
      if let collectionGateRefresher {
        await collectionGateRefresher()
      }
      guard let self else { return }
      self.finishRefresh(
        with: Task.isCancelled ? nil : refreshedSnapshot
      )
    }
  }

  private func finishRefresh(with refreshedSnapshot: AppRuntimeSnapshot?) {
    if let refreshedSnapshot {
      snapshot = refreshedSnapshot
    }
    isRefreshing = false
    refreshTask = nil
    if let day = todayTimelineDay, todayTimelineVisible {
      publishTodayTimeline(day: day, now: schedule.now(), runtime: snapshot)
    } else if todayTimelineDay == nil {
      refreshTodayTimeline()
    }
  }
}

private enum TodayDayDescriptorError: Error {
  case nextDayUnavailable
  case invalidDate
}
