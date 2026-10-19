import AppKit
import DaydayCore
import SwiftUI

/// A focused replay of one logical workday. It owns no live collectors: every
/// item comes from durable local facts or durable visual inference records for
/// the selected day.
struct HistoryView: View {
  @ObservedObject var workReport: WorkReportGenerationModel
  @ObservedObject var timeline: HistoricalTimelineModel

  enum ContentKind: String, CaseIterable, Identifiable {
    case replay = "时段回放"
    case reports = "工作日报"

    var id: Self { self }
  }

  private enum TimeScope: String, CaseIterable, Identifiable {
    case wholeDay = "全天"
    case custom = "自定时段"

    var id: Self { self }
  }

  @State private var contentKind: ContentKind = .replay
  @State private var timeScope: TimeScope = .wholeDay
  @State private var customStart = Date()
  @State private var customEnd = Date()
  @State private var query = ""

  private static let chineseLocale = Locale(identifier: "zh_CN")

  private var visibleReports: [PersistedWorkReportRecord] {
    guard contentKind == .reports else { return [] }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return workReport.recentReports.filter {
      isSelectedWorkday($0.day)
        && (
          trimmed.isEmpty
            || $0.currentRevision.body.localizedCaseInsensitiveContains(trimmed)
            || Self.dayTitle($0.day).localizedCaseInsensitiveContains(trimmed)
        )
    }
  }

  var body: some View {
    rootContent
      .task {
        await workReport.refreshHistory()
        timeline.refresh()
      }
      .onChange(of: timeline.selectedCalendarDate) { _, _ in
        synchronizeCustomTimeRange()
        timeline.refresh()
      }
      .onChange(of: timeline.presentation?.boundary.startsAt) { _, _ in
        if timeScope == .custom { synchronizeCustomTimeRange() }
      }
      .onChange(of: timeScope) { _, scope in
        if scope == .custom { synchronizeCustomTimeRange() }
      }
      .onChange(of: contentKind) { _, kind in
        if kind == .reports { Task { await workReport.refreshHistory() } }
      }
  }

