import DaydayCapture
import DaydayCore
import SwiftUI

struct InsightsView: View {
  enum Range: String, CaseIterable, Identifiable {
    case today = "今日"
    case week = "本周"
    case month = "本月"
    case year = "今年"
    case custom = "自定义"

    var id: Self { self }
  }

  @ObservedObject var input: InputInsightsModel
  @ObservedObject var runtime: AppRuntimeModel
  @ObservedObject var dailyWorkScheduleSettings: DailyWorkScheduleSettingsModel
  @ObservedObject var applicationUsage: ApplicationUsageInsightsModel
  @State private var range: Range = .today
  @State private var customStart = Calendar.autoupdatingCurrent.startOfDay(for: Date())
  @State private var customEnd = Calendar.autoupdatingCurrent.startOfDay(for: Date())
  @State private var selection = PrototypeData.insightSections[0]
  @State private var pointerScope: PointerHeatmapScope = .all
  @State private var pointerMetric: PointerHeatmapMetric = .clicks
  @State private var pointerSelectedDay: Date?
  @State private var isCustomRangePresented = false

  var body: some View {
    VStack(spacing: 0) {
      PageHeaderBar(title: "洞察", subtitle: nil, systemImage: "chart.bar.xaxis") {
        insightFilters
      }

      DaydayScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 7) {
            Picker("洞察类型", selection: $selection) {
              ForEach(PrototypeData.insightSections) { section in
                Label(section.title, systemImage: section.systemImage).tag(section)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }
          insightContent
        }
        .padding(.horizontal, DaydaySpace.pageHorizontal)
        .padding(.top, DaydaySpace.pageContentTop)
        .padding(.bottom, DaydaySpace.pageHorizontal)
        .frame(maxWidth: 1180, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onChange(of: input.pointerHistoryDays) { _, days in
      if let selected = pointerSelectedDay, days.contains(where: { $0.logicalDayStart == selected })
      {
        return
      }
      pointerSelectedDay = days.first?.logicalDayStart
    }
    .onChange(of: pointerScope) { _, nextScope in
      if nextScope == .day {
        isCustomRangePresented = false
      }
    }
    .task(id: rangeKey) {
      let range = effectiveRange
      input.refresh(range: range)
      while !Task.isCancelled {
        // Live input is event-driven. This slow pass only reconciles a
        // completed durable bucket or an externally changed database.
        try? await Task.sleep(for: .seconds(300))
        guard !Task.isCancelled else { return }
        input.refresh(range: effectiveRange)
      }
    }
    .task(id: "\(rangeKey)-\(selection.title)-\(pointerScope.rawValue)") {
      let range = effectiveRange
      let presentsLiveInput =
        (selection == .keyboard || selection == .mouse)
        && !isPointerDayBrowsing
        && self.range == .today
      guard presentsLiveInput else { return }
      let token = input.beginLivePresentation(
        range: range,
        mode: selection == .mouse ? .pointerOverview : .aggregatesOnly
      )
      defer { input.endLivePresentation(token) }
      await input.refreshLive(range: range)
      while !Task.isCancelled {
        // Capture drives ordinary input refreshes. This slow pass is
        // only insurance for a dropped lifecycle notification.
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        await input.refreshLive(range: effectiveRange)
      }
    }
    .task(id: "application-\(rangeKey)-\(selection.title)") {
      let range = effectiveRange
      guard selection == .applications else { return }
      applicationUsage.refresh(range: range)
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }
        applicationUsage.refresh(range: effectiveRange)
      }
    }
    .task(id: "pointer-history-\(selection.title)-\(pointerScope.rawValue)") {
      guard selection == .mouse, pointerScope == .day else { return }
      input.refreshPointerHistory()
    }
    .task(
      id: "pointer-day-\(selection.title)-\(pointerScope.rawValue)-\(pointerSelectedDay?.timeIntervalSinceReferenceDate ?? -1)"
    ) {
      guard selection == .mouse, pointerScope == .day else { return }
      input.refreshPointerDay(startingAt: pointerSelectedDay)
    }
  }

  private var insightFilters: some View {
    HStack(spacing: 10) {
      if selection == .mouse {
        pointerScopePicker.frame(minWidth: 128)
        if pointerScope == .day {
          pointerDayPicker.frame(minWidth: 166)
        }
        pointerMetricPicker.frame(minWidth: 128)
      }
      if !isPointerDayBrowsing {
        timeRangePicker.frame(minWidth: 140)
      }
    }
  }

  private var pointerScopePicker: some View {
    Picker("鼠标视图", selection: $pointerScope) {
      ForEach(PointerHeatmapScope.allCases) { Text($0.rawValue).tag($0) }
    }
    .pickerStyle(.menu)
  }

  @ViewBuilder
  private var pointerDayPicker: some View {
    if input.pointerHistoryDays.isEmpty {
      Label(
        input.isPointerHistoryLoading ? "正在读取…" : "暂无历史",
        systemImage: "calendar"
      )
      .foregroundStyle(.secondary)
    } else {
      DatePicker(
        "日期",
        selection: pointerDaySelection,
        in: pointerHistoryDateRange,
        displayedComponents: .date
      )
      .datePickerStyle(.compact)
      .labelsHidden()
      .accessibilityLabel("历史日期")
      .accessibilityValue(pointerSelectedDayTitle)
      .help(pointerSelectedDayTitle)
    }
  }

  private var pointerDaySelection: Binding<Date> {
    Binding(
      get: {
        let selected = pointerSelectedDay ?? input.pointerHistoryDays.first?.logicalDayStart ?? .now
        return Calendar.autoupdatingCurrent.startOfDay(for: selected)
      },
      set: { selected in
        let calendar = Calendar.autoupdatingCurrent
        pointerSelectedDay = input.pointerHistoryDays.first(where: {
          calendar.isDate($0.logicalDayStart, inSameDayAs: selected)
        })?.logicalDayStart
      }
    )
  }

  private var pointerHistoryDateRange: ClosedRange<Date> {
    let calendar = Calendar.autoupdatingCurrent
    let newest = input.pointerHistoryDays.first?.logicalDayStart ?? .now
    let oldest = input.pointerHistoryDays.last?.logicalDayStart ?? newest
    return calendar.startOfDay(for: oldest)...calendar.startOfDay(for: newest)
  }

  private var pointerSelectedDayTitle: String {
    input.pointerHistoryDays.first(where: {
      $0.logicalDayStart == pointerSelectedDay
    })?.displayTitle ?? "选择历史日期"
  }

  private var pointerMetricPicker: some View {
    Picker("鼠标热度", selection: $pointerMetric) {
      ForEach(PointerHeatmapMetric.allCases) { Text($0.rawValue).tag($0) }
    }
    .pickerStyle(.menu)
  }

