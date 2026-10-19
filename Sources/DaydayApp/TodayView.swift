import AppKit
import DaydayCore
import SwiftUI
import UniformTypeIdentifiers

struct TodayView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var runtime: AppRuntimeModel
  @ObservedObject var weather: WeatherRuntime
  @ObservedObject var dailyWorkScheduleSettings: DailyWorkScheduleSettingsModel
  /// These models are observed by the narrow pulse column only. Keeping the
  /// evidence thread outside their observation scope prevents live counters
  /// from rebuilding the full timeline on every coalesced input update.
  let input: InputInsightsModel
  let applicationUsage: ApplicationUsageInsightsModel
  let onOpenHistory: () -> Void
  let onOpenInsights: () -> Void
  @State private var timelineItemLimit = TodayTimelineWindow.initialItemLimit
  @State private var timelineScrollTargetID: String?
  @State private var pulseProjectionNow = Date.now

  var body: some View {
    let pulseOverview = TodayOverviewPresentationAdapter.make(
      timeline: runtime.todayTimeline,
      report: .init(hasDraft: false, isGenerating: false, isReady: false),
      now: pulseProjectionNow,
      timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
    )
    let pulseTimelineProjection = TodayDashboardPresentationAdapter.makeTimelineProjection(
      now: pulseProjectionNow,
      timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
      timelineItems: runtime.todayTimeline?.items ?? []
    )

    VStack(spacing: 0) {
      header

      ScrollViewReader { proxy in
        DaydayScrollView {
          VStack(alignment: .leading, spacing: 20) {
            collectionBanner
            contentColumns(
              overview: pulseOverview,
              timelineProjection: pulseTimelineProjection
            )
          }
          .padding(.horizontal, DaydaySpace.pageHorizontal)
          .padding(.top, DaydaySpace.pageContentTop)
          .padding(.bottom, DaydaySpace.pageHorizontal)
          .frame(maxWidth: 1180, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .onChange(of: timelineScrollTargetID) { _, targetID in
          guard let targetID else { return }
          Task { @MainActor in
            await Task.yield()
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
              proxy.scrollTo(targetID, anchor: .center)
            }
            timelineScrollTargetID = nil
          }
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      input.refresh(range: liveInputRange)
      let token = input.beginLivePresentation(range: liveInputRange)
      defer { input.endLivePresentation(token) }

      while !Task.isCancelled {
        await input.refreshLive(range: liveInputRange)
        // Aggregate changes normally arrive through Capture invalidations.
        // Keep only a slow insurance refresh while Today remains visible.
        try? await Task.sleep(for: .seconds(30))
      }
    }
    .task {
      // The visible formatter has minute-level precision. Advancing this open
      // interval twice per minute keeps it current without publishing and
      // rebuilding the pulse column every second.
      while !Task.isCancelled {
        applicationUsage.refreshVisibleDuration()
        try? await Task.sleep(for: .seconds(30))
      }
    }
    .task {
      // Roll the stable twelve-hour evidence window at most once per hour.
      // Live duration ticks stay inside TodayPulseColumn and never invalidate
      // this timeline-only projection.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        let now = Date.now
        guard
          !Calendar.autoupdatingCurrent.isDate(
            now,
            equalTo: pulseProjectionNow,
            toGranularity: .hour
          )
        else { continue }
        pulseProjectionNow = now
      }
    }
  }

  private var header: some View {
    PageHeaderBar(
      title: greeting,
      subtitle: Date.now.formatted(.dateTime.year().month(.wide).day().weekday(.wide)),
      systemImage: "sparkles"
    ) {
      weatherControls
    }
  }

  @ViewBuilder
  private var weatherControls: some View {
    if weather.state == .unconfigured {
      HStack(spacing: 10) {
        weatherSummary
        Button("配置天气", systemImage: "location") {
          weather.enableAutomaticDistrictWeather()
        }
        .buttonStyle(.bordered)
        .help("启用后会请求前台定位，用于查询并保存区级天气；不保存经纬度或地址")
      }
    } else if weather.state == .needsPermission {
      Button("授权定位", systemImage: "location.fill") {
        weather.requestLocationAuthorization()
      }
      .buttonStyle(.borderedProminent)
      .help("仅在你点击后请求 macOS 前台定位权限")
    } else {
      Button {
        weather.refreshIfNeeded(force: true)
      } label: {
        weatherSummary
      }
      .buttonStyle(.plain)
      .disabled(weather.state == .loading)
      .contentShape(Rectangle())
      .accessibilityLabel("\(weatherTitle)。点按更新天气")
      .help(weather.state == .loading ? "正在更新天气" : "点按更新天气")
    }
  }

  private var weatherSummary: some View {
    VStack(alignment: .trailing, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: weatherSymbol)
          .foregroundStyle(weatherColor)
          .accessibilityHidden(true)
        Text(weatherTitle)
      }
      .font(.callout.weight(.medium))

      Text(weatherDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private var collectionBanner: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        collectionStatusSummary(compact: false)
        Spacer(minLength: 12)
        permissionControls
      }
      VStack(alignment: .leading, spacing: 10) {
        collectionStatusSummary(compact: true)
        permissionControls
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      bannerColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func collectionStatusSummary(compact: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: bannerSymbol)
        .font(.body.weight(.semibold))
        .foregroundStyle(bannerColor)
        .accessibilityHidden(true)

      Text(bannerTitle)
        .font(.callout.weight(.semibold))

      if runtime.collectionStatus != .running {
        Text(bannerDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(compact ? 2 : 1)
      }
    }
  }

  private var permissionControls: some View {
    HStack(spacing: 8) {
      PermissionStatusBadge(category: "屏幕录制", state: runtime.snapshot.screenRecording)
      PermissionStatusBadge(category: "辅助功能", state: runtime.snapshot.accessibility)
      Button {
        runtime.requestRefresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(runtime.isRefreshing)
      .help("刷新本机状态")
    }
  }

  private func contentColumns(
    overview: TodayOverviewPresentation,
    timelineProjection: TodayDashboardPresentation
  ) -> some View {
    TodayContentColumnsLayout {
      timelineCard(overview: overview)
      TodayPulseColumn(
        runtimeSnapshot: runtime.snapshot,
        overview: overview,
        timelineProjection: timelineProjection,
        input: input,
        applicationUsage: applicationUsage,
        onOpenInsights: onOpenInsights,
        onSelectTimelineHour: selectTimelineHour
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func timelineCard(overview: TodayOverviewPresentation) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Label("今天发生了什么", systemImage: "list.bullet.rectangle")
          .font(.headline)
        Spacer()
        if let timeline = runtime.todayTimeline, timeline.state == .populated {
          Text("已载入 \(overview.timelineEntryCount) 个时间线条目")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Button("查看完整回放", systemImage: "arrow.up.right") {
          onOpenHistory()
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(.medium))
      }
      liveTimeline
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var liveTimeline: some View {
    if let presentation = runtime.todayTimeline {
      switch presentation.state {
      case .populated:
        let primaryItems = TodayTimelineWindow.primaryItems(from: presentation.items)
        let usesObjectiveFallback = TodayTimelineWindow.usesObjectiveFallback(
          from: presentation.items
        )
        let visibleItems = TodayTimelineWindow.visibleItems(
          from: primaryItems,
          limit: timelineItemLimit
        )
        let showsVisualInferences = primaryItems.first?.kind == .inferredActivity
        let canRevealMore = TodayTimelineWindow.canRevealMore(
          totalCount: primaryItems.count,
          currentLimit: timelineItemLimit
        )
        VStack(alignment: .leading, spacing: 0) {
          timelineContext(for: presentation)
          if usesObjectiveFallback {
            HStack(spacing: 8) {
              Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
              VStack(alignment: .leading, spacing: 2) {
                Text("AI 总结暂未覆盖最近时段，先显示最新本地事实")
                  .font(.caption.weight(.medium))
                Text("AI 正在归集或补充该时段；已记录的事实不会受影响。")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
          }
          LazyVStack(spacing: 0) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
              LiveTimelineRow(
                item: item,
                connectsToEarlierItem: index < visibleItems.count - 1,
                connectsToLaterItem: index > 0
              )
              .id(item.id)
            }
            if canRevealMore {
              TimelineRevealMoreRow(
                nextBatchCount: TodayTimelineWindow.nextBatchCount(
                  currentLimit: timelineItemLimit,
                  totalCount: primaryItems.count
                ),
                action: showMoreTimelineItems
              )
              .id(visibleItems.last?.id)
            } else if runtime.canLoadOlderTodayTimeline || runtime.todayTimelineLoadMoreFailed {
              TimelineLoadMoreRow(
                isLoading: runtime.isLoadingOlderTodayTimeline,
                failed: runtime.todayTimelineLoadMoreFailed,
                action: showMoreTimelineItems
              )
            }
          }
        }
        .onChange(of: presentation.boundary.startsAt) { _, _ in
          timelineItemLimit = TodayTimelineWindow.initialItemLimit
        }
        .onChange(of: showsVisualInferences) { _, _ in
          timelineItemLimit = TodayTimelineWindow.initialItemLimit
        }
      case .empty:
        EmptyState(
          title: "今天还没有本地事实",
          detail: "完成“应用与窗口上下文”的确认和系统权限后，应用切换会显示在这里。",
          systemImage: "clock.badge.questionmark"
        )
      case .permission:
        EmptyState(
          title: "需要辅助功能权限",
          detail: "已有的本地事实会保留；完成权限设置后可继续记录。",
          systemImage: "accessibility"
        )
      case .failure:
        EmptyState(
          title: "无法读取本地时间线",
          detail: "记录已安全停止或数据存储不可用；请重新启动 App 后重试。",
          systemImage: "externaldrive.badge.exclamationmark"
        )
      case .loading, .paused, .degraded:
        EmptyState(
          title: presentation.state == .paused ? "记录已暂停" : "正在更新本地时间线",
          detail: "暂停不会删除已有本地事实。",
          systemImage: presentation.state == .paused
            ? "pause.circle" : "arrow.triangle.2.circlepath"
        )
      }
    } else {
      EmptyState(
        title: "正在读取今天的本地记录",
        detail: "只查询本机 SQLite 中当前工作日的客观事实。",
        systemImage: "arrow.triangle.2.circlepath"
      )
    }
  }

  private func showMoreTimelineItems() {
    guard let presentation = runtime.todayTimeline else { return }
    let primaryItems = TodayTimelineWindow.primaryItems(from: presentation.items)
    if TodayTimelineWindow.canRevealMore(
      totalCount: primaryItems.count,
      currentLimit: timelineItemLimit
    ) {
      timelineItemLimit = TodayTimelineWindow.nextLimit(
        currentLimit: timelineItemLimit,
        totalCount: primaryItems.count
      )
    } else if runtime.canLoadOlderTodayTimeline {
      // Reserve the next visible window before the query begins. When the page arrives, the
      // requested records become visible immediately rather than requiring a second click.
      if !runtime.todayTimelineLoadMoreFailed {
        timelineItemLimit += TodayTimelineWindow.additionalItemCount
      }
      runtime.loadOlderTodayTimeline()
    }
  }

  private func timelineContext(for presentation: TodayTimelinePresentation) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(
        workdayRange(presentation.boundary.startsAt, presentation.boundary.endsAt)
      )
      .font(.caption.monospacedDigit().weight(.medium))
      .foregroundStyle(.secondary)

      Spacer()

      Text("最近记录")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private func workdayTime(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute())
  }

  private func workdayRange(_ start: Date, _ end: Date) -> String {
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    let endLabel =
      calendar.isDate(start, inSameDayAs: end)
      ? workdayTime(end)
      : "次日 \(workdayTime(end))"
    return "本工作日 \(workdayTime(start)) 至 \(endLabel)"
  }

  private var liveInputRange: Range<Date> {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    let now = Date.now
    let boundary = dailyWorkScheduleSettings.currentSchedule.workdayBoundary
    let start =
      (try? boundary.start(containing: now, calendar: calendar))
      ?? calendar.startOfDay(for: now)
    return start..<now.addingTimeInterval(1)
  }

  private func selectTimelineHour(_ hour: TodayDashboardHour) {
    guard let presentation = runtime.todayTimeline else { return }
    let primaryItems = TodayTimelineWindow.primaryItems(from: presentation.items)
    let visibleItems = TodayTimelineWindow.visibleItems(
      from: primaryItems,
      limit: timelineItemLimit
    )
    guard
      let item = visibleItems.first(where: {
        $0.occurredAt >= hour.startsAt && $0.occurredAt < hour.endsAt
      })
    else { return }

    // Do not bypass the five-at-a-time timeline window. Selecting an older
    // hour keeps the dashboard detail pinned without eagerly rendering every
    // intervening inference card.
    timelineScrollTargetID = item.id
  }

  private var weatherTitle: String {
    if let snapshot = weather.snapshot {
      return
        "\(weatherCondition(snapshot.weatherCode)) · \(Int(snapshot.temperatureCelsius.rounded()))℃"
    }
    switch weather.state {
    case .loading: return "正在更新天气"
    case .needsPermission: return "需要定位权限"
    case .unavailable: return "天气暂不可用"
    default: return "天气尚未配置"
    }
  }

  private var weatherSymbol: String {
    guard let snapshot = weather.snapshot else {
      switch weather.state {
      case .loading: return "arrow.triangle.2.circlepath"
      case .needsPermission: return "location.slash"
      case .unavailable: return "cloud.slash"
      default: return "cloud.sun"
      }
    }
    return weatherSymbol(for: snapshot.weatherCode)
  }

  private var weatherColor: Color {
    guard let snapshot = weather.snapshot else { return .secondary }
    switch snapshot.weatherCode {
    case 0: return .orange
    case 51...67, 80...82: return .blue
    case 71...77, 85...86: return .cyan
    case 95...99: return .purple
    default: return .secondary
    }
  }

  private var weatherDetail: String {
    if let snapshot = weather.snapshot {
      let feeling = snapshot.feelsLikeCelsius.map { " · 体感 \(Int($0.rounded()))℃" } ?? ""
      return
        "\(snapshot.district)\(feeling) · 更新于 \(snapshot.retrievedAt.formatted(.dateTime.hour().minute()))"
    }
    if case .unavailable(let message) = weather.state { return message }
    return "启用后使用前台定位查询区级实时天气"
  }

  private func weatherCondition(_ code: Int) -> String {
    switch code {
    case 0: "晴"
    case 1...3: "多云"
    case 45, 48: "雾"
    case 51...67, 80...82: "雨"
    case 71...77, 85...86: "雪"
    case 95...99: "雷雨"
    default: "天气"
    }
  }

  private func weatherSymbol(for code: Int) -> String {
    switch code {
    case 0: "sun.max"
    case 1...2: "cloud.sun"
    case 3: "cloud"
    case 45, 48: "cloud.fog"
    case 51...57: "cloud.drizzle"
    case 61...67, 80...82: "cloud.rain"
    case 71...77, 85...86: "cloud.snow"
    case 95: "cloud.bolt"
    case 96...99: "cloud.bolt.rain"
    default: "cloud"
    }
  }

  private var greeting: String {
    TodayGreeting.message(for: .now)
  }

  private var bannerTitle: String {
    runtime.collectionStatus.title
  }

  private var bannerDetail: String {
    runtime.collectionStatus.detail
  }

  private var bannerSymbol: String {
    runtime.collectionStatus.symbolName
  }

  private var bannerColor: Color {
    runtime.collectionStatus.color
  }

}

enum TodayContentLayout: Equatable {
  case stacked
  case twoColumn

  static let spacing: CGFloat = 20
  static let timelineMinimumWidth: CGFloat = 480
  static let pulseWidth: CGFloat = 310
  static let minimumTwoColumnContentWidth = timelineMinimumWidth + spacing + pulseWidth

  init(availableWidth: CGFloat) {
    self = availableWidth >= Self.minimumTwoColumnContentWidth ? .twoColumn : .stacked
  }
}

private struct TodayContentColumnsLayout: Layout {
  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    guard subviews.count == 2 else { return .zero }

    let width = proposal.width ?? TodayContentLayout.minimumTwoColumnContentWidth
    switch TodayContentLayout(availableWidth: width) {
    case .twoColumn:
      let timelineWidth =
        width
        - TodayContentLayout.spacing
        - TodayContentLayout.pulseWidth
      let timelineSize = subviews[0].sizeThatFits(
        ProposedViewSize(width: timelineWidth, height: nil)
      )
      let pulseSize = subviews[1].sizeThatFits(
        ProposedViewSize(width: TodayContentLayout.pulseWidth, height: nil)
      )
      return CGSize(width: width, height: max(timelineSize.height, pulseSize.height))
    case .stacked:
      let childProposal = ProposedViewSize(width: width, height: nil)
      let timelineSize = subviews[0].sizeThatFits(childProposal)
      let pulseSize = subviews[1].sizeThatFits(childProposal)
      return CGSize(
        width: width,
        height: pulseSize.height + TodayContentLayout.spacing + timelineSize.height
      )
    }
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard subviews.count == 2 else { return }

    switch TodayContentLayout(availableWidth: bounds.width) {
    case .twoColumn:
      let timelineWidth =
        bounds.width
        - TodayContentLayout.spacing
        - TodayContentLayout.pulseWidth
      subviews[0].place(
        at: bounds.origin,
        anchor: .topLeading,
        proposal: ProposedViewSize(width: timelineWidth, height: nil)
      )
      subviews[1].place(
        at: CGPoint(
          x: bounds.minX + timelineWidth + TodayContentLayout.spacing,
          y: bounds.minY
        ),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: TodayContentLayout.pulseWidth, height: nil)
      )
    case .stacked:
      let childProposal = ProposedViewSize(width: bounds.width, height: nil)
      let pulseSize = subviews[1].sizeThatFits(childProposal)
      subviews[1].place(
        at: bounds.origin,
        anchor: .topLeading,
        proposal: childProposal
      )
      subviews[0].place(
        at: CGPoint(
          x: bounds.minX,
          y: bounds.minY + pulseSize.height + TodayContentLayout.spacing
        ),
        anchor: .topLeading,
        proposal: childProposal
      )
    }
  }
}

private struct TodayInfoCard<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: Content

  init(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    DaydayThemeReader { theme, _ in
      VStack(alignment: .leading, spacing: 13) {
        HStack(spacing: 8) {
          Image(systemName: systemImage)
            .foregroundStyle(theme[.textSecondary])
            .accessibilityHidden(true)
          Text(title)
            .foregroundStyle(theme[.textPrimary])
        }
        .font(.headline)
        content
      }
      .padding(15)
      .frame(maxWidth: .infinity, alignment: .leading)
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

private struct TodayDisplayMiniCard: View {
  let display: AppRuntimeDisplay
  let ordinal: Int

  var body: some View {
    DaydayThemeReader { theme, _ in
      VStack(alignment: .leading, spacing: 5) {
        Image(systemName: display.isBuiltIn ? "macbook" : "display")
          .font(.caption.weight(.semibold))
          .foregroundStyle(theme[.textSecondary])
        Text(title)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
        Text(resolution)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(theme[.textSecondary])
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
      .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
      .padding(9)
      .background(
        theme[.surfaceInset],
        in: RoundedRectangle(cornerRadius: DaydayRadius.control, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: DaydayRadius.control, style: .continuous)
          .stroke(theme[.separator], lineWidth: DaydayDepth.hairline)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(title)，\(resolution)")
    }
  }

  private var title: String {
    if display.isBuiltIn { return "内建屏" }
    if display.isMain { return "主显示器" }
    return "显示器 \(ordinal)"
  }

  private var resolution: String {
    guard let width = display.pixelWidth, let height = display.pixelHeight else {
      return "分辨率待读取"
    }
    return "\(width) × \(height)"
  }
}

private struct TodayInputSummary {
  let keyCount: UInt64
  let clickCount: UInt64

  init(summary: InputMetricSummary) {
    keyCount = summary.keyPressCount
    clickCount = summary.clickCount
  }
}

/// The live dashboard is intentionally its own observation island. Keyboard,
/// pointer, and open foreground-duration changes should update this compact
/// column only; the evidence thread remains still until its own data changes.
private struct TodayPulseColumn: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let runtimeSnapshot: AppRuntimeSnapshot
  let overview: TodayOverviewPresentation
  /// Stable evidence-only projection supplied by TodayView. ApplicationUsage
  /// publishes every second, but that must not rescan or recluster the timeline.
  let timelineProjection: TodayDashboardPresentation
  @ObservedObject var input: InputInsightsModel
  @ObservedObject var applicationUsage: ApplicationUsageInsightsModel
  let onOpenInsights: () -> Void
  let onSelectTimelineHour: (TodayDashboardHour) -> Void

  @State private var hoveredDashboardHour: Date?
  @State private var selectedDashboardHour: Date?

  var body: some View {
    let dashboard = todayDashboard
    VStack(spacing: 14) {
      TodayInfoCard("今日脉搏", systemImage: "waveform.path.ecg") {
        HStack(spacing: 0) {
          PulseMetric(
            value: applicationUsage.presentation.trackedDuration.daydayDurationText,
            label: "前台时长"
          )
          PulseMetric(
            value: "\(applicationUsage.presentation.summaries.count)",
            label: "前台应用"
          )
          PulseMetric(value: "\(overview.factualEntryCount)", label: "独立事实卡")
          PulseMetric(value: "\(overview.inferenceEntryCount)", label: "AI 推断")
        }

        TodayHourlyPulseChart(
          presentation: dashboard,
          hoveredHour: $hoveredDashboardHour,
          selectedHour: selectedDashboardHour,
          onSelect: selectDashboardHour
        )
      }

      TodayInfoCard("主要应用", systemImage: "rectangle.stack") {
        if applicationUsage.presentation.summaries.isEmpty {
          Text(
            applicationUsage.isLoading
              ? "正在汇总今天的应用记录…" : "今天还没有可展示的应用记录"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          VStack(spacing: 10) {
            ForEach(
              Array(applicationUsage.presentation.summaries.prefix(3).enumerated()),
              id: \.element.id
            ) { index, summary in
              TodayApplicationRow(
                rank: index + 1,
                label: summary.displayLabel,
                duration: summary.duration,
                maximumDuration: applicationUsage.presentation.summaries.first?.duration ?? 0
              )
            }
          }
        }

        Button("查看应用洞察", systemImage: "arrow.up.right", action: onOpenInsights)
          .buttonStyle(.borderless)
          .font(.caption.weight(.medium))
      }

      TodayInfoCard("键鼠互动", systemImage: "keyboard") {
        HStack(spacing: 0) {
          PulseMetric(value: "\(inputSummary.keyCount)", label: "键位按下")
          PulseMetric(value: "\(inputSummary.clickCount)", label: "点击")
        }

        VStack(spacing: 7) {
          TodayHourlyInputHeatRow(
            label: "按键",
            metric: .physicalKeys,
            hours: dashboard.hours,
            hoveredHour: $hoveredDashboardHour,
            selectedHour: selectedDashboardHour
          )
          TodayHourlyInputHeatRow(
            label: "点击",
            metric: .clicks,
            hours: dashboard.hours,
            hoveredHour: $hoveredDashboardHour,
            selectedHour: selectedDashboardHour
          )
        }

        HStack(spacing: 5) {
          Circle()
            .fill(isInputLive ? .green : .secondary)
            .frame(width: 6, height: 6)
          Text(
            input.aggregates.isEmpty
              ? "等待今天的键鼠聚合"
              : (isInputLive ? "实时更新中" : "只汇总计数，不展示输入内容")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      displayInventory
    }
  }

  private var todayDashboard: TodayDashboardPresentation {
    TodayDashboardPresentationAdapter.mergeLiveSignals(
      into: timelineProjection,
      now: .now,
      applicationIntervals: applicationUsage.presentation.intervals,
      inputAggregates: input.aggregates
    )
  }

  private var inputSummary: TodayInputSummary {
    TodayInputSummary(summary: input.metricSummary)
  }

  private var isInputLive: Bool {
    input.liveStatus == .running
      && (input.keyboardLiveEnabled || input.pointerLiveEnabled)
  }

  private func selectDashboardHour(_ hour: TodayDashboardHour) {
    if selectedDashboardHour == hour.id {
      withAnimation(reduceMotion ? nil : DaydayLiveMetricMotion.animation(reduceMotion: false)) {
        selectedDashboardHour = nil
      }
      return
    }
    withAnimation(reduceMotion ? nil : DaydayLiveMetricMotion.animation(reduceMotion: false)) {
      selectedDashboardHour = hour.id
    }
    onSelectTimelineHour(hour)
  }

  @ViewBuilder
  private var displayInventory: some View {
    switch runtimeSnapshot.displayInventoryState {
    case .available where !runtimeSnapshot.displays.isEmpty:
      Label("已连接 \(runtimeSnapshot.displays.count) 台显示器", systemImage: "display.2")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    case .available:
      Label("未检测到显示器", systemImage: "display.trianglebadge.exclamationmark")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .unknown:
      Label("正在读取显示器", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .unavailable:
      Label("显示器状态不可用", systemImage: "display.trianglebadge.exclamationmark")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct PulseMetric: View {
  let value: String
  let label: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value)
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .daydayLiveMetricValue(value)
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct TodayHourlyPulseChart: View {
  let presentation: TodayDashboardPresentation
  @Binding var hoveredHour: Date?
  let selectedHour: Date?
  let onSelect: (TodayDashboardHour) -> Void

  private let chartHeight: CGFloat = 56

  var body: some View {
    DaydayThemeReader { theme, _ in
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 8) {
          Text("每小时前台事实时段")
            .font(.caption.weight(.medium))
            .foregroundStyle(theme[.textSecondary])
          Spacer()
          Circle()
            .fill(theme[.action])
            .frame(width: 5, height: 5)
          Text("0–60 分钟")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(theme[.textTertiary])
        }

        HStack(alignment: .bottom, spacing: 4) {
          ForEach(presentation.hours) { hour in
            Button {
              onSelect(hour)
            } label: {
              DaydayGrowingBar(
                fraction: barFraction(for: hour),
                axis: .vertical,
                minimumVisibleLength: 1
              ) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                  .fill(theme[.action].opacity(hour.isCurrent ? 0.92 : 0.68))
              }
              .frame(maxWidth: .infinity, minHeight: chartHeight, maxHeight: chartHeight)
              .padding(.horizontal, 1)
              .background(
                highlightColor(for: hour, theme: theme),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(TodayDashboardHourButtonStyle())
            .onHover { isInside in
              updateHover(hour.id, isInside: isInside)
            }
            .help(hourSummary(hour))
            .accessibilityLabel("\(hour.label) 前台时段")
            .accessibilityValue(hourSummary(hour))
          }
        }

        chartAxis

        VStack(alignment: .leading, spacing: 5) {
          HStack {
            Text("独立事实卡分布")
              .font(.caption2.weight(.medium))
              .foregroundStyle(theme[.textSecondary])
            Spacer()
            Text("已载入独立事实卡")
              .font(.caption2)
              .foregroundStyle(theme[.textTertiary])
          }
          TodayDashboardFactStrip(
            hours: presentation.hours,
            hoveredHour: $hoveredHour,
            selectedHour: selectedHour
          )
        }

        TodayDashboardInferenceRibbon(
          presentation: presentation,
          hoveredHour: $hoveredHour,
          selectedHour: selectedHour,
          onSelect: onSelect
        )

        if let hour = focusedHour {
          Text(hourSummary(hour))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(theme[.textSecondary])
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .daydayLiveMetricValue(hourSummary(hour))
        }
      }
    }
  }

  private var focusedHour: TodayDashboardHour? {
    let identifier = hoveredHour ?? selectedHour
    return presentation.hours.first(where: { $0.id == identifier })
      ?? presentation.hours.first(where: \.isCurrent)
  }

  private var chartAxis: some View {
    HStack {
      Text(presentation.hours.first?.label ?? "—")
      Spacer()
      Text(presentation.hours.dropFirst(presentation.hours.count / 2).first?.label ?? "—")
      Spacer()
      Text("现在")
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.tertiary)
  }

  private func barFraction(for hour: TodayDashboardHour) -> CGFloat {
    CGFloat(
      min(
        1,
        max(
          0,
          hour.foregroundDuration / TodayDashboardPresentationAdapter.foregroundScaleMaximum
        )
      )
    )
  }

  private func highlightColor(for hour: TodayDashboardHour, theme: DaydayTheme) -> Color {
    guard hour.id == hoveredHour || hour.id == selectedHour else { return .clear }
    return theme[.selectionFill]
  }

  private func updateHover(_ identifier: Date, isInside: Bool) {
    if isInside {
      hoveredHour = identifier
    } else if hoveredHour == identifier {
      hoveredHour = nil
    }
  }

  private func hourSummary(_ hour: TodayDashboardHour) -> String {
    let foreground = hour.foregroundDuration.daydayDurationText
    let inference =
      hour.inferenceEntryCount > 0 ? " · AI 推断 \(hour.inferenceEntryCount)" : ""
    return "\(hour.label) · 前台 \(foreground) · 独立事实卡 \(hour.factualEntryCount)\(inference)"
  }
}

private struct TodayDashboardHourButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.72 : 1)
  }
}

private struct TodayDashboardFactStrip: View {
  let hours: [TodayDashboardHour]
  @Binding var hoveredHour: Date?
  let selectedHour: Date?

  private var maximum: Double {
    Double(max(hours.map(\.factualEntryCount).max() ?? 0, 1))
  }

  var body: some View {
    DaydayThemeReader { theme, _ in
      HStack(spacing: 4) {
        ForEach(hours) { hour in
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(
              DaydayHeatmapScale.color(
                tint: theme[.evidenceObjective],
                value: Double(hour.factualEntryCount),
                maximum: maximum
              )
            )
            .frame(maxWidth: .infinity)
            .frame(height: 7)
            .overlay {
              if hour.id == hoveredHour || hour.id == selectedHour {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                  .stroke(theme[.selectionBorder], lineWidth: 1)
              }
            }
            .contentShape(Rectangle())
            .onHover { isInside in
              if isInside {
                hoveredHour = hour.id
              } else if hoveredHour == hour.id {
                hoveredHour = nil
              }
            }
            .help("\(hour.label) · 已载入独立事实卡 \(hour.factualEntryCount) 个")
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("近十二小时已载入独立事实卡分布")
    }
  }
}

private struct TodayDashboardInferenceRibbon: View {
  let presentation: TodayDashboardPresentation
  @Binding var hoveredHour: Date?
  let selectedHour: Date?
  let onSelect: (TodayDashboardHour) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DaydayThemeReader { theme, _ in
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .accessibilityHidden(true)
          Text("AI 推断")
            .fontWeight(.medium)
          Spacer()
          Text(inferenceCountLabel)
            .foregroundStyle(theme[.textTertiary])
        }
        .font(.caption2)
        .foregroundStyle(theme[.evidenceInference])

        inferenceOverview(theme: theme)

        if let hour = detailHour {
          let detail = presentation.inferenceDetail(for: hour)
          if detail.segmentCount > 0 {
            TodayDashboardInferenceDetailTrack(hour: hour, detail: detail)
              .transition(.opacity)
          }
        }
      }
      .animation(
        reduceMotion ? nil : DaydayLiveMetricMotion.animation(reduceMotion: false),
        value: selectedHour
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("AI 推断区间，不代表客观前台时长")
    }
  }

  private var inferenceCountLabel: String {
    guard !presentation.inferenceSegments.isEmpty else { return "当前无" }
    return "\(presentation.inferenceSegments.count) 段 · \(presentation.inferenceClusters.count) 组"
  }

  private var detailHour: TodayDashboardHour? {
    presentation.hours.first(where: { $0.id == selectedHour })
      ?? presentation.hours.first(where: \.isCurrent)
  }

  private func inferenceOverview(theme: DaydayTheme) -> some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(theme[.surfaceInset])
        if let range = presentation.range {
          hourHighlight(in: range, width: proxy.size.width, theme: theme)
          ForEach(presentation.inferenceClusters) { cluster in
            let start = position(of: cluster.startsAt, in: range)
            let end = position(of: cluster.endsAt, in: range)
            let width = segmentWidth(
              start: start,
              end: end,
              availableWidth: proxy.size.width,
              minimumWidth: 4
            )
            if let hour = hour(containing: cluster.startsAt) {
              Button {
                onSelect(hour)
              } label: {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                  .fill(theme[.evidenceInference].opacity(0.62))
                  .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                      .stroke(theme[.evidenceInference].opacity(0.78), lineWidth: 0.75)
                  }
                  .frame(width: width)
                  .contentShape(Rectangle())
              }
              .buttonStyle(TodayDashboardHourButtonStyle())
              .offset(x: proxy.size.width * start)
              .onHover { isInside in
                updateHover(hour.id, isInside: isInside)
              }
              .help(clusterSummary(cluster))
            }
          }
        }
      }
    }
    .frame(height: 10)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(inferenceCountLabel)
  }

  private func hour(containing date: Date) -> TodayDashboardHour? {
    presentation.hours.first {
      $0.startsAt <= date && date < $0.endsAt
    }
  }

  private func updateHover(_ identifier: Date, isInside: Bool) {
    if isInside {
      hoveredHour = identifier
    } else if hoveredHour == identifier {
      hoveredHour = nil
    }
  }

  private func clusterSummary(_ cluster: TodayDashboardInferenceCluster) -> String {
    let time = timeRange(startsAt: cluster.startsAt, endsAt: cluster.endsAt)
    let titles = cluster.titles.prefix(2).joined(separator: "；")
    let remaining = max(0, cluster.titles.count - 2)
    let suffix = remaining > 0 ? "；另有 \(remaining) 条" : ""
    return "\(time) · \(cluster.segmentCount) 条 AI 推断\n\(titles)\(suffix)"
  }

  private func timeRange(startsAt: Date, endsAt: Date) -> String {
    let start = startsAt.formatted(date: .omitted, time: .shortened)
    let end = endsAt.formatted(date: .omitted, time: .shortened)
    return start == end ? start : "\(start)–\(end)"
  }

  private func segmentWidth(
    start: CGFloat,
    end: CGFloat,
    availableWidth: CGFloat,
    minimumWidth: CGFloat
  ) -> CGFloat {
    let offset = availableWidth * start
    return min(max(minimumWidth, availableWidth * (end - start)), availableWidth - offset)
  }

  @ViewBuilder
  private func hourHighlight(
    in range: Range<Date>,
    width: CGFloat,
    theme: DaydayTheme
  ) -> some View {
    let identifier = hoveredHour ?? selectedHour
    if let hour = presentation.hours.first(where: { $0.id == identifier }) {
      let start = position(of: hour.startsAt, in: range)
      let end = position(of: hour.endsAt, in: range)
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(theme[.selectionFill])
        .frame(width: max(2, width * (end - start)))
        .offset(x: width * start)
        .allowsHitTesting(false)
    }
  }

  private func position(of date: Date, in range: Range<Date>) -> CGFloat {
    let duration = range.upperBound.timeIntervalSince(range.lowerBound)
    guard duration > 0 else { return 0 }
    return CGFloat(min(1, max(0, date.timeIntervalSince(range.lowerBound) / duration)))
  }
}

private struct TodayDashboardInferenceDetailTrack: View {
  let hour: TodayDashboardHour
  let detail: TodayDashboardInferenceDetail

  var body: some View {
    DaydayThemeReader { theme, _ in
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text("\(hour.label) 详情")
            .fontWeight(.medium)
          Spacer()
          Text("\(detail.segmentCount) 条")
            .foregroundStyle(theme[.textTertiary])
        }
        .font(.caption2)
        .foregroundStyle(theme[.textSecondary])

        VStack(spacing: 3) {
          ForEach(Array(detail.lanes.enumerated()), id: \.offset) { _, lane in
            GeometryReader { proxy in
              ZStack(alignment: .leading) {
                Capsule()
                  .fill(theme[.surfaceInset])
                ForEach(lane) { segment in
                  let start = position(of: segment.startsAt)
                  let end = position(of: segment.endsAt)
                  let offset = proxy.size.width * start
                  let width = min(
                    max(4, proxy.size.width * (end - start)),
                    proxy.size.width - offset
                  )
                  RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme[.evidenceInference].opacity(0.76))
                    .frame(width: width)
                    .offset(x: offset)
                    .help(segmentSummary(segment))
                }
              }
            }
            .frame(height: 7)
          }
        }

        if detail.overflowCount > 0 {
          Text("另有 \(detail.overflowCount) 条重叠推断")
            .font(.caption2)
            .foregroundStyle(theme[.evidenceInference])
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(hour.label) AI 推断详情，共 \(detail.segmentCount) 条，\(detail.overflowCount) 条重叠"
      )
    }
  }

  private func segmentSummary(_ segment: TodayDashboardInferenceSegment) -> String {
    "\(timeRange(startsAt: segment.startsAt, endsAt: segment.endsAt))\n\(segment.title)"
  }

  private func position(of date: Date) -> CGFloat {
    let duration = hour.endsAt.timeIntervalSince(hour.startsAt)
    guard duration > 0 else { return 0 }
    return CGFloat(min(1, max(0, date.timeIntervalSince(hour.startsAt) / duration)))
  }

  private func timeRange(startsAt: Date, endsAt: Date) -> String {
    let start = startsAt.formatted(date: .omitted, time: .shortened)
    let end = endsAt.formatted(date: .omitted, time: .shortened)
    return start == end ? start : "\(start)–\(end)"
  }
}

private enum TodayHourlyInputMetric {
  case physicalKeys
  case clicks

  func value(in hour: TodayDashboardHour) -> UInt64 {
    switch self {
    case .physicalKeys: hour.physicalKeyPressCount
    case .clicks: hour.clickCount
    }
  }
}

private struct TodayHourlyInputHeatRow: View {
  let label: String
  let metric: TodayHourlyInputMetric
  let hours: [TodayDashboardHour]
  @Binding var hoveredHour: Date?
  let selectedHour: Date?

  private var maximum: Double {
    Double(max(hours.map { metric.value(in: $0) }.max() ?? 0, 1))
  }

  var body: some View {
    DaydayThemeReader { theme, _ in
      HStack(spacing: 7) {
        Text(label)
          .font(.caption2.weight(.medium))
          .foregroundStyle(theme[.textSecondary])
          .frame(width: 28, alignment: .leading)

        HStack(spacing: 3) {
          ForEach(hours) { hour in
            let value = metric.value(in: hour)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(
                DaydayHeatmapScale.color(
                  tint: theme[.action],
                  value: Double(value),
                  maximum: maximum
                )
              )
              .frame(maxWidth: .infinity)
              .frame(height: 6)
              .overlay {
                if hour.id == hoveredHour || hour.id == selectedHour {
                  RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(theme[.selectionBorder], lineWidth: 1)
                }
              }
              .contentShape(Rectangle())
              .onHover { isInside in
                if isInside {
                  hoveredHour = hour.id
                } else if hoveredHour == hour.id {
                  hoveredHour = nil
                }
              }
              .help("\(hour.label) · \(label) \(value)")
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("近十二小时\(label)分布")
    }
  }
}

private struct TodayApplicationRow: View {
  let rank: Int
  let label: String
  let duration: TimeInterval
  let maximumDuration: TimeInterval

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 7) {
        Text("\(rank)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .frame(width: 10, alignment: .leading)
        Text(label)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Spacer(minLength: 6)
        Text(duration.daydayDurationText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.accentColor.opacity(0.16))
        DaydayGrowingBar(
          fraction: CGFloat(duration / max(maximumDuration, 1)),
          axis: .horizontal
        ) {
          Capsule()
            .fill(Color.accentColor.opacity(0.72))
        }
      }
      .frame(height: 4)
    }
    .accessibilityElement(children: .combine)
  }
}

extension TimeInterval {
  fileprivate var daydayDurationText: String {
    let wholeSeconds = max(0, Int(rounded()))
    let hours = wholeSeconds / 3_600
    let minutes = (wholeSeconds % 3_600) / 60
    if hours > 0 { return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时" }
    return minutes > 0 ? "\(minutes)分" : "< 1分"
  }
}

private enum ReportEditorOperation {
  case autosave
  case generate
  case save
  case finalize
  case openHistory
  case export
}

struct WorkReportReviewPresentation: Equatable {
  let characterCounts: [JournalLogicalDayKey: Int]
  let previewTextByReportID: [WorkReportID: String]
  let heatmap: JournalWritingHeatmapPresentation
  let totalCharacterCount: Int
  let writingDayCount: Int
  let currentStreak: Int

  init(
    records: [PersistedWorkReportRecord],
    endingAt: Date = .now,
    calendar sourceCalendar: Calendar = .autoupdatingCurrent
  ) {
    var counts: [JournalLogicalDayKey: Int] = [:]
    var previews: [WorkReportID: String] = [:]
    for record in records {
      let visible = JournalMarkdownText.visibleText(in: record.currentRevision.body)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !visible.isEmpty else { continue }
      counts[JournalLogicalDayKey(record.day.logicalDate)] =
        JournalMarkdownText.characterCount(inVisibleText: visible)
      previews[record.report.id] = visible
    }
    characterCounts = counts
    previewTextByReportID = previews
    heatmap = JournalWritingHeatmapPresentation(
      characterCounts: counts,
      endingAt: endingAt,
      calendar: sourceCalendar
    )
    totalCharacterCount = counts.values.reduce(0, +)
    writingDayCount = counts.count
    currentStreak = Self.streak(in: counts.keys, calendar: sourceCalendar)
  }

  private static func streak(
    in keys: Dictionary<JournalLogicalDayKey, Int>.Keys,
    calendar sourceCalendar: Calendar
  ) -> Int {
    guard let latest = keys.max(by: Self.isEarlier) else { return 0 }
    let calendar = sourceCalendar
    guard
      var cursor = calendar.date(
        from: DateComponents(year: latest.year, month: latest.month, day: latest.day)
      )
    else { return 0 }
    let keySet = Set(keys)
    var result = 0
    while true {
      let parts = calendar.dateComponents([.year, .month, .day], from: cursor)
      let key = JournalLogicalDayKey(
        year: parts.year ?? 0,
        month: parts.month ?? 0,
        day: parts.day ?? 0
      )
      guard keySet.contains(key) else { break }
      result += 1
      guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
      cursor = previous
    }
    return result
  }

  private static func isEarlier(_ lhs: JournalLogicalDayKey, _ rhs: JournalLogicalDayKey) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }
}

struct DailyReportView: View {
  @ObservedObject var weather: WeatherRuntime
  @ObservedObject var workReport: WorkReportGenerationModel
  let isActive: Bool
  let onOpenHistory: () -> Void

  @State private var reportEditText = ""
  @State private var editorAction: JournalMarkdownEditorAction?
  @State private var editorActionRequest = 0
  @State private var editorSnapshotRequest = 0
  @State private var editorSelection = JournalMarkEditSelectionState()
  @State private var isSourceMode = false
  @State private var isInspectorPresented = true
  @State private var isLinkEditorPresented = false
  @State private var isRegenerationConfirmationPresented = false
  @State private var pendingEditorOperation: ReportEditorOperation?
  @State private var linkLabel = ""
  @State private var linkDestination = ""
  @State private var exportFeedback: String?
  @State private var reportHistoryQuery = ""
  @State private var reviewedReport: PersistedWorkReportRecord?
  @State private var reviewPresentation = WorkReportReviewPresentation(records: [])

  var body: some View {
    VStack(spacing: 0) {
      writingSurface
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .toolbar {
      if DaydayWritingToolbarPresentation.isVisible(isActive: isActive) {
        ToolbarItemGroup(placement: .automatic) {
          formatMenu
          sourceModeButton
            .daydayWritingToolbarIcon()
          historyButton
            .daydayWritingToolbarIcon()
          exportButton
            .daydayWritingToolbarIcon()
        }
        ToolbarItemGroup(placement: .primaryAction) {
          aiGenerationButton
            .daydayWritingToolbarLabel()
          if !workReport.isFinalized {
            saveButton
              .daydayWritingToolbarLabel()
            finalizeButton
              .daydayWritingToolbarLabel()
          }
          inspectorButton
            .daydayWritingToolbarIcon()
        }
      }
    }
    .inspector(isPresented: activeReviewInspectorBinding) {
      reportReviewSidebar
        .inspectorColumnWidth(
          min: JournalReviewLayoutPolicy.minimumWidth,
          ideal: JournalReviewLayoutPolicy.idealWidth,
          max: JournalReviewLayoutPolicy.maximumWidth
        )
    }
    .sheet(isPresented: $isLinkEditorPresented) {
      DaydayMarkdownLinkEditor(
        label: $linkLabel,
        destination: $linkDestination,
        insert: insertLink
      )
    }
    .sheet(
      isPresented: Binding(
        get: { reviewedReport != nil },
        set: { if !$0 { reviewedReport = nil } }
      )
    ) {
      if let reviewedReport {
        WorkReportHistoryPreviewSheet(
          record: reviewedReport,
          close: { self.reviewedReport = nil }
        )
      }
    }
    .confirmationDialog(
      "替换未保存的修改？",
      isPresented: $isRegenerationConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("舍弃修改并重新生成", role: .destructive) {
        workReport.discardWorkingDraft()
        reportEditText = workReport.draft ?? ""
        generateReport()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("AI 会生成新的日报版本；当前尚未保存的文字不会保留。")
    }
    .onAppear {
      weather.refreshPlaceNameIfNeeded()
      if reportEditText.isEmpty {
        reportEditText = restoredEditorText
      }
      updateReportReviewPresentation()
      if workReport.recentReports.isEmpty {
        Task { await workReport.refreshHistory() }
      }
    }
    .onChange(of: workReport.recentReports) { _, _ in
      updateReportReviewPresentation()
    }
    .onChange(of: workReport.draft) { previous, next in
      let previousText = previous ?? ""
      if reportEditText == previousText {
        reportEditText = next ?? ""
      }
    }
    .onChange(of: workReport.workingDraft) { _, next in
      if let next, reportEditText.isEmpty || reportEditText == (workReport.draft ?? "") {
        reportEditText = next
      }
    }
    .onChange(of: isActive) { _, active in
      if !active { requestEditorSnapshot(for: .autosave) }
    }
    .onDisappear {
      requestEditorSnapshot(for: .autosave)
    }
  }

  private var formatMenu: some View {
    DaydayMarkdownFormatMenu(
      disabled: workReport.isFinalized,
      iconOnly: true,
      requestAction: requestEditorAction,
      presentLinkEditor: presentLinkEditor
    )
  }

  private var sourceModeButton: some View {
    Button(
      isSourceMode ? "实时预览" : "源码",
      systemImage: isSourceMode
        ? DaydayWritingToolbarSymbol.preview : DaydayWritingToolbarSymbol.source
    ) {
      toggleSourceMode()
    }
    .help(isSourceMode ? "返回实时预览" : "查看 Markdown 源码")
    .foregroundStyle(isSourceMode ? Color.accentColor : Color.primary)
    .accessibilityValue(isSourceMode ? "源码模式" : "实时预览模式")
  }

  private var historyButton: some View {
    Button("历史日报", systemImage: DaydayWritingToolbarSymbol.history) {
      requestEditorSnapshot(for: .openHistory)
    }
    .disabled(isEditorOperationPending)
    .help("查看历史日报与版本")
  }

  private var exportButton: some View {
    Button("导出 Markdown", systemImage: DaydayWritingToolbarSymbol.export) {
      requestEditorSnapshot(for: .export)
    }
    .disabled(workReport.currentRecord == nil || isEditorOperationPending)
    .help("导出当前已保存的日报 Markdown")
  }

  private var inspectorButton: some View {
    Button(
      isInspectorPresented ? "隐藏回顾" : "显示回顾",
      systemImage: DaydayWritingToolbarSymbol.review
    ) {
      toggleReviewInspector()
    }
    .keyboardShortcut("h", modifiers: [.command, .shift])
    .help(isInspectorPresented ? "隐藏日报回顾" : "显示日报回顾与工作上下文")
    .foregroundStyle(isInspectorPresented ? Color.accentColor : Color.primary)
    .accessibilityValue(isInspectorPresented ? "已显示" : "已隐藏")
    .accessibilityIdentifier("report.review-inspector.toggle")
  }

  private func toggleReviewInspector() {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      isInspectorPresented.toggle()
    }
  }

  @ViewBuilder
  private var aiGenerationButton: some View {
    aiGenerationControl
  }

  private var aiGenerationControl: some View {
    Button(
      workReport.draft == nil ? "AI 生成" : "重新生成",
      systemImage: workReport.isGenerating ? "ellipsis" : DaydayWritingToolbarSymbol.journalAI
    ) {
      requestEditorSnapshot(for: .generate)
    }
    .disabled(!canGenerateReport || workReport.isFinalized || isEditorOperationPending)
    .help(reportHelp)
  }

  private var saveButton: some View {
    Button("保存版本", systemImage: DaydayWritingToolbarSymbol.saveVersion) {
      requestEditorSnapshot(for: .save)
    }
    .disabled(!canSaveReport || isEditorOperationPending)
    .keyboardShortcut("s", modifiers: .command)
    .help("将当前自动保存的工作副本记录为一个历史版本")
  }

  private var finalizeButton: some View {
    Button("定稿", systemImage: DaydayWritingToolbarSymbol.finalize) {
      requestEditorSnapshot(for: .finalize)
    }
    .buttonStyle(.borderedProminent)
    .disabled(workReport.isFinalizing || workReport.isGenerating || isEditorOperationPending)
  }

  private var activeReviewInspectorBinding: Binding<Bool> {
    Binding(
      get: { isActive && isInspectorPresented },
      // SwiftUI writes `false` when a retained page becomes inactive. The toolbar button owns the
      // user's preference so this transient unmount must not erase it before the page is revisited.
      set: { _ in }
    )
  }

  private var writingSurface: some View {
    DaydayMarkdownWritingSurface(
      markdown: Binding(
        get: { reportEditText },
        set: {
          reportEditText = $0
          exportFeedback = nil
          workReport.stageWorkingDraft($0)
        }
      ),
      title: JournalDateFormatting.dayTitle(Date.now),
      placeholder: "写下今天的工作，或使用 AI 生成一份草稿……",
      contentAccessibilityLabel: "工作日报正文，实时 Markdown 预览，支持 macOS 系统听写",
      status: reportStatus,
      statusAccessibilityLabel: "日报状态",
      statusSystemImage: reportStatusSystemImage,
      statusColor: reportStatusColor,
      pendingAttachment: nil,
      attachmentRequest: 0,
      action: editorAction,
      actionRequest: editorActionRequest,
      snapshotRequest: editorSnapshotRequest,
      isSourceMode: isSourceMode,
      isReadOnly: workReport.isFinalized,
      isActive: isActive,
      onSelectionChange: { editorSelection = $0 },
      onRequestAttachmentRemoval: { _ in },
      onUserEdit: {},
      onSnapshot: receiveEditorSnapshot,
      context: { reportContextLine }
    )
  }

  private var reportContextLine: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        reportWeatherContext
        reportStateContext
      }
      VStack(alignment: .leading, spacing: 6) {
        reportWeatherContext
        reportStateContext
      }
    }
  }

  private var reportWeatherContext: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        reportWeatherLabel
        reportLocationLabel
      }
      VStack(alignment: .leading, spacing: 6) {
        reportWeatherLabel
        reportLocationLabel
      }
    }
  }

  @ViewBuilder
  private var reportWeatherLabel: some View {
    if let snapshot = weather.snapshot {
      Label(
        "\(snapshot.district) · \(Int(snapshot.temperatureCelsius.rounded()))℃",
        systemImage: "cloud.sun"
      )
    }
  }

  @ViewBuilder
  private var reportLocationLabel: some View {
    if let snapshot = weather.snapshot {
      Label(snapshot.placeName ?? snapshot.district, systemImage: "location")
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var reportStateContext: some View {
    HStack(spacing: 12) {
      Label(reportBadgeTitle, systemImage: reportBadgeSystemImage)
      if let record = workReport.currentRecord {
        Text("第 \(record.report.currentRevisionNumber) 版")
          .monospacedDigit()
      }
      if let model = workReport.currentRecord?.currentRevision.modelProvenance?.model {
        Text(model)
          .lineLimit(1)
      }
    }
    .lineLimit(1)
  }

  private var reportReviewSidebar: some View {
    DaydayThemeReader { theme, _ in
      let palette = DaydayWritingReviewPalette(theme: theme)
      reportReviewSidebarContent(palette: palette)
        .tint(palette.action.color)
    }
  }

  private func reportReviewSidebarContent(
    palette: DaydayWritingReviewPalette
  ) -> some View {
    DaydayScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        Text("日报回顾")
          .font(.title3.weight(.semibold))

        DaydayWritingHistoryCalendar(
          characterCounts: reviewPresentation.characterCounts,
          selectedDay: reviewedReport?.day ?? workReport.dayDescriptor(),
          palette: palette,
          artifactName: "日报",
          allowsEmptySelection: false,
          selectDate: presentReport(on:)
        )

        DaydayWritingHeatmap(
          presentation: reviewPresentation.heatmap,
          selectedDay: reviewedReport?.day ?? workReport.dayDescriptor(),
          palette: palette,
          artifactName: "日报",
          allowsEmptySelection: false,
          selectDate: presentReport(on:)
        )

        DaydayCompactWritingStatistics(
          totalCharacterCount: reviewPresentation.totalCharacterCount,
          writingDayCount: reviewPresentation.writingDayCount,
          currentStreak: reviewPresentation.currentStreak
        )

        VStack(alignment: .leading, spacing: 8) {
          Text("日报列表")
            .font(.headline)
          TextField("搜索日报内容", text: $reportHistoryQuery)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("搜索日报内容")
        }

        if filteredRecentReports.isEmpty {
          ContentUnavailableView(
            workReport.recentReports.isEmpty ? "还没有历史日报" : "没有匹配的日报",
            systemImage: workReport.recentReports.isEmpty ? "doc.text" : "magnifyingglass",
            description: Text(workReport.historyStatus)
          )
          .frame(maxWidth: .infinity, minHeight: 130)
        } else {
          LazyVStack(spacing: 6) {
            ForEach(filteredRecentReports, id: \.report.id) { record in
              Button {
                reviewedReport = record
              } label: {
                WorkReportReviewEntryRow(
                  record: record,
                  previewText: reviewPresentation.previewTextByReportID[record.report.id] ?? "",
                  characterCount: reviewPresentation.characterCounts[
                    JournalLogicalDayKey(record.day.logicalDate)
                  ] ?? 0,
                  isSelected:
                    reviewedReport?.report.id == record.report.id
                    || (reviewedReport == nil
                      && workReport.currentRecord?.report.id == record.report.id),
                  palette: palette
                )
              }
              .buttonStyle(.plain)
            }
          }
        }

        Divider()

        reportContextSections
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var reportContextSections: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("AI 生成", systemImage: "sparkles")
        .font(.headline)
      if let generatedAt = workReport.generatedAt {
        LabeledContent("更新时间", value: generatedAt.formatted(date: .abbreviated, time: .shortened))
      }
      if let usage = workReport.usage {
        LabeledContent(
          "本版用量",
          value: usage.totalTokens.map { "\($0) tokens" } ?? "服务商未报告"
        )
      }
      if let record = workReport.currentRecord {
        LabeledContent(
          "来源",
          value: record.currentRevision.origin == .model ? "AI 草稿" : "用户手写"
        )
      }
      LabeledContent("证据覆盖", value: workReport.evidenceCoverage.statusText)
      if workReport.submittedContextUTF8Bytes > 0 {
        LabeledContent(
          "提交上下文",
          value: ByteCountFormatter.string(
            fromByteCount: Int64(workReport.submittedContextUTF8Bytes),
            countStyle: .file
          )
        )
      }
      if workReport.hasPendingSourceUpdates {
        Label("已有生成后的新事实，等待合并到下一版", systemImage: "arrow.triangle.2.circlepath")
          .foregroundStyle(.orange)
      }
    }
    .font(.caption)
  }

  private var reportStatus: String {
    if let exportFeedback { return exportFeedback }
    if hasUncommittedEdits {
      return workReport.workingDraftStatus ?? "正在准备自动保存…"
    }
    return workReport.status
  }

  private var reportStatusSystemImage: String {
    if workReport.isGenerating { return "sparkles" }
    if workReport.isFinalized { return "checkmark.seal" }
    if workReport.workingDraftSaveFailed { return "exclamationmark.circle" }
    if hasUncommittedEdits {
      return workReport.workingDraftStatus == "正在自动保存…"
        ? "arrow.triangle.2.circlepath" : "checkmark.circle"
    }
    if isReportError { return "exclamationmark.circle" }
    return "checkmark.circle"
  }

  private var reportStatusColor: Color {
    isReportError ? .orange : .secondary
  }

  private var isReportError: Bool {
    let status = reportStatus
    return workReport.workingDraftSaveFailed || status.contains("失败")
      || status.contains("无效") || status.contains("尚未就绪")
      || status.contains("不可用") || status.contains("受限")
  }

  private var reportBadgeTitle: String {
    if workReport.isFinalized { return "已定稿" }
    guard let record = workReport.currentRecord else { return "未保存" }
    return record.currentRevision.origin == .model ? "AI 草稿" : "手写草稿"
  }

  private var reportBadgeSystemImage: String {
    if workReport.isFinalized { return "checkmark.seal" }
    return workReport.currentRecord?.currentRevision.origin == .model ? "sparkles" : "person"
  }

  private var hasUncommittedEdits: Bool {
    reportEditText != (workReport.draft ?? "")
  }

  private var restoredEditorText: String {
    workReport.workingDraft ?? workReport.draft ?? ""
  }

  private var canSaveReport: Bool {
    workReport.isReady && !workReport.isSavingEdit && !workReport.isGenerating
      && !workReport.isFinalized
  }

  private var canGenerateReport: Bool {
    workReport.isReady && !workReport.isGenerating && !workReport.isSavingEdit
  }

  private var isEditorOperationPending: Bool {
    pendingEditorOperation != nil
  }

  private var reportHelp: String {
    if workReport.isFinalized { return "已定稿的日报不会被 AI 覆盖" }
    return workReport.isReady ? "根据本机工作事实生成新的可编辑草稿" : "本地工作数据尚未就绪"
  }

  private var filteredRecentReports: [PersistedWorkReportRecord] {
    let needle = reportHistoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return workReport.recentReports }
    return workReport.recentReports.filter { record in
      let preview = reviewPresentation.previewTextByReportID[record.report.id] ?? ""
      return preview.localizedCaseInsensitiveContains(needle)
        || JournalDateFormatting.dayTitle(record.day).localizedCaseInsensitiveContains(needle)
    }
  }

  private func updateReportReviewPresentation() {
    reviewPresentation = WorkReportReviewPresentation(records: workReport.recentReports)
  }

  private func presentReport(on date: Date) {
    let calendar = Calendar.autoupdatingCurrent
    reviewedReport = workReport.recentReports.first {
      calendar.isDate($0.day.boundary.startsAt, inSameDayAs: date)
    }
  }

  private func requestEditorAction(_ action: JournalMarkdownEditorAction) {
    editorAction = action
    editorActionRequest += 1
  }

  private func toggleSourceMode() {
    isSourceMode.toggle()
    requestEditorAction(.sourceMode(isSourceMode))
  }

  private func presentLinkEditor() {
    linkLabel = editorSelection.selectedText
    linkDestination = ""
    isLinkEditorPresented = true
  }

  private func insertLink() -> Bool {
    let rawDestination = linkDestination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawDestination.isEmpty else { return false }
    let normalizedDestination =
      rawDestination.contains("://")
      ? rawDestination : "https://\(rawDestination)"
    guard let url = URL(string: normalizedDestination),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return false }
    let label = linkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    requestEditorAction(
      .link(title: label.isEmpty ? normalizedDestination : label, url: url.absoluteString)
    )
    return true
  }

  private func requestEditorSnapshot(for operation: ReportEditorOperation) {
    guard pendingEditorOperation == nil else { return }
    pendingEditorOperation = operation
    editorSnapshotRequest += 1
  }

  private func receiveEditorSnapshot(_ source: String?, request: Int) {
    guard request == editorSnapshotRequest, let operation = pendingEditorOperation else { return }
    pendingEditorOperation = nil
    guard let source else {
      exportFeedback = "无法读取编辑器中的最新内容，请重试"
      return
    }
    reportEditText = source
    switch operation {
    case .autosave:
      workReport.stageWorkingDraft(source, flush: true)
    case .generate:
      requestGeneration(with: source)
    case .save:
      saveReportEdit(source)
    case .finalize:
      finalizeReport(source)
    case .openHistory:
      workReport.stageWorkingDraft(source, flush: true)
      onOpenHistory()
    case .export:
      if source != (workReport.draft ?? "") {
        exportFeedback = "请先保存当前修改再导出"
      } else {
        exportCurrentReport()
      }
    }
  }

  private func requestGeneration(with source: String) {
    if source != (workReport.draft ?? "") {
      isRegenerationConfirmationPresented = true
    } else {
      generateReport()
    }
  }

  private func generateReport() {
    exportFeedback = nil
    Task {
      let weatherSnapshot = workReport.dayDescriptor().flatMap(weather.workReportSnapshot)
      await workReport.generate(
        workNote: "",
        weatherSnapshot: weatherSnapshot
      )
      if let generated = workReport.draft {
        reportEditText = generated
      }
    }
  }

  private func saveReportEdit(_ edited: String) {
    guard !isBlank(edited) else {
      exportFeedback = "工作日报正文不能为空"
      return
    }
    guard edited != (workReport.draft ?? "") else {
      exportFeedback = "当前内容已保存"
      return
    }
    exportFeedback = nil
    Task {
      await workReport.saveUserEdit(edited)
      if let saved = workReport.draft, saved == edited {
        reportEditText = saved
      }
    }
  }

  private func finalizeReport(_ edited: String) {
    guard !isBlank(edited) || workReport.currentRecord != nil else {
      exportFeedback = "请先写下日报内容"
      return
    }
    exportFeedback = nil
    Task {
      if edited != (workReport.draft ?? "") {
        await workReport.saveUserEdit(edited)
        guard workReport.draft == edited else { return }
        reportEditText = workReport.draft ?? edited
      }
      await workReport.finalizeReport()
    }
  }

  private func exportCurrentReport() {
    guard let record = workReport.currentRecord, !hasUncommittedEdits else { return }
    let exporter = WorkReportMarkdownExporter()
    let panel = NSSavePanel()
    panel.title = "导出工作日报"
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = exporter.defaultFilename(for: record)
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try exporter.render(record).write(to: url, atomically: true, encoding: .utf8)
      exportFeedback = "已导出当前日报 Markdown"
    } catch {
      exportFeedback = "导出失败；本机日报未受影响"
    }
  }

  private func isBlank(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

private struct WorkReportReviewEntryRow: View {
  let record: PersistedWorkReportRecord
  let previewText: String
  let characterCount: Int
  let isSelected: Bool
  let palette: DaydayWritingReviewPalette

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(JournalDateFormatting.dayTitle(record.day))
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        Text("\(characterCount) 字")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Text(previewText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(record.report.status == .final ? "已定稿" : "第 \(record.report.currentRevisionNumber) 版")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      isSelected ? palette.selectionFill.color : Color.secondary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(palette.selectionBorder.color.opacity(0.45), lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(JournalDateFormatting.dayTitle(record.day))，\(characterCount) 字，"
        + (record.report.status == .final ? "已定稿" : "可查看历史版本")
    )
  }
}

private struct WorkReportHistoryPreviewSheet: View {
  let record: PersistedWorkReportRecord
  private let renderedBody: AttributedString
  let close: () -> Void

  init(record: PersistedWorkReportRecord, close: @escaping () -> Void) {
    self.record = record
    self.renderedBody =
      (try? AttributedString(markdown: record.currentRevision.body))
      ?? AttributedString(record.currentRevision.body)
    self.close = close
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(JournalDateFormatting.dayTitle(record.day))
            .font(.title2.weight(.semibold))
          Text(
            record.report.status == .final
              ? "已定稿" : "第 \(record.report.currentRevisionNumber) 版"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭", action: close)
      }
      .padding(20)
      Divider()
      ScrollView {
        Text(renderedBody)
          .font(.body)
          .textSelection(.enabled)
          .frame(maxWidth: 760, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(28)
      }
    }
    .frame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 680)
  }
}

