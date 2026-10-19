import AppKit
import DaydayCore
import SwiftUI

// Intent: help one private owner scan a complete Apple Health archive without implying diagnosis
// or a synthetic health score. Hierarchy: the selected annual rhythm leads, while every available
// measured metric remains visible in a compact waterfall below. Palette: neutral mineral surfaces
// with category-semantic health tints. Depth: solid, low-contrast partitions; material is reserved
// for transient tooltips. Typography: system type and monospaced values. Spacing: a 4-point rhythm.
struct HealthArchiveView: View {
  @ObservedObject var archive: HealthArchiveModel
  @State private var selectedMetric: HealthObservationKind = .heartRate

  var body: some View {
    VStack(spacing: 0) {
      PageHeaderBar(
        title: "健康档案",
        subtitle: "来自 Apple 健康的客观事实，仅保存在这台 Mac",
        systemImage: "heart.text.clipboard"
      ) {
        HealthArchiveHeaderStatus(archive: archive, refresh: refresh)
      }

      DaydayScrollView {
        VStack(alignment: .leading, spacing: DaydaySpace.xl) {
          if let issue = archive.refreshIssue {
            HealthArchiveIssueBanner(
              title: issue.title,
              detail: issue.detail,
              systemImage: "arrow.clockwise.circle",
              role: .warning,
              actionTitle: "重新尝试",
              action: refresh
            )
          }

          if let connectionIssue {
            HealthArchiveIssueBanner(
              title: connectionIssue.title,
              detail: connectionIssue.detail,
              systemImage: connectionIssue.systemImage,
              role: .warning
            )
          }

          archiveContent

          HealthSyncAndSources(archive: archive)
        }
        .padding(.horizontal, DaydaySpace.pageHorizontal)
        .padding(.top, DaydaySpace.pageContentTop)
        .padding(.bottom, DaydaySpace.pageHorizontal)
        .frame(maxWidth: 1180, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task(id: statisticsQueryKey) {
      archive.loadIfNeeded(matching: statisticsQuery)
    }
    .task {
      await refreshAtDayBoundaries()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: Notification.Name.NSSystemTimeZoneDidChange)
    ) { _ in
      refresh()
    }
  }

  @ViewBuilder
  private var archiveContent: some View {
    switch archive.loadingState {
    case .initialArchive:
      HealthArchiveLoadingDashboard()
    case .idle, .refreshingExistingDashboard:
      if let dashboard = archive.currentDashboard, dashboard.summary.observationCount > 0 {
        HealthArchiveDashboardContent(
          dashboard: dashboard,
          selectedMetric: $selectedMetric,
          startsAt: selectedRange.lowerBound,
          endsAt: selectedRange.upperBound,
          exactSampleProvider: { kind, point in
            await archive.exactQuantitySample(kind: kind, near: point)
          }
        )
      } else if archive.state == .failed {
        VStack(spacing: DaydaySpace.l) {
          EmptyState(
            title: "无法读取本机健康档案",
            detail: "健康事实仍保留在这台 Mac；可以稍后重新尝试。",
            systemImage: "externaldrive.badge.exclamationmark"
          )
          Button("重新尝试", systemImage: "arrow.clockwise", action: refresh)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
      } else if archive.state == .waitingForLocalArchive {
        HealthArchiveLoadingDashboard()
      } else {
        VStack(spacing: DaydaySpace.l) {
          EmptyState(
            title: "等待 iPhone 同步健康数据",
            detail: archive.compactSyncStatus,
            systemImage: "iphone.and.arrow.forward"
          )
          if archive.pairingState == .notPaired || archive.pairingState == .failed {
            Button(
              "准备 iPhone 配对",
              systemImage: "iphone.gen3.radiowaves.left.and.right",
              action: archive.preparePairing
            )
          }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
      }
    }
  }

  private var selectedRange: ClosedRange<Date> {
    let calendar = Calendar.autoupdatingCurrent
    let end = Date()
    let start =
      calendar.date(
        byAdding: .day,
        value: -364,
        to: calendar.startOfDay(for: end)
      ) ?? end
    return start...end
  }

  private var statisticsQuery: HealthArchiveStatisticsQuery? {
    try? HealthArchiveStatisticsQuery(
      startsAt: selectedRange.lowerBound,
      endsAt: selectedRange.upperBound
    )
  }

  private var statisticsQueryKey: String {
    "all-health-metrics"
  }

  private func refresh() {
    archive.refresh(matching: statisticsQuery)
  }

  private func refreshAtDayBoundaries() async {
    while !Task.isCancelled {
      let calendar = Calendar.autoupdatingCurrent
      let now = Date()
      guard
        let nextDay = calendar.date(
          byAdding: .day,
          value: 1,
          to: calendar.startOfDay(for: now)
        )
      else { return }

      do {
        try await Task.sleep(for: .seconds(max(1, nextDay.timeIntervalSince(now) + 1)))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      refresh()
    }
  }

  private var connectionIssue: HealthArchiveConnectionIssue? {
    if archive.pairingState == .failed {
      return .syncServiceUnavailable
    }
    if archive.transferState == .incomplete {
      return .incompleteTransfer
    }
    return nil
  }
}

private enum HealthArchiveConnectionIssue {
  case syncServiceUnavailable
  case incompleteTransfer

  var title: String {
    switch self {
    case .syncServiceUnavailable: "本机同步服务暂不可用"
    case .incompleteTransfer: "上次 iPhone 传输未完成"
    }
  }

  var detail: String {
    switch self {
    case .syncServiceUnavailable: "既有健康档案保持可见；请展开“同步与来源”重新准备配对。"
    case .incompleteTransfer: "已写入的事实不会丢失；iPhone 会保留未完成的内容并在下次连接时重试。"
    }
  }

  var systemImage: String {
    switch self {
    case .syncServiceUnavailable: "iphone.slash"
    case .incompleteTransfer: "arrow.trianglehead.2.clockwise.rotate.90"
    }
  }
}

private struct HealthArchiveHeaderStatus: View {
  @ObservedObject var archive: HealthArchiveModel
  let refresh: () -> Void

  var body: some View {
    HStack(spacing: DaydaySpace.m) {
      statusSymbol

      VStack(alignment: .leading, spacing: 2) {
        Text(updateText)
          .font(DaydayType.metadata.weight(.medium))
          .foregroundStyle(.primary)
        Text(archive.compactSyncStatus)
          .font(DaydayType.metadata)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Button("刷新", systemImage: "arrow.clockwise", action: refresh)
        .labelStyle(.iconOnly)
        .help("刷新当前健康档案视图")
        .disabled(archive.loadingState != .idle)
        .accessibilityLabel("刷新健康档案")
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var statusSymbol: some View {
    if archive.loadingState == .refreshingExistingDashboard {
      ProgressView().controlSize(.small).accessibilityLabel("正在刷新健康档案")
    } else {
      Image(systemName: symbolName)
        .foregroundStyle(symbolColor)
        .accessibilityHidden(true)
    }
  }

  private var updateText: String {
    guard let date = archive.dashboard?.summary.latestBatchReceivedAt else {
      return "尚无同步记录"
    }
    return healthArchiveTimestamp(date) + " 更新"
  }

  private var symbolName: String {
    switch archive.transferState {
    case .persisted: "checkmark.circle.fill"
    case .incomplete: "exclamationmark.circle.fill"
    case .notPaired: "iphone.slash"
    case .waitingForIPhone: "iphone"
    case .receiving: "arrow.down.circle.fill"
    }
  }

  private var symbolColor: Color {
    switch archive.transferState {
    case .persisted: .green
    case .incomplete: .orange
    case .notPaired, .waitingForIPhone: .secondary
    case .receiving: .accentColor
    }
  }
}

private struct HealthArchiveIssueBanner: View {
  let title: String
  let detail: String
  let systemImage: String
  let role: DaydayThemeRole
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    DaydayThemeReader { theme, _ in
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: DaydaySpace.m) {
          issueLabel(theme: theme)
          Spacer(minLength: DaydaySpace.l)
          issueAction
        }
        VStack(alignment: .leading, spacing: DaydaySpace.m) {
          issueLabel(theme: theme)
          issueAction
        }
      }
      .padding(DaydaySpace.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        theme[role].opacity(0.08),
        in: RoundedRectangle(cornerRadius: DaydayRadius.control, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: DaydayRadius.control, style: .continuous)
          .stroke(theme[role].opacity(0.20), lineWidth: DaydayDepth.hairline)
      }
    }
  }

  private func issueLabel(theme: DaydayTheme) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(DaydayType.detail.weight(.semibold))
        Text(detail)
          .font(DaydayType.metadata)
          .foregroundStyle(theme[.textSecondary])
      }
    } icon: {
      Image(systemName: systemImage).foregroundStyle(theme[role])
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var issueAction: some View {
    if let actionTitle, let action {
      Button(actionTitle, action: action)
    }
  }
}

private struct HealthArchiveDashboardContent: View {
  let dashboard: HealthArchiveDashboard
  @Binding var selectedMetric: HealthObservationKind
  let startsAt: Date
  let endsAt: Date
  let exactSampleProvider:
    (HealthObservationKind, HealthMetricPoint) async -> HealthMetricExactSample?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(HealthMetricVisibilityPreference.storageKey)
  private var visibleMetricStorage = HealthMetricVisibilityPreference.allToken
  @AppStorage(HealthDashboardLayoutPreference.storageKey)
  private var dashboardLayoutStorage = "{}"

  private var seriesByKind: [HealthObservationKind: HealthMetricSeries] {
    Dictionary(uniqueKeysWithValues: dashboard.metricSeries.map { ($0.kind, $0) })
  }

  private var orderedSeries: [HealthMetricSeries] {
    let defaultOrder = HealthMetricPresentationAdapter.orderedSeries(dashboard.metricSeries)
    let preference = HealthDashboardLayoutPreference.decode(dashboardLayoutStorage)
    let seriesByKind = Dictionary(uniqueKeysWithValues: defaultOrder.map { ($0.kind, $0) })
    return preference.orderedKinds(available: defaultOrder.map(\.kind)).compactMap {
      seriesByKind[$0]
    }
  }

  private var dashboardLayoutPreference: HealthDashboardLayoutPreference {
    HealthDashboardLayoutPreference.decode(dashboardLayoutStorage)
  }

  private var visibleKinds: Set<HealthObservationKind> {
    HealthMetricVisibilityPreference.decode(
      visibleMetricStorage,
      available: Set(orderedSeries.map(\.kind))
    )
  }

  private var visibleSeries: [HealthMetricSeries] {
    orderedSeries.filter { visibleKinds.contains($0.kind) }
  }

  private var focusedSeries: HealthMetricSeries? {
    visibleSeries.first { $0.kind == selectedMetric } ?? visibleSeries.first
  }

  private var selectedCoverage: HealthObservationCoverage? {
    guard let focusedSeries else { return nil }
    return dashboard.coverage.first { $0.kind == focusedSeries.kind }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.xl) {
      if let focusedSeries {
        annualPanel(
          presentation: HealthMetricPresentationAdapter.calendar(
            from: focusedSeries,
            startsAt: startsAt,
            endsAt: endsAt
          )
        )

        HealthMetricWaterfallSection(
          series: visibleSeries,
          allKinds: orderedSeries.map(\.kind),
          visibleKinds: Binding(
            get: { visibleKinds },
            set: { kinds in
              visibleMetricStorage = HealthMetricVisibilityPreference.encode(
                kinds,
                available: Set(orderedSeries.map(\.kind))
              )
            }
          ),
          layoutPreference: Binding(
            get: { dashboardLayoutPreference },
            set: { dashboardLayoutStorage = $0.encode() }
          ),
          coverage: dashboard.coverage,
          archiveRevision: dashboard.archiveRevision,
          selectedMetric: Binding(
            get: { focusedSeries.kind },
            set: { selectedMetric = $0 }
          ),
          now: endsAt,
          metricSelectionAnimation: metricSelectionAnimation,
          exactSampleProvider: exactSampleProvider
        )
      } else {
        EmptyState(
          title: "暂时没有可展示的健康指标",
          detail: "档案仍然保留；完成下一次 iPhone 同步后会自动加入具有真实数值的指标。",
          systemImage: "chart.xyaxis.line"
        )
      }
    }
    .onAppear(perform: selectAvailableMetricIfNeeded)
    .onChange(of: dashboard.metricSeries) { _, _ in selectAvailableMetricIfNeeded() }
    .onChange(of: visibleMetricStorage) { _, _ in selectAvailableMetricIfNeeded() }
  }

  private func annualPanel(
    presentation: HealthMetricCalendarPresentation
  ) -> some View {
    HealthDashboardMetricPanel {
      HealthDashboardPanelHeader(
        title: "\(presentation.kind.healthDisplayName) · 全年节律",
        systemImage: "calendar"
      ) {
        HealthMetricInfoButton(
          kind: presentation.kind,
          coverage: selectedCoverage,
          series: focusedSeries
        )
      }
    } content: {
      HealthMetricCalendarHeatmap(
        presentation: presentation,
        tint: presentation.kind.healthTint
      )
    }
  }

  private var metricSelectionAnimation: Animation? {
    HealthMetricChartMotion.animation(reduceMotion: reduceMotion)
  }

  private func selectAvailableMetricIfNeeded() {
    guard seriesByKind[selectedMetric] == nil, let first = orderedSeries.first else { return }
    selectedMetric = first.kind
  }
}

private struct HealthSpecializedCardsSection: View {
  let series: [HealthMetricSeries]
  let now: Date
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var expandedKind: HealthSpecializedCardKind?
  @State private var rangesByIdentifier: [String: HealthMetricTrendRange] = [:]

  private var availableKinds: [HealthSpecializedCardKind] {
    let available = Set(series.map(\.kind))
    return HealthSpecializedCardKind.allCases.filter { kind in
      !available.isDisjoint(with: kind.metricKinds)
    }
  }

  var body: some View {
    if !availableKinds.isEmpty {
      VStack(alignment: .leading, spacing: DaydaySpace.m) {
        HStack {
          Text("健康概览").font(DaydayType.sectionTitle)
          Spacer()
          Text("展开后才计算范围与上一周期")
            .font(DaydayType.metadata)
            .foregroundStyle(.secondary)
        }

        HealthMetricWaterfallLayout(spacing: DaydaySpace.m) {
          ForEach(availableKinds) { kind in
            let isExpanded = expandedKind == kind
            VStack(alignment: .leading, spacing: DaydaySpace.s) {
              HStack {
                Spacer()
                if isExpanded {
                  Picker("时间范围", selection: rangeBinding(for: kind)) {
                    ForEach(HealthMetricTrendRange.allCases) { range in
                      Text(range.compactTitle).tag(range)
                    }
                  }
                  .pickerStyle(.segmented)
                  .controlSize(.mini)
                  .labelsHidden()
                  .frame(maxWidth: 360)
                }
                Button {
                  withAnimation(HealthMetricChartMotion.animation(reduceMotion: reduceMotion)) {
                    expandedKind = isExpanded ? nil : kind
                  }
                } label: {
                  Image(
                    systemName: isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right"
                  )
                  .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起\(kind.title)概览" : "展开\(kind.title)概览")
              }

              HealthSpecializedMetricCard(
                kind: kind,
                series: series,
                range: range(for: kind),
                now: now,
                isExpanded: isExpanded
              )
            }
            .healthMetricWaterfallSpan(isExpanded ? 2 : 1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  private func range(for kind: HealthSpecializedCardKind) -> HealthMetricTrendRange {
    rangesByIdentifier[kind.rawValue] ?? .week
  }

  private func rangeBinding(for kind: HealthSpecializedCardKind) -> Binding<HealthMetricTrendRange>
  {
    Binding(
      get: { range(for: kind) },
      set: { rangesByIdentifier[kind.rawValue] = $0 }
    )
  }
}

private struct HealthMetricWaterfallSection: View {
  let series: [HealthMetricSeries]
  let allKinds: [HealthObservationKind]
  @Binding var visibleKinds: Set<HealthObservationKind>
  @Binding var layoutPreference: HealthDashboardLayoutPreference
  let coverage: [HealthObservationCoverage]
  let archiveRevision: UInt64
  @Binding var selectedMetric: HealthObservationKind
  let now: Date
  let metricSelectionAnimation: Animation?
  let exactSampleProvider:
    (HealthObservationKind, HealthMetricPoint) async -> HealthMetricExactSample?
  @State private var rangeSelections = HealthMetricCardRangeSelections()
  @State private var availableWidth: CGFloat = 0
  @State private var visibleMetricCount = 6
  @State private var expandedMetric: HealthObservationKind?

  private var coverageByKind: [HealthObservationKind: HealthObservationCoverage] {
    Dictionary(uniqueKeysWithValues: coverage.map { ($0.kind, $0) })
  }

  private var prioritizedSeries: [HealthMetricSeries] {
    let order = Dictionary(uniqueKeysWithValues: series.enumerated().map { ($1.kind, $0) })
    let hasRecentData = Dictionary(
      uniqueKeysWithValues: series.map { item in
        (
          item.kind,
          HealthMetricPresentationAdapter.cardSummary(from: item, range: .week, now: now).value
            != nil
        )
      }
    )
    return series.sorted { lhs, rhs in
      let lhsPinned = layoutPreference.isPinned(lhs.kind)
      let rhsPinned = layoutPreference.isPinned(rhs.kind)
      if lhsPinned != rhsPinned { return lhsPinned }
      let lhsHasData = hasRecentData[lhs.kind] == true
      let rhsHasData = hasRecentData[rhs.kind] == true
      if lhsHasData != rhsHasData { return lhsHasData }
      return (order[lhs.kind] ?? .max) < (order[rhs.kind] ?? .max)
    }
  }

  private var columnCount: Int {
    HealthMetricWaterfallDistribution.columnCount(for: availableWidth)
  }

  private var effectiveVisibleMetricCount: Int {
    HealthMetricWaterfallDistribution.visibleCount(
      requested: visibleMetricCount,
      total: prioritizedSeries.count,
      columnCount: columnCount
    )
  }

  private var nextVisibleMetricCount: Int {
    HealthMetricWaterfallDistribution.expandedVisibleCount(
      current: effectiveVisibleMetricCount,
      total: prioritizedSeries.count,
      columnCount: columnCount
    )
  }

  private var visibleSeries: [HealthMetricSeries] {
    Array(prioritizedSeries.prefix(effectiveVisibleMetricCount))
  }

  private var visibleMetricKinds: [HealthObservationKind] {
    visibleSeries.map(\.kind)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.m) {
      HStack(alignment: .firstTextBaseline) {
        Text("全部健康趋势")
          .font(DaydayType.sectionTitle)
        Spacer()
        HealthDashboardLayoutPicker(
          kinds: allKinds,
          visibleKinds: $visibleKinds,
          preference: $layoutPreference
        )
        HealthMetricFocusPicker(kinds: allKinds, selection: $visibleKinds)
      }

      HealthMetricWaterfallLayout(spacing: DaydaySpace.m) {
        ForEach(visibleSeries) { item in
          metricCard(item)
            .healthMetricWaterfallSpan(expandedMetric == item.kind ? 2 : 1)
            .draggable(item.kind.rawValue)
            .dropDestination(for: String.self) { identifiers, _ in
              guard let identifier = identifiers.first,
                let dragged = HealthObservationKind(rawValue: identifier)
              else { return false }
              layoutPreference.move(dragged, before: item.kind, available: allKinds)
              return true
            }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .animation(metricSelectionAnimation, value: expandedMetric)
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: HealthMetricWaterfallWidthPreferenceKey.self,
            value: geometry.size.width
          )
        }
      }
      .onPreferenceChange(HealthMetricWaterfallWidthPreferenceKey.self) { width in
        guard width > 0, abs(width - availableWidth) > 0.5 else { return }
        availableWidth = width
      }
      .onChange(of: visibleMetricKinds) { _, visibleKinds in
        guard let expandedMetric, !visibleKinds.contains(expandedMetric) else { return }
        self.expandedMetric = nil
      }

      if effectiveVisibleMetricCount < prioritizedSeries.count {
        Button("查看更多健康趋势", systemImage: "chevron.down") {
          visibleMetricCount = nextVisibleMetricCount
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .frame(maxWidth: .infinity)
        .accessibilityHint("继续显示健康趋势，并补齐当前卡片行")
      }
    }
  }

  private func metricCard(_ item: HealthMetricSeries) -> some View {
    let isExpanded = expandedMetric == item.kind
    return HealthMetricWaterfallCard(
      series: item,
      coverage: coverageByKind[item.kind],
      range: rangeSelections.range(for: item.kind),
      isSelected: selectedMetric == item.kind,
      isExpanded: isExpanded,
      isProminent: [.heartRate, .stepCount, .sleepAnalysis].contains(item.kind),
      cardSize: layoutPreference.cardSize(for: item.kind),
      archiveRevision: archiveRevision,
      now: now,
      exactSampleProvider: exactSampleProvider,
      select: {
        guard selectedMetric != item.kind else { return }
        withAnimation(metricSelectionAnimation) {
          selectedMetric = item.kind
        }
      },
      toggleExpansion: {
        withAnimation(metricSelectionAnimation) {
          selectedMetric = item.kind
          expandedMetric = isExpanded ? nil : item.kind
        }
      },
      setRange: { nextRange in
        rangeSelections.set(nextRange, for: item.kind)
      }
    )
    .equatable()
  }
}

struct HealthMetricVisibilityPreference: Equatable {
  static let storageKey = "dayday.health.focused-metrics.v1"
  static let allToken = "*"
  static let recommended: Set<HealthObservationKind> = [
    .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .stepCount,
    .activeEnergyBurned, .appleExerciseTime, .sleepAnalysis, .respiratoryRate,
    .oxygenSaturation, .bodyMass, .bodyMassIndex, .dietaryWater,
  ]

  static func decode(
    _ storedValue: String,
    available: Set<HealthObservationKind>
  ) -> Set<HealthObservationKind> {
    guard storedValue != allToken else { return available }
    let decoded = Set(
      storedValue.split(separator: ",").compactMap {
        HealthObservationKind(rawValue: String($0))
      }
    ).intersection(available)
    return decoded.isEmpty ? available : decoded
  }

  static func encode(
    _ selection: Set<HealthObservationKind>,
    available: Set<HealthObservationKind>
  ) -> String {
    let bounded = selection.intersection(available)
    guard !bounded.isEmpty, bounded != available else { return allToken }
    return bounded.map(\.rawValue).sorted().joined(separator: ",")
  }
}

private struct HealthMetricFocusPicker: View {
  let kinds: [HealthObservationKind]
  @Binding var selection: Set<HealthObservationKind>
  @State private var isPresented = false
  @State private var searchText = ""

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: DaydaySpace.s) {
        Image(systemName: "slider.horizontal.3")
          .foregroundStyle(.tint)
        Text("关注指标")
        Text("\(selection.count)/\(kinds.count)")
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: DaydaySpace.m) {
        HStack {
          Text("关注指标").font(DaydayType.sectionTitle)
          Spacer()
          Button("全部") { selection = Set(kinds) }
          Button("常用") {
            let next = HealthMetricVisibilityPreference.recommended.intersection(Set(kinds))
            selection = next.isEmpty ? Set(kinds) : next
          }
        }
        TextField("搜索健康指标", text: $searchText)
          .textFieldStyle(.roundedBorder)

        DaydayScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(HealthArchiveKindGroup.allCases.sorted { $0.sortOrder < $1.sortOrder }) {
              group in
              let matches = matchingKinds(in: group)
              if !matches.isEmpty {
                Text(group.title)
                  .font(DaydayType.metadata)
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, DaydaySpace.s)
                  .padding(.top, DaydaySpace.m)
                  .padding(.bottom, DaydaySpace.xs)
                ForEach(matches) { kind in metricRow(kind) }
              }
            }
          }
        }
      }
      .padding(DaydaySpace.l)
      .frame(width: 380, height: 500)
      .onDisappear { searchText = "" }
    }
    .accessibilityLabel("关注指标")
    .accessibilityValue("已显示 \(selection.count) 项，共 \(kinds.count) 项")
  }

  private func matchingKinds(in group: HealthArchiveKindGroup) -> [HealthObservationKind] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return kinds.filter {
      $0.healthGroup == group
        && (query.isEmpty || $0.healthDisplayName.localizedCaseInsensitiveContains(query)
          || $0.rawValue.localizedCaseInsensitiveContains(query))
    }
  }

  private func metricRow(_ kind: HealthObservationKind) -> some View {
    Button {
      if selection.contains(kind) {
        guard selection.count > 1 else { return }
        selection.remove(kind)
      } else {
        selection.insert(kind)
      }
    } label: {
      HStack(spacing: DaydaySpace.s) {
        Circle().fill(kind.healthTint).frame(width: 8, height: 8)
        Text(kind.healthDisplayName)
        Spacer()
        Image(systemName: selection.contains(kind) ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selection.contains(kind) ? Color.accentColor : .secondary)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, DaydaySpace.s)
      .padding(.vertical, DaydaySpace.s)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selection.contains(kind) ? .isSelected : [])
  }
}

private struct HealthDashboardLayoutPicker: View {
  let kinds: [HealthObservationKind]
  @Binding var visibleKinds: Set<HealthObservationKind>
  @Binding var preference: HealthDashboardLayoutPreference
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Label("布局", systemImage: "rectangle.3.group")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: DaydaySpace.m) {
        Text("健康仪表盘").font(DaydayType.sectionTitle)
        Text("布局设置只保存在这台 Mac，不会读取或复制健康数值。")
          .font(DaydayType.metadata)
          .foregroundStyle(.secondary)

        HStack(spacing: DaydaySpace.s) {
          ForEach(HealthDashboardPreset.allCases) { preset in
            Button(preset.title) { apply(preset) }
              .buttonStyle(.bordered)
              .controlSize(.small)
          }
        }

        Divider()
        Text("固定项优先；其余卡片先显示近 7 天有数据的指标，再按这里的顺序排列。")
          .font(DaydayType.metadata)
          .foregroundStyle(.secondary)

        DaydayScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(preference.orderedKinds(available: kinds).enumerated()), id: \.element) {
              index, kind in
              HStack(spacing: DaydaySpace.s) {
                Circle().fill(kind.healthTint).frame(width: 8, height: 8)
                Text(kind.healthDisplayName).lineLimit(1)
                Spacer()
                Button {
                  preference.togglePinned(kind)
                } label: {
                  Image(systemName: preference.isPinned(kind) ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .help(preference.isPinned(kind) ? "取消固定" : "固定在前")

                Menu(preference.cardSize(for: kind).title) {
                  ForEach(HealthMetricCardSize.allCases, id: \.self) { size in
                    Button(size.title) { preference.setCardSize(size, for: kind) }
                  }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 56)

                Button {
                  preference.move(kind, by: -1, available: kinds)
                } label: {
                  Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                Button {
                  preference.move(kind, by: 1, available: kinds)
                } label: {
                  Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(index == kinds.count - 1)
              }
              .padding(.horizontal, DaydaySpace.s)
              .padding(.vertical, DaydaySpace.s)
            }
          }
        }
      }
      .padding(DaydaySpace.l)
      .frame(width: 460, height: 510)
    }
    .accessibilityLabel("调整健康仪表盘布局")
  }