  private var timeRangePicker: some View {
    Picker("时间范围", selection: $range) {
      ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
    }
    .pickerStyle(.menu)
    .onChange(of: range) { _, next in
      if next == .custom { isCustomRangePresented = true }
    }
    .popover(isPresented: $isCustomRangePresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 14) {
        Text("自定义时间范围").font(.headline)
        DatePicker("开始日期", selection: $customStart, displayedComponents: .date)
        DatePicker("结束日期", selection: $customEnd, displayedComponents: .date)
        HStack {
          Spacer()
          Button("完成") { isCustomRangePresented = false }
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(16)
      .frame(width: 300)
    }
  }

  /// The concrete half-open range backing the picker selection. Today and
  /// week start at the configured workday boundary; year starts at the
  /// civil calendar year; custom clamps the two date pickers into order.
  private var effectiveRange: Swift.Range<Date> {
    let now = Date()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    switch range {
    case .today:
      return Self.calendarRange(
        days: 1,
        endingAt: now,
        calendar: calendar,
        boundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
      )
    case .week:
      return Self.calendarRange(
        days: 7,
        endingAt: now,
        calendar: calendar,
        boundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
      )
    case .month:
      return Self.calendarRange(
        days: 31,
        endingAt: now,
        calendar: calendar,
        boundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
      )
    case .year:
      guard let start = calendar.dateInterval(of: .year, for: now)?.start,
        start < now
      else {
        return Self.calendarRange(
          days: 31,
          endingAt: now,
          calendar: calendar,
          boundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
        )
      }
      return start..<now.addingTimeInterval(1)
    case .custom:
      let start = calendar.startOfDay(for: min(customStart, customEnd))
      let end = calendar.startOfDay(for: max(customStart, customEnd))
      return start..<end.addingTimeInterval(86_400)
    }
  }

  /// A stable identity for the range selection that also changes when the
  /// custom date pickers move, so the refresh tasks restart.
  private var rangeKey: String {
    "\(range.rawValue)-\(customStart.timeIntervalSinceReferenceDate)-\(customEnd.timeIntervalSinceReferenceDate)-\(dailyWorkScheduleSettings.currentSchedule.logicalDayBoundaryHour)"
  }

  private static func calendarRange(
    days: Int,
    endingAt now: Date,
    calendar: Calendar,
    boundary: WorkdayBoundary
  )
    -> Swift.Range<Date>
  {
    let todayStart =
      (try? boundary.start(containing: now, calendar: calendar))
      ?? calendar.startOfDay(for: now)
    let start =
      calendar.date(byAdding: .day, value: -max(0, days - 1), to: todayStart)
      ?? todayStart
    return start..<now.addingTimeInterval(1)
  }

  /// Long ranges cannot be shown hour-by-hour; they get the year-style
  /// logical-day calendar instead.
  private var usesYearCalendar: Bool {
    guard range == .year || range == .custom else { return false }
    return effectiveRange.upperBound.timeIntervalSince(effectiveRange.lowerBound) > 62 * 86_400
  }

  @ViewBuilder
  private var insightContent: some View {
    switch selection {
    case .applications:
      ApplicationInputDetailCard(
        applicationUsage: applicationUsage.presentation,
        inputAggregates: input.aggregates,
        isLoading: applicationUsage.isLoading || input.isLoading,
        inputLoadFailed: input.loadFailed
      )
      ApplicationUsageCard(
        presentation: applicationUsage.presentation,
        isLoading: applicationUsage.isLoading
      )
    case .activity:
      InteractionHeatmapCard(
        aggregates: input.aggregates,
        range: effectiveRange,
        isLoading: input.isLoading,
        loadFailed: input.loadFailed,
        boundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
      )
    case .keyboard:
      KeyboardHeatmapCard(
        counts: input.keyboardCounts,
        isLoading: input.isLoading,
        loadFailed: input.loadFailed,
        liveStatus: input.liveStatus,
        isLiveEnabled: input.keyboardLiveEnabled,
        updatesLive: range == .today,
        layoutProfile: KeyboardPhysicalLayoutProfile.preferred(from: runtime.snapshot.displays)
      )
    case .mouse:
      PointerHeatmapCard(
        displays: input.pointerDisplays,
        loadedDayPresentation: input.selectedPointerDayPresentation,
        previewCanvas: PointerHeatmapPreviewCanvas.preferred(from: runtime.snapshot.displays),
        rangeTitle: range.rawValue,
        isLoading: input.isLoading,
        isHistoryLoading: input.isPointerHistoryLoading,
        loadFailed: !isPointerDayBrowsing
          && (input.loadFailed || input.pointerPresentationFailed),
        historyLoadFailed: input.pointerHistoryLoadFailed,
        liveStatus: input.liveStatus,
        isLiveEnabled: input.pointerLiveEnabled,
        updatesLive: range == .today && !isPointerDayBrowsing,
        scope: pointerScope,
        metric: pointerMetric,
        selectedDay: pointerSelectedDay
      )
    }
  }

  /// A selected logical day is a self-contained historical aggregate. The
  /// global range must neither appear nor drive background refresh work in
  /// this mode, otherwise the two controls describe conflicting filters.
  private var isPointerDayBrowsing: Bool {
    selection == .mouse && pointerScope == .day
  }
}

private struct ApplicationInputDetailCard: View {
  let applicationUsage: ApplicationUsagePresentation
  let inputAggregates: [InputAggregate]
  let isLoading: Bool
  let inputLoadFailed: Bool

  private var presentation: Result<ApplicationInputDetailPresentation, Error> {
    Result {
      try ApplicationInputDetailPresentationAdapter.make(
        applicationUsage: applicationUsage,
        inputAggregates: inputAggregates
      )
    }
  }

