import Combine
import DaydayCore
import DaydayIntegrations
import Foundation
import os

struct HealthMetricExactSample: Equatable, Sendable {
  let measuredAt: Date
  let value: Double
}

@MainActor
final class HealthArchiveModel: ObservableObject {
  struct StatisticsScopeKey: Hashable {
    let kindIdentifiers: [String]
    let startsAt: Date
    let endsOn: String
    let recentSyncLimit: Int
    let timeZoneIdentifier: String

    init(
      query: HealthArchiveStatisticsQuery,
      calendar suppliedCalendar: Calendar = .autoupdatingCurrent
    ) {
      var calendar = suppliedCalendar
      calendar.timeZone = suppliedCalendar.timeZone
      kindIdentifiers = query.kinds?.map(\.rawValue).sorted() ?? []
      startsAt = query.startsAt
      endsOn = Self.logicalDate(query.endsAt, calendar: calendar)
      recentSyncLimit = query.recentSyncLimit
      timeZoneIdentifier = calendar.timeZone.identifier
    }

    private static func logicalDate(_ date: Date, calendar: Calendar) -> String {
      let components = calendar.dateComponents([.year, .month, .day], from: date)
      return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
      )
    }
  }

  private struct DashboardCacheEntry {
    let query: HealthArchiveStatisticsQuery
    let dashboard: HealthArchiveDashboard
  }

  private struct ExactSampleCacheKey: Hashable {
    let archiveRevision: UInt64
    let kind: HealthObservationKind
    let startedAt: Date
    let endedAt: Date
  }

  private enum ExactSampleCacheValue {
    case sample(HealthMetricExactSample)
    case unavailable

    var sample: HealthMetricExactSample? {
      switch self {
      case .sample(let sample): sample
      case .unavailable: nil
      }
    }
  }

  enum State: Equatable {
    case waitingForLocalArchive
    case loading
    case ready
    case failed
  }

  enum LoadingState: Equatable {
    case idle
    case initialArchive
    case refreshingExistingDashboard
  }

  enum RefreshIssue: Equatable {
    case showingStaleDashboard

    var title: String { "本机健康档案暂未刷新" }

    var detail: String {
      "正在显示上次成功读取的数据；健康事实仍保留在本机。"
    }
  }

  @Published private(set) var state: State = .waitingForLocalArchive
  @Published private(set) var dashboard: HealthArchiveDashboard?
  @Published private(set) var refreshIssue: RefreshIssue?
  @Published private(set) var pairingState: PairingState = .notPaired
  @Published private(set) var transferState: TransferState = .notPaired
  @Published private(set) var pairingCodeIsVisible = false
  @Published private(set) var archiveActionMessage: String?

  enum PairingState: Equatable {
    case notPaired
    case starting(setupCode: String)
    case ready(setupCode: String)
    case failed

    var title: String {
      switch self {
      case .notPaired: "尚未配对"
      case .starting: "正在启动本机同步服务"
      case .ready: "已配对，等待 iPhone"
      case .failed: "本机同步服务不可用"
      }
    }
  }

  enum TransferState: Equatable {
    case notPaired
    case waitingForIPhone
    case receiving
    case persisted(observationCount: Int, tombstoneCount: Int, at: Date)
    case incomplete

    var title: String {
      switch self {
      case .notPaired: return "尚未配对"
      case .waitingForIPhone: return "等待已配对的 iPhone 连接"
      case .receiving: return "正在接收 iPhone 健康事实"
      case .persisted(let observationCount, let tombstoneCount, let at):
        let deletion = tombstoneCount > 0 ? "，\(tombstoneCount) 条删除记录" : ""
        return
          "\(at.formatted(date: .omitted, time: .shortened)) 已写入 \(observationCount) 条事实\(deletion)"
      case .incomplete: return "上次连接未完成；iPhone 会保留待同步数据"
      }
    }

    var metricTitle: String {
      switch self {
      case .notPaired: "尚未配对"
      case .waitingForIPhone: "等待 iPhone"
      case .receiving: "正在接收"
      case .persisted: "已写入"
      case .incomplete: "等待重试"
      }
    }

    func compactTitle(hasLocalArchive: Bool) -> String {
      guard hasLocalArchive else { return metricTitle }
      switch self {
      case .notPaired:
        return "档案已保留，iPhone 尚未配对"
      case .waitingForIPhone:
        return "档案已更新，iPhone 当前未连接"
      case .receiving:
        return "正在接收 iPhone 健康事实"
      case .persisted(_, _, let at):
        return "\(at.formatted(date: .omitted, time: .shortened)) 档案已更新"
      case .incomplete:
        return "档案已保留，等待 iPhone 重试"
      }
    }
  }

  private var repository: (any HealthArchiveRepository)?
  private var syncServer: HealthLocalSyncServer?
  private let pairingStore: any AppHealthPairingCredentialStoring
  private var activeStatisticsQuery: HealthArchiveStatisticsQuery?
  private var dashboardStatisticsQuery: HealthArchiveStatisticsQuery?
  private var activeStatisticsScope: StatisticsScopeKey?
  private var dashboardStatisticsScope: StatisticsScopeKey?
  private var dashboardCache: [StatisticsScopeKey: DashboardCacheEntry] = [:]
  private var dashboardCacheOrder: [StatisticsScopeKey] = []
  private var exactSampleCache: [ExactSampleCacheKey: ExactSampleCacheValue] = [:]
  private var exactSampleCacheOrder: [ExactSampleCacheKey] = []
  private var inFlightStatisticsScopes: Set<StatisticsScopeKey> = []
  private var pendingStatisticsQueries: [StatisticsScopeKey: HealthArchiveStatisticsQuery] = [:]
  private var syncRefreshTask: Task<Void, Never>?
  private let prewarmingEnabled: Bool

  private static let dashboardCacheLimit = 8
  private static let exactSampleCacheLimit = 256
  private static let performanceLog = OSLog(
    subsystem: "app.dayday.health",
    category: .pointsOfInterest
  )

  init(
    pairingStore: any AppHealthPairingCredentialStoring =
      AppHealthPairingCredentialStoreFactory.make(),
    prewarmingEnabled: Bool = true
  ) {
    self.pairingStore = pairingStore
    self.prewarmingEnabled = prewarmingEnabled
  }

  var loadingState: LoadingState {
    guard state == .loading else { return .idle }
    return currentDashboard == nil ? .initialArchive : .refreshingExistingDashboard
  }

  var currentDashboard: HealthArchiveDashboard? {
    guard dashboardStatisticsScope == activeStatisticsScope else { return nil }
    return dashboard
  }

  var compactSyncStatus: String {
    transferState.compactTitle(
      hasLocalArchive: (dashboard?.summary.observationCount ?? 0) > 0
    )
  }

  func configure(repository: any HealthArchiveRepository) {
    self.repository = repository
    exactSampleCache.removeAll(keepingCapacity: true)
    exactSampleCacheOrder.removeAll(keepingCapacity: true)
    pairingCodeIsVisible = false
    configureSyncServer(using: repository)
    if let activeStatisticsQuery {
      refresh(matching: activeStatisticsQuery)
    } else if prewarmingEnabled, let query = try? Self.defaultStatisticsQuery() {
      refresh(matching: query)
    }
  }

  func preparePairing() {
    guard let repository else { return }
    do {
      let credential = try HealthPairingCredential.generate()
      try pairingStore.save(credential)
      try startSyncServer(repository: repository, credential: credential)
      pairingState = .starting(setupCode: credential.setupCode)
      transferState = .waitingForIPhone
      pairingCodeIsVisible = true
    } catch {
      pairingState = .failed
    }
  }

  func revokePairing() {
    syncServer?.stop()
    syncServer = nil
    pairingCodeIsVisible = false
    do {
      try pairingStore.remove()
      pairingState = .notPaired
      transferState = .notPaired
    } catch {
      pairingState = .failed
    }
  }

  func revealPairingCode() { pairingCodeIsVisible = true }
  func hidePairingCode() { pairingCodeIsVisible = false }

  func refresh(matching suppliedQuery: HealthArchiveStatisticsQuery? = nil) {
    let query: HealthArchiveStatisticsQuery
    do {
      query = try suppliedQuery ?? Self.defaultStatisticsQuery()
    } catch {
      state = .failed
      return
    }
    let scope = StatisticsScopeKey(query: query)
    activeStatisticsQuery = query
    activeStatisticsScope = scope
    refreshIssue = nil
    if let cached = cachedDashboard(for: scope) {
      dashboard = cached.dashboard
      dashboardStatisticsQuery = cached.query
      dashboardStatisticsScope = scope
    }
    guard let repository else {
      state = .waitingForLocalArchive
      return
    }
    state = .loading
    pendingStatisticsQueries[scope] = query
    guard !inFlightStatisticsScopes.contains(scope) else { return }
    startStatisticsRefresh(query: query, scope: scope, repository: repository)
  }

  /// Presents an already-built dashboard without starting another archive scan.
  /// Health facts change through the local sync path, which explicitly refreshes
  /// the active scope; navigation alone is not a data-change signal.
  func loadIfNeeded(matching suppliedQuery: HealthArchiveStatisticsQuery? = nil) {
    let query: HealthArchiveStatisticsQuery
    do {
      query = try suppliedQuery ?? Self.defaultStatisticsQuery()
    } catch {
      state = .failed
      return
    }
    let scope = StatisticsScopeKey(query: query)

    if activeStatisticsScope == scope,
      currentDashboard != nil || inFlightStatisticsScopes.contains(scope)
    {
      return
    }
    if let cached = cachedDashboard(for: scope) {
      activeStatisticsQuery = query
      activeStatisticsScope = scope
      dashboard = cached.dashboard
      dashboardStatisticsQuery = cached.query
      dashboardStatisticsScope = scope
      refreshIssue = nil
      state = .ready
      return
    }
    refresh(matching: query)
  }

  private func startStatisticsRefresh(
    query: HealthArchiveStatisticsQuery,
    scope: StatisticsScopeKey,
    repository: any HealthArchiveRepository
  ) {
    inFlightStatisticsScopes.insert(scope)
    pendingStatisticsQueries.removeValue(forKey: scope)
    let signpostID = OSSignpostID(log: Self.performanceLog)
    let cacheStatus = dashboardCache[scope] == nil ? "miss" : "hit"
    os_signpost(
      .begin,
      log: Self.performanceLog,
      name: "Health Dashboard Refresh",
      signpostID: signpostID,
      "cache=%{public}s",
      cacheStatus
    )
    Task { [weak self] in
      do {
        let refreshedDashboard = try await repository.dashboard(matching: query)
        guard let self else { return }
        os_signpost(
          .end,
          log: Self.performanceLog,
          name: "Health Dashboard Refresh",
          signpostID: signpostID,
          "revision=%{public}llu",
          refreshedDashboard.archiveRevision
        )
        self.inFlightStatisticsScopes.remove(scope)
        self.storeDashboard(refreshedDashboard, query: query, for: scope)
        if self.activeStatisticsScope == scope {
          self.dashboard = refreshedDashboard
          self.dashboardStatisticsQuery = query
          self.dashboardStatisticsScope = scope
          self.refreshIssue = nil
          self.state = .ready
        }
        self.startPendingStatisticsRefreshIfNeeded(
          completedQuery: query,
          scope: scope,
          repository: repository
        )
      } catch {
        guard let self else { return }
        os_signpost(
          .end,
          log: Self.performanceLog,
          name: "Health Dashboard Refresh",
          signpostID: signpostID,
          "failed"
        )
        self.inFlightStatisticsScopes.remove(scope)
        if self.activeStatisticsScope == scope {
          if self.currentDashboard == nil {
            self.state = .failed
          } else {
            self.refreshIssue = .showingStaleDashboard
            self.state = .ready
          }
        }
        self.startPendingStatisticsRefreshIfNeeded(
          completedQuery: query,
          scope: scope,
          repository: repository
        )
      }
    }
  }

  private func startPendingStatisticsRefreshIfNeeded(
    completedQuery: HealthArchiveStatisticsQuery,
    scope: StatisticsScopeKey,
    repository: any HealthArchiveRepository
  ) {
    guard let pendingQuery = pendingStatisticsQueries.removeValue(forKey: scope),
      pendingQuery != completedQuery
    else { return }
    if activeStatisticsScope == scope { state = .loading }
    startStatisticsRefresh(query: pendingQuery, scope: scope, repository: repository)
  }

  private func cachedDashboard(for scope: StatisticsScopeKey) -> DashboardCacheEntry? {
    guard let cached = dashboardCache[scope] else { return nil }
    touchDashboardCache(scope)
    return cached
  }

  private func storeDashboard(
    _ dashboard: HealthArchiveDashboard,
    query: HealthArchiveStatisticsQuery,
    for scope: StatisticsScopeKey
  ) {
    dashboardCache[scope] = DashboardCacheEntry(query: query, dashboard: dashboard)
    touchDashboardCache(scope)
    while dashboardCacheOrder.count > Self.dashboardCacheLimit {
      let evicted = dashboardCacheOrder.removeFirst()
      dashboardCache.removeValue(forKey: evicted)
    }
  }

  private func touchDashboardCache(_ scope: StatisticsScopeKey) {
    dashboardCacheOrder.removeAll { $0 == scope }
    dashboardCacheOrder.append(scope)
  }

  /// Resolves a five-minute discrete aggregate back to the nearest individual quantity sample.
  /// The result is loaded only after hover settles and stays in a small revision-aware cache.
  func exactQuantitySample(
    kind: HealthObservationKind,
    near point: HealthMetricPoint
  ) async -> HealthMetricExactSample? {
    guard let repository,
      point.endedAt > point.startedAt,
      point.endedAt.timeIntervalSince(point.startedAt) <= 5 * 60 + 1
    else { return nil }

    let key = ExactSampleCacheKey(
      archiveRevision: dashboard?.archiveRevision ?? 0,
      kind: kind,
      startedAt: point.startedAt,
      endedAt: point.endedAt
    )
    if let cached = exactSampleCache[key] {
      touchExactSampleCache(key)
      return cached.sample
    }

    let query: HealthArchiveQuery
    do {
      query = try HealthArchiveQuery(
        kinds: [kind],
        startsAtOrAfter: point.startedAt,
        endsAtOrBefore: point.endedAt,
        limit: 256
      )
    } catch {
      storeExactSample(nil, for: key)
      return nil
    }

    do {
      let target = point.startedAt.addingTimeInterval(
        point.endedAt.timeIntervalSince(point.startedAt) / 2
      )
      let sample = try await repository.observations(matching: query)
        .compactMap { observation -> HealthMetricExactSample? in
          guard observation.endedAt >= point.startedAt,
            observation.endedAt <= point.endedAt,
            case .quantity(let value, _) = observation.payload,
            value.isFinite
          else { return nil }
          return HealthMetricExactSample(measuredAt: observation.endedAt, value: value)
        }
        .min {
          abs($0.measuredAt.timeIntervalSince(target))
            < abs($1.measuredAt.timeIntervalSince(target))
        }
      storeExactSample(sample, for: key)
      return sample
    } catch {
      return nil
    }
  }

  private func storeExactSample(
    _ sample: HealthMetricExactSample?,
    for key: ExactSampleCacheKey
  ) {
    exactSampleCache[key] = sample.map(ExactSampleCacheValue.sample) ?? .unavailable
    touchExactSampleCache(key)
    while exactSampleCacheOrder.count > Self.exactSampleCacheLimit {
      let evicted = exactSampleCacheOrder.removeFirst()
      exactSampleCache.removeValue(forKey: evicted)
    }
  }

  private func touchExactSampleCache(_ key: ExactSampleCacheKey) {
    exactSampleCacheOrder.removeAll { $0 == key }
    exactSampleCacheOrder.append(key)
  }

  func deleteLocally(
    _ request: HealthArchiveDeletionRequest, thenRefresh query: HealthArchiveStatisticsQuery
  ) {
    guard let repository else { return }
    archiveActionMessage = nil
    Task { [weak self] in
      do {
        let result = try await repository.delete(request)
        guard let self else { return }
        self.archiveActionMessage =
          result.removedObservationCount == 0
          ? "没有符合该范围的本机健康事实。"
          : "已从 Dayday 本机档案移除 \(result.removedObservationCount) 条事实；Apple 健康中的原始数据未被修改。"
        self.refresh(matching: query)
      } catch {
        self?.archiveActionMessage = "未能清理本机健康档案；原始数据没有被修改。"
      }
    }
  }

  func export(to url: URL, matching query: HealthArchiveQuery) {
    guard let repository else { return }
    archiveActionMessage = nil
    Task { [weak self] in
      do {
        let snapshot = try await repository.export(matching: query, exportedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        self?.archiveActionMessage = "已导出 \(snapshot.observations.count) 条健康事实到你选择的位置。"
      } catch {
        self?.archiveActionMessage = "导出失败；Dayday 本机档案未被修改。"
      }
    }
  }

  private static func defaultStatisticsQuery(now: Date = Date()) throws
    -> HealthArchiveStatisticsQuery
  {
    let calendar = Calendar.autoupdatingCurrent
    let end = now
    let start = calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: now)) ?? now
    return try HealthArchiveStatisticsQuery(startsAt: start, endsAt: end)
  }

  static func rollingQuery(
    advancing query: HealthArchiveStatisticsQuery,
    to now: Date,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) -> HealthArchiveStatisticsQuery? {
    var calendar = suppliedCalendar
    calendar.timeZone = suppliedCalendar.timeZone
    let oldStart = calendar.startOfDay(for: query.startsAt)
    let oldEnd = calendar.startOfDay(for: query.endsAt)
    guard let elapsedDays = calendar.dateComponents([.day], from: oldStart, to: oldEnd).day,
      elapsedDays >= 0,
      let newStart = calendar.date(
        byAdding: .day,
        value: -elapsedDays,
        to: calendar.startOfDay(for: now)
      )
    else { return nil }
    return try? HealthArchiveStatisticsQuery(
      kinds: query.kinds,
      startsAt: newStart,
      endsAt: now,
      recentSyncLimit: query.recentSyncLimit
    )
  }

  private func configureSyncServer(using repository: any HealthArchiveRepository) {
    do {
      guard let credential = try pairingStore.load() else {
        pairingState = .notPaired
        return
      }
      try startSyncServer(repository: repository, credential: credential)
      pairingState = .starting(setupCode: credential.setupCode)
      transferState = .waitingForIPhone
      pairingCodeIsVisible = false
    } catch {
      pairingState = .failed
    }
  }

  private func startSyncServer(
    repository: any HealthArchiveRepository,
    credential: HealthPairingCredential
  ) throws {
    syncServer?.stop()
    let server = HealthLocalSyncServer(archive: repository)
    server.stateUpdateHandler = { [weak self, weak server] serverState in
      Task { @MainActor [weak self, weak server] in
        guard let self, let server, self.syncServer === server else { return }
        switch serverState {
        case .ready:
          self.pairingState = .ready(setupCode: credential.setupCode)
        case .starting:
          self.pairingState = .starting(setupCode: credential.setupCode)
        case .failed:
          self.pairingState = .failed
        case .stopped:
          break
        }
      }
    }
    server.transferUpdateHandler = { [weak self, weak server] transferState in
      Task { @MainActor [weak self, weak server] in
        guard let self, let server, self.syncServer === server else { return }
        switch transferState {
        case .waitingForCompanion:
          self.transferState = .waitingForIPhone
        case .receiving:
          self.transferState = .receiving
        case .persisted(let observationCount, let tombstoneCount, let at):
          self.transferState = .persisted(
            observationCount: observationCount,
            tombstoneCount: tombstoneCount,
            at: at
          )
          self.scheduleDashboardRefresh(afterBatchReceivedAt: at)
        case .incomplete:
          self.transferState = .incomplete
        }
      }
    }
    syncServer = server
    do {
      try server.start(using: credential)
    } catch {
      syncServer = nil
      throw error
    }
  }

  private func scheduleDashboardRefresh(afterBatchReceivedAt receivedAt: Date) {
    syncRefreshTask?.cancel()
    syncRefreshTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      let refreshedQuery = self.activeStatisticsQuery.flatMap {
        Self.rollingQuery(advancing: $0, to: receivedAt)
      }
      self.refresh(matching: refreshedQuery)
      self.syncRefreshTask = nil
    }
  }
}