  private func apply(_ preset: HealthDashboardPreset) {
    preference.apply(preset, available: kinds)
    let next = Set(preset.preferredKinds).intersection(Set(kinds))
    visibleKinds = next.isEmpty ? Set(kinds) : next
  }
}

private struct HealthMetricWaterfallCard: View, Equatable {
  let series: HealthMetricSeries
  let coverage: HealthObservationCoverage?
  let range: HealthMetricTrendRange
  let isSelected: Bool
  let isExpanded: Bool
  let isProminent: Bool
  let cardSize: HealthMetricCardSize
  let archiveRevision: UInt64
  let now: Date
  let exactSampleProvider:
    (HealthObservationKind, HealthMetricPoint) async -> HealthMetricExactSample?
  let select: () -> Void
  let toggleExpansion: () -> Void
  let setRange: (HealthMetricTrendRange) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.series == rhs.series && lhs.coverage == rhs.coverage && lhs.range == rhs.range
      && lhs.isSelected == rhs.isSelected && lhs.isExpanded == rhs.isExpanded
      && lhs.isProminent == rhs.isProminent && lhs.archiveRevision == rhs.archiveRevision
      && lhs.cardSize == rhs.cardSize
      && lhs.now == rhs.now
  }

  private var chartHeight: CGFloat {
    if isExpanded { return 232 }
    if cardSize == .compact { return isProminent ? 92 : 80 }
    return isProminent ? 112 : 96
  }

  var body: some View {
    let summary = HealthMetricPresentationAdapter.cardSummary(
      from: series,
      range: range,
      now: now
    )
    VStack(alignment: .leading, spacing: DaydaySpace.s) {
      HStack(alignment: .top, spacing: DaydaySpace.s) {
        Button(action: select) {
          VStack(alignment: .leading, spacing: 3) {
            Label(series.kind.healthDisplayName, systemImage: series.kind.healthSymbolName)
              .font(DaydayType.detail.weight(.semibold))
              .foregroundStyle(series.kind.healthTint)
            HStack(alignment: .firstTextBaseline, spacing: DaydaySpace.s) {
              Text(
                summary.value.map { formatMetricValue($0, kind: series.kind) } ?? "—"
              )
              .font(.system(size: isProminent ? 22 : 20, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.primary)
              Text(summary.value == nil ? "等待数据" : summary.contextLabel)
                .font(DaydayType.metadata)
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "选择\(series.kind.healthDisplayName)，\(summary.contextLabel)\(summary.value.map { formatMetricValue($0, kind: series.kind) } ?? "暂无数据")"
        )

        HStack(spacing: 0) {
          HealthMetricInfoButton(kind: series.kind, coverage: coverage, series: series)

          Button(action: toggleExpansion) {
            Image(
              systemName: isExpanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right"
            )
            .font(.system(size: 13, weight: .medium))
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(isExpanded ? series.kind.healthTint : .secondary)
          .help(
            isExpanded
              ? "收起\(series.kind.healthDisplayName)趋势" : "展开\(series.kind.healthDisplayName)趋势"
          )
          .accessibilityLabel(
            isExpanded
              ? "收起\(series.kind.healthDisplayName)趋势" : "展开\(series.kind.healthDisplayName)趋势"
          )
          .accessibilityHint(
            isExpanded
              ? "恢复为概览卡片，其他指标会重新排列"
              : "在当前位置放大这张卡片，其他指标会根据窗口宽度重新排列"
          )
        }
      }

      Picker("\(series.kind.healthDisplayName)时间范围", selection: animatedRange) {
        ForEach(HealthMetricTrendRange.allCases) { candidate in
          Text(candidate.compactTitle).tag(candidate)
        }
      }
      .pickerStyle(.segmented)
      .controlSize(.mini)
      .labelsHidden()

      HealthMetricLineChart(
        series: series,
        range: range,
        now: now,
        tint: series.kind.healthTint,
        height: chartHeight,
        showsAxisUnit: false,
        displayMode: isExpanded ? .expanded : .compact,
        archiveRevision: archiveRevision,
        exactSampleProvider: exactSampleProvider
      )
    }
    .padding(DaydaySpace.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      series.kind.healthTint.opacity(isSelected ? 0.085 : 0.025),
      in: RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
        .stroke(
          isSelected ? series.kind.healthTint.opacity(0.48) : Color.primary.opacity(0.065),
          lineWidth: isSelected ? 1.2 : DaydayDepth.hairline
        )
    }
    .animation(.easeOut(duration: 0.16), value: isSelected)
  }

  private var animatedRange: Binding<HealthMetricTrendRange> {
    Binding(
      get: { range },
      set: { nextRange in
        guard nextRange != range else { return }
        setRange(nextRange)
      }
    )
  }
}

struct HealthMetricCardRangeSelections: Equatable {
  private var rangesByKind: [HealthObservationKind: HealthMetricTrendRange] = [:]

  func range(for kind: HealthObservationKind) -> HealthMetricTrendRange {
    rangesByKind[kind] ?? .week
  }

  mutating func set(_ range: HealthMetricTrendRange, for kind: HealthObservationKind) {
    rangesByKind[kind] = range
  }
}

private struct HealthMetricWaterfallWidthPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct HealthMetricWaterfallSpanKey: LayoutValueKey {
  static let defaultValue = 1
}

extension View {
  fileprivate func healthMetricWaterfallSpan(_ span: Int) -> some View {
    layoutValue(key: HealthMetricWaterfallSpanKey.self, value: max(1, span))
  }
}

struct HealthMetricWaterfallPlacementPlan: Equatable {
  struct Item: Equatable {
    let index: Int
    let frame: CGRect
  }

  let items: [Item]
  let size: CGSize
}

enum HealthMetricWaterfallPlacementPlanner {
  struct Item: Equatable {
    let span: Int
    let height: CGFloat

    init(span: Int = 1, height: CGFloat) {
      self.span = span
      self.height = height
    }
  }

  static func plan(
    availableWidth: CGFloat,
    spacing: CGFloat,
    items: [Item]
  ) -> HealthMetricWaterfallPlacementPlan {
    let width = max(0, availableWidth)
    let gap = max(0, spacing)
    let columnCount = HealthMetricWaterfallDistribution.columnCount(for: width)
    guard !items.isEmpty, width > 0 else {
      return HealthMetricWaterfallPlacementPlan(items: [], size: CGSize(width: width, height: 0))
    }

    let columnWidth = max(0, (width - CGFloat(columnCount - 1) * gap) / CGFloat(columnCount))
    var columnBottoms = Array(repeating: CGFloat.zero, count: columnCount)
    var placements: [HealthMetricWaterfallPlacementPlan.Item] = []
    placements.reserveCapacity(items.count)

    for (index, item) in items.enumerated() {
      let span = min(max(1, item.span), columnCount)
      let finalStartingColumn = columnCount - span
      var selectedColumn = 0
      var selectedY = CGFloat.greatestFiniteMagnitude

      for startingColumn in 0...finalStartingColumn {
        let candidateY = columnBottoms[startingColumn..<(startingColumn + span)].max() ?? 0
        if candidateY < selectedY {
          selectedColumn = startingColumn
          selectedY = candidateY
        }
      }

      let itemWidth = columnWidth * CGFloat(span) + gap * CGFloat(span - 1)
      let frame = CGRect(
        x: CGFloat(selectedColumn) * (columnWidth + gap),
        y: selectedY,
        width: itemWidth,
        height: max(0, item.height)
      )
      placements.append(.init(index: index, frame: frame))

      let nextBottom = frame.maxY + gap
      for column in selectedColumn..<(selectedColumn + span) {
        columnBottoms[column] = nextBottom
      }
    }

    let contentHeight = max(0, (columnBottoms.max() ?? gap) - gap)
    return HealthMetricWaterfallPlacementPlan(
      items: placements,
      size: CGSize(width: width, height: contentHeight)
    )
  }
}

private struct HealthMetricWaterfallLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    makePlan(
      availableWidth: resolvedWidth(proposal: proposal, subviews: subviews), subviews: subviews
    )
    .size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let plan = makePlan(availableWidth: bounds.width, subviews: subviews)
    for placement in plan.items {
      let frame = placement.frame.offsetBy(dx: bounds.minX, dy: bounds.minY)
      subviews[placement.index].place(
        at: frame.origin,
        anchor: .topLeading,
        proposal: ProposedViewSize(width: frame.width, height: frame.height)
      )
    }
  }

  private func makePlan(
    availableWidth: CGFloat,
    subviews: Subviews
  ) -> HealthMetricWaterfallPlacementPlan {
    let columnCount = HealthMetricWaterfallDistribution.columnCount(for: availableWidth)
    let columnWidth = max(
      0,
      (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
    )
    let items = subviews.map { subview in
      let span = min(max(1, subview[HealthMetricWaterfallSpanKey.self]), columnCount)
      let width = columnWidth * CGFloat(span) + spacing * CGFloat(span - 1)
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      return HealthMetricWaterfallPlacementPlanner.Item(span: span, height: size.height)
    }
    return HealthMetricWaterfallPlacementPlanner.plan(
      availableWidth: availableWidth,
      spacing: spacing,
      items: items
    )
  }

  private func resolvedWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
    if let width = proposal.width, width.isFinite, width > 0 { return width }
    return subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
  }
}

private struct HealthMetricInfoButton: View {
  let kind: HealthObservationKind
  let coverage: HealthObservationCoverage?
  let series: HealthMetricSeries?
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Image(systemName: "info.circle")
        .font(.system(size: 13, weight: .medium))
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("查看\(kind.healthDisplayName)档案信息")
    .popover(isPresented: $isPresented, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: DaydaySpace.m) {
        Label(kind.healthDisplayName, systemImage: kind.healthSymbolName)
          .font(DaydayType.sectionTitle)
          .foregroundStyle(kind.healthTint)
        LabeledContent("本机样本", value: coverage?.observationCount.formatted() ?? "0")
        LabeledContent(
          "最近记录",
          value: coverage?.latestEndedAt.map(healthArchiveTimestamp) ?? "暂无"
        )
        Divider()
        Text(metricAggregationNote)
          .font(DaydayType.metadata)
          .foregroundStyle(.secondary)
      }
      .padding(DaydaySpace.l)
      .frame(width: 280, alignment: .leading)
    }
  }

  private var metricAggregationNote: String {
    switch kind {
    case .heartRate, .restingHeartRate, .walkingHeartRateAverage:
      "趋势按时间段显示平均 BPM；卡片显示最近一次心率。"
    case .stepCount:
      "按小时协调多个设备来源后累计，减少 iPhone 与 Apple Watch 重叠计数。"
    case .sleepAnalysis:
      "只累计已入睡阶段，不把卧床或清醒时段计入睡眠时长。"
    default:
      switch series?.aggregation {
      case .discreteAverage:
        "卡片显示最近一次样本；趋势按所选时间粒度显示客观平均值。"
      case .cumulativeSum:
        "按小时协调多个来源后累计，避免明显重叠的设备记录被盲目相加。"
      case .duration:
        "趋势按事实记录中的持续时间汇总，不生成评分或健康结论。"
      case nil:
        "数值来自已同步到本机的 Apple 健康事实。"
      }
    }
  }
}