struct LiveTimelineRow: View {
  let item: TodayTimelineItem
  let connectsToEarlierItem: Bool
  let connectsToLaterItem: Bool
  @State private var isInferenceExpanded = false
  @State private var isActivityExpanded = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(timeRange)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if let timeMetadata {
          Text(timeMetadata)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: timeColumnWidth, alignment: .leading)
      .padding(.top, 13)

      TimelineTrack(
        color: color,
        dashed: item.kind == .activityInference || item.kind == .inferredActivity,
        connectsToEarlierItem: connectsToEarlierItem,
        connectsToLaterItem: connectsToLaterItem
      )
      .frame(width: 18)

      entryCard
    }
    .padding(.vertical, 1)
  }

  @ViewBuilder
  private var entryCard: some View {
    Group {
      if isExpandable {
        Button {
          toggleExpansion()
        } label: {
          entryCardContent
        }
        .buttonStyle(TimelineCardButtonStyle())
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(isExpanded ? "已展开" : "已收起")
        .accessibilityHint(isExpanded ? "点按卡片收起详细内容" : "点按卡片展开详细内容")
      } else {
        entryCardContent
          .accessibilityElement(children: .combine)
          .accessibilityLabel(item.accessibilityLabel)
      }
    }
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(entryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(color.opacity(0.18), lineWidth: 0.5)
    }
  }

  private var entryCardContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      entrySummary
      if isExpanded {
        if let inference = item.inference, item.kind == .inferredActivity {
          inferenceDetail(inference)
        } else if let activity = item.activity, item.kind == .activityInference {
          activityDetail(activity)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var isExpandable: Bool {
    switch item.kind {
    case .inferredActivity:
      item.inference != nil
    case .activityInference:
      item.activity != nil
    default:
      false
    }
  }

  private var isExpanded: Bool {
    switch item.kind {
    case .inferredActivity:
      isInferenceExpanded
    case .activityInference:
      isActivityExpanded
    default:
      false
    }
  }

  private func toggleExpansion() {
    guard isExpandable else { return }
    withAnimation(.easeOut(duration: 0.18)) {
      switch item.kind {
      case .inferredActivity:
        isInferenceExpanded.toggle()
      case .activityInference:
        isActivityExpanded.toggle()
      default:
        break
      }
    }
  }

  private var entrySummary: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let kindTitle {
          Text(kindTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
        }
        Text(item.title)
          .font(.body.weight(.semibold))
          .lineLimit(2)
        Spacer(minLength: 0)
      }
      if item.kind != .inferredActivity && item.kind != .activityInference {
        Text(item.sourceLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let inference = item.inference {
        Text(inference.interaction)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  private func activityDetail(_ activity: TodayActivityDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider().padding(.top, 6)
      Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 7) {
        GridRow {
          LabeledContent("性质", value: "确定性推断")
          LabeledContent("证据", value: "\(activity.eventCount) 条事实")
        }
        GridRow {
          LabeledContent("显示器", value: activity.displayLabel)
          LabeledContent("复核", value: activity.reviewState == .needsReview ? "待确认" : "已就绪")
        }
      }
      .font(.caption)
      if let rationale = activity.rationale {
        Text(rationale)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .textSelection(.enabled)
  }

  private func inferenceDetail(_ inference: VisualInferenceDigest) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider().padding(.top, 6)
      LabeledContent("可见交互") {
        Text(inference.interaction)
          .multilineTextAlignment(.leading)
      }
      .font(.caption)

      HStack(spacing: 8) {
        Text(inference.activityKind)
          .font(.caption.monospaced())
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
      }

      if !inference.evidence.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("可见依据")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(inference.evidence, id: \.self) { evidence in
            Text("• \(evidence)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .textSelection(.enabled)
  }

  private var entryBackground: Color {
    switch item.kind {
    case .lifecycleGap: Color.orange.opacity(0.06)
    case .securityGap: Color.secondary.opacity(0.04)
    case .inferredActivity: Color.accentColor.opacity(0.055)
    default: Color(nsColor: .textBackgroundColor)
    }
  }

  private var kindTitle: String? {
    switch item.kind {
    case .objectiveFact: "客观事实"
    case .sessionSpan: "客观会话"
    case .activitySegment: "事实时段"
    case .activityInference, .inferredActivity: nil
    case .lifecycleGap: "系统边界"
    case .securityGap: "记录间隔"
    case .boundaryStart, .boundaryEnd: "工作日边界"
    }
  }

  private var color: Color {
    switch item.kind {
    case .activitySegment: .accentColor
    case .sessionSpan: .green
    case .activityInference: .accentColor
    case .inferredActivity: .accentColor
    case .objectiveFact: .green
    case .lifecycleGap: .orange
    case .securityGap: .secondary
    case .boundaryStart, .boundaryEnd: .secondary
    }
  }

  private var timeRange: String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm:ss"
    if let endedAt = item.endedAt, endedAt > item.occurredAt {
      return "\(formatter.string(from: item.occurredAt))\n– \(formatter.string(from: endedAt))"
    }
    return formatter.string(from: item.occurredAt)
  }

  private var timeMetadata: String? {
    if let inference = item.inference, item.kind == .inferredActivity {
      return "\(inference.observationCount) 条观察"
    }
    if let activity = item.activity, item.kind == .activityInference {
      return "\(activity.eventCount) 条事实"
    }
    return nil
  }

  private var timeColumnWidth: CGFloat { 88 }
}

private struct TimelineCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.72 : 1)
  }
}

private struct TimelineTrack: View {
  let color: Color
  let dashed: Bool
  let connectsToEarlierItem: Bool
  let connectsToLaterItem: Bool

  var body: some View {
    GeometryReader { proxy in
      let center = min(24, max(12, proxy.size.height / 2))
      Path { path in
        if connectsToLaterItem {
          path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
          path.addLine(to: CGPoint(x: proxy.size.width / 2, y: center))
        }
        if connectsToEarlierItem {
          path.move(to: CGPoint(x: proxy.size.width / 2, y: center))
          path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
        }
      }
      .stroke(
        color.opacity(0.34),
        style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : [])
      )

      Circle()
        .fill(color)
        .frame(width: 10, height: 10)
        .overlay {
          Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
        }
        .position(x: proxy.size.width / 2, y: center)
    }
    .accessibilityHidden(true)
  }
}