  var body: some View {
    DaydayCard("应用与输入明细", systemImage: "rectangle.3.group") {
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    if inputLoadFailed || applicationUsage.state == .failure {
      EmptyState(
        title: "无法读取应用与输入明细",
        detail: "没有显示可能不完整的合并统计；下次刷新时会再次读取本地事实。",
        systemImage: "exclamationmark.triangle"
      )
    } else {
      switch presentation {
      case .success(let value):
        switch value.state {
        case .failure:
          EmptyState(
            title: "无法读取应用与输入明细",
            detail: "本地应用事实暂不可用；没有显示部分合并结果。",
            systemImage: "exclamationmark.triangle"
          )
        case .empty where isLoading:
          EmptyState(
            title: "正在读取本地明细…",
            detail: "只读取已保存的前台应用事实与输入聚合。",
            systemImage: "rectangle.3.group"
          )
        case .empty:
          EmptyState(
            title: "尚无应用与输入明细",
            detail: "启用相应采集并完成系统授权后，这里会显示真实的前台应用事实和粗粒度输入总数。",
            systemImage: "rectangle.3.group"
          )
        case .populated, .partial:
          details(value)
        }
      case .failure:
        EmptyState(
          title: "无法安全汇总应用与输入明细",
          detail: "没有显示可能溢出或失真的部分统计；下次刷新时会再次读取本地事实。",
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  private func details(_ value: ApplicationInputDetailPresentation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if value.state == .partial {
        Label("前台应用事实不完整；以下仅显示已保存的部分事实。", systemImage: "exclamationmark.circle")
          .font(.caption.weight(.medium))
          .foregroundStyle(.orange)
          .accessibilityLabel("前台应用事实不完整，以下仅显示已保存的部分事实")
      }
      Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
        GridRow {
          detailValue(value.foregroundDuration.durationText, label: "已观测前台时长")
          detailValue(value.noForegroundFactDuration.durationText, label: "未观测前台时段")
          detailValue("\(value.applicationSwitchCount)", label: "应用切换")
        }
        GridRow {
          liveDetailValue("\(value.input.keyCount)", label: "键位按下（不含重复）")
          liveDetailValue("\(value.input.clickCount)", label: "点击总数")
          liveDetailValue("\(value.input.scrollCount)", label: "滚动动作")
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func detailValue(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title3.weight(.semibold).monospacedDigit())
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func liveDetailValue(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.title3.weight(.semibold).monospacedDigit())
        .daydayLiveMetricValue(value)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct InteractionHeatmapCard: View {
  let aggregates: [InputAggregate]
  let range: Range<Date>
  let isLoading: Bool
  let loadFailed: Bool
  let boundary: WorkdayBoundary

  private var presentation: Result<InteractionHeatmapPresentation, Error> {
    Result {
      try InteractionHeatmapPresentationAdapter.make(from: aggregates, in: range, boundary: boundary)
    }
  }

  var body: some View {
    DaydayCard("键鼠活动分布", systemImage: "calendar.day.timeline.leading") {
      if loadFailed {
        EmptyState(
          title: "无法读取本地交互聚合", detail: "采集已保持停止；可在下次刷新时重试。", systemImage: "exclamationmark.triangle"
        )
      } else {
        switch presentation {
        case .success(let value) where !value.days.isEmpty:
          InteractionHeatmap(presentation: value)
        case .success:
          EmptyState(
            title: isLoading ? "正在读取本地聚合…" : "尚无可展示的逻辑日",
            detail: "启用键盘或鼠标聚合并授权输入监控后，已观测键位、点击与滚动会显示在这里。",
            systemImage: "calendar.badge.questionmark")
        case .failure:
          EmptyState(
            title: "无法安全汇总交互时段", detail: "没有显示可能失真的部分统计；可在下次刷新时重试。",
            systemImage: "exclamationmark.triangle")
        }
      }
    }
  }
}

private struct InteractionHeatmap: View {
  let presentation: InteractionHeatmapPresentation
  @State private var hoveredCell: HoveredCell?

  private struct HoveredCell: Hashable {
    let day: Date
    let hour: Int
    let detail: String
  }

  private struct RevealID: Hashable {
    let firstDay: Date?
    let dayCount: Int
  }

  private var nonzeroValues: [UInt64] {
    presentation.days.flatMap(\.cells).map(\.interactionCount).filter { $0 > 0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 24) {
        heatValue("\(presentation.interactionCount)", label: "键鼠动作")
        heatValue("\(presentation.activeDayCount) 天", label: "有交互的逻辑日")
        heatValue("\(presentation.objectiveRecordCount)", label: "客观聚合记录")
      }
      DaydayHeatmapHoverSummary(
        text: hoveredCell?.detail ?? "将指针移到色块上，查看该时段的准确键鼠动作构成",
        isActive: hoveredCell != nil
      )
      DaydayHeatmapWaveReveal(
        runID: RevealID(
          firstDay: presentation.days.first?.logicalDayStart,
          dayCount: presentation.days.count
        ),
        columnCount: InteractionHeatmapPresentationAdapter.workdayHours.count
      ) { revealProgress, reduceMotion in
        GeometryReader { proxy in
          let layout = InteractionHeatmapLayout(
            availableWidth: proxy.size.width,
            dayCount: presentation.days.count,
            columnCount: presentation.days.first?.cells.count ?? 24
          )
          Grid(alignment: .leading, horizontalSpacing: layout.columnSpacing, verticalSpacing: 3) {
            GridRow {
              Text("逻辑日").frame(width: layout.dayLabelWidth, alignment: .leading)
              ForEach(presentation.days.first?.cells ?? []) { cell in
                Text(String(format: "%02d", cell.hour))
                  .lineLimit(1)
                  .minimumScaleFactor(0.55)
                  .frame(width: layout.cellWidth)
              }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            ForEach(Array(presentation.days.enumerated()), id: \.offset) { rowIndex, day in
              GridRow {
                Text(day.logicalDayStart, format: .dateTime.month().day())
                  .lineLimit(1)
                  .minimumScaleFactor(0.72)
                  .frame(width: layout.dayLabelWidth, alignment: .leading)
                ForEach(Array(day.cells.enumerated()), id: \.element.id) { columnIndex, cell in
                  let detail = activityDetail(for: cell, day: day)
                  RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                    .fill(
                      cell.hasAggregate
                        ? DaydayHeatmapScale.activityColor(
                          tint: .accentColor,
                          value: cell.interactionCount,
                          values: nonzeroValues
                        )
                        : Color.secondary.opacity(DaydayHeatmapScale.emptyOpacity)
                    )
                    .frame(width: layout.cellWidth, height: layout.cellHeight)
                    .overlay {
                      RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                        .stroke(
                          hoveredCell?.day == day.logicalDayStart
                            && hoveredCell?.hour == cell.hour
                            ? Color.primary.opacity(0.48) : .clear,
                          lineWidth: 1
                        )
                    }
                    .overlay {
                      if !cell.hasAggregate {
                        RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                          .stroke(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                      }
                    }
                    .onHover { isHovering in
                      hoveredCell =
                        isHovering
                        ? HoveredCell(
                          day: day.logicalDayStart,
                          hour: cell.hour,
                          detail: detail
                        ) : nil
                    }
                    .help(detail)
                    .accessibilityLabel(detail)
                    .daydayHeatmapWaveCell(
                      revealProgress: revealProgress,
                      column: columnIndex,
                      row: rowIndex,
                      columnCount: day.cells.count,
                      rowStep: layout.cellHeight + 3,
                      reduceMotion: reduceMotion
                    )
                }
              }
            }
          }
          .padding(.horizontal, 2)
        }
        .frame(height: InteractionHeatmapLayout.height(for: presentation.days.count))
      }
      DaydayHeatmapContinuousLegend(
        title: "键鼠活动强度",
        tint: .accentColor,
        maximumLabel: "P90：\(ActivityHeatmapContrast.upperLabel(for: nonzeroValues))",
        unitDetail: "每格一小时 · 当前范围内稳健连续色阶"
      )
    }
  }

  private func heatValue(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title3.weight(.semibold).monospacedDigit())
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func activityDetail(
    for cell: InteractionHeatmapPresentation.Day.Cell,
    day: InteractionHeatmapPresentation.Day
  ) -> String {
    let dayText = day.logicalDayStart.formatted(date: .abbreviated, time: .omitted)
    guard cell.hasAggregate else {
      return "\(dayText)，\(cell.hour) 时：暂无可用交互聚合"
    }
    return "\(dayText)，\(cell.hour) 时：键位按下 \(cell.keyPressCount) 次 · 鼠标按下 \(cell.pointerClickCount) 次 · 滚动 \(cell.scrollActionCount) 次 · 合计 \(cell.interactionCount) 次"
  }
}

/// The activity heatmap must show all 24 logical hours in its card. A previous
/// fixed 37 pt cell width silently pushed the final hours outside the detail
/// column. This layout spends the available width exactly once and never asks
/// the surrounding page to scroll horizontally.
private struct InteractionHeatmapLayout {
  let dayLabelWidth: CGFloat
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  let cornerRadius: CGFloat
  let columnSpacing: CGFloat

  init(availableWidth: CGFloat, dayCount _: Int, columnCount: Int) {
    columnSpacing = 3
    dayLabelWidth = min(78, max(54, availableWidth * 0.12))
    let totalSpacing = CGFloat(max(0, columnCount - 1)) * columnSpacing
    cellWidth = max(10, (availableWidth - dayLabelWidth - totalSpacing - 4) / CGFloat(max(1, columnCount)))
    cellHeight = min(28, max(20, cellWidth * 0.9))
    cornerRadius = min(4, max(2, cellWidth * 0.16))
  }

  static func height(for dayCount: Int) -> CGFloat {
    24 + CGFloat(max(0, dayCount)) * 31 + 8
  }
}

private struct YearInteractionCalendarCard: View {
  let aggregates: [InputAggregate]
  let range: Range<Date>
  let rangeTitle: String
  let isLoading: Bool
  let loadFailed: Bool

  private var presentation: Result<YearInteractionCalendarPresentation, Error> {
    Result {
      try YearInteractionCalendarPresentationAdapter.make(
        from: aggregates,
        in: range,
        timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
      )
    }
  }

  var body: some View {
    DaydayCard("年度日历热力图", systemImage: "calendar") {
      if loadFailed {
        EmptyState(
          title: "无法读取本地交互聚合", detail: "采集已保持停止；可在下次刷新时重试。", systemImage: "exclamationmark.triangle"
        )
      } else {
        switch presentation {
        case .success(let value) where value.activeDayCount > 0:
          YearInteractionCalendar(presentation: value, rangeTitle: rangeTitle)
        case .success:
          EmptyState(
            title: isLoading ? "正在读取本地聚合…" : "尚无检测到交互的时段记录",
            detail: "启用键盘或鼠标聚合并授权输入监控后，真实的粗粒度交互时长会显示在这里。",
            systemImage: "calendar.badge.questionmark")
        case .failure:
          EmptyState(
            title: "无法安全汇总交互时段", detail: "没有显示可能失真的部分统计；可在下次刷新时重试。",
            systemImage: "exclamationmark.triangle")
        }
      }
    }
  }
}

private struct YearInteractionCalendar: View {
  let presentation: YearInteractionCalendarPresentation
  let rangeTitle: String

  private var maximum: UInt64 {
    presentation.days.map(\.detectedInteractionMilliseconds).max() ?? 1
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 24) {
        heatValue(presentation.detectedInteractionMilliseconds.durationText, label: "检测到交互")
        heatValue("\(presentation.activeDayCount) 天", label: "有交互的逻辑日")
        heatValue("\(presentation.objectiveRecordCount)", label: "客观聚合记录")
      }
      YearCalendarGrid(
        days: presentation.days, timeZoneIdentifier: presentation.timeZoneIdentifier,
        maximum: maximum)
    }
  }

  private func heatValue(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title3.weight(.semibold).monospacedDigit())
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Week columns of logical days (Monday first), one column per week.
private struct YearCalendarGrid: View {
  let days: [YearInteractionCalendarPresentation.DayCell]
  let timeZoneIdentifier: String
  let maximum: UInt64
  @State private var hoveredDay: YearInteractionCalendarPresentation.DayCell?

  private struct RevealID: Hashable {
    let firstDay: Date?
    let lastDay: Date?
    let dayCount: Int
  }

  private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

  private var columns: [[YearInteractionCalendarPresentation.DayCell?]] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
    calendar.firstWeekday = 2
    guard let first = days.first else { return [] }
    let leading =
      (calendar.component(.weekday, from: first.logicalDayStart) - calendar.firstWeekday + 7) % 7
    let totalSlots = leading + days.count
    let weekCount = (totalSlots + 6) / 7
    var slots: [YearInteractionCalendarPresentation.DayCell?] = Array(
      repeating: nil, count: weekCount * 7)
    for (index, day) in days.enumerated() {
      slots[leading + index] = day
    }
    return stride(from: 0, to: slots.count, by: 7).map {
      Array(slots[$0..<min($0 + 7, slots.count)])
    }
  }

  var body: some View {
    let columns = self.columns
    VStack(alignment: .leading, spacing: 8) {
      DaydayHeatmapHoverSummary(
        text: hoveredDay.map(dayDetail(for:))
          ?? "将指针移到日期上，查看当天准确的交互时长与记录数",
        isActive: hoveredDay != nil,
        activeSystemImage: "calendar"
      )

      GeometryReader { proxy in
        let horizontalPadding = DaydaySpace.s * 2
        let weekdayWidth: CGFloat = 18
        let gutter = DaydaySpace.s
        let gridWidth = max(
          0,
          proxy.size.width - horizontalPadding - weekdayWidth - gutter
        )
        let layout = DaydayCalendarHeatmapLayout.fitting(
          availableWidth: gridWidth,
          columnCount: columns.count
        )

        HStack(alignment: .top, spacing: gutter) {
          VStack(spacing: layout.rowSpacing) {
            Color.clear.frame(width: weekdayWidth, height: 13)
            ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
              Text(label)
                .font(DaydayType.micro)
                .foregroundStyle(.secondary)
                .frame(width: weekdayWidth, height: layout.cellSize)
            }
          }

          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: layout.columnSpacing) {
              ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                let firstDay = column.compactMap { $0 }.first?.logicalDayStart
                Text(firstDay.map(Self.monthLabel) ?? " ")
                  .font(DaydayType.micro)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: true, vertical: false)
                  .frame(width: layout.cellSize, height: 13, alignment: .leading)
              }
            }

            DaydayHeatmapWaveReveal(
              runID: RevealID(
                firstDay: days.first?.logicalDayStart,
                lastDay: days.last?.logicalDayStart,
                dayCount: days.count
              ),
              columnCount: columns.count
            ) { revealProgress, reduceMotion in
              HStack(alignment: .top, spacing: layout.columnSpacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { columnIndex, column in
                  VStack(spacing: layout.rowSpacing) {
                    ForEach(Array(column.enumerated()), id: \.offset) { rowIndex, slot in
                      if let day = slot {
                        let detail = dayDetail(for: day)
                        RoundedRectangle(
                          cornerRadius: max(1.5, layout.cellSize * 0.22),
                          style: .continuous
                        )
                        .fill(
                          DaydayHeatmapScale.color(
                            tint: .accentColor,
                            value: Double(day.detectedInteractionMilliseconds),
                            maximum: Double(maximum)
                          )
                        )
                        .frame(width: layout.cellSize, height: layout.cellSize)
                        .overlay {
                          RoundedRectangle(
                            cornerRadius: max(1.5, layout.cellSize * 0.22),
                            style: .continuous
                          )
                          .stroke(
                            hoveredDay?.id == day.id
                              ? Color.primary.opacity(0.48) : .clear,
                            lineWidth: 1
                          )
                        }
                        .onHover { isHovering in
                          hoveredDay = isHovering ? day : nil
                        }
                        .help(detail)
                        .accessibilityLabel(detail)
                        .daydayHeatmapWaveCell(
                          revealProgress: revealProgress,
                          column: columnIndex,
                          row: rowIndex,
                          columnCount: columns.count,
                          rowStep: layout.cellSize + layout.rowSpacing,
                          reduceMotion: reduceMotion
                        )
                      } else {
                        Color.clear
                          .frame(
                            width: layout.cellSize,
                            height: layout.cellSize
                          )
                      }
                    }
                  }
                }
              }
            }
          }
        }
        .padding(DaydaySpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 130)
      .background(
        Color.primary.opacity(0.035),
        in: RoundedRectangle(cornerRadius: DaydayRadius.control, style: .continuous)
      )

      DaydayHeatmapContinuousLegend(
        title: "检测到交互",
        tint: .accentColor,
        maximumLabel: maximum.durationText,
        unitDetail: "每格一天 · 连续色阶"
      )
    }
  }

  private static func monthLabel(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated))
  }

  private func dayDetail(for day: YearInteractionCalendarPresentation.DayCell) -> String {
    "\(day.logicalDayStart.formatted(date: .abbreviated, time: .omitted)) · \(day.detectedInteractionMilliseconds.durationText) · \(day.objectiveRecordCount) 条客观聚合记录"
  }
}

private struct TimeTrackingCard: View {
  let presentation: ApplicationUsagePresentation
  let isLoading: Bool