private struct HealthDashboardMetricPanel<Header: View, Content: View>: View {
  @ViewBuilder let header: Header
  @ViewBuilder let content: Content

  init(
    @ViewBuilder header: () -> Header,
    @ViewBuilder content: () -> Content
  ) {
    self.header = header()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.m) {
      header
      content
    }
    .padding(DaydaySpace.l)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.76),
      in: RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
        .stroke(Color.primary.opacity(0.065), lineWidth: DaydayDepth.hairline)
    }
  }
}

private struct HealthDashboardPanelHeader<Trailing: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let trailing: Trailing

  init(
    title: String,
    systemImage: String,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.systemImage = systemImage
    self.trailing = trailing()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DaydaySpace.m) { headerContent }
      VStack(alignment: .leading, spacing: DaydaySpace.s) { headerContent }
    }
  }

  @ViewBuilder
  private var headerContent: some View {
    Label(title, systemImage: systemImage)
      .font(DaydayType.sectionTitle)
    Spacer(minLength: 0)
    trailing
  }
}

private struct HealthArchiveFilterBar: View {
  @Binding var selectedKind: HealthObservationKind?

  var body: some View {
    DaydayThemeReader { theme, _ in
      HStack(spacing: DaydaySpace.m) {
        HealthArchiveKindPicker(selection: $selectedKind)
          .frame(width: 260, alignment: .leading)
        Label("最近一年", systemImage: "calendar")
          .font(DaydayType.detail)
          .foregroundStyle(.secondary)
        Spacer(minLength: DaydaySpace.m)
        if selectedKind != nil {
          Button("清除类型", systemImage: "xmark.circle") {
            selectedKind = nil
          }
          .help("恢复为全部健康档案")
        }
      }
      .padding(DaydaySpace.m)
      .background(
        theme[.surfaceRaised],
        in: RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
          .stroke(theme[.separator], lineWidth: DaydayDepth.hairline)
      }
    }
  }
}