struct TimelineLoadMoreRow: View {
  let isLoading: Bool
  let failed: Bool
  let action: () -> Void

  var body: some View {
    HStack {
      Spacer()
      Button(
        failed ? "重试查看更多" : "查看更多",
        systemImage: failed ? "arrow.clockwise" : "clock.arrow.circlepath"
      ) {
        action()
      }
      .buttonStyle(.borderless)
      .disabled(isLoading)
      if isLoading {
        ProgressView().controlSize(.small)
      }
      Spacer()
    }
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(failed ? "加载更多记录失败，重试" : "查看更多记录")
  }
}

private struct TimelineRevealMoreRow: View {
  let nextBatchCount: Int
  let action: () -> Void

  var body: some View {
    HStack {
      Spacer()
      Button("查看更多（\(nextBatchCount) 条）", systemImage: "chevron.down") {
        action()
      }
      .buttonStyle(.borderless)
      Spacer()
    }
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("查看更多 \(nextBatchCount) 条记录")
    .accessibilityHint("点按后显示下一批记录")
  }
}

private struct DisplayStatusRow: View {
  let display: AppRuntimeDisplay
  let ordinal: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: display.isBuiltIn ? "macbook" : "display")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title).font(.body.weight(.medium))
          if display.isMain {
            Text("主显示器").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
          }
          if display.isMirrored {
            Text("镜像").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
          }
        }
        Text(display.dimensionsDescription)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Spacer()

      StatusBadge(title: "已连接", systemImage: "checkmark.circle.fill", color: .green)
    }
    .padding(10)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .combine)
  }

  private var title: String {
    display.isBuiltIn ? "内建显示器" : "显示器 \(ordinal)"
  }
}