  var body: some View {
    DaydayCard("时段记录", systemImage: "clock") {
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    switch presentation.state {
    case .loading:
      EmptyState(title: "正在读取本地时段…", detail: "只读取已保存的前台应用事实。", systemImage: "clock")
    case .failure:
      EmptyState(
        title: "无法读取本地时段", detail: "采集已保持停止；稍后可再次打开此页重试。", systemImage: "exclamationmark.triangle")
    case .empty:
      EmptyState(
        title: isLoading ? "正在读取本地时段…" : "还没有可计时的前台应用事实",
        detail: "启用“应用与窗口上下文”并完成辅助功能授权后，Dayday 会从真实切换记录构造不重叠时段。",
        systemImage: "clock.badge.questionmark"
      )
    case .populated:
      ApplicationUsageTotals(presentation: presentation)
      if presentation.intervals.last?.isOngoing == true {
        Label("当前前台时段正在实时递增", systemImage: "record.circle.fill")
          .font(.caption.weight(.medium))
          .foregroundStyle(.green)
      }
      Divider()
      Text("最近时段")
        .font(.headline)
      ForEach(Array(presentation.intervals.suffix(10).reversed())) { interval in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(interval.startedAt, format: .dateTime.hour().minute())
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .leading)
          VStack(alignment: .leading, spacing: 2) {
            Text(interval.displayLabel).font(.body.weight(.medium))
            Text(interval.isOngoing ? "仍在前台" : "前台时段结束")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text(interval.duration.durationText)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        if interval.id != presentation.intervals.last?.id { Divider() }
      }
    }
  }
}

private struct ApplicationUsageCard: View {
  private enum VisibleCount: String, CaseIterable, Identifiable {
    case topTen
    case topTwenty
    case all

    var id: Self { self }

    var title: String {
      switch self {
      case .topTen: "Top 10"
      case .topTwenty: "Top 20"
      case .all: "全部"
      }
    }

    func limit(for total: Int) -> Int {
      switch self {
      case .topTen: min(10, total)
      case .topTwenty: min(20, total)
      case .all: total
      }
    }
  }

  let presentation: ApplicationUsagePresentation
  let isLoading: Bool
  @Environment(\.daydayAccent) private var accent
  @State private var chartStyle: ApplicationDurationChartStyle = .bar
  @State private var visibleCount: VisibleCount = .topTen