private struct HealthArchiveKindPicker: View {
  @Binding var selection: HealthObservationKind?
  @State private var isPresented = false
  @State private var searchText = ""

  private var normalizedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: DaydaySpace.s) {
        Image(systemName: selection == nil ? "square.stack.3d.up" : "circle.fill")
          .foregroundStyle(selection?.healthTint ?? Color.accentColor)
          .accessibilityHidden(true)
        Text(selection?.healthDisplayName ?? "全部档案")
        Spacer(minLength: DaydaySpace.s)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.bordered)
    .accessibilityLabel("健康类型")
    .accessibilityValue(selection?.healthDisplayName ?? "全部档案")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: DaydaySpace.m) {
        Text("选择健康类型")
          .font(DaydayType.sectionTitle)

        TextField("搜索健康类型", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("搜索健康类型")

        DaydayScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            kindRow(nil, title: "全部档案", tint: .accentColor)

            Divider().padding(.vertical, DaydaySpace.s)

            ForEach(
              HealthArchiveKindGroup.allCases.sorted { $0.sortOrder < $1.sortOrder }
            ) { group in
              let kinds = matchingKinds(in: group)
              if !kinds.isEmpty {
                Text(group.title)
                  .font(DaydayType.metadata)
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, DaydaySpace.s)
                  .padding(.top, DaydaySpace.m)
                  .padding(.bottom, DaydaySpace.xs)
                ForEach(kinds) { kind in
                  kindRow(kind, title: kind.healthDisplayName, tint: kind.healthTint)
                }
              }
            }
          }
        }
      }
      .padding(DaydaySpace.l)
      .frame(width: 360, height: 460)
      .onDisappear { searchText = "" }
    }
  }

  private func matchingKinds(in group: HealthArchiveKindGroup) -> [HealthObservationKind] {
    HealthObservationKind.allCases
      .filter { kind in
        guard kind.healthGroup == group else { return false }
        guard !normalizedSearch.isEmpty else { return true }
        return kind.healthDisplayName.localizedCaseInsensitiveContains(normalizedSearch)
          || kind.rawValue.localizedCaseInsensitiveContains(normalizedSearch)
      }
      .sorted { $0.healthDisplayName.localizedCompare($1.healthDisplayName) == .orderedAscending }
  }

  private func kindRow(
    _ kind: HealthObservationKind?,
    title: String,
    tint: Color
  ) -> some View {
    Button {
      selection = kind
      isPresented = false
    } label: {
      HStack(spacing: DaydaySpace.s) {
        Circle()
          .fill(tint)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
        Text(title)
        Spacer()
        if selection == kind {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
      .padding(.horizontal, DaydaySpace.s)
      .padding(.vertical, DaydaySpace.s)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selection == kind ? .isSelected : [])
  }
}

private struct HealthArchiveCoverageSummary: View {
  let density: HealthArchiveDensityPresentation

  var body: some View {
    DaydayThemeReader { theme, _ in
      ViewThatFits(in: .horizontal) {
        HStack(spacing: DaydaySpace.xl) {
          metric(density.observationCount.formatted(), label: "最近一年记录", theme: theme)
          metric("\(density.activeDayCount) 天", label: "有记录日期", theme: theme)
          metric(density.maximumDayCount.formatted(), label: "单日最高记录数", theme: theme)
          Spacer()
        }
        VStack(alignment: .leading, spacing: DaydaySpace.m) {
          metric(density.observationCount.formatted(), label: "最近一年记录", theme: theme)
          metric("\(density.activeDayCount) 天", label: "有记录日期", theme: theme)
          metric(density.maximumDayCount.formatted(), label: "单日最高记录数", theme: theme)
        }
      }
      .padding(.horizontal, DaydaySpace.xs)
    }
  }

  private func metric(_ value: String, label: String, theme: DaydayTheme) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.title3.weight(.semibold).monospacedDigit())
        .contentTransition(.numericText())
      Text(label)
        .font(DaydayType.metadata)
        .foregroundStyle(theme[.textSecondary])
    }
    .frame(minWidth: 112, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label)，\(value)")
  }
}

