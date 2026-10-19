import DaydayCore
import Foundation
import SwiftUI

struct MenuBarView: View {
  @ObservedObject var runtime: AppRuntimeModel
  @ObservedObject var permissionOnboarding: PermissionOnboardingModel
  @ObservedObject var timeline: MenuBarTimelineModel
  @ObservedObject var insights: MenuBarInsightsModel
  @ObservedObject var appearance: AppearanceSettingsModel
  @ObservedObject var layout: MenuBarPopoverLayout
  let onOpenToday: @MainActor () -> Void
  let onQuit: @MainActor () -> Void

  @State private var selectedRange: MenuBarTimelineRange = .recentNinetyMinutes
  @State private var selectedMiniInsight: MenuBarDashboardTab = .records

  var body: some View {
    VStack(spacing: 0) {
      DaydayScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 14) {
          statusHeader
          recordingCondition
          Divider()
          observationDistribution
          Divider()
          dashboard
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
      }
      Divider()
      actions
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
    .frame(
      width: layout.contentSize.width,
      height: layout.contentSize.height,
      alignment: .top
    )
    .preferredColorScheme(appearance.preference.colorScheme)
    .environment(\.daydayAccent, appearance.accent)
    .accentColor(appearance.accent.tint)
    .tint(appearance.accent.tint)
    .onAppear { refreshForVisibleRange() }
    .onChange(of: selectedRange) { _, range in
      layout.use(range)
      timeline.refresh(range: range)
      insights.refresh(range: range)
    }
    .task(id: "\(selectedRange.rawValue)-\(selectedMiniInsight.title)") {
      guard selectedMiniInsight == .inputHeatmaps else { return }
      await insights.presentLiveInput(range: selectedRange)
    }
  }