  var body: some View {
    DaydayCard("应用时长分布", systemImage: "chart.bar.xaxis") {
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    switch presentation.state {
    case .loading:
      EmptyState(
        title: "正在读取本地应用记录…", detail: "只读取已保存的前台应用事实。", systemImage: "macwindow.on.rectangle")
    case .failure:
      EmptyState(
        title: "无法读取本地应用记录", detail: "采集已保持停止；稍后可再次打开此页重试。", systemImage: "exclamationmark.triangle"
      )
    case .empty:
      EmptyState(
        title: isLoading ? "正在读取本地应用记录…" : "还没有应用记录",
        detail: "授权应用使用采集后，将显示真实前台时段与时长分布。",
        systemImage: "macwindow.on.rectangle"
      )
    case .populated:
      ApplicationUsageTotals(presentation: presentation)
      Divider()
      chartControls
      ApplicationDurationChart(
        summaries: Array(
          presentation.summaries.prefix(visibleCount.limit(for: presentation.summaries.count))),
        style: chartStyle
      )
    }
  }

  private var chartControls: some View {
    AdaptiveLeadingTrailingLayout(horizontalSpacing: 16, verticalSpacing: 10) {
      Text("按前台时长分布")
        .font(.headline)
      chartFilters
    }
  }

  private var chartFilters: some View {
    HStack(spacing: 12) {
      HStack(spacing: 6) {
        Text("显示数量")
          .font(.callout)
          .foregroundStyle(.secondary)
        Picker("显示数量", selection: $visibleCount) {
          ForEach(VisibleCount.allCases) { option in
            Text(option.title).tag(option)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 94)
      }
      HStack(spacing: 2) {
        ForEach(ApplicationDurationChartStyle.allCases) { style in
          Button {
            selectChartStyle(style)
          } label: {
            Text(style.rawValue)
              .font(.callout)
              .frame(minWidth: 66)
              .padding(.vertical, 5)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(chartStyle == style ? accent.tint : Color.primary)
          .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(chartStyle == style ? accent.tint.opacity(0.16) : Color.clear)
          }
          .accessibilityAddTraits(chartStyle == style ? .isSelected : [])
        }
      }
      .padding(2)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary.opacity(0.07))
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("图表类型")
    }
  }

  /// A SwiftUI button group avoids the macOS 26 NSSegmentedCell accessibility
  /// re-entrancy path. The deferred mutation also keeps the button's native
  /// press cycle separate from chart visibility updates.
  private func selectChartStyle(_ newStyle: ApplicationDurationChartStyle) {
    guard newStyle != chartStyle else { return }
    Task { @MainActor in
      await Task.yield()
      chartStyle = newStyle
    }
  }
}

private struct ApplicationUsageTotals: View {
  let presentation: ApplicationUsagePresentation

  var body: some View {
    HStack(spacing: 28) {
      usageValue(presentation.trackedDuration.durationText, label: "已观测前台时长")
      usageValue("\(presentation.intervals.count)", label: "前台时段")
      usageValue("\(presentation.summaries.count)", label: "涉及应用")
    }
    .accessibilityElement(children: .combine)
  }

  private func usageValue(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title3.weight(.semibold).monospacedDigit())
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}

extension TimeInterval {
  var durationText: String {
    let total = max(0, Int(rounded()))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    if hours > 0 { return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时" }
    if minutes > 0 { return "\(minutes)分" }
    return "\(seconds)秒"
  }
}

extension UInt64 {
  fileprivate var durationText: String { TimeInterval(Double(self) / 1_000).durationText }
}

private struct KeyboardHeatmapCard: View {
  let counts: [UInt16: UInt64]
  let isLoading: Bool
  let loadFailed: Bool
  let liveStatus: InputCollectionRuntimeStatus
  let isLiveEnabled: Bool
  let updatesLive: Bool
  let layoutProfile: KeyboardPhysicalLayoutProfile