private struct HealthArchiveSelectedKindSummary: View {
  let coverage: HealthObservationCoverage

  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.l) {
      HStack(spacing: DaydaySpace.m) {
        Circle()
          .fill(coverage.kind.healthTint.opacity(0.16))
          .frame(width: 40, height: 40)
          .overlay {
            Circle().fill(coverage.kind.healthTint).frame(width: 12, height: 12)
          }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(coverage.kind.healthDisplayName)
            .font(DaydayType.sectionTitle)
          Text(coverage.kind.healthGroup.title)
            .font(DaydayType.metadata)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(coverage.observationCount.formatted())
          .font(.title2.weight(.semibold).monospacedDigit())
        Text("最近一年入档记录")
          .font(DaydayType.metadata)
          .foregroundStyle(.secondary)
      }

      if let latest = coverage.latestEndedAt {
        LabeledContent("最近记录") {
          Text(healthArchiveFullTimestamp(latest))
            .monospacedDigit()
        }
        .font(DaydayType.detail)
      }
    }
    .accessibilityElement(children: .contain)
  }
}

private struct HealthArchiveSelectionEmpty: View {
  let selectedKind: HealthObservationKind?
  let clearKind: () -> Void

  var body: some View {
    VStack(spacing: DaydaySpace.l) {
      EmptyState(
        title: "最近一年没有健康记录",
        detail: "这只表示当前健康类型在最近一年没有入档事实，不代表 Apple 健康授权失败。",
        systemImage: "calendar.badge.questionmark"
      )

      ViewThatFits(in: .horizontal) {
        HStack(spacing: DaydaySpace.m) { recoveryButtons }
        VStack(spacing: DaydaySpace.s) { recoveryButtons }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 280)
  }

  @ViewBuilder
  private var recoveryButtons: some View {
    if selectedKind != nil {
      Button("清除健康类型", systemImage: "xmark.circle", action: clearKind)
    }
  }
}

private struct HealthArchiveLoadingDashboard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.xl) {
      RoundedRectangle(cornerRadius: DaydayRadius.partition)
        .fill(.primary.opacity(0.07))
        .frame(height: 48)