  private var statusHeader: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: runtime.collectionStatus.symbolName)
        .font(.title3.weight(.semibold))
        .foregroundStyle(runtime.collectionStatus.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(runtime.collectionStatus.title).font(.headline)
        Text(headerDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button("刷新", systemImage: "arrow.clockwise") { refreshForVisibleRange() }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(runtime.isRefreshing || timeline.isLoading || insights.isLoading)
        .help("刷新本机状态与记录分布，不会请求权限")
    }
    .accessibilityElement(children: .combine)
  }

  private var headerDetail: String {
    let displays = runtime.snapshot.displays.count
    let displayText = displays == 0 ? "显示器状态待确认" : String(displays) + " 个显示器"
    guard let latest = recentItems.first else { return "本机 · " + displayText }
    return "本机 · " + displayText + " · 最近记录 "
      + latest.occurredAt.formatted(date: .omitted, time: .shortened)
  }

  @ViewBuilder
  private var recordingCondition: some View {
    if permissionOnboarding.hasUnconfirmedCollectors {
      Button("记录条件需要处理", systemImage: "exclamationmark.shield") {
        onOpenToday()
      }
      .buttonStyle(.bordered)
      .tint(.orange)
      .help("在今日页面检查未完成的记录条件")
    } else {
      HStack(spacing: 8) {
        Label("记录条件正常", systemImage: "checkmark.shield")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
        Spacer()
        Text("已启用 \(permissionOnboarding.enabledCollectorCount) / \(permissionOnboarding.collectorCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var observationDistribution: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Picker("时间范围", selection: $selectedRange) {
          ForEach(MenuBarTimelineRange.allCases) { range in
            Text(range.title).tag(range)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        if timeline.isLoading {
          ProgressView().controlSize(.small)
        } else {
          Text("\(timeline.presentation.totalObservationCount) 条客观记录")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
        }
      }

      MenuBarObservationChart(
        presentation: timeline.presentation,
        height: selectedRange.chartHeight
      )

    }
  }

  private var recentFacts: some View {
    VStack(alignment: .leading, spacing: 8) {
      if recentItems.isEmpty {
        Text("完成授权并开始采集后，这里会显示最新本机事实。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(recentItems.prefix(8)) { item in
          HStack(alignment: .top, spacing: 8) {
            Text(item.occurredAt, format: .dateTime.hour().minute())
              .font(.caption.monospacedDigit().weight(.medium))
              .foregroundStyle(.secondary)
              .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
              Text(item.sourceLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(item.accessibilityLabel)
        }
        observationSummary
      }
    }
  }

  private var dashboard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Picker("摘要视图", selection: $selectedMiniInsight) {
        ForEach(MenuBarDashboardTab.allCases) { insight in
          Text(insight.title).tag(insight)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)

      dashboardContent
    }
  }

  @ViewBuilder
  private var dashboardContent: some View {
    switch selectedMiniInsight {
    case .records:
      recentFacts
    case .inputHeatmaps:
      MenuBarKeyMouseHeatmaps(input: insights.presentation.input, state: insights.presentation.state)
    case .applications:
      MenuBarApplicationMiniView(
        applications: insights.presentation.applications,
        switchCount: insights.presentation.applicationSwitchCount,
        hasIncompleteFacts: insights.presentation.hasIncompleteForegroundFacts,
        state: insights.presentation.state
      )
    }
  }

  private var observationSummary: some View {
    HStack(spacing: 0) {
      observationMetric(
        title: "屏幕", count: timeline.presentation.screenObservationCount,
        symbol: "rectangle.inset.filled")
      Divider().frame(height: 22)
      observationMetric(
        title: "应用", count: timeline.presentation.applicationObservationCount,
        symbol: "macwindow")
      Divider().frame(height: 22)
      observationMetric(
        title: "其他", count: timeline.presentation.otherObservationCount,
        symbol: "circle.dotted")
    }
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "当前时间范围内：屏幕记录 \(timeline.presentation.screenObservationCount) 条，应用上下文 \(timeline.presentation.applicationObservationCount) 条，其他记录 \(timeline.presentation.otherObservationCount) 条。"
    )
  }

  private func observationMetric(title: String, count: Int, symbol: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.caption2)
      Text(title)
      Text(count, format: .number)
        .font(.caption.monospacedDigit().weight(.semibold))
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity)
  }

  private var recentItems: [TodayTimelineItem] {
    let cutoff = Date.now.addingTimeInterval(-90 * 60)
    return (runtime.todayTimeline?.items ?? [])
      .filter { $0.occurredAt >= cutoff && $0.kind != .boundaryStart && $0.kind != .boundaryEnd }
      .sorted { $0.occurredAt > $1.occurredAt }
  }

  private var actions: some View {
    HStack(spacing: 10) {
      Button("退出 Dayday", systemImage: "power", role: .destructive) { onQuit() }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("安全停止采集并退出 Dayday")
      Spacer()
      Button("打开今日", systemImage: "arrow.right") { onOpenToday() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("o")
    }
  }

  private func refreshForVisibleRange() {
    runtime.startMonitoring()
    runtime.requestRefresh()
    permissionOnboarding.refreshSystemStatuses()
    timeline.refresh(range: selectedRange)
    insights.refresh(range: selectedRange)
  }
}

enum MenuBarDashboardTab: CaseIterable, Identifiable {
  case records
  case inputHeatmaps
  case applications

  var id: Self { self }
  var title: String {
    switch self {
    case .records: "记录"
    case .inputHeatmaps: "键鼠热图"
    case .applications: "应用时长"
    }
  }
}