  var body: some View {
    DaydayCard("键盘热图", systemImage: "keyboard") {
      LiveInputStatus(
        status: liveStatus,
        isEnabled: isLiveEnabled,
        updatesLive: updatesLive,
        kind: "键盘"
      )
      if loadFailed {
        EmptyState(
          title: "无法读取本地键盘聚合", detail: "采集已保持停止；可在下次刷新时重试。", systemImage: "exclamationmark.triangle"
        )
      } else if counts.isEmpty {
        EmptyState(
          title: isLoading ? "正在读取本地聚合…" : "尚无键盘聚合数据",
          detail: "在“设置 › 权限”启用键盘聚合并授权输入监控后，真实按键会在此页同步显示；持久化仍每 30 秒进行一次。", systemImage: "keyboard")
      } else {
        // A single keyboard tree stays centred when it fits and scrolls when
        // it does not. ViewThatFits previously built and measured two complete
        // 80-key alternatives on every tab switch.
        DaydayScrollView(.horizontal, showsIndicators: true) {
          PhysicalKeyboardHeatmap(counts: counts, layoutProfile: layoutProfile)
            .containerRelativeFrame(.horizontal, alignment: .center) { available, _ in
              max(available, PhysicalKeyboardHeatmap.minimumContentWidth)
            }
            .padding(.bottom, 4)
        }
        DaydayHeatmapContinuousLegend(
          title: "键位按下（不含重复）",
          tint: .accentColor,
          maximumLabel: (counts.values.max() ?? 0).formatted(),
          unitDetail: "悬浮查看准确次数 · 连续色阶"
        )
        let totalCount = counts.values.reduce(0, +)
        Text("\(totalCount) 次键位按下（不含重复）· 热度采用全局连续色阶；不保存字符或输入顺序。")
          .font(.caption).foregroundStyle(.secondary)
          .daydayLiveMetricValue(totalCount)
        Text(layoutProfile.detail)
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
}

/// A presentation choice only. The input collector receives physical key codes
/// but macOS does not attach an individual keyboard device to each CGEvent tap
/// event, so this never claims to attribute a count to a particular keyboard.
enum KeyboardPhysicalLayoutProfile: Hashable {
  case macBook
  case externalANSI

  static func preferred(from displays: [AppRuntimeDisplay]) -> Self {
    guard
      let builtIn = displays.first(where: { display in
        !display.isMirrored
          && display.isBuiltIn
          && (display.pixelWidth ?? 0) > 0
          && (display.pixelHeight ?? 0) > 0
      }),
      let width = builtIn.pixelWidth,
      let height = builtIn.pixelHeight
    else {
      return .externalANSI
    }

    let aspectRatio = Double(width) / Double(height)
    // MacBook panels across the current Air and Pro families are close to
    // 16:10 / 3:2, whereas current iMac built-in panels are wider. This is
    // deliberately a conservative visual default, not a device identity.
    return (1.45...1.65).contains(aspectRatio) ? .macBook : .externalANSI
  }

  var showsTouchID: Bool {
    self == .macBook
  }

  var detail: String {
    switch self {
    case .macBook:
      "已按本机内建 MacBook Magic Keyboard 的 ANSI 物理布局展示：12 个全高功能键、右上角 Touch ID，以及倒 T 方向键。检测到外接数字键盘时会单独显示；ISO/JIS 或媒体键会保留在“未映射物理键”中。"
    case .externalANSI:
      "未检测到可作为笔记本基准的内建屏幕，按通用 macOS ANSI 物理布局展示。检测到外接数字键盘时会单独显示；ISO/JIS 或媒体键会保留在“未映射物理键”中。"
    }
  }
}

private struct PhysicalKeyboardHeatmap: View {
  let counts: [UInt16: UInt64]
  let layoutProfile: KeyboardPhysicalLayoutProfile
  // Keep the MacBook footprint on a stable canvas. Every row can then meet
  // the same left and right edges without moving the keyboard itself away
  // from the centre of the heatmap card.
  private static let keyUnit: CGFloat = 34
  private static let keyGap: CGFloat = 7
  private static let keyboardCanvasWidth: CGFloat = 588
  static let minimumContentWidth: CGFloat = keyboardCanvasWidth

  private struct Key: Identifiable {
    let label: String
    let code: UInt16
    let width: CGFloat
    let recordsInput: Bool

    var id: UInt16 { code }

    init(label: String, code: UInt16, width: CGFloat, recordsInput: Bool = true) {
      self.label = label
      self.code = code
      self.width = width
      self.recordsInput = recordsInput
    }
  }

  // This follows the current MacBook Air / Pro Magic Keyboard footprint.
  // Hardware key codes remain the source of truth; the diagram only gives
  // those codes their physical position and never derives typed characters.
  private var rows: [[Key]] {
    var layout: [[Key]] = [
      [
        .init(label: "esc", code: 53, width: 1.1), .init(label: "F1", code: 122, width: 1),
        .init(label: "F2", code: 120, width: 1), .init(label: "F3", code: 99, width: 1),
        .init(label: "F4", code: 118, width: 1), .init(label: "F5", code: 96, width: 1),
        .init(label: "F6", code: 97, width: 1), .init(label: "F7", code: 98, width: 1),
        .init(label: "F8", code: 100, width: 1), .init(label: "F9", code: 101, width: 1),
        .init(label: "F10", code: 109, width: 1), .init(label: "F11", code: 103, width: 1),
        .init(label: "F12", code: 111, width: 1),
      ],
      [
        .init(label: "`", code: 50, width: 1), .init(label: "1", code: 18, width: 1),
        .init(label: "2", code: 19, width: 1), .init(label: "3", code: 20, width: 1),
        .init(label: "4", code: 21, width: 1), .init(label: "5", code: 23, width: 1),
        .init(label: "6", code: 22, width: 1), .init(label: "7", code: 26, width: 1),
        .init(label: "8", code: 28, width: 1), .init(label: "9", code: 25, width: 1),
        .init(label: "0", code: 29, width: 1), .init(label: "-", code: 27, width: 1),
        .init(label: "=", code: 24, width: 1), .init(label: "delete", code: 51, width: 1.55),
      ],
      [
        .init(label: "tab", code: 48, width: 1.5), .init(label: "Q", code: 12, width: 1),
        .init(label: "W", code: 13, width: 1), .init(label: "E", code: 14, width: 1),
        .init(label: "R", code: 15, width: 1), .init(label: "T", code: 17, width: 1),
        .init(label: "Y", code: 16, width: 1), .init(label: "U", code: 32, width: 1),
        .init(label: "I", code: 34, width: 1), .init(label: "O", code: 31, width: 1),
        .init(label: "P", code: 35, width: 1), .init(label: "[", code: 33, width: 1),
        .init(label: "]", code: 30, width: 1), .init(label: "\\", code: 42, width: 1),
      ],
      [
        .init(label: "caps", code: 57, width: 1.75), .init(label: "A", code: 0, width: 1),
        .init(label: "S", code: 1, width: 1), .init(label: "D", code: 2, width: 1),
        .init(label: "F", code: 3, width: 1), .init(label: "G", code: 5, width: 1),
        .init(label: "H", code: 4, width: 1), .init(label: "J", code: 38, width: 1),
        .init(label: "K", code: 40, width: 1), .init(label: "L", code: 37, width: 1),
        .init(label: ";", code: 41, width: 1), .init(label: "'", code: 39, width: 1),
        .init(label: "return", code: 36, width: 1.85),
      ],
      [
        .init(label: "shift", code: 56, width: 2.2), .init(label: "Z", code: 6, width: 1),
        .init(label: "X", code: 7, width: 1), .init(label: "C", code: 8, width: 1),
        .init(label: "V", code: 9, width: 1), .init(label: "B", code: 11, width: 1),
        .init(label: "N", code: 45, width: 1), .init(label: "M", code: 46, width: 1),
        .init(label: ",", code: 43, width: 1), .init(label: ".", code: 47, width: 1),
        .init(label: "/", code: 44, width: 1), .init(label: "shift", code: 60, width: 2.2),
      ],
    ]
    if layoutProfile.showsTouchID {
      layout[0].append(.init(label: "Touch ID", code: .max, width: 1.5, recordsInput: false))
    }
    return layout
  }

  private let bottomRow: [Key] = [
    .init(label: "fn", code: 63, width: 1.1),
    .init(label: "ctrl", code: 59, width: 1.15),
    .init(label: "opt", code: 58, width: 1.15),
    .init(label: "⌘", code: 55, width: 1.3),
    .init(label: "space", code: 49, width: 5.35),
    .init(label: "⌘", code: 54, width: 1.3),
    .init(label: "opt", code: 61, width: 1.15),
  ]

  private let numericPad: [[Key]] = [
    [
      .init(label: "clear", code: 71, width: 1), .init(label: "=", code: 81, width: 1),
      .init(label: "÷", code: 75, width: 1), .init(label: "×", code: 67, width: 1),
    ],
    [
      .init(label: "7", code: 89, width: 1), .init(label: "8", code: 91, width: 1),
      .init(label: "9", code: 92, width: 1), .init(label: "−", code: 78, width: 1),
    ],
    [
      .init(label: "4", code: 86, width: 1), .init(label: "5", code: 87, width: 1),
      .init(label: "6", code: 88, width: 1), .init(label: "+", code: 69, width: 1),
    ],
    [
      .init(label: "1", code: 83, width: 1), .init(label: "2", code: 84, width: 1),
      .init(label: "3", code: 85, width: 1), .init(label: "enter", code: 76, width: 1),
    ],
    [
      .init(label: "0", code: 82, width: 2), .init(label: ".", code: 65, width: 1),
    ],
  ]

  private var mappedCodes: Set<UInt16> {
    Set(
      (rows + [bottomRow] + numericPad).flatMap { row in
        row.compactMap { $0.recordsInput ? $0.code : nil }
      }
    )
    .union([123, 124, 125, 126])
  }
  private var unknownKeys: [(code: UInt16, count: UInt64)] {
    counts.filter { !mappedCodes.contains($0.key) }
      .map { (code: $0.key, count: $0.value) }
      .sorted { $0.count > $1.count }
  }

  var body: some View {
    let maximum = counts.values.max() ?? 1
    VStack(alignment: .leading, spacing: 7) {
      VStack(alignment: .leading, spacing: Self.keyGap) {
        ForEach(rows.indices, id: \.self) { row in
          HStack(spacing: rowSpacing(for: rows[row])) {
            ForEach(rows[row]) { key in
              keycap(for: key, maximum: maximum)
            }
          }
          .frame(width: Self.keyboardCanvasWidth, alignment: .leading)
        }
        HStack(alignment: .bottom, spacing: bottomRowSpacing) {
          ForEach(bottomRow) { key in
            keycap(for: key, maximum: maximum)
          }
          MacBookArrowCluster(counts: counts, maximum: maximum)
        }
        .frame(width: Self.keyboardCanvasWidth, alignment: .leading)
      }
      .frame(width: Self.keyboardCanvasWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      if numericPad.flatMap({ $0 }).contains(where: { counts[$0.code, default: 0] > 0 }) {
        VStack(alignment: .leading, spacing: 5) {
          Text("数字键盘").font(.caption.weight(.medium))
          VStack(alignment: .leading, spacing: 5) {
            ForEach(numericPad.indices, id: \.self) { row in
              HStack(spacing: 5) {
                ForEach(numericPad[row]) { key in
                  keycap(for: key, maximum: maximum)
                }
              }
            }
          }
          .padding(.top, 4)
        }
      }
      if !unknownKeys.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("未映射物理键").font(.caption.weight(.medium))
          Text(
            unknownKeys.prefix(8).map { "代码 \($0.code)：\($0.count) 次" }.joined(separator: " · ")
          )
          .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
          Text("这通常来自数字键盘、ISO/JIS 差异或媒体键；统计仍保留，但不把未知代码伪装成键帽。")
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("键盘热图")
    .accessibilityValue(
      "共 \(counts.values.reduce(0, +)) 次键位按下（不含重复）；颜色越深，表示相对使用次数越高。"
    )
  }

  @ViewBuilder
  private func keycap(
    for key: Key,
    maximum: UInt64
  ) -> some View {
    KeyboardKeycap(
      label: key.label,
      count: key.recordsInput ? counts[key.code, default: 0] : nil,
      width: key.width,
      maximum: maximum
    )
  }

  private func rowSpacing(for row: [Key]) -> CGFloat {
    guard row.count > 1 else { return 0 }
    let keyWidth = row.reduce(CGFloat.zero) { $0 + (Self.keyUnit * $1.width) }
    return max(0, (Self.keyboardCanvasWidth - keyWidth) / CGFloat(row.count - 1))
  }

  private var bottomRowSpacing: CGFloat {
    let bottomKeyWidth = bottomRow.reduce(CGFloat.zero) { $0 + (Self.keyUnit * $1.width) }
    // The arrow cluster spans three physical key columns and two internal gaps.
    let arrowClusterWidth = (Self.keyUnit * 3) + (Self.keyGap * 2)
    return max(
      0, (Self.keyboardCanvasWidth - bottomKeyWidth - arrowClusterWidth) / CGFloat(bottomRow.count))
  }
}

private struct MacBookArrowCluster: View {
  let counts: [UInt16: UInt64]
  let maximum: UInt64

  var body: some View {
    HStack(alignment: .bottom, spacing: 7) {
      keycap("←", code: 123, height: 17)
      VStack(spacing: 3) {
        keycap("↑", code: 126, height: 16)
        keycap("↓", code: 125, height: 17)
      }
      keycap("→", code: 124, height: 17)
    }
  }

  private func keycap(_ label: String, code: UInt16, height: CGFloat = 36) -> some View {
    KeyboardKeycap(
      label: label,
      count: counts[code, default: 0],
      width: 1,
      height: height,
      maximum: maximum
    )
  }
}

private struct KeyboardKeycap: View {
  let label: String
  let count: UInt64?
  let width: CGFloat
  var height: CGFloat = 36
  let maximum: UInt64

  var body: some View {
    Text(label)
      .font((height < 24 ? Font.system(size: 8) : .caption2).monospaced().weight(.medium))
      .lineLimit(1)
      .frame(width: 34 * width, height: height)
      .background(
        DaydayHeatmapScale.color(
          tint: .accentColor,
          value: Double(count ?? 0),
          maximum: Double(maximum)
        ),
        in: RoundedRectangle(cornerRadius: 5)
      )
      .accessibilityLabel(count.map { "物理键位 \(label)，\($0) 次" } ?? "\(label) 键")
      .help(count.map { "物理键位 \(label)：\($0) 次" } ?? label)
  }
}

private enum PointerHeatmapScope: String, CaseIterable, Identifiable {
  case all = "总览"
  case day = "按日"
  var id: Self { self }
}

/// The visual canvas for a normalized pointer heatmap. It deliberately uses
/// live display inventory only for presentation; aggregate input data retains
/// no physical display identity or raw coordinates.
struct PointerHeatmapPreviewCanvas: Equatable {
  enum Source: Equatable {
    case builtIn
    case main
    case connected

    var label: String {
      switch self {
      case .builtIn: "内建显示器"
      case .main: "主显示器"
      case .connected: "已连接显示器"
      }
    }
  }

  let pixelWidth: Int
  let pixelHeight: Int
  let source: Source

  var aspectRatio: CGFloat {
    CGFloat(pixelWidth) / CGFloat(pixelHeight)
  }

  var label: String {
    "\(source.label) \(pixelWidth) × \(pixelHeight) 像素"
  }

  static func preferred(from displays: [AppRuntimeDisplay]) -> Self? {
    let candidates = displays.filter {
      !$0.isMirrored
        && ($0.pixelWidth ?? 0) > 0
        && ($0.pixelHeight ?? 0) > 0
    }
    guard
      let display = candidates.first(where: \.isBuiltIn)
        ?? candidates.first(where: \.isMain)
        ?? candidates.first
    else {
      return nil
    }

    guard let rawWidth = display.pixelWidth, let rawHeight = display.pixelHeight else {
      return nil
    }
    let isQuarterTurn = abs(display.rotationDegrees.truncatingRemainder(dividingBy: 180)) == 90
    return PointerHeatmapPreviewCanvas(
      pixelWidth: isQuarterTurn ? rawHeight : rawWidth,
      pixelHeight: isQuarterTurn ? rawWidth : rawHeight,
      source: display.isBuiltIn ? .builtIn : (display.isMain ? .main : .connected)
    )
  }
}

private enum PointerHeatmapMetric: String, CaseIterable, Identifiable, Hashable {
  case clicks = "点击"
  case dwell = "停留"
  var id: Self { self }
}

private struct PointerHeatmapCard: View {
  let displays: [PointerHeatmapPresentation]
  let loadedDayPresentation: PointerDayHeatmapPresentation?
  let previewCanvas: PointerHeatmapPreviewCanvas?
  let rangeTitle: String
  let isLoading: Bool
  let isHistoryLoading: Bool
  let loadFailed: Bool
  let historyLoadFailed: Bool
  let liveStatus: InputCollectionRuntimeStatus
  let isLiveEnabled: Bool
  let updatesLive: Bool
  let scope: PointerHeatmapScope
  let metric: PointerHeatmapMetric
  let selectedDay: Date?

  var body: some View {
    DaydayCard("鼠标热图", systemImage: "computermouse") {
      LiveInputStatus(
        status: liveStatus,
        isEnabled: isLiveEnabled,
        updatesLive: updatesLive,
        kind: "鼠标"
      )
      if loadFailed {
        EmptyState(
          title: "无法读取或安全汇总鼠标聚合", detail: "没有显示可能失真的部分统计；可在下次刷新时重试。",
          systemImage: "exclamationmark.triangle")
      } else if scope == .day, historyLoadFailed {
        EmptyState(
          title: "无法读取按日鼠标聚合", detail: "总览仍可使用；下次进入或刷新此页时会再次读取本地历史。",
          systemImage: "exclamationmark.triangle")
      } else if scope == .day, isHistoryLoading, selectedDayPresentation == nil {
        EmptyState(
          title: "正在读取历史鼠标聚合…", detail: "按日视图读取保留期内的本地聚合，不读取原始鼠标轨迹。",
          systemImage: "calendar.badge.clock")
      } else if let presentation = activePresentation {
        DisplayHeatmap(
          display: presentation.display,
          title: activeTitle,
          metric: metric,
          previewCanvas: previewCanvas
        )
        .equatable()
      } else if scope == .day {
        EmptyState(
          title: "所选日期没有鼠标聚合", detail: "可在右上角选择保留期内的其它工作日，或切换回总览。",
          systemImage: "calendar.badge.clock")
      } else {
        EmptyState(
          title: isLoading ? "正在读取本地聚合…" : "尚无鼠标聚合数据",
          detail: "在“设置 › 权限”启用鼠标聚合并授权输入监控后，真实点击会在此页同步显示；持久化仍每 30 秒进行一次。",
          systemImage: "cursorarrow.motionlines")
      }
    }
  }

  private var activePresentation: PointerHeatmapPresentation? {
    switch scope {
    case .all: displays.first
    case .day: selectedDayPresentation.map { PointerHeatmapPresentation(display: $0.display) }
    }
  }

  private var activeTitle: String {
    switch scope {
    case .all: return "\(rangeTitle) · 全显示器合并"
    case .day:
      return selectedDayPresentation.map { "\(Self.dayTitle(for: $0)) · 按日聚合" } ?? "所选日期"
    }
  }

  private var selectedDayPresentation: PointerDayHeatmapPresentation? {
    guard loadedDayPresentation?.logicalDayStart == selectedDay else { return nil }
    return loadedDayPresentation
  }

  private static func dayTitle(for day: PointerDayHeatmapPresentation) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: day.timeZoneIdentifier)
    return formatter.string(from: day.logicalDayStart)
  }
}

private struct LiveInputStatus: View {
  let status: InputCollectionRuntimeStatus
  let isEnabled: Bool
  let updatesLive: Bool
  let kind: String

  private var presentation: (title: String, systemImage: String, color: Color) {
    if status == .running, isEnabled, updatesLive {
      return ("实时统计中 · 最新聚合会同步显示", "record.circle.fill", .green)
    }
    if status == .running, isEnabled {
      return ("历史范围使用缓存 · 切换到今日可查看实时更新", "clock.arrow.circlepath", .secondary)
    }
    if status == .running {
      return ("\(kind)聚合未启用", "pause.circle", .secondary)
    }
    switch status {
    case .waitingForConsent:
      return ("等待在设置中启用", "checkmark.shield", .secondary)
    case .waitingForInputMonitoring:
      return ("等待 macOS 输入监控授权", "lock", .orange)
    case .pausedForPrivacy:
      return ("为保护隐私，实时统计已暂停", "hand.raised", .secondary)
    case .unavailable:
      return ("实时统计暂不可用", "exclamationmark.triangle", .orange)
    case .idle:
      return ("正在连接实时统计", "circle.dotted", .secondary)
    case .running:
      preconditionFailure("Running state is handled above")
    }
  }

  var body: some View {
    Label(presentation.title, systemImage: presentation.systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(presentation.color)
      .accessibilityLabel(presentation.title)
  }
}

private struct DisplayHeatmap: View, Equatable {
  let display: DisplayInputAggregate
  let title: String
  let metric: PointerHeatmapMetric
  let previewCanvas: PointerHeatmapPreviewCanvas?
  @State private var hoveredCell: PointerHeatmapHoveredCell?

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.display == rhs.display
      && lhs.title == rhs.title
      && lhs.metric == rhs.metric
      && lhs.previewCanvas == rhs.previewCanvas
  }

  /// Pointer coordinates are collected as a normalized 32×24 grid. The
  /// current preferred display is only a visual aspect-ratio reference; it
  /// never claims to restore a physical multi-display arrangement.
  private static let maximumPreviewWidth: CGFloat = 680

  private var previewAspectRatio: CGFloat {
    previewCanvas?.aspectRatio
      ?? CGFloat(display.grid.columns) / CGFloat(display.grid.rows)
  }

  private var previewLabel: String {
    previewCanvas?.label ?? "归一化网格预览"
  }

  var body: some View {
    let renderData = PointerHeatmapRenderData(display: display)
    let values = renderData.values(for: metric)
    let maximum = renderData.maximum(for: metric)
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 8) {
        DaydayHeatmapHoverSummary(
          text: hoveredCell.map {
            "归一化网格第 \($0.row + 1) 行、第 \($0.column + 1) 列 · \(metricLabel($0.value))"
          } ?? "将指针移到网格上，查看该区域的准确聚合值",
          isActive: hoveredCell != nil,
          activeSystemImage: "cursorarrow.motionlines"
        )

        PointerHeatmapCanvas(
          values: values,
          columns: renderData.columns,
          rows: renderData.rows,
          maximum: maximum,
          hoveredCell: $hoveredCell
        )
        .aspectRatio(previewAspectRatio, contentMode: .fit)
        .padding(6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)鼠标热图")
        .accessibilityValue(heatmapAccessibilityValue(renderData: renderData))
        .accessibilityHint(
          "以\(previewLabel)比例显示。颜色越深，表示相对此图最大值的\(metric == .clicks ? "点击次数" : "停留时长")越高。")
        DaydayHeatmapContinuousLegend(
          title: metric == .clicks ? "区域点击次数" : "区域停留时长",
          tint: .accentColor,
          maximumLabel: metricLabel(maximum),
          unitDetail: "\(previewLabel) · 连续色阶"
        )
      }
      .frame(maxWidth: Self.maximumPreviewWidth)
      .frame(maxWidth: .infinity)
      Text(
        "左键 \(display.pointer.clicks.left) · 右键 \(display.pointer.clicks.right) · 滚动动作 \(display.pointer.scrollEventCount) · 滚动步进 \(display.pointer.scroll.up + display.pointer.scroll.down + display.pointer.scroll.left + display.pointer.scroll.right) · 移动约 \(Double(display.pointer.estimatedDistanceMilliPoints) / 1_000, format: .number.precision(.fractionLength(1))) 点"
      )
      .font(.caption).foregroundStyle(.secondary)
      .daydayLiveMetricValue(pointerMetricIdentity)
    }
  }

  private func metricLabel(_ value: UInt64) -> String {
    switch metric {
    case .clicks: "\(value) 次点击"
    case .dwell: TimeInterval(Double(value) / 1_000).durationText + " 停留"
    }
  }

  private var pointerMetricIdentity: String {
    [
      display.pointer.clicks.left,
      display.pointer.clicks.right,
      display.pointer.clicks.other,
      display.pointer.scroll.up,
      display.pointer.scroll.down,
      display.pointer.scroll.left,
      display.pointer.scroll.right,
      display.pointer.estimatedDistanceMilliPoints,
    ].map(String.init).joined(separator: "-")
  }

  private func heatmapAccessibilityValue(renderData: PointerHeatmapRenderData) -> String {
    switch metric {
    case .clicks:
      return
        "共 \(display.pointer.clicks.left + display.pointer.clicks.right + display.pointer.clicks.other) 次点击；\(Int(display.grid.rows)) 行、\(Int(display.grid.columns)) 列。"
    case .dwell:
      return
        "\(TimeInterval(Double(renderData.totalDwellMilliseconds) / 1_000).durationText) 停留；\(renderData.rows) 行、\(renderData.columns) 列。"
    }
  }
}

private struct PointerHeatmapHoveredCell: Equatable {
  let row: Int
  let column: Int
  let value: UInt64
}

private struct PointerHeatmapRenderData {
  let columns: Int
  let rows: Int
  let clickValues: [UInt64]
  let dwellValues: [UInt64]
  let clickMaximum: UInt64
  let dwellMaximum: UInt64
  let totalDwellMilliseconds: UInt64