      HStack(spacing: DaydaySpace.xl) {
        placeholderMetric
        placeholderMetric
        placeholderMetric
        Spacer()
      }

      RoundedRectangle(cornerRadius: DaydayRadius.partition)
        .fill(.primary.opacity(0.055))
        .frame(minHeight: 280)

      RoundedRectangle(cornerRadius: DaydayRadius.partition)
        .fill(.primary.opacity(0.04))
        .frame(minHeight: 220)
    }
    .redacted(reason: .placeholder)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("正在准备本机健康档案")
  }

  private var placeholderMetric: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.xs) {
      RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.09)).frame(width: 76, height: 20)
      RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.06)).frame(width: 96, height: 10)
    }
  }
}

private struct HealthSyncAndSources: View {
  @ObservedObject var archive: HealthArchiveModel
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: DaydaySpace.l) {
        Label(archive.compactSyncStatus, systemImage: syncStatusSymbol)
          .font(DaydayType.detail.weight(.medium))
          .foregroundStyle(.secondary)
          .accessibilityElement(children: .combine)

        if let summary = archive.dashboard?.summary {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: DaydaySpace.xl) {
              syncMetric(summary.observationCount.formatted(), label: "本机事实")
              syncMetric(
                "\(summary.coveredKindCount) / \(HealthObservationKind.allCases.count)",
                label: "覆盖类型"
              )
              syncMetric(summary.sourceInstallationCount.formatted(), label: "iPhone 来源")
              syncMetric(summary.receivedBatchCount.formatted(), label: "成功批次")
              Spacer()
            }
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 120), spacing: DaydaySpace.l)],
              alignment: .leading,
              spacing: DaydaySpace.m
            ) {
              syncMetric(summary.observationCount.formatted(), label: "本机事实")
              syncMetric(
                "\(summary.coveredKindCount) / \(HealthObservationKind.allCases.count)",
                label: "覆盖类型"
              )
              syncMetric(summary.sourceInstallationCount.formatted(), label: "iPhone 来源")
              syncMetric(summary.receivedBatchCount.formatted(), label: "成功批次")
            }
          }

          HStack(spacing: DaydaySpace.s) {
            Image(systemName: "calendar")
            Text(archiveRange(summary))
          }
          .font(DaydayType.metadata)
          .foregroundStyle(.secondary)
        }

        Divider()
        HealthSourceCoverageList(coverage: archive.dashboard?.coverage ?? [])
        Label(
          "这里显示已经到达 Mac 的客观覆盖；读取授权的具体开关仍以 iPhone 的“健康”设置为准。",
          systemImage: "lock.shield"
        )
        .font(DaydayType.metadata)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        Divider()
        HealthSyncHistory(receipts: archive.dashboard?.recentSyncs ?? [])
        Divider()
        HealthPairingControls(archive: archive)

        if let message = archive.archiveActionMessage {
          Label(message, systemImage: "info.circle")
            .font(DaydayType.metadata)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
      }
      .padding(.top, DaydaySpace.m)
    } label: {
      Label("数据与来源", systemImage: "externaldrive.connected.to.line.below")
        .font(DaydayType.detail.weight(.medium))
    }
    .padding(DaydaySpace.l)
    .background(
      .primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
    )
    .accessibilityHint("展开后可查看本机覆盖范围、同步批次、来源与配对设置")
  }

  private var syncStatusSymbol: String {
    switch archive.transferState {
    case .receiving: "arrow.triangle.2.circlepath"
    case .persisted: "checkmark.circle.fill"
    case .incomplete: "exclamationmark.circle"
    case .notPaired, .waitingForIPhone: "iphone"
    }
  }

  private func archiveRange(_ summary: HealthArchiveSummary) -> String {
    guard let earliest = summary.earliestEndedAt, let latest = summary.latestEndedAt else {
      return "尚无本机健康事实"
    }
    return
      "档案范围：\(earliest.formatted(date: .abbreviated, time: .omitted)) 至 \(latest.formatted(date: .abbreviated, time: .omitted))"
  }

  private func syncMetric(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title3.weight(.semibold).monospacedDigit())
      Text(label).font(DaydayType.metadata).foregroundStyle(.secondary)
    }
    .frame(minWidth: 96, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct HealthSourceCoverageList: View {
  let coverage: [HealthObservationCoverage]
  @State private var showsAll = false

  private var orderedCoverage: [HealthObservationCoverage] {
    coverage.sorted {
      if $0.observationCount != $1.observationCount {
        return $0.observationCount > $1.observationCount
      }
      return $0.kind.healthDisplayName < $1.kind.healthDisplayName
    }
  }

  private var visibleCoverage: [HealthObservationCoverage] {
    Array(orderedCoverage.prefix(showsAll ? orderedCoverage.count : 8))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.m) {
      HStack {
        Text("本机类型覆盖").font(DaydayType.detail.weight(.semibold))
        Spacer()
        if orderedCoverage.count > 8 {
          Button(showsAll ? "收起" : "查看全部 \(orderedCoverage.count) 项") {
            showsAll.toggle()
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
        }
      }

      if visibleCoverage.isEmpty {
        Text("完成首次同步后，这里会列出已入档的健康类型。")
          .font(DaydayType.detail)
          .foregroundStyle(.secondary)
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 210), spacing: DaydaySpace.m)],
          alignment: .leading,
          spacing: DaydaySpace.s
        ) {
          ForEach(visibleCoverage) { item in
            HStack(spacing: DaydaySpace.s) {
              Circle().fill(item.kind.healthTint).frame(width: 7, height: 7)
              Text(item.kind.healthDisplayName).lineLimit(1)
              Spacer()
              Text(item.observationCount.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .font(DaydayType.metadata)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
              "\(item.kind.healthDisplayName)，\(item.observationCount) 条，最近记录 \(item.latestEndedAt.map(healthArchiveTimestamp) ?? "暂无")"
            )
          }
        }
      }
    }
  }
}