private struct MenuBarObservationChart: View {
  let presentation: MenuBarTimelinePresentation
  let height: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hoveredBucketID: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      GeometryReader { proxy in
        HStack(alignment: .bottom, spacing: chartSpacing(for: proxy.size.width)) {
          ForEach(Array(presentation.buckets.enumerated()), id: \.offset) { _, bucket in
            MenuBarObservationColumn(
              bucket: bucket,
              maximum: presentation.maximumBucketCount,
              isHovered: hoveredBucketID == bucket.id,
              onHover: { isHovering in
                if isHovering {
                  hoveredBucketID = bucket.id
                } else if hoveredBucketID == bucket.id {
                  hoveredBucketID = nil
                }
              }
            )
            .frame(
              width: chartColumnWidth(for: proxy.size.width),
              height: proxy.size.height,
              alignment: .bottom
            )
            .transition(.opacity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(chartTransition, value: presentation.buckets)
      }
      .frame(height: height)

      HStack {
        Text(axisLabel(for: presentation.rangeStart))
        Spacer()
        Text(axisLabel(for: midpoint))
        Spacer()
        Text(axisLabel(for: presentation.rangeEnd))
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.tertiary)

      chartDetail
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(presentation.range.chartTitle)，共 \(presentation.totalObservationCount) 条客观记录。")
    .onChange(of: presentation.range) { _, _ in
      hoveredBucketID = nil
    }
  }

  private var midpoint: Date {
    presentation.rangeStart.addingTimeInterval(
      presentation.rangeEnd.timeIntervalSince(presentation.rangeStart) / 2)
  }

  private var chartTransition: Animation? {
    reduceMotion ? nil : DaydayLiveMetricMotion.animation(reduceMotion: false)
  }

  @ViewBuilder
  private var chartDetail: some View {
    Group {
      if let bucket = presentation.buckets.first(where: { $0.id == hoveredBucketID }) {
        Label(bucketDetail(bucket), systemImage: "cursorarrow.rays")
          .accessibilityLabel(bucketAccessibilityLabel(bucket))
      } else {
        switch presentation.state {
        case .loading:
          Label("正在读取本机记录", systemImage: "arrow.triangle.2.circlepath")
        case .empty:
          Label("范围内暂无记录", systemImage: "tray")
        case .populated:
          Label("悬浮柱条查看该时段记录", systemImage: "cursorarrow")
        case .failure:
          Label("暂时无法读取", systemImage: "exclamationmark.triangle")
        }
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  private func bucketDetail(_ bucket: MenuBarTimelineBucket) -> String {
    "\(bucket.startedAt.formatted(date: .omitted, time: .shortened))–\(bucket.endedAt.formatted(date: .omitted, time: .shortened)) · \(bucket.objectiveObservationCount) 条 · 屏幕 \(bucket.screenObservationCount) · 应用 \(bucket.applicationObservationCount) · 其他 \(bucket.otherObservationCount)"
  }

  private func bucketAccessibilityLabel(_ bucket: MenuBarTimelineBucket) -> String {
    "所选时段 \(bucket.startedAt.formatted(date: .omitted, time: .shortened)) 至 \(bucket.endedAt.formatted(date: .omitted, time: .shortened))，共 \(bucket.objectiveObservationCount) 条客观记录；屏幕 \(bucket.screenObservationCount) 条，应用 \(bucket.applicationObservationCount) 条，其他 \(bucket.otherObservationCount) 条。"
  }

  private func chartSpacing(for width: CGFloat) -> CGFloat {
    switch presentation.buckets.count {
    case 0...8: 14
    case 9...18: 5
    default: 2
    }
  }

  private func chartColumnWidth(for availableWidth: CGFloat) -> CGFloat {
    let count = max(1, presentation.buckets.count)
    let spacing = chartSpacing(for: availableWidth) * CGFloat(max(0, count - 1))
    let width = max(6, (availableWidth - spacing) / CGFloat(count))
    switch count {
    case 0...8: return min(22, width)
    case 9...18: return min(16, width)
    default: return min(10, width)
    }
  }

  private func axisLabel(for date: Date) -> String {
    presentation.range.axisLabel(for: date, calendar: .autoupdatingCurrent)
  }
}

private struct MenuBarObservationColumn: View {
  let bucket: MenuBarTimelineBucket
  let maximum: Int
  let isHovered: Bool
  let onHover: (Bool) -> Void

  var body: some View {
    let total = bucket.objectiveObservationCount
    DaydayGrowingBar(
      fraction: total == 0 ? 0.000_001 : CGFloat(total) / CGFloat(max(maximum, 1)),
      axis: .vertical,
      minimumVisibleLength: total == 0 ? 2 : 6
    ) {
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(columnColor.opacity(total == 0 ? 0.12 : (isHovered ? 1 : 0.82)))
        .overlay {
          if isHovered {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .stroke(columnColor.opacity(0.55), lineWidth: 1)
          }
        }
        .shadow(color: isHovered ? columnColor.opacity(0.26) : .clear, radius: 3, y: 1)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
    .accessibilityLabel(
      "\(bucket.startedAt.formatted(date: .omitted, time: .shortened))，\(total) 条客观记录"
    )
    .help(
      "\(bucket.startedAt.formatted(date: .omitted, time: .shortened))：屏幕 \(bucket.screenObservationCount)，应用 \(bucket.applicationObservationCount)，其他 \(bucket.otherObservationCount)"
    )
  }

  private var columnColor: Color {
    // The distribution encodes record volume by height. Source composition
    // remains available in the hover/VoiceOver detail, so fixed blue/indigo
    // fills only created a second, competing palette in the popover.
    return .accentColor
  }
}