  init(display: DisplayInputAggregate) {
    columns = Int(display.grid.columns)
    rows = Int(display.grid.rows)
    let cells = Dictionary(
      uniqueKeysWithValues: display.grid.cells.map {
        ($0.row * display.grid.columns + $0.column, $0)
      })
    var clicks: [UInt64] = []
    var dwell: [UInt64] = []
    clicks.reserveCapacity(max(0, columns * rows))
    dwell.reserveCapacity(max(0, columns * rows))
    for index in 0..<max(0, columns * rows) {
      guard columns > 0 else { break }
      let key = UInt16(index / columns) * display.grid.columns + UInt16(index % columns)
      let cell = cells[key]
      clicks.append(
        Self.saturatedAdd(
          Self.saturatedAdd(cell?.clicks.left ?? 0, cell?.clicks.right ?? 0),
          cell?.clicks.other ?? 0
        )
      )
      dwell.append(cell?.dwellMilliseconds ?? 0)
    }
    clickValues = clicks
    dwellValues = dwell
    clickMaximum = clicks.max() ?? 1
    dwellMaximum = dwell.max() ?? 1
    totalDwellMilliseconds = dwell.reduce(0, Self.saturatedAdd)
  }

  func values(for metric: PointerHeatmapMetric) -> [UInt64] {
    metric == .clicks ? clickValues : dwellValues
  }