private struct HealthSyncHistory: View {
  let receipts: [HealthSyncReceipt]

  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.m) {
      Text("最近同步")
        .font(DaydayType.detail.weight(.semibold))

      if receipts.isEmpty {
        Text("尚无成功写入的同步批次。")
          .font(DaydayType.detail)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(receipts.enumerated()), id: \.element.id) { index, receipt in
            ViewThatFits(in: .horizontal) {
              HStack(spacing: DaydaySpace.m) {
                receiptStatus
                receiptDescription(receipt)
                Spacer()
                Text("成功")
                  .font(DaydayType.metadata.weight(.medium))
                  .foregroundStyle(.secondary)
              }
              HStack(alignment: .top, spacing: DaydaySpace.m) {
                receiptStatus
                receiptDescription(receipt)
                Spacer()
              }
            }
            .padding(.vertical, DaydaySpace.s)
            .accessibilityElement(children: .combine)
            if index < receipts.count - 1 { Divider() }
          }
        }
      }
    }
  }

  private var receiptStatus: some View {
    Image(systemName: "checkmark.circle.fill")
      .foregroundStyle(.green)
      .accessibilityHidden(true)
  }

  private func receiptDescription(_ receipt: HealthSyncReceipt) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(healthArchiveTimestamp(receipt.receivedAt))
        .font(DaydayType.metadata)
      Text("成功写入 \(receipt.observationCount.formatted()) 条")
        .font(DaydayType.detail)
      if receipt.tombstoneCount > 0 {
        Text("同时写入 \(receipt.tombstoneCount.formatted()) 条删除记录")
          .font(DaydayType.metadata)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private func healthArchiveTimestamp(_ date: Date) -> String {
  let components = Calendar.autoupdatingCurrent.dateComponents(
    [.month, .day, .hour, .minute],
    from: date
  )
  guard
    let month = components.month,
    let day = components.day,
    let hour = components.hour,
    let minute = components.minute
  else {
    return date.formatted(date: .numeric, time: .shortened)
  }
  return String(format: "%d月%d日 %02d:%02d", month, day, hour, minute)
}

private func healthArchiveFullTimestamp(_ date: Date) -> String {
  let components = Calendar.autoupdatingCurrent.dateComponents(
    [.year, .month, .day, .hour, .minute],
    from: date
  )
  guard
    let year = components.year,
    let month = components.month,
    let day = components.day,
    let hour = components.hour,
    let minute = components.minute
  else {
    return date.formatted(date: .numeric, time: .shortened)
  }
  return String(format: "%d年%d月%d日 %02d:%02d", year, month, day, hour, minute)
}

private struct HealthPairingControls: View {
  @ObservedObject var archive: HealthArchiveModel

  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.m) {
      Text("连接与配对")
        .font(DaydayType.detail.weight(.semibold))
      LabeledContent("配对状态") { Text(archive.pairingState.title) }
      LabeledContent("当前传输") { Text(archive.transferState.title) }
      pairingActions
      Text("配对码仅用于同一 Wi-Fi 下的本机加密同步。")
        .font(DaydayType.metadata)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var pairingActions: some View {
    switch archive.pairingState {
    case .starting(let setupCode), .ready(let setupCode):
      ViewThatFits(in: .horizontal) {
        HStack { pairingButtons(setupCode: setupCode) }
        VStack(alignment: .leading, spacing: DaydaySpace.s) {
          pairingButtons(setupCode: setupCode)
        }
      }
      if archive.pairingCodeIsVisible {
        Text(setupCode)
          .font(.title3.weight(.semibold).monospaced())
          .monospacedDigit()
          .textSelection(.enabled)
          .accessibilityLabel("配对码 \(setupCode)")
      }
    case .notPaired, .failed:
      Button("准备 iPhone 配对", systemImage: "iphone.gen3.radiowaves.left.and.right") {
        archive.preparePairing()
      }
    }
  }

  @ViewBuilder
  private func pairingButtons(setupCode: String) -> some View {
    Button(archive.pairingCodeIsVisible ? "隐藏配对码" : "显示配对码") {
      archive.pairingCodeIsVisible ? archive.hidePairingCode() : archive.revealPairingCode()
    }
    if archive.pairingCodeIsVisible {
      Button("复制配对码", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupCode, forType: .string)
      }
    }
    Button("取消配对", role: .destructive) { archive.revokePairing() }
  }
}