  private var rootContent: some View {
    VStack(spacing: 0) {
      PageHeaderBar(
        title: "历史",
        subtitle: "按工作日回看本机事实与工作日报",
        systemImage: "clock.arrow.circlepath"
      ) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) { headerContentControls }
          VStack(alignment: .trailing, spacing: 8) { headerContentControls }
        }
      }

      contextBar

      if contentKind == .replay {
        replayContent
      } else {
        reportContent
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.locale, Self.chineseLocale)
    .toolbar {
      if contentKind == .reports {
        ToolbarItem(placement: .primaryAction) {
          Button("导出", systemImage: "square.and.arrow.up") {
            exportVisibleReports()
          }
          .disabled(visibleReports.isEmpty)
          .help("将当前可见的工作日报导出为 Markdown 文件")
        }
      }
    }
  }

  @ViewBuilder
  private var headerContentControls: some View {
    Picker("内容", selection: $contentKind) {
      ForEach(ContentKind.allCases) { kind in
        Text(kind.rawValue).tag(kind)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 220)

    Button("前一天", systemImage: "chevron.left", action: showPreviousDay)
      .buttonStyle(.borderless)
      .labelStyle(.iconOnly)
      .help("查看前一个工作日")

    DatePicker(
      "工作日",
      selection: $timeline.selectedCalendarDate,
      in: ...timeline.latestSelectableCalendarDate,
      displayedComponents: .date
    )
    .datePickerStyle(.compact)
    .labelsHidden()
    .accessibilityLabel("工作日")

    Button("后一天", systemImage: "chevron.right", action: showNextDay)
      .buttonStyle(.borderless)
      .labelStyle(.iconOnly)
      .disabled(isShowingLatestDay)
      .help("查看后一个工作日")
  }

  private var contextBar: some View {
    HStack(spacing: DaydaySpace.s) {
      Group {
        if contentKind == .replay {
          replayContextControls
        } else {
          reportContextControls
        }
      }
      .transition(.opacity)
    }
    .frame(minHeight: 38, alignment: .leading)
    .padding(.horizontal, DaydaySpace.pageHorizontal)
    .padding(.bottom, DaydaySpace.s)
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeInOut(duration: 0.16), value: contentKind)
  }

  private var replayContextControls: some View {
    HStack(spacing: DaydaySpace.s) {
      Text("回放范围")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("时段", selection: $timeScope) {
        ForEach(TimeScope.allCases) { scope in
          Text(scope.rawValue).tag(scope)
        }
      }
      .pickerStyle(.menu)

      if timeScope == .custom {
        DatePicker("开始", selection: $customStart, displayedComponents: .hourAndMinute)
          .datePickerStyle(.compact)
          .labelsHidden()
          .accessibilityLabel("开始时间")
        Text("至").font(.caption).foregroundStyle(.secondary)
        DatePicker("结束", selection: $customEnd, displayedComponents: .hourAndMinute)
          .datePickerStyle(.compact)
          .labelsHidden()
          .accessibilityLabel("结束时间")
      }
    }
  }

  private var reportContextControls: some View {
    HStack(spacing: DaydaySpace.s) {
      Text("当前工作日的日报")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("搜索该日报", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(width: 190)
    }
  }

  @ViewBuilder
  private var replayContent: some View {
    if timeline.isLoading {
      ProgressView("正在读取本机历史回放…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let presentation = timeline.presentation {
      switch presentation.state {
      case .populated:
        replayTimeline(presentation)
      case .empty:
        EmptyState(
          title: "此工作日还没有时段内容",
          detail: "历史只展示已保存的本机事实与已完成的 AI 推断，不补造空白时段。",
          systemImage: "calendar.badge.questionmark"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failure:
        EmptyState(
          title: "无法读取本地历史",
          detail: "SQLite 历史记录暂时不可用；请稍后重试。",
          systemImage: "externaldrive.badge.exclamationmark"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      default:
        ProgressView("正在更新本地历史回放…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      ProgressView("正在准备本地历史回放…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func replayTimeline(_ presentation: TodayTimelinePresentation) -> some View {
    let items = filteredItems(from: presentation)
    return historyScroll {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(dayTitle(presentation.boundary))
              .font(.headline)
            Text(timeRangeDescription(for: presentation.boundary))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Spacer()
          HistoryReplayCount(items: items)
        }

        if timeScope == .custom, selectedTimeRange(for: presentation.boundary) == nil {
          ContentUnavailableView(
            "结束时间需晚于开始时间",
            systemImage: "clock.badge.exclamationmark",
            description: Text("请选择工作日边界内的有效时间范围。")
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        } else if items.isEmpty {
          ContentUnavailableView(
            "所选时段没有内容",
            systemImage: "clock.badge.questionmark",
            description: Text("改变时间范围，或切换到全天查看该工作日的完整回放。")
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
              LiveTimelineRow(
                item: item,
                connectsToEarlierItem: index < items.count - 1,
                connectsToLaterItem: index > 0
              )
            }
            if timeline.canLoadOlder || timeline.loadOlderFailed {
              TimelineLoadMoreRow(
                isLoading: timeline.isLoadingOlder,
                failed: timeline.loadOlderFailed,
                action: timeline.loadOlder
              )
            }
          }
        }
      }
    }
  }

  private var reportContent: some View {
    historyScroll {
      Group {
        if visibleReports.isEmpty {
          ContentUnavailableView(
            query.isEmpty ? "这一天还没有已保存的工作日报" : "没有匹配的工作日报",
            systemImage: "calendar.badge.clock",
            description: Text(query.isEmpty ? workReport.historyStatus : "请调整搜索内容后重试。")
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        } else {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(visibleReports, id: \.report.id) { record in
              reportRow(record)
            }
          }
        }
      }
    }
  }

  private func historyScroll<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    DaydayScrollView {
      content()
        .padding(.horizontal, DaydaySpace.pageHorizontal)
        .padding(.top, DaydaySpace.pageContentTop)
        .padding(.bottom, DaydaySpace.pageHorizontal)
        .frame(maxWidth: 980, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func filteredItems(from presentation: TodayTimelinePresentation) -> [TodayTimelineItem] {
    guard let range = selectedTimeRange(for: presentation.boundary) else { return [] }
    return presentation.items.filter { item in
      let end = item.endedAt ?? item.occurredAt
      return item.occurredAt < range.upperBound && end >= range.lowerBound
    }
  }

  private func selectedTimeRange(for boundary: WorkdayBoundarySnapshot) -> Range<Date>? {
    guard timeScope == .custom else { return boundary.startsAt..<boundary.endsAt }
    let start = min(max(customStart, boundary.startsAt), boundary.endsAt)
    let end = min(max(customEnd, boundary.startsAt), boundary.endsAt)
    guard start < end else { return nil }
    return start..<end
  }

  private func timeRangeDescription(for boundary: WorkdayBoundarySnapshot) -> String {
    let range = selectedTimeRange(for: boundary) ?? boundary.startsAt..<boundary.endsAt
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm"
    let endPrefix = Calendar.autoupdatingCurrent.isDate(range.lowerBound, inSameDayAs: range.upperBound)
      ? "" : "次日 "
    return "\(formatter.string(from: range.lowerBound)) 至 \(endPrefix)\(formatter.string(from: range.upperBound))"
  }

  private func synchronizeCustomTimeRange() {
    guard let boundary = timeline.presentation?.boundary else { return }
    customStart = boundary.startsAt
    customEnd = boundary.endsAt
  }

  private func showPreviousDay() {
    guard let previous = Calendar.autoupdatingCurrent.date(
      byAdding: .day, value: -1, to: timeline.selectedCalendarDate
    ) else { return }
    timeline.selectedCalendarDate = previous
  }

  private func showNextDay() {
    guard !isShowingLatestDay,
          let next = Calendar.autoupdatingCurrent.date(
            byAdding: .day, value: 1, to: timeline.selectedCalendarDate
          )
    else { return }
    timeline.selectedCalendarDate = min(next, timeline.latestSelectableCalendarDate)
  }

  private var isShowingLatestDay: Bool {
    Calendar.autoupdatingCurrent.isDate(
      timeline.selectedCalendarDate,
      inSameDayAs: timeline.latestSelectableCalendarDate
    )
  }

  private func isSelectedWorkday(_ day: DayDescriptor) -> Bool {
    let components = Calendar.autoupdatingCurrent.dateComponents(
      [.year, .month, .day], from: timeline.selectedCalendarDate
    )
    return day.logicalDate.year == components.year
      && day.logicalDate.month == components.month
      && day.logicalDate.day == components.day
  }

  @ViewBuilder
  private func reportRow(_ record: PersistedWorkReportRecord) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(Self.dayTitle(record.day))
          .font(.headline)
        Text("第 \(record.report.currentRevisionNumber) 版")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Text(record.report.updatedAt, format: .dateTime.hour().minute().locale(Self.chineseLocale))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text(record.currentRevision.body)
        .font(.body)
        .lineSpacing(3)
        .lineLimit(5)
        .textSelection(.enabled)
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }

  private func exportVisibleReports() {
    guard let first = visibleReports.first else { return }
    let exporter = WorkReportMarkdownExporter()
    let panel = NSSavePanel()
    panel.title = "导出工作日报"
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = exporter.defaultFilename(for: first)
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let content = visibleReports.map { exporter.render($0) }.joined(separator: "\n\n---\n\n")
    try? content.write(to: url, atomically: true, encoding: .utf8)
  }

  private static func dayTitle(_ day: DayDescriptor) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .autoupdatingCurrent
    guard let date = calendar.date(from: DateComponents(
      year: day.logicalDate.year,
      month: day.logicalDate.month,
      day: day.logicalDate.day
    )) else {
      return "\(day.logicalDate.year)年\(day.logicalDate.month)月\(day.logicalDate.day)日"
    }
    return date.formatted(.dateTime.year().month().day().weekday(.wide).locale(chineseLocale))
  }

  private func dayTitle(_ boundary: WorkdayBoundarySnapshot) -> String {
    boundary.startsAt.formatted(.dateTime.year().month().day().weekday(.wide).locale(Self.chineseLocale))
  }
}

private struct HistoryReplayCount: View {
  let items: [TodayTimelineItem]

  private var factualCount: Int {
    items.filter {
      switch $0.kind {
      case .objectiveFact, .activitySegment, .sessionSpan: true
      default: false
      }
    }.count
  }

  private var inferenceCount: Int {
    items.filter { $0.kind == .inferredActivity || $0.kind == .activityInference }.count
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text("\(items.count) 条内容")
        .font(.caption.monospacedDigit().weight(.medium))
      Text("事实 \(factualCount) · AI 推断 \(inferenceCount)")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