  func maximum(for metric: PointerHeatmapMetric) -> UInt64 {
    metric == .clicks ? clickMaximum : dwellMaximum
  }

  private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
  }
}

private struct PointerHeatmapCanvas: View {
  let values: [UInt64]
  let columns: Int
  let rows: Int
  let maximum: UInt64
  @Binding var hoveredCell: PointerHeatmapHoveredCell?

  var body: some View {
    GeometryReader { proxy in
      Canvas { context, size in
        guard columns > 0, rows > 0 else { return }
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        for row in 0..<rows {
          for column in 0..<columns {
            let valueIndex = row * columns + column
            let value = values.indices.contains(valueIndex) ? values[valueIndex] : 0
            let rect = CGRect(
              x: CGFloat(column) * cellWidth,
              y: CGFloat(row) * cellHeight,
              width: cellWidth,
              height: cellHeight
            ).insetBy(dx: 0.5, dy: 0.5)
            context.fill(
              Path(rect),
              with: .color(
                DaydayHeatmapScale.color(
                  tint: .accentColor,
                  value: Double(value),
                  maximum: Double(maximum)
                )))
          }
        }
      }
      .contentShape(Rectangle())
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let location):
          updateHover(at: location, size: proxy.size)
        case .ended:
          if hoveredCell != nil { hoveredCell = nil }
        }
      }
    }
  }

  private func updateHover(at location: CGPoint, size: CGSize) {
    guard columns > 0, rows > 0, size.width > 0, size.height > 0 else {
      hoveredCell = nil
      return
    }
    let column = min(columns - 1, max(0, Int(location.x / size.width * CGFloat(columns))))
    let row = min(rows - 1, max(0, Int(location.y / size.height * CGFloat(rows))))
    let valueIndex = row * columns + column
    let next = PointerHeatmapHoveredCell(
      row: row,
      column: column,
      value: values.indices.contains(valueIndex) ? values[valueIndex] : 0
    )
    if hoveredCell != next { hoveredCell = next }
  }
}
